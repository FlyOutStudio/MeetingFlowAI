import Combine
import Foundation

@MainActor
final class MeetingViewModel: ObservableObject {
  @Published var meetingTitle = ""
  @Published var captureMode: MeetingCaptureMode = .microphone
  @Published private(set) var transcript = ""
  @Published private(set) var analysis: MeetingAnalysis?
  @Published private(set) var phase: SessionPhase = .idle
  @Published private(set) var presentedError: AppError?
  @Published private(set) var isExporting = false

  private let recordingService: any RecordingServicing
  private let analysisService: any MeetingAnalysisGenerating
  private let exportService: ExportService
  private let speechServiceFactory: @Sendable () -> any SpeechServicing

  private var speechService: (any SpeechServicing)?
  private var sampleTask: Task<Void, Never>?
  private var transcriptTask: Task<Void, Never>?
  private var workflowTask: Task<Void, Never>?
  private var activeOperationID: UUID?
  private var cleanupOperationID: UUID?

  init(
    recordingService: any RecordingServicing = RecordingServiceCoordinator(),
    analysisService: any MeetingAnalysisGenerating = OpenAIService(),
    exportService: ExportService = ExportService(),
    speechServiceFactory: @escaping @Sendable () -> any SpeechServicing = {
      SpeechServiceFactory.make()
    }
  ) {
    self.recordingService = recordingService
    self.analysisService = analysisService
    self.exportService = exportService
    self.speechServiceFactory = speechServiceFactory
  }

  var canStartRecording: Bool {
    switch phase {
    case .idle, .transcriptReady, .completed:
      true
    default:
      false
    }
  }

  var canStopRecording: Bool {
    phase == .recording
  }

  var canRetryAnalysis: Bool {
    phase == .transcriptReady
      && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var shouldShowAnalysisTabs: Bool {
    switch phase {
    case .stopping, .transcriptReady, .generating, .completed:
      true
    default:
      false
    }
  }

  func startRecording() {
    guard canStartRecording else { return }

    workflowTask?.cancel()
    presentedError = nil
    transcript = ""
    analysis = nil
    phase = .starting

    let operationID = UUID()
    let captureMode = captureMode
    activeOperationID = operationID
    workflowTask = Task { [weak self] in
      await self?.beginRecording(
        operationID: operationID,
        captureMode: captureMode
      )
    }
  }

  func stopRecording() {
    guard canStopRecording, let operationID = activeOperationID else { return }
    phase = .stopping

    workflowTask = Task { [weak self] in
      await self?.finishRecordingAndAnalyze(operationID: operationID)
    }
  }

  func retryAnalysis() {
    guard canRetryAnalysis else { return }
    presentedError = nil
    phase = .generating

    let operationID = UUID()
    activeOperationID = operationID
    workflowTask = Task { [weak self] in
      await self?.generateAnalysis(operationID: operationID)
    }
  }

  func cancelProcessing() {
    guard
      phase.isBusy,
      cleanupOperationID == nil,
      let operationID = activeOperationID
    else { return }
    scheduleCleanup(operationID: operationID)
  }

  func export(_ format: ExportFormat) {
    guard let analysis, !isExporting else { return }
    isExporting = true
    presentedError = nil

    Task { [weak self] in
      guard let self else { return }
      defer { self.isExporting = false }

      do {
        _ = try await self.exportService.export(
          analysis: analysis,
          format: format,
          title: self.normalizedTitle
        )
      } catch is CancellationError {
        // 保存パネルのキャンセルはエラー表示しません。
      } catch let error as AppError where error == .cancelled {
        // 同上。
      } catch {
        self.present(error)
      }
    }
  }

  func dismissError() {
    presentedError = nil
  }

  private var normalizedTitle: String {
    let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "無題の会議" : title
  }

  private func beginRecording(
    operationID: UUID,
    captureMode: MeetingCaptureMode
  ) async {
    guard activeOperationID == operationID else { return }
    let speechService = speechServiceFactory()

    // 音声認識の権限確認や辞書アセット取得の待機中でも、
    // cancelProcessing() から開始予約を無効化できるよう先に保持します。
    self.speechService = speechService

    do {
      let updates = try await speechService.start(locale: .current)
      try ensureCurrent(operationID)

      let session = try await recordingService.startRecording(mode: captureMode)
      try ensureCurrent(operationID)

      transcriptTask = Task { @MainActor [weak self] in
        do {
          for try await update in updates {
            try Task.checkCancellation()
            guard self?.activeOperationID == operationID else {
              throw CancellationError()
            }
            self?.transcript = update.displayText
          }
          if self?.phase == .recording {
            self?.handleLiveWorkerFailure(
              AppError.speech("文字起こしが予期せず終了しました。"),
              operationID: operationID
            )
          }
        } catch {
          self?.handleLiveWorkerFailure(error, operationID: operationID)
        }
      }

      sampleTask = Task { @MainActor [weak self] in
        do {
          for try await sample in session.samples {
            try Task.checkCancellation()
            try await speechService.append(sample)
          }
          if self?.phase == .recording {
            self?.handleLiveWorkerFailure(
              AppError.recording("音声入力が予期せず終了しました。"),
              operationID: operationID
            )
          }
        } catch {
          self?.handleLiveWorkerFailure(error, operationID: operationID)
        }
      }

      phase = .recording
    } catch {
      await speechService.cancel()
      guard activeOperationID == operationID else { return }
      if !isCancellation(error) { present(error) }
      scheduleCleanup(operationID: operationID)
    }
  }

  private func finishRecordingAndAnalyze(operationID: UUID) async {
    guard activeOperationID == operationID else { return }

    let speechService = self.speechService
    let sampleTask = self.sampleTask
    let transcriptTask = self.transcriptTask

    do {
      let stoppedFileURL = try await recordingService.stopRecording()
      try ensureCurrent(operationID)

      await sampleTask?.value
      try ensureCurrent(operationID)

      try await speechService?.finish()
      await transcriptTask?.value
      try ensureCurrent(operationID)

      if let stoppedFileURL {
        try await recordingService.discardRecording(at: stoppedFileURL)
        try ensureCurrent(operationID)
      }

      self.sampleTask = nil
      self.transcriptTask = nil
      self.speechService = nil
      phase = .transcriptReady

      guard
        !transcript
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      else {
        throw AppError.speech("認識できる発話がありませんでした。")
      }

      phase = .generating
      await generateAnalysis(operationID: operationID)
    } catch {
      guard activeOperationID == operationID else { return }
      if !isCancellation(error) { present(error) }
      scheduleCleanup(operationID: operationID)
    }
  }

  private func generateAnalysis(operationID: UUID) async {
    do {
      let generated = try await analysisService.analyze(
        title: normalizedTitle,
        transcript: transcript
      )
      try ensureCurrent(operationID)
      analysis = generated
      activeOperationID = nil
      phase = .completed
    } catch {
      guard activeOperationID == operationID else { return }
      activeOperationID = nil
      phase = .transcriptReady
      if !isCancellation(error) {
        present(error)
      }
    }
  }

  /// 録音・文字起こしワーカーの失敗を録音中に検知し、入力を止めます。
  private func handleLiveWorkerFailure(_ error: Error, operationID: UUID) {
    guard activeOperationID == operationID else { return }

    if !isCancellation(error) {
      if error is AppError {
        present(error)
      } else {
        present(AppError.speech(error.localizedDescription))
      }
    }
    scheduleCleanup(operationID: operationID)
  }

  /// 現在のセッションだけを破棄します。operationIDを先に無効化することで、
  /// 古いタスクが次のセッションの状態を上書きするのを防ぎます。
  private func scheduleCleanup(operationID: UUID) {
    guard activeOperationID == operationID, cleanupOperationID == nil else {
      return
    }

    let cleanupID = UUID()
    activeOperationID = cleanupID
    cleanupOperationID = cleanupID

    let speechService = self.speechService
    let sampleTask = self.sampleTask
    let transcriptTask = self.transcriptTask
    let recordingService = self.recordingService

    self.speechService = nil
    self.sampleTask = nil
    self.transcriptTask = nil

    workflowTask?.cancel()
    sampleTask?.cancel()
    transcriptTask?.cancel()

    if phase == .recording {
      phase = .stopping
    }

    workflowTask = Task { @MainActor [weak self] in
      // 音声認識は録音ファイルの削除成否にかかわらず必ず停止します。
      // 削除失敗は黙殺せず、後始末が終わってから利用者へ通知します。
      let cleanupError: Error?
      do {
        try await recordingService.cancelRecording()
        cleanupError = nil
      } catch {
        cleanupError = error
      }
      await speechService?.cancel()

      guard let self, self.activeOperationID == cleanupID else { return }
      self.activeOperationID = nil
      self.cleanupOperationID = nil
      self.phase = self.transcript.isEmpty ? .idle : .transcriptReady
      if let cleanupError {
        self.present(cleanupError)
      }
    }
  }

  private func ensureCurrent(_ operationID: UUID) throws {
    try Task.checkCancellation()
    guard activeOperationID == operationID else {
      throw CancellationError()
    }
  }

  private func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? AppError) == .cancelled
  }

  private func present(_ error: Error) {
    if let appError = error as? AppError {
      presentedError = appError
    } else {
      presentedError = .invalidResponse(error.localizedDescription)
    }
  }
}
