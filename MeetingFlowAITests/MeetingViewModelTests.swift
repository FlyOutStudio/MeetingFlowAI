import Foundation
import XCTest

@testable import MeetingFlowAI

final class MeetingViewModelTests: XCTestCase {
  @MainActor
  func testStartStopCompletesAnalysis() async throws {
    let recording = RecordingServiceStub()
    let speech = SpeechServiceStub()
    let expected = Self.analysis(summary: "正常完了")
    let analysisService = SequencedAnalysisService([.success(expected)])
    let speechFactory = SpeechServiceFactoryStub([speech])
    let viewModel = makeViewModel(
      recording: recording,
      analysis: analysisService,
      speechFactory: speechFactory
    )

    viewModel.startRecording()
    try await waitUntil("録音状態へ遷移しませんでした。") {
      viewModel.phase == .recording
    }

    await speech.emit(finalizedText: "営業が受注内容を確認する。")
    try await waitUntil("文字起こしが画面へ反映されませんでした。") {
      viewModel.transcript == "営業が受注内容を確認する。"
    }

    viewModel.stopRecording()
    try await waitUntil("AI解析が完了しませんでした。") {
      viewModel.phase == .completed
    }

    XCTAssertEqual(viewModel.analysis, expected)
    XCTAssertNil(viewModel.presentedError)

    let recordingCounts = await recording.counts()
    XCTAssertEqual(recordingCounts.starts, 1)
    XCTAssertEqual(recordingCounts.modes, [.microphone])
    XCTAssertEqual(recordingCounts.stops, 1)
    XCTAssertEqual(recordingCounts.discards, 1)
    let analysisCalls = await analysisService.numberOfCalls()
    XCTAssertEqual(analysisCalls, 1)
  }

  @MainActor
  func testOnlineMeetingModeIsForwardedToRecordingService() async throws {
    let recording = RecordingServiceStub()
    let speech = SpeechServiceStub()
    let analysisService = SequencedAnalysisService([])
    let speechFactory = SpeechServiceFactoryStub([speech])
    let viewModel = makeViewModel(
      recording: recording,
      analysis: analysisService,
      speechFactory: speechFactory
    )
    viewModel.captureMode = .onlineMeeting

    viewModel.startRecording()
    try await waitUntil("オンライン会議モードで録音を開始できませんでした。") {
      viewModel.phase == .recording
    }

    let recordingCounts = await recording.counts()
    XCTAssertEqual(recordingCounts.modes, [.onlineMeeting])

    viewModel.stopRecording()
    try await waitUntil("テスト録音の後始末が完了しませんでした。") {
      viewModel.phase == .idle
    }
  }

  @MainActor
  func testAnalysisFailureCanBeRetried() async throws {
    let recording = RecordingServiceStub()
    let speech = SpeechServiceStub()
    let expected = Self.analysis(summary: "再試行成功")
    let analysisService = SequencedAnalysisService([
      .failure(.openAI("一時的な失敗")),
      .success(expected),
    ])
    let speechFactory = SpeechServiceFactoryStub([speech])
    let viewModel = makeViewModel(
      recording: recording,
      analysis: analysisService,
      speechFactory: speechFactory
    )

    viewModel.startRecording()
    try await waitUntil("録音状態へ遷移しませんでした。") {
      viewModel.phase == .recording
    }
    await speech.emit(finalizedText: "管理部が在庫を確認する。")
    try await waitUntil("文字起こしが画面へ反映されませんでした。") {
      !viewModel.transcript.isEmpty
    }

    viewModel.stopRecording()
    try await waitUntil("AI失敗後の再試行状態へ遷移しませんでした。") {
      viewModel.phase == .transcriptReady
        && viewModel.presentedError != nil
    }

    XCTAssertNil(viewModel.analysis)
    XCTAssertTrue(viewModel.canRetryAnalysis)

    viewModel.retryAnalysis()
    try await waitUntil("AI解析の再試行が完了しませんでした。") {
      viewModel.phase == .completed
    }

    XCTAssertEqual(viewModel.analysis, expected)
    XCTAssertNil(viewModel.presentedError)
    let analysisCalls = await analysisService.numberOfCalls()
    XCTAssertEqual(analysisCalls, 2)
  }

  @MainActor
  func testCancelledGenerationCannotOverwriteNewSession() async throws {
    let recording = RecordingServiceStub()
    let firstSpeech = SpeechServiceStub()
    let secondSpeech = SpeechServiceStub()
    let staleAnalysis = Self.analysis(summary: "破棄される旧結果")
    let freshAnalysis = Self.analysis(summary: "新しい結果")
    let analysisService = ControlledAnalysisService(
      staleAnalysis: staleAnalysis,
      freshAnalysis: freshAnalysis
    )
    let speechFactory = SpeechServiceFactoryStub([firstSpeech, secondSpeech])
    let viewModel = makeViewModel(
      recording: recording,
      analysis: analysisService,
      speechFactory: speechFactory
    )

    viewModel.startRecording()
    try await waitUntil("1回目の録音を開始できませんでした。") {
      viewModel.phase == .recording
    }
    await firstSpeech.emit(finalizedText: "古い会議内容")
    try await waitUntil("1回目の文字起こしが反映されませんでした。") {
      viewModel.transcript == "古い会議内容"
    }
    viewModel.stopRecording()

    try await waitForAnalysisCalls(
      1,
      service: analysisService,
      message: "1回目のAI生成が開始されませんでした。"
    )
    XCTAssertEqual(viewModel.phase, .generating)

    // 1回目のanalyzeは意図的にキャンセルへ協調せず、後から結果を返します。
    viewModel.cancelProcessing()
    try await waitUntil("生成キャンセルが完了しませんでした。") {
      viewModel.phase == .transcriptReady
    }

    viewModel.startRecording()
    try await waitUntil("2回目の録音を開始できませんでした。") {
      viewModel.phase == .recording
    }
    await secondSpeech.emit(finalizedText: "新しい会議内容")
    try await waitUntil("2回目の文字起こしが反映されませんでした。") {
      viewModel.transcript == "新しい会議内容"
    }
    viewModel.stopRecording()

    try await waitUntil("2回目のAI生成が完了しませんでした。") {
      viewModel.phase == .completed
    }
    XCTAssertEqual(viewModel.analysis, freshAnalysis)

    // キャンセル済みの1回目をここで解放し、遅延結果が届いても新状態を
    // 上書きしないことを確認します。
    await analysisService.releaseStaleAnalysis()
    try await waitUntilForStaleDelivery(analysisService)
    for _ in 0..<10 {
      await Task.yield()
    }

    XCTAssertEqual(viewModel.phase, .completed)
    XCTAssertEqual(viewModel.analysis, freshAnalysis)
    XCTAssertNotEqual(viewModel.analysis, staleAnalysis)
    let analysisCalls = await analysisService.numberOfCalls()
    XCTAssertEqual(analysisCalls, 2)
  }

  @MainActor
  func testCleanupPresentsTemporaryRecordingDeletionFailure() async throws {
    let deletionError = AppError.recording(
      "一時録音ファイルを削除できませんでした。"
    )
    let recording = RecordingServiceStub(cancelError: deletionError)
    let speech = SpeechServiceStub()
    let analysisService = SequencedAnalysisService([])
    let speechFactory = SpeechServiceFactoryStub([speech])
    let viewModel = makeViewModel(
      recording: recording,
      analysis: analysisService,
      speechFactory: speechFactory
    )

    viewModel.startRecording()
    try await waitUntil("録音状態へ遷移しませんでした。") {
      viewModel.phase == .recording
    }

    await speech.fail(AppError.speech("テスト用の文字起こし失敗"))
    try await waitUntil("障害後の後始末が完了しませんでした。") {
      viewModel.phase == .idle && viewModel.presentedError != nil
    }

    XCTAssertEqual(viewModel.presentedError, deletionError)
    let recordingCounts = await recording.counts()
    XCTAssertEqual(recordingCounts.cancels, 1)
  }

  @MainActor
  private func makeViewModel(
    recording: any RecordingServicing,
    analysis: any MeetingAnalysisGenerating,
    speechFactory: SpeechServiceFactoryStub
  ) -> MeetingViewModel {
    MeetingViewModel(
      recordingService: recording,
      analysisService: analysis,
      speechServiceFactory: { speechFactory.make() }
    )
  }

  private static func analysis(summary: String) -> MeetingAnalysis {
    MeetingAnalysis(
      summary: summary,
      todo: [],
      flow: [
        FlowStep(
          id: "1",
          actor: "営業",
          action: "確認",
          next: []
        )
      ]
    )
  }

  private enum WaitError: Error {
    case timedOut
  }

  @MainActor
  private func waitUntil(
    _ message: String,
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        XCTFail(message)
        throw WaitError.timedOut
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  @MainActor
  private func waitForAnalysisCalls(
    _ expectedCount: Int,
    service: ControlledAnalysisService,
    message: String,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let callCount = await service.numberOfCalls()
      if callCount >= expectedCount { return }
      guard Date() < deadline else {
        XCTFail(message)
        throw WaitError.timedOut
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  @MainActor
  private func waitUntilForStaleDelivery(
    _ service: ControlledAnalysisService,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if await service.didDeliverStaleAnalysis() { return }
      guard Date() < deadline else {
        XCTFail("旧AI結果がテストへ返却されませんでした。")
        throw WaitError.timedOut
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private struct RecordingServiceCounts: Sendable {
  let starts: Int
  let modes: [MeetingCaptureMode]
  let stops: Int
  let discards: Int
  let cancels: Int
}

private actor RecordingServiceStub: RecordingServicing {
  private var continuation: AsyncThrowingStream<AudioSample, Error>.Continuation?
  private var currentURL: URL?
  private var startCount = 0
  private var startedModes: [MeetingCaptureMode] = []
  private var stopCount = 0
  private var discardCount = 0
  private var cancelCount = 0
  private let cancelError: AppError?

  init(cancelError: AppError? = nil) {
    self.cancelError = cancelError
  }

  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession {
    guard continuation == nil else {
      throw AppError.recording("テスト録音はすでに開始済みです。")
    }

    startCount += 1
    startedModes.append(mode)
    let url = URL(
      fileURLWithPath: "/private/tmp/meeting-flow-ai-test-\(startCount).caf"
    )
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: AudioSample.self,
      throwing: Error.self
    )
    self.continuation = continuation
    currentURL = url
    return RecordingSession(fileURL: url, samples: stream)
  }

  func stopRecording() async throws -> URL? {
    stopCount += 1
    continuation?.finish()
    continuation = nil
    return currentURL
  }

  func discardRecording(at url: URL) async throws {
    discardCount += 1
    if currentURL == url {
      currentURL = nil
    }
  }

  func cancelRecording() async throws {
    cancelCount += 1
    continuation?.finish(throwing: CancellationError())
    continuation = nil
    currentURL = nil
    if let cancelError {
      throw cancelError
    }
  }

  func counts() -> RecordingServiceCounts {
    RecordingServiceCounts(
      starts: startCount,
      modes: startedModes,
      stops: stopCount,
      discards: discardCount,
      cancels: cancelCount
    )
  }
}

private actor SpeechServiceStub: SpeechServicing {
  private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?

  func start(
    locale: Locale
  ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
    guard continuation == nil else {
      throw AppError.speech("テスト文字起こしはすでに開始済みです。")
    }

    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: TranscriptUpdate.self,
      throwing: Error.self,
      bufferingPolicy: .bufferingNewest(4)
    )
    self.continuation = continuation
    return stream
  }

  func append(_ sample: AudioSample) async throws {}

  func finish() async throws {
    continuation?.finish()
    continuation = nil
  }

  func cancel() async {
    continuation?.finish(throwing: CancellationError())
    continuation = nil
  }

  func emit(finalizedText: String, volatileText: String = "") {
    continuation?.yield(
      TranscriptUpdate(
        finalizedText: finalizedText,
        volatileText: volatileText
      )
    )
  }

  func fail(_ error: Error) {
    continuation?.finish(throwing: error)
    continuation = nil
  }
}

private final class SpeechServiceFactoryStub: @unchecked Sendable {
  private let lock = NSLock()
  private var services: [any SpeechServicing]

  init(_ services: [any SpeechServicing]) {
    self.services = services
  }

  func make() -> any SpeechServicing {
    lock.lock()
    defer { lock.unlock() }
    precondition(!services.isEmpty, "テスト用SpeechServiceが不足しています。")
    return services.removeFirst()
  }
}

private actor SequencedAnalysisService: MeetingAnalysisGenerating {
  enum Outcome: Sendable {
    case success(MeetingAnalysis)
    case failure(AppError)
  }

  private var outcomes: [Outcome]
  private var callCount = 0

  init(_ outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func analyze(title: String, transcript: String) async throws -> MeetingAnalysis {
    callCount += 1
    guard !outcomes.isEmpty else {
      throw AppError.openAI("テスト用AI応答が不足しています。")
    }

    switch outcomes.removeFirst() {
    case .success(let analysis):
      return analysis
    case .failure(let error):
      throw error
    }
  }

  func numberOfCalls() -> Int {
    callCount
  }
}

private actor ControlledAnalysisService: MeetingAnalysisGenerating {
  private let staleAnalysis: MeetingAnalysis
  private let freshAnalysis: MeetingAnalysis
  private var staleContinuation: CheckedContinuation<MeetingAnalysis, Never>?
  private var callCount = 0
  private var staleAnalysisWasDelivered = false

  init(staleAnalysis: MeetingAnalysis, freshAnalysis: MeetingAnalysis) {
    self.staleAnalysis = staleAnalysis
    self.freshAnalysis = freshAnalysis
  }

  func analyze(title: String, transcript: String) async throws -> MeetingAnalysis {
    callCount += 1
    guard callCount == 1 else { return freshAnalysis }

    // Task cancellationへ意図的に協調しないAPIを再現します。
    let result = await withCheckedContinuation { continuation in
      staleContinuation = continuation
    }
    staleAnalysisWasDelivered = true
    return result
  }

  func releaseStaleAnalysis() {
    let continuation = staleContinuation
    staleContinuation = nil
    continuation?.resume(returning: staleAnalysis)
  }

  func numberOfCalls() -> Int {
    callCount
  }

  func didDeliverStaleAnalysis() -> Bool {
    staleAnalysisWasDelivered
  }
}
