@preconcurrency import AVFoundation
import Foundation

protocol RecordingServicing: Sendable {
  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession
  func stopRecording() async throws -> URL?
  func discardRecording(at url: URL) async throws
  func cancelRecording() async throws
}

/// マイク入力の唯一の tap を所有し、録音保存と文字起こし用ストリームへ分配します。
actor RecordingService: RecordingServicing {
  private enum Lifecycle {
    case idle
    case starting(UUID)
    case recording(UUID)
  }

  private let audioEngine = AVAudioEngine()
  private var audioFile: AVAudioFile?
  private var sampleContinuation: AsyncThrowingStream<AudioSample, Error>.Continuation?
  private var currentFileURL: URL?
  private var lifecycle: Lifecycle = .idle

  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession {
    guard mode == .microphone else {
      throw AppError.recording("マイク録音サービスに不正な録音モードが指定されました。")
    }
    guard case .idle = lifecycle else {
      throw AppError.recording("すでに録音中です。")
    }

    // 権限ダイアログの待機中は actor が再入可能です。先に開始予約を
    // 取り、二重開始と「キャンセル後に録音が始まる」競合を防ぎます。
    let startID = UUID()
    lifecycle = .starting(startID)

    do {
      return try await prepareAndStartRecording(startID: startID)
    } catch {
      if isStarting(startID) {
        lifecycle = .idle
      }
      throw error
    }
  }

  private func prepareAndStartRecording(
    startID: UUID
  ) async throws -> RecordingSession {
    guard await requestMicrophonePermission() else {
      throw AppError.permissionDenied("マイク")
    }
    try Task.checkCancellation()
    guard isStarting(startID) else {
      throw CancellationError()
    }

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw AppError.recording("利用可能なマイク入力が見つかりません。")
    }

    let fileURL: URL
    do {
      fileURL = try TemporaryRecordingStore.makeURL()
    } catch {
      throw AppError.recording("録音ファイルの保存先を準備できませんでした。")
    }
    let file: AVAudioFile
    do {
      file = try AVAudioFile(
        forWriting: fileURL,
        settings: inputFormat.settings,
        commonFormat: inputFormat.commonFormat,
        interleaved: inputFormat.isInterleaved
      )
    } catch {
      throw AppError.recording("録音ファイルを作成できませんでした。")
    }

    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: AudioSample.self,
      throwing: Error.self,
      bufferingPolicy: .bufferingNewest(64)
    )

    // tap の処理はリアルタイムスレッド上で呼ばれるため、書き込みとコピーだけに
    // 留め、音声認識やUI更新はストリームの消費側で行います。
    inputNode.installTap(
      onBus: 0,
      bufferSize: 4_096,
      format: inputFormat
    ) { buffer, time in
      do {
        try file.write(from: buffer)
        guard let sample = AudioSample(copying: buffer, time: time) else {
          throw AppError.recording("音声バッファをコピーできませんでした。")
        }
        if case .dropped = continuation.yield(sample) {
          // 欠落した音声でAI解析を続けると誤った業務フローを
          // 生成し得るため、無通知で捨てずセッションを失敗させます。
          continuation.finish(
            throwing: AppError.recording(
              "文字起こし用の音声処理が録音に追いつきませんでした。"
            )
          )
        }
      } catch {
        continuation.finish(
          throwing: AppError.recording(
            "録音データの保存中にエラーが発生しました。"
          )
        )
      }
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      continuation.finish(throwing: error)
      try? FileManager.default.removeItem(at: fileURL)
      throw AppError.recording("録音を開始できませんでした。")
    }

    audioFile = file
    sampleContinuation = continuation
    currentFileURL = fileURL
    lifecycle = .recording(startID)

    return RecordingSession(fileURL: fileURL, samples: stream)
  }

  func stopRecording() async throws -> URL? {
    guard case .recording = lifecycle else {
      // startRecording() が権限待ち中なら、その開始予約を無効化します。
      if case .starting = lifecycle {
        lifecycle = .idle
      }
      return currentFileURL
    }

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    sampleContinuation?.finish()

    sampleContinuation = nil
    audioFile = nil
    lifecycle = .idle

    return currentFileURL
  }

  /// 録音は文字起こし中だけの一時データです。解析結果の正本は文字起こしと
  /// 構造化JSONであり、音声は処理完了後に端末へ残しません。
  func discardRecording(at url: URL) async throws {
    do {
      try TemporaryRecordingStore.discard(url)
      if currentFileURL == url {
        currentFileURL = nil
      }
    } catch {
      throw AppError.recording("一時録音ファイルを削除できませんでした。")
    }
  }

  func cancelRecording() async throws {
    guard let url = try await stopRecording() else { return }
    try await discardRecording(at: url)
  }

  private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func isStarting(_ startID: UUID) -> Bool {
    guard case .starting(let currentID) = lifecycle else { return false }
    return currentID == startID
  }

}
