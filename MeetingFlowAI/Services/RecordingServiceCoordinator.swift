import Foundation

/// 選択された録音モードを対応するサービスへ振り分けます。
actor RecordingServiceCoordinator: RecordingServicing {
  private enum Lifecycle: Equatable {
    case idle
    case starting(UUID)
    case active(UUID)
    case stopping(UUID)
    case stopped(UUID)
  }

  private let microphoneService: any RecordingServicing
  private let onlineMeetingService: any RecordingServicing

  private var lifecycle: Lifecycle = .idle
  private var currentService: (any RecordingServicing)?

  init(
    microphoneService: any RecordingServicing = RecordingService(),
    onlineMeetingService: any RecordingServicing = OnlineMeetingRecordingService()
  ) {
    self.microphoneService = microphoneService
    self.onlineMeetingService = onlineMeetingService
  }

  func startRecording(mode: MeetingCaptureMode) async throws -> RecordingSession {
    guard lifecycle == .idle else {
      throw AppError.recording("すでに録音中です。")
    }

    let sessionID = UUID()
    let service = service(for: mode)
    lifecycle = .starting(sessionID)
    currentService = service

    do {
      let session = try await service.startRecording(mode: mode)
      try ensureLifecycle(.starting(sessionID))
      lifecycle = .active(sessionID)
      return session
    } catch {
      if lifecycle == .starting(sessionID) {
        reset()
      }
      throw error
    }
  }

  func stopRecording() async throws -> URL? {
    guard
      case .active(let sessionID) = lifecycle,
      let currentService
    else { return nil }

    lifecycle = .stopping(sessionID)
    do {
      let url = try await currentService.stopRecording()
      try ensureLifecycle(.stopping(sessionID))
      if url == nil {
        reset()
      } else {
        lifecycle = .stopped(sessionID)
      }
      return url
    } catch {
      if lifecycle == .stopping(sessionID) {
        lifecycle = .active(sessionID)
      }
      throw error
    }
  }

  func discardRecording(at url: URL) async throws {
    guard case .stopped = lifecycle, let currentService else {
      try TemporaryRecordingStore.discard(url)
      return
    }

    do {
      try await currentService.discardRecording(at: url)
      reset()
    } catch {
      throw error
    }
  }

  func cancelRecording() async throws {
    guard lifecycle != .idle else { return }
    let service = currentService
    reset()
    try await service?.cancelRecording()
  }

  private func service(
    for mode: MeetingCaptureMode
  ) -> any RecordingServicing {
    switch mode {
    case .microphone:
      microphoneService
    case .onlineMeeting:
      onlineMeetingService
    }
  }

  private func ensureLifecycle(_ expected: Lifecycle) throws {
    try Task.checkCancellation()
    guard lifecycle == expected else {
      throw CancellationError()
    }
  }

  private func reset() {
    lifecycle = .idle
    currentService = nil
  }
}
