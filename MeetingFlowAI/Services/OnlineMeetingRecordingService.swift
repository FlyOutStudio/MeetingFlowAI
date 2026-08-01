@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

enum CapturedAudioSource: CaseIterable, Hashable, Sendable {
  case system
  case microphone
}

/// ScreenCaptureKitのコールバックから所有権を移した音声です。
struct CapturedAudioSample: @unchecked Sendable {
  let source: CapturedAudioSource
  let buffer: AVAudioPCMBuffer
  let presentationTime: CMTime
}

/// システム音声とマイクを同じ時刻軸で合成するオンライン会議用録音です。
actor OnlineMeetingRecordingService: RecordingServicing {
  private enum Lifecycle: Equatable {
    case idle
    case starting(UUID)
    case recording(UUID)
    case stopping(UUID)
  }

  private let sourcePicker: ScreenCaptureSourcePicker

  private var lifecycle: Lifecycle = .idle
  private var stream: SCStream?
  private var streamOutput: ScreenCaptureAudioOutput?
  private var mixer: OnlineTimelineAudioMixer?
  private var mixTask: Task<Void, Error>?
  private var currentFileURL: URL?

  init(sourcePicker: ScreenCaptureSourcePicker = ScreenCaptureSourcePicker()) {
    self.sourcePicker = sourcePicker
  }

  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession {
    guard mode == .onlineMeeting else {
      throw AppError.recording("オンライン録音サービスに不正な録音モードが指定されました。")
    }
    guard lifecycle == .idle else {
      throw AppError.recording("すでに録音中です。")
    }

    let sessionID = UUID()
    lifecycle = .starting(sessionID)

    do {
      guard await requestMicrophonePermission() else {
        throw AppError.permissionDenied("マイク")
      }
      try ensureLifecycle(.starting(sessionID))

      let selectedContent = try await sourcePicker.selectSource()
      try ensureLifecycle(.starting(sessionID))

      let fileURL = try TemporaryRecordingStore.makeURL()
      // 以降の初期化途中で失敗しても、一時ファイルを必ず回収できるよう
      // URLを作成直後に保持します。
      currentFileURL = fileURL
      let (combinedStream, combinedContinuation) =
        AsyncThrowingStream.makeStream(
          of: AudioSample.self,
          throwing: Error.self,
          bufferingPolicy: .bufferingNewest(64)
        )
      let timelineMixer = try OnlineTimelineAudioMixer(
        fileURL: fileURL,
        continuation: combinedContinuation
      )

      let (capturedStream, capturedContinuation) =
        AsyncThrowingStream.makeStream(
          of: CapturedAudioSample.self,
          throwing: Error.self,
          bufferingPolicy: .bufferingOldest(512)
        )
      let output = ScreenCaptureAudioOutput(
        continuation: capturedContinuation
      )
      let configuration = Self.streamConfiguration()
      let captureStream = SCStream(
        filter: selectedContent.filter,
        configuration: configuration,
        delegate: output
      )

      // output追加の途中で失敗した場合もtearDown()で終了できるよう、
      // ScreenCaptureKitへ登録する前にリソースを保持します。
      stream = captureStream
      streamOutput = output
      mixer = timelineMixer

      try captureStream.addStreamOutput(
        output,
        type: .audio,
        sampleHandlerQueue: output.sampleQueue
      )
      try captureStream.addStreamOutput(
        output,
        type: .microphone,
        sampleHandlerQueue: output.sampleQueue
      )

      let mixingTask = Task {
        do {
          for try await sample in capturedStream {
            try Task.checkCancellation()
            try await timelineMixer.ingest(sample)
          }
        } catch {
          await timelineMixer.fail(error)
          throw error
        }
      }

      // startCapture()のawait中にキャンセルされた場合も、同じリソースを
      // cancelRecording()から停止できるよう、開始前に保持します。
      mixTask = mixingTask

      try await captureStream.startCapture()
      try ensureLifecycle(.starting(sessionID))
      lifecycle = .recording(sessionID)

      return RecordingSession(fileURL: fileURL, samples: combinedStream)
    } catch {
      let normalizedError = Self.normalizedError(error)
      await tearDown(
        finishingWith: normalizedError,
        discardFile: true
      )
      if lifecycle == .starting(sessionID) {
        lifecycle = .idle
      }
      throw normalizedError
    }
  }

  func stopRecording() async throws -> URL? {
    guard case .recording(let sessionID) = lifecycle else {
      if case .starting = lifecycle {
        sourcePicker.cancelSelection()
        lifecycle = .idle
      }
      return currentFileURL
    }

    lifecycle = .stopping(sessionID)
    let stoppedURL = currentFileURL

    do {
      streamOutput?.beginExpectedStop()
      try await stream?.stopCapture()
      streamOutput?.finish()
      try await mixTask?.value
      try await mixer?.finish()
      try ensureLifecycle(.stopping(sessionID))

      clearCaptureResources()
      lifecycle = .idle
      return stoppedURL
    } catch {
      let normalizedError = Self.normalizedError(error)
      await tearDown(
        finishingWith: normalizedError,
        discardFile: false
      )
      if lifecycle == .stopping(sessionID) {
        lifecycle = .idle
      }
      throw normalizedError
    }
  }

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
    sourcePicker.cancelSelection()
    guard lifecycle != .idle || currentFileURL != nil else { return }

    lifecycle = .idle
    await tearDown(finishingWith: .cancelled, discardFile: true)
  }

  private func tearDown(
    finishingWith error: AppError,
    discardFile: Bool
  ) async {
    streamOutput?.beginExpectedStop()
    try? await stream?.stopCapture()
    streamOutput?.finish(throwing: error)
    mixTask?.cancel()
    await mixer?.fail(error)
    _ = try? await mixTask?.value

    if discardFile, let currentFileURL {
      try? TemporaryRecordingStore.discard(currentFileURL)
      self.currentFileURL = nil
    }
    clearCaptureResources()
  }

  private func clearCaptureResources() {
    stream = nil
    streamOutput = nil
    mixer = nil
    mixTask = nil
  }

  private func ensureLifecycle(_ expected: Lifecycle) throws {
    try Task.checkCancellation()
    guard lifecycle == expected else {
      throw CancellationError()
    }
  }

  private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private static func streamConfiguration() -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.captureMicrophone = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = Int(OnlineTimelineAudioMixer.sampleRate)
    configuration.channelCount = 1

    // 画面フレームは受け取らず音声だけを使います。最小サイズ・低頻度にして
    // WindowServer側の不要な映像処理を抑えます。
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    return configuration
  }

  nonisolated private static func normalizedError(_ error: Error) -> AppError {
    if error is CancellationError {
      return .cancelled
    }
    if let appError = error as? AppError {
      return appError
    }

    let nsError = error as NSError
    if nsError.domain == SCStreamError.errorDomain,
      nsError.code == SCStreamError.Code.userDeclined.rawValue
    {
      return .permissionDenied("画面とシステムオーディオ録音")
    }
    if nsError.domain == SCStreamError.errorDomain,
      nsError.code == SCStreamError.Code.failedToStartMicrophoneCapture.rawValue
    {
      return .recording("オンライン会議用のマイク入力を開始できませんでした。")
    }
    return .recording("オンライン会議の音声を取得できませんでした。")
  }
}

/// SCContentSharingPickerが返す非Sendableなfilterを所有してactorへ渡します。
struct SelectedCaptureContent: @unchecked Sendable {
  let filter: SCContentFilter
}

final class ScreenCaptureSourcePicker: NSObject, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SelectedCaptureContent, Error>?

  func selectSource() async throws -> SelectedCaptureContent {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        guard self.continuation == nil else {
          lock.unlock()
          continuation.resume(
            throwing: AppError.recording("共有する会議アプリをすでに選択中です。")
          )
          return
        }
        self.continuation = continuation
        lock.unlock()

        Task { @MainActor [weak self] in
          self?.presentPickerIfNeeded()
        }
      }
    } onCancel: { [weak self] in
      self?.cancelSelection()
    }
  }

  func cancelSelection() {
    resolve(.failure(CancellationError()))
  }

  @MainActor
  private func presentPickerIfNeeded() {
    guard hasPendingSelection else { return }

    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = [.singleApplication]
    configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier]
      .compactMap { $0 }
    configuration.allowsChangingSelectedContent = false

    let picker = SCContentSharingPicker.shared
    picker.defaultConfiguration = configuration
    picker.maximumStreamCount = 1
    picker.add(self)
    picker.isActive = true
    picker.present(using: .application)
  }

  private var hasPendingSelection: Bool {
    lock.lock()
    defer { lock.unlock() }
    return continuation != nil
  }

  private func resolve(_ result: Result<SelectedCaptureContent, Error>) {
    lock.lock()
    let pendingContinuation = continuation
    continuation = nil
    lock.unlock()

    guard let pendingContinuation else { return }
    Task { @MainActor in
      let picker = SCContentSharingPicker.shared
      picker.remove(self)
      picker.isActive = false
      picker.maximumStreamCount = 0
    }
    pendingContinuation.resume(with: result)
  }
}

extension ScreenCaptureSourcePicker: SCContentSharingPickerObserver {
  func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didCancelFor stream: SCStream?
  ) {
    resolve(.failure(CancellationError()))
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker,
    didUpdateWith filter: SCContentFilter,
    for stream: SCStream?
  ) {
    resolve(.success(SelectedCaptureContent(filter: filter)))
  }

  func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    resolve(
      .failure(
        AppError.recording("共有する会議アプリの選択画面を開けませんでした。")
      )
    )
  }
}

/// ScreenCaptureKitの一時バッファをcallback内でdeep-copyします。
final class ScreenCaptureAudioOutput: NSObject, @unchecked Sendable {
  let sampleQueue = DispatchQueue(
    label: "jp.flyoutstudio.MeetingFlowAI.screen-audio",
    qos: .userInitiated
  )

  private let lock = NSLock()
  private let continuation:
    AsyncThrowingStream<
      CapturedAudioSample,
      Error
    >.Continuation
  private var expectsStop = false

  init(
    continuation: AsyncThrowingStream<
      CapturedAudioSample,
      Error
    >.Continuation
  ) {
    self.continuation = continuation
  }

  func beginExpectedStop() {
    lock.lock()
    expectsStop = true
    lock.unlock()
  }

  func finish(throwing error: Error? = nil) {
    sampleQueue.sync {}
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }

  private var isExpectedStop: Bool {
    lock.lock()
    defer { lock.unlock() }
    return expectsStop
  }

  private func copySample(
    _ sampleBuffer: CMSampleBuffer,
    source: CapturedAudioSource
  ) throws -> CapturedAudioSample? {
    guard
      sampleBuffer.isValid,
      sampleBuffer.numSamples > 0,
      let description =
        sampleBuffer.formatDescription?.audioStreamBasicDescription
    else { return nil }

    var streamDescription = description
    guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
      return nil
    }

    let ownedSample = try sampleBuffer.withAudioBufferList {
      audioBufferList,
      _ in
      guard
        let borrowedBuffer = AVAudioPCMBuffer(
          pcmFormat: format,
          bufferListNoCopy: audioBufferList.unsafePointer
        )
      else {
        throw AppError.recording("取得したオンライン会議音声を読み取れませんでした。")
      }
      return AudioSample(copying: borrowedBuffer, time: nil)
    }

    guard let ownedSample else {
      throw AppError.recording("オンライン会議音声をコピーできませんでした。")
    }
    return CapturedAudioSample(
      source: source,
      buffer: ownedSample.buffer,
      presentationTime: sampleBuffer.presentationTimeStamp
    )
  }
}

extension ScreenCaptureAudioOutput: SCStreamOutput {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    let source: CapturedAudioSource
    switch outputType {
    case .audio:
      source = .system
    case .microphone:
      source = .microphone
    default:
      return
    }

    do {
      guard let sample = try copySample(sampleBuffer, source: source) else {
        return
      }
      switch continuation.yield(sample) {
      case .enqueued:
        return
      case .dropped:
        continuation.finish(
          throwing: AppError.recording(
            "オンライン会議音声の処理が録音に追いつきませんでした。"
          )
        )
      case .terminated:
        return
      @unknown default:
        continuation.finish(
          throwing: AppError.recording("未知の音声入力状態を受信しました。")
        )
      }
    } catch {
      continuation.finish(throwing: error)
    }
  }
}

extension ScreenCaptureAudioOutput: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    guard !isExpectedStop else { return }
    continuation.finish(throwing: error)
  }
}

private struct TimelineAudioChunk: Sendable {
  let startFrame: Int64
  let samples: [Float]

  var endFrame: Int64 {
    startFrame + Int64(samples.count)
  }
}

/// 両入力のPTSを48kHzのframe indexへ変換し、最大100ms待って合成します。
actor OnlineTimelineAudioMixer {
  static let sampleRate = 48_000.0

  private let targetFormat: AVAudioFormat
  private let continuation: AsyncThrowingStream<AudioSample, Error>.Continuation
  private var audioFile: AVAudioFile?
  private var converters: [CapturedAudioSource: OnlinePCMConverter] = [:]
  private var firstTimes: [CapturedAudioSource: CMTime] = [:]
  private var pendingBeforeAnchor: [CapturedAudioSample] = []
  private var anchorTime: CMTime?
  private var chunks: [CapturedAudioSource: [TimelineAudioChunk]] = [
    .system: [],
    .microphone: [],
  ]
  private var latestEndFrames: [CapturedAudioSource: Int64] = [:]
  private var outputFrame: Int64 = 0
  private var isActive = true

  private let jitterFrames = Int64(sampleRate / 10)
  private let alignmentToleranceFrames = Int64(sampleRate / 100)
  private let maximumGapFrames = Int64(sampleRate / 2)
  private let maximumBufferedFrames = Int64(sampleRate * 5)
  private let minimumOutputFrames: Int64 = 1_024
  private let maximumOutputFrames: Int64 = 4_096

  init(
    fileURL: URL,
    continuation: AsyncThrowingStream<AudioSample, Error>.Continuation
  ) throws {
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.sampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw AppError.recording("オンライン会議用の音声形式を作成できませんでした。")
    }

    self.targetFormat = targetFormat
    self.continuation = continuation
    audioFile = try AVAudioFile(
      forWriting: fileURL,
      settings: targetFormat.settings,
      commonFormat: targetFormat.commonFormat,
      interleaved: targetFormat.isInterleaved
    )
  }

  func ingest(_ sample: CapturedAudioSample) throws {
    guard isActive else { throw CancellationError() }
    guard sample.presentationTime.isValid, sample.presentationTime.isNumeric else {
      throw AppError.recording("オンライン会議音声の時刻情報が不正です。")
    }

    if firstTimes[sample.source] == nil {
      firstTimes[sample.source] = sample.presentationTime
    }

    if anchorTime == nil {
      pendingBeforeAnchor.append(sample)
      guard pendingBeforeAnchor.count <= 512 else {
        throw AppError.recording("オンライン会議音声の同期を開始できませんでした。")
      }

      if firstTimes.count == CapturedAudioSource.allCases.count
        || pendingDurationReachedJitterWindow
      {
        try establishAnchorAndDrainPending()
      }
      return
    }

    try process(sample)
  }

  func finish() throws {
    guard isActive else { return }

    if anchorTime == nil, !pendingBeforeAnchor.isEmpty {
      try establishAnchorAndDrainPending()
    }

    for source in CapturedAudioSource.allCases {
      guard let converter = converters[source] else { continue }
      let flushedSamples = try converter.flushSamples()
      guard !flushedSamples.isEmpty else { continue }
      let start = latestEndFrames[source] ?? outputFrame
      appendChunk(
        source: source,
        chunk: TimelineAudioChunk(
          startFrame: start,
          samples: flushedSamples
        )
      )
    }

    try renderAvailable(final: true)
    audioFile = nil
    isActive = false
    continuation.finish()
  }

  func fail(_ error: Error) {
    guard isActive else { return }
    isActive = false
    audioFile = nil
    if error is CancellationError || (error as? AppError) == .cancelled {
      continuation.finish(throwing: AppError.cancelled)
    } else if let appError = error as? AppError {
      continuation.finish(throwing: appError)
    } else {
      continuation.finish(
        throwing: AppError.recording("オンライン会議音声の合成に失敗しました。")
      )
    }
  }

  private var pendingDurationReachedJitterWindow: Bool {
    guard
      let earliest = pendingBeforeAnchor.map(\.presentationTime).min(
        by: { CMTimeCompare($0, $1) < 0 }
      ),
      let latest = pendingBeforeAnchor.map(\.presentationTime).max(
        by: { CMTimeCompare($0, $1) < 0 }
      )
    else { return false }

    let duration = CMTimeGetSeconds(CMTimeSubtract(latest, earliest))
    return duration.isFinite && duration >= Double(jitterFrames) / Self.sampleRate
  }

  private func establishAnchorAndDrainPending() throws {
    guard
      let earliest = pendingBeforeAnchor.map(\.presentationTime).min(
        by: { CMTimeCompare($0, $1) < 0 }
      )
    else { return }

    anchorTime = earliest
    let pending = pendingBeforeAnchor.sorted {
      CMTimeCompare($0.presentationTime, $1.presentationTime) < 0
    }
    pendingBeforeAnchor.removeAll(keepingCapacity: false)
    for sample in pending {
      try process(sample)
    }
  }

  private func process(_ sample: CapturedAudioSample) throws {
    guard let anchorTime else { return }

    let converter: OnlinePCMConverter
    if let existing = converters[sample.source] {
      converter = existing
    } else {
      converter = try OnlinePCMConverter(
        inputFormat: sample.buffer.format,
        outputFormat: targetFormat
      )
      converters[sample.source] = converter
    }

    var samples = try converter.convertToSamples(sample.buffer)
    guard !samples.isEmpty else { return }

    let relativeTime = CMTimeSubtract(sample.presentationTime, anchorTime)
    let relativeSeconds = CMTimeGetSeconds(relativeTime)
    guard relativeSeconds.isFinite else {
      throw AppError.recording("オンライン会議音声の時刻を変換できませんでした。")
    }

    var startFrame = Int64((relativeSeconds * Self.sampleRate).rounded())
    if let latestEnd = latestEndFrames[sample.source] {
      let difference = startFrame - latestEnd
      if abs(difference) <= alignmentToleranceFrames {
        startFrame = latestEnd
      } else if difference > maximumGapFrames {
        throw AppError.recording("オンライン会議音声に大きな欠落を検出しました。")
      }
    }

    if startFrame < outputFrame {
      let lateFrames = outputFrame - startFrame
      guard lateFrames < Int64(samples.count) else {
        return
      }
      samples.removeFirst(Int(lateFrames))
      startFrame = outputFrame
    }

    if let latestEnd = latestEndFrames[sample.source], startFrame < latestEnd {
      let overlapFrames = latestEnd - startFrame
      guard overlapFrames < Int64(samples.count) else {
        return
      }
      samples.removeFirst(Int(overlapFrames))
      startFrame = latestEnd
    }

    appendChunk(
      source: sample.source,
      chunk: TimelineAudioChunk(
        startFrame: startFrame,
        samples: samples
      )
    )
    try renderAvailable(final: false)
  }

  private func appendChunk(
    source: CapturedAudioSource,
    chunk: TimelineAudioChunk
  ) {
    chunks[source, default: []].append(chunk)
    latestEndFrames[source] = max(
      latestEndFrames[source] ?? chunk.endFrame,
      chunk.endFrame
    )
  }

  private func renderAvailable(final: Bool) throws {
    guard let furthestEnd = latestEndFrames.values.max() else { return }

    let safeEnd: Int64
    if final {
      safeEnd = furthestEnd
    } else {
      let sourceEnds = CapturedAudioSource.allCases.compactMap {
        latestEndFrames[$0]
      }
      // 片方だけ先に到着した短いbufferを即時出力すると、同じPTSで後から
      // 到着したもう片方が「遅延」と判定されて混合されません。両入力が
      // 揃うか、jitter許容幅を超えるまでは出力を待ちます。
      let commonEnd =
        sourceEnds.count == CapturedAudioSource.allCases.count
        ? sourceEnds.min() ?? outputFrame
        : outputFrame
      safeEnd = max(commonEnd, furthestEnd - jitterFrames)
    }

    guard furthestEnd - outputFrame <= maximumBufferedFrames else {
      throw AppError.recording("オンライン会議音声の合成処理が遅延しました。")
    }

    while safeEnd > outputFrame {
      let available = safeEnd - outputFrame
      if !final, available < minimumOutputFrames { return }

      let frameCount = min(available, maximumOutputFrames)
      try render(frameCount: frameCount)
    }
  }

  private func render(frameCount: Int64) throws {
    let rangeStart = outputFrame
    let rangeEnd = rangeStart + frameCount
    var mixed = [Float](repeating: 0, count: Int(frameCount))

    for source in CapturedAudioSource.allCases {
      for chunk in chunks[source, default: []] {
        let overlapStart = max(rangeStart, chunk.startFrame)
        let overlapEnd = min(rangeEnd, chunk.endFrame)
        guard overlapStart < overlapEnd else { continue }

        let outputOffset = Int(overlapStart - rangeStart)
        let inputOffset = Int(overlapStart - chunk.startFrame)
        let count = Int(overlapEnd - overlapStart)
        for index in 0..<count {
          mixed[outputOffset + index] += chunk.samples[inputOffset + index]
        }
      }
    }

    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      ),
      let outputChannel = outputBuffer.floatChannelData?[0]
    else {
      throw AppError.recording("合成音声バッファを作成できませんでした。")
    }

    outputBuffer.frameLength = AVAudioFrameCount(frameCount)
    for index in mixed.indices {
      outputChannel[index] = min(max(mixed[index], -1), 1)
    }

    guard let audioFile else {
      throw AppError.recording("一時録音ファイルが閉じられています。")
    }
    try audioFile.write(from: outputBuffer)

    guard
      let sample = AudioSample(
        copying: outputBuffer,
        time: AVAudioTime(
          sampleTime: AVAudioFramePosition(rangeStart),
          atRate: Self.sampleRate
        )
      )
    else {
      throw AppError.recording("合成音声を文字起こしへ渡せませんでした。")
    }

    switch continuation.yield(sample) {
    case .enqueued:
      break
    case .dropped:
      throw AppError.recording(
        "文字起こし用の音声処理が録音に追いつきませんでした。"
      )
    case .terminated:
      throw CancellationError()
    @unknown default:
      throw AppError.recording("未知の音声出力状態を受信しました。")
    }

    outputFrame = rangeEnd
    for source in CapturedAudioSource.allCases {
      chunks[source, default: []].removeAll { $0.endFrame <= outputFrame }
    }
  }
}

private final class OnlineConverterInputSupplier: @unchecked Sendable {
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

/// sourceごとに1つだけ使う永続的なサンプルレート変換器です。
private final class OnlinePCMConverter {
  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter?

  init(
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat
  ) throws {
    self.inputFormat = inputFormat
    self.outputFormat = outputFormat
    if inputFormat.isEqual(outputFormat) {
      converter = nil
    } else {
      guard
        let converter = AVAudioConverter(
          from: inputFormat,
          to: outputFormat
        )
      else {
        throw AppError.recording("オンライン会議音声の形式を変換できません。")
      }
      self.converter = converter
    }
  }

  func convertToSamples(_ input: AVAudioPCMBuffer) throws -> [Float] {
    guard input.format.isEqual(inputFormat) else {
      throw AppError.recording("録音中にオンライン会議音声の形式が変更されました。")
    }

    if converter == nil {
      return try samples(from: input)
    }
    guard let converter else { return [] }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = max(
      AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32,
      1
    )
    let supplier = OnlineConverterInputSupplier(input: input)
    let buffers = try drain(
      converter,
      capacity: capacity
    ) { _, inputStatus in
      supplier.next(inputStatus: inputStatus)
    }
    return try buffers.flatMap(samples(from:))
  }

  func flushSamples() throws -> [Float] {
    guard let converter else { return [] }
    let capacity = max(
      AVAudioFrameCount(outputFormat.sampleRate / 10),
      1
    )
    let buffers = try drain(
      converter,
      capacity: capacity
    ) { _, inputStatus in
      inputStatus.pointee = .endOfStream
      return nil
    }
    return try buffers.flatMap(samples(from:))
  }

  private func drain(
    _ converter: AVAudioConverter,
    capacity: AVAudioFrameCount,
    inputBlock: @escaping AVAudioConverterInputBlock
  ) throws -> [AVAudioPCMBuffer] {
    var outputs: [AVAudioPCMBuffer] = []

    for _ in 0..<64 {
      guard
        let output = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: capacity
        )
      else {
        throw AppError.recording("変換後のオンライン会議音声を作成できません。")
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
        throw AppError.recording("オンライン会議音声の形式変換に失敗しました。")
      @unknown default:
        throw AppError.recording("未知の音声変換状態を受信しました。")
      }
    }

    throw AppError.recording("オンライン会議音声の形式変換が完了しませんでした。")
  }

  private func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
    guard
      buffer.format.commonFormat == .pcmFormatFloat32,
      buffer.format.channelCount == 1,
      let channel = buffer.floatChannelData?[0]
    else {
      throw AppError.recording("合成用のオンライン会議音声を読み取れませんでした。")
    }
    return Array(
      UnsafeBufferPointer(
        start: channel,
        count: Int(buffer.frameLength)
      )
    )
  }
}
