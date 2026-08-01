import Foundation
import XCTest

@testable import MeetingFlowAI

final class RecordingServiceCoordinatorTests: XCTestCase {
  func testRoutesCompleteLifecycleToSelectedService() async throws {
    let microphone = CoordinatorRecordingServiceStub(identifier: "microphone")
    let onlineMeeting = CoordinatorRecordingServiceStub(identifier: "online")
    let coordinator = RecordingServiceCoordinator(
      microphoneService: microphone,
      onlineMeetingService: onlineMeeting
    )

    let microphoneSession = try await coordinator.startRecording(
      mode: .microphone
    )
    let stoppedURL = try await coordinator.stopRecording()
    XCTAssertEqual(stoppedURL, microphoneSession.fileURL)
    try await coordinator.discardRecording(at: microphoneSession.fileURL)

    _ = try await coordinator.startRecording(mode: .onlineMeeting)
    try await coordinator.cancelRecording()

    let microphoneSnapshot = await microphone.snapshot()
    XCTAssertEqual(microphoneSnapshot.startedModes, [.microphone])
    XCTAssertEqual(microphoneSnapshot.stopCount, 1)
    XCTAssertEqual(
      microphoneSnapshot.discardedURLs,
      [microphoneSession.fileURL]
    )
    XCTAssertEqual(microphoneSnapshot.cancelCount, 0)

    let onlineSnapshot = await onlineMeeting.snapshot()
    XCTAssertEqual(onlineSnapshot.startedModes, [.onlineMeeting])
    XCTAssertEqual(onlineSnapshot.stopCount, 0)
    XCTAssertTrue(onlineSnapshot.discardedURLs.isEmpty)
    XCTAssertEqual(onlineSnapshot.cancelCount, 1)
  }

  func testRejectsSecondStartUntilActiveSessionIsCancelled() async throws {
    let microphone = CoordinatorRecordingServiceStub(identifier: "microphone")
    let onlineMeeting = CoordinatorRecordingServiceStub(identifier: "online")
    let coordinator = RecordingServiceCoordinator(
      microphoneService: microphone,
      onlineMeetingService: onlineMeeting
    )

    _ = try await coordinator.startRecording(mode: .microphone)

    do {
      _ = try await coordinator.startRecording(mode: .onlineMeeting)
      XCTFail("録音中の二重開始が成功してしまいました。")
    } catch let error as AppError {
      XCTAssertEqual(error, .recording("すでに録音中です。"))
    } catch {
      XCTFail("予期しないエラーです: \(error)")
    }

    let onlineBeforeCancel = await onlineMeeting.snapshot()
    XCTAssertTrue(onlineBeforeCancel.startedModes.isEmpty)

    try await coordinator.cancelRecording()
    _ = try await coordinator.startRecording(mode: .onlineMeeting)
    try await coordinator.cancelRecording()

    let microphoneSnapshot = await microphone.snapshot()
    XCTAssertEqual(microphoneSnapshot.cancelCount, 1)
    let onlineSnapshot = await onlineMeeting.snapshot()
    XCTAssertEqual(onlineSnapshot.startedModes, [.onlineMeeting])
    XCTAssertEqual(onlineSnapshot.cancelCount, 1)
  }

  func testFailedStartResetsCoordinatorForAnotherMode() async throws {
    let expectedError = AppError.recording("テスト用の開始失敗")
    let microphone = CoordinatorRecordingServiceStub(
      identifier: "microphone",
      startError: expectedError
    )
    let onlineMeeting = CoordinatorRecordingServiceStub(identifier: "online")
    let coordinator = RecordingServiceCoordinator(
      microphoneService: microphone,
      onlineMeetingService: onlineMeeting
    )

    do {
      _ = try await coordinator.startRecording(mode: .microphone)
      XCTFail("録音サービスの開始エラーが伝播しませんでした。")
    } catch let error as AppError {
      XCTAssertEqual(error, expectedError)
    } catch {
      XCTFail("予期しないエラーです: \(error)")
    }

    _ = try await coordinator.startRecording(mode: .onlineMeeting)
    try await coordinator.cancelRecording()

    let microphoneSnapshot = await microphone.snapshot()
    XCTAssertEqual(microphoneSnapshot.startedModes, [.microphone])
    let onlineSnapshot = await onlineMeeting.snapshot()
    XCTAssertEqual(onlineSnapshot.startedModes, [.onlineMeeting])
  }

  func testCancelDuringAsynchronousStartInvalidatesPendingSession()
    async throws
  {
    let microphone = SuspendedStartRecordingServiceStub()
    let onlineMeeting = CoordinatorRecordingServiceStub(identifier: "online")
    let coordinator = RecordingServiceCoordinator(
      microphoneService: microphone,
      onlineMeetingService: onlineMeeting
    )

    let startTask = Task {
      try await coordinator.startRecording(mode: .microphone)
    }
    let startBecamePending = await waitUntilStartIsPending(microphone)
    XCTAssertTrue(startBecamePending)

    try await coordinator.cancelRecording()
    do {
      _ = try await startTask.value
      XCTFail("キャンセル済みの開始処理がセッションを返しました。")
    } catch is CancellationError {
      // 期待どおりです。
    } catch {
      XCTFail("予期しないエラーです: \(error)")
    }

    _ = try await coordinator.startRecording(mode: .onlineMeeting)
    try await coordinator.cancelRecording()

    let microphoneCancelCount = await microphone.cancelCount()
    XCTAssertEqual(microphoneCancelCount, 1)
    let onlineSnapshot = await onlineMeeting.snapshot()
    XCTAssertEqual(onlineSnapshot.startedModes, [.onlineMeeting])
  }

  func testStopWithoutActiveSessionDoesNotCallEitherService() async throws {
    let microphone = CoordinatorRecordingServiceStub(identifier: "microphone")
    let onlineMeeting = CoordinatorRecordingServiceStub(identifier: "online")
    let coordinator = RecordingServiceCoordinator(
      microphoneService: microphone,
      onlineMeetingService: onlineMeeting
    )

    let stoppedURL = try await coordinator.stopRecording()

    XCTAssertNil(stoppedURL)
    let microphoneSnapshot = await microphone.snapshot()
    XCTAssertEqual(microphoneSnapshot.stopCount, 0)
    let onlineSnapshot = await onlineMeeting.snapshot()
    XCTAssertEqual(onlineSnapshot.stopCount, 0)
  }

  private func waitUntilStartIsPending(
    _ service: SuspendedStartRecordingServiceStub
  ) async -> Bool {
    for _ in 0..<1_000 {
      if await service.isStartPending() { return true }
      await Task.yield()
    }
    return false
  }
}

private struct CoordinatorRecordingServiceSnapshot: Sendable {
  let startedModes: [MeetingCaptureMode]
  let stopCount: Int
  let discardedURLs: [URL]
  let cancelCount: Int
}

private actor CoordinatorRecordingServiceStub: RecordingServicing {
  private let identifier: String
  private let startError: AppError?
  private var continuation: AsyncThrowingStream<AudioSample, Error>.Continuation?
  private var currentURL: URL?
  private var startedModes: [MeetingCaptureMode] = []
  private var stopCount = 0
  private var discardedURLs: [URL] = []
  private var cancelCount = 0

  init(identifier: String, startError: AppError? = nil) {
    self.identifier = identifier
    self.startError = startError
  }

  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession {
    startedModes.append(mode)
    if let startError {
      throw startError
    }

    let fileURL = URL(
      fileURLWithPath: "/private/tmp/meeting-flow-ai-\(identifier).caf"
    )
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: AudioSample.self,
      throwing: Error.self
    )
    self.continuation = continuation
    currentURL = fileURL
    return RecordingSession(fileURL: fileURL, samples: stream)
  }

  func stopRecording() async throws -> URL? {
    stopCount += 1
    continuation?.finish()
    continuation = nil
    return currentURL
  }

  func discardRecording(at url: URL) async throws {
    discardedURLs.append(url)
    if currentURL == url {
      currentURL = nil
    }
  }

  func cancelRecording() async throws {
    cancelCount += 1
    continuation?.finish(throwing: CancellationError())
    continuation = nil
    currentURL = nil
  }

  func snapshot() -> CoordinatorRecordingServiceSnapshot {
    CoordinatorRecordingServiceSnapshot(
      startedModes: startedModes,
      stopCount: stopCount,
      discardedURLs: discardedURLs,
      cancelCount: cancelCount
    )
  }
}

private actor SuspendedStartRecordingServiceStub: RecordingServicing {
  private var startContinuation: CheckedContinuation<RecordingSession, Error>?
  private var cancellations = 0

  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession {
    try await withCheckedThrowingContinuation { continuation in
      startContinuation = continuation
    }
  }

  func stopRecording() async throws -> URL? {
    nil
  }

  func discardRecording(at url: URL) async throws {}

  func cancelRecording() async throws {
    cancellations += 1
    let continuation = startContinuation
    startContinuation = nil
    continuation?.resume(throwing: CancellationError())
  }

  func isStartPending() -> Bool {
    startContinuation != nil
  }

  func cancelCount() -> Int {
    cancellations
  }
}
