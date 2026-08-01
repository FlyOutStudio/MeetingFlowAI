#if compiler(>=6.2)
  @preconcurrency import AVFoundation
  import CoreMedia
  import Foundation
  import Speech

  /// AVAudioConverterの同期input blockへ1バッファだけを安全に渡します。
  /// Xcode 26ではinput blockがSendableとして検査されるため、ローカルの可変値を
  /// captureせず、ロックで保護した参照型に状態を閉じ込めます。
  private final class ConverterInputSupplier: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(input: AVAudioPCMBuffer) {
      self.input = input
    }

    func next(
      inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
      lock.lock()
      defer { lock.unlock() }

      guard let input else {
        inputStatus.pointee = .noDataNow
        return nil
      }

      self.input = nil
      inputStatus.pointee = .haveData
      return input
    }
  }

  /// macOS 26+ の長時間・オンデバイス文字起こし実装です。
  ///
  /// このファイルはmacOS 26 SDKを含むXcodeでのみコンパイルされます。Deployment
  /// TargetはmacOS 15のまま維持し、古いOSではLegacySpeechServiceを使用します。
  @available(macOS 26.0, *)
  actor SpeechAnalyzerService: SpeechServicing {
    private enum Lifecycle: Equatable {
      case idle
      case starting(UUID)
      case active(UUID)
      case stopping(UUID)
    }

    private struct TranscriptSegment: Sendable {
      let range: CMTimeRange
      let text: String
    }

    private let inputBufferLimit = 256

    private var lifecycle: Lifecycle = .idle
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var updateContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var resultTask: Task<Void, Error>?

    func start(
      locale: Locale
    ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
      guard lifecycle == .idle else {
        throw AppError.speech("文字起こしはすでに開始されています。")
      }

      // アセット取得などのawait中はactorが再入可能です。開始予約を先に確保し、
      // 二重startと「キャンセル後に開始する」競合を防ぎます。
      let sessionID = UUID()
      lifecycle = .starting(sessionID)

      do {
        return try await prepareAndStart(locale: locale, sessionID: sessionID)
      } catch {
        let normalizedError = Self.normalizedSpeechError(
          error,
          context: "SpeechAnalyzerを準備できませんでした。"
        )
        await cleanUpFailedStart(
          sessionID: sessionID,
          error: normalizedError
        )
        throw normalizedError
      }
    }

    private func prepareAndStart(
      locale: Locale,
      sessionID: UUID
    ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
      guard SpeechTranscriber.isAvailable else {
        throw AppError.speech("このMacではSpeechAnalyzerを利用できません。")
      }
      guard
        let supportedLocale = await SpeechTranscriber.supportedLocale(
          equivalentTo: locale
        )
      else {
        throw AppError.speech("選択中の言語はSpeechAnalyzerに対応していません。")
      }
      try ensureStarting(sessionID)

      let transcriber = SpeechTranscriber(
        locale: supportedLocale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: []
      )

      if let installationRequest =
        try await AssetInventory
        .assetInstallationRequest(supporting: [transcriber])
      {
        try await installationRequest.downloadAndInstall()
      }
      try ensureStarting(sessionID)

      guard
        let analyzerFormat =
          await SpeechAnalyzer
          .bestAvailableAudioFormat(compatibleWith: [transcriber])
      else {
        throw AppError.speech("音声認識用の音声形式を取得できませんでした。")
      }
      try ensureStarting(sessionID)

      let analyzer = SpeechAnalyzer(modules: [transcriber])
      try await analyzer.prepareToAnalyze(in: analyzerFormat)
      try ensureStarting(sessionID)

      let (inputStream, inputContinuation) = AsyncStream.makeStream(
        of: AnalyzerInput.self,
        bufferingPolicy: .bufferingOldest(inputBufferLimit)
      )
      let (updateStream, updateContinuation) =
        AsyncThrowingStream.makeStream(
          of: TranscriptUpdate.self,
          throwing: Error.self,
          bufferingPolicy: .bufferingNewest(16)
        )

      self.analyzer = analyzer
      self.transcriber = transcriber
      self.analyzerFormat = analyzerFormat
      self.inputContinuation = inputContinuation
      self.updateContinuation = updateContinuation
      lifecycle = .active(sessionID)

      resultTask = makeResultTask(
        transcriber: transcriber,
        continuation: updateContinuation
      )

      try await analyzer.start(inputSequence: inputStream)
      try ensureActive(sessionID)
      return updateStream
    }

    func append(_ sample: AudioSample) async throws {
      guard
        case .active = lifecycle,
        let analyzerFormat
      else {
        throw AppError.speech("文字起こしが開始されていません。")
      }

      let convertedBuffers = try convert(
        sample.buffer,
        to: analyzerFormat
      )
      for buffer in convertedBuffers where buffer.frameLength > 0 {
        try yieldAnalyzerInput(buffer)
      }
    }

    func finish() async throws {
      guard
        case .active(let sessionID) = lifecycle,
        let analyzer
      else { return }

      lifecycle = .stopping(sessionID)

      do {
        for buffer in try flushAudioConverter() where buffer.frameLength > 0 {
          try yieldAnalyzerInput(buffer)
        }
        inputContinuation?.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultTask?.value

        guard lifecycle == .stopping(sessionID) else {
          throw CancellationError()
        }
        reset()
      } catch {
        let normalizedError = Self.normalizedSpeechError(
          error,
          context: "文字起こしを確定できませんでした。"
        )
        resultTask?.cancel()
        inputContinuation?.finish()
        updateContinuation?.finish(throwing: normalizedError)
        await analyzer.cancelAndFinishNow()
        if lifecycle == .stopping(sessionID) {
          reset()
        }
        throw normalizedError
      }
    }

    func cancel() async {
      switch lifecycle {
      case .idle:
        return
      case .starting:
        // ローカルで準備中のオブジェクトはstart側のcurrent-session確認後に
        // 破棄されます。先に予約を無効化すれば再開は起きません。
        lifecycle = .idle
        return
      case .active(let sessionID):
        lifecycle = .stopping(sessionID)
        inputContinuation?.finish()
        resultTask?.cancel()
        updateContinuation?.finish(throwing: CancellationError())
        await analyzer?.cancelAndFinishNow()
        if lifecycle == .stopping(sessionID) {
          reset()
        }
      case .stopping(let sessionID):
        inputContinuation?.finish()
        resultTask?.cancel()
        updateContinuation?.finish(throwing: CancellationError())
        await analyzer?.cancelAndFinishNow()
        if lifecycle == .stopping(sessionID) {
          reset()
        }
      }
    }

    /// SpeechTranscriberのvolatile結果は、同じ範囲がfinalとして再通知されるとは
    /// 限りません。rangeで置換し、resultsFinalizationTime以前の既存範囲も確定済み
    /// とみなすことで、更新されなかった発話を失わないようにします。
    private func makeResultTask(
      transcriber: SpeechTranscriber,
      continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation
    ) -> Task<Void, Error> {
      Task {
        var segments: [TranscriptSegment] = []
        var finalizationTime = CMTime.zero

        do {
          for try await result in transcriber.results {
            try Task.checkCancellation()

            let text = String(result.text.characters)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            // 一度確定した範囲はSpeechの契約上更新されません。境界を遡る
            // 異常な通知でも確定済みテキストを消さないよう防御します。
            if CMTimeCompare(result.range.start, finalizationTime) >= 0 {
              segments.removeAll {
                Self.overlaps($0.range, result.range)
                  && CMTimeCompare(
                    CMTimeRangeGetEnd($0.range),
                    finalizationTime
                  ) > 0
              }
              if !text.isEmpty {
                segments.append(
                  TranscriptSegment(range: result.range, text: text)
                )
              }
            }
            segments.sort {
              CMTimeCompare($0.range.start, $1.range.start) < 0
            }

            if CMTimeCompare(
              result.resultsFinalizationTime,
              finalizationTime
            ) > 0 {
              finalizationTime = result.resultsFinalizationTime
            }

            let update = Self.transcriptUpdate(
              segments: segments,
              finalizedThrough: finalizationTime
            )
            if case .terminated = continuation.yield(update) {
              throw CancellationError()
            }
          }

          // Analyzerの正常終了時点では残ったvolatile範囲も確定済みです。
          if !segments.isEmpty {
            continuation.yield(
              TranscriptUpdate(
                finalizedText: Self.joined(segments.map(\.text)),
                volatileText: ""
              )
            )
          }
          continuation.finish()
        } catch {
          let normalizedError = Self.normalizedSpeechError(
            error,
            context: "文字起こし結果を取得できませんでした。"
          )
          continuation.finish(throwing: normalizedError)
          throw normalizedError
        }
      }
    }

    /// AVAudioConverterは1入力を複数出力へ分ける場合があります。
    /// inputRanDry/endOfStreamまで取り出し、途中のバッファを捨てません。
    private func convert(
      _ input: AVAudioPCMBuffer,
      to outputFormat: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
      if input.format.isEqual(outputFormat) {
        return [input]
      }

      if let audioConverter {
        guard
          audioConverter.inputFormat.isEqual(input.format),
          audioConverter.outputFormat.isEqual(outputFormat)
        else {
          throw AppError.speech("録音中に音声フォーマットが変更されました。")
        }
      } else {
        audioConverter = AVAudioConverter(
          from: input.format,
          to: outputFormat
        )
      }

      guard let audioConverter else {
        throw AppError.speech("音声フォーマット変換器を作成できませんでした。")
      }

      let rateRatio = outputFormat.sampleRate / input.format.sampleRate
      let capacity = max(
        AVAudioFrameCount(ceil(Double(input.frameLength) * rateRatio)) + 32,
        1
      )
      let inputSupplier = ConverterInputSupplier(input: input)

      return try drainConverter(
        audioConverter,
        outputCapacity: capacity
      ) { _, inputStatus in
        inputSupplier.next(inputStatus: inputStatus)
      }
    }

    /// 変換器が内部に保持した末尾サンプルをendOfStreamで回収します。
    private func flushAudioConverter() throws -> [AVAudioPCMBuffer] {
      guard let audioConverter else { return [] }

      let capacity = max(
        AVAudioFrameCount(audioConverter.outputFormat.sampleRate / 10),
        1
      )
      return try drainConverter(
        audioConverter,
        outputCapacity: capacity
      ) { _, inputStatus in
        inputStatus.pointee = .endOfStream
        return nil
      }
    }

    private func drainConverter(
      _ converter: AVAudioConverter,
      outputCapacity: AVAudioFrameCount,
      inputBlock: @escaping AVAudioConverterInputBlock
    ) throws -> [AVAudioPCMBuffer] {
      var outputs: [AVAudioPCMBuffer] = []

      // 異常なconverter実装で無限ループしないため、十分に大きい上限を設けます。
      for _ in 0..<64 {
        guard
          let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputCapacity
          )
        else {
          throw AppError.speech("変換後の音声バッファを作成できませんでした。")
        }

        var conversionError: NSError?
        let status = converter.convert(
          to: output,
          error: &conversionError,
          withInputFrom: inputBlock
        )

        if output.frameLength > 0 {
          outputs.append(output)
        }

        switch status {
        case .haveData:
          continue
        case .inputRanDry, .endOfStream:
          return outputs
        case .error:
          throw AppError.speech(
            conversionError?.localizedDescription
              ?? "音声フォーマットの変換に失敗しました。"
          )
        @unknown default:
          throw AppError.speech("未知の音声変換状態を受信しました。")
        }
      }

      throw AppError.speech("音声フォーマットの変換が完了しませんでした。")
    }

    private func yieldAnalyzerInput(_ buffer: AVAudioPCMBuffer) throws {
      guard let inputContinuation else {
        throw AppError.speech("文字起こし入力が終了しています。")
      }

      // 入力は連続ストリームです。変換器のprimingで元のAVAudioTimeからずれる
      // 可能性があるため、Analyzer側に連続したtime-codeを割り当てさせます。
      switch inputContinuation.yield(AnalyzerInput(buffer: buffer)) {
      case .enqueued:
        return
      case .dropped:
        throw AppError.speech(
          "音声認識が録音に追いつかず、入力が欠落しました。"
        )
      case .terminated:
        throw CancellationError()
      @unknown default:
        throw AppError.speech("未知の音声入力状態を受信しました。")
      }
    }

    private func ensureStarting(_ sessionID: UUID) throws {
      try Task.checkCancellation()
      guard lifecycle == .starting(sessionID) else {
        throw CancellationError()
      }
    }

    private func ensureActive(_ sessionID: UUID) throws {
      try Task.checkCancellation()
      guard lifecycle == .active(sessionID) else {
        throw CancellationError()
      }
    }

    private func cleanUpFailedStart(
      sessionID: UUID,
      error: AppError
    ) async {
      switch lifecycle {
      case .starting(let currentID) where currentID == sessionID:
        reset()
      case .active(let currentID) where currentID == sessionID:
        lifecycle = .stopping(sessionID)
        inputContinuation?.finish()
        resultTask?.cancel()
        updateContinuation?.finish(throwing: error)
        await analyzer?.cancelAndFinishNow()
        if lifecycle == .stopping(sessionID) {
          reset()
        }
      default:
        // cancel()がすでに同じセッションを破棄済みです。
        break
      }
    }

    private func reset() {
      analyzer = nil
      transcriber = nil
      analyzerFormat = nil
      audioConverter = nil
      inputContinuation = nil
      updateContinuation = nil
      resultTask = nil
      lifecycle = .idle
    }

    nonisolated private static func transcriptUpdate(
      segments: [TranscriptSegment],
      finalizedThrough time: CMTime
    ) -> TranscriptUpdate {
      var finalized: [String] = []
      var volatile: [String] = []

      for segment in segments {
        if CMTimeCompare(CMTimeRangeGetEnd(segment.range), time) <= 0 {
          finalized.append(segment.text)
        } else {
          volatile.append(segment.text)
        }
      }

      return TranscriptUpdate(
        finalizedText: joined(finalized),
        volatileText: joined(volatile)
      )
    }

    nonisolated private static func overlaps(
      _ lhs: CMTimeRange,
      _ rhs: CMTimeRange
    ) -> Bool {
      CMTimeCompare(CMTimeRangeGetEnd(lhs), rhs.start) > 0
        && CMTimeCompare(CMTimeRangeGetEnd(rhs), lhs.start) > 0
    }

    nonisolated private static func joined(_ parts: [String]) -> String {
      parts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    nonisolated private static func normalizedSpeechError(
      _ error: Error,
      context: String
    ) -> AppError {
      if error is CancellationError {
        return .cancelled
      }
      if let appError = error as? AppError {
        return appError
      }

      let details = error.localizedDescription.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      return .speech(details.isEmpty ? context : "\(context) \(details)")
    }
  }
#endif
