import Foundation
@preconcurrency import Speech

/// macOS 15〜25向けのSpeech Framework実装です。
///
/// SFSpeechRecognizerは長時間入力でタスクを終了することがあるため、録音継続中に
/// final結果を受け取った場合は新しい認識タスクを開始し、確定済みテキストへ連結します。
actor LegacySpeechService: SpeechServicing {
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var updateContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?

  private var finalizedText = ""
  private var currentPartialText = ""
  private var startID: UUID?
  private var isActive = false
  private var isFinishing = false

  func start(
    locale: Locale
  ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
    guard !isActive, startID == nil else {
      throw AppError.speech("文字起こしはすでに開始されています。")
    }

    // 権限待ち中の actor 再入による二重開始を防ぎます。
    let startID = UUID()
    self.startID = startID

    do {
      return try await prepareAndStart(locale: locale, startID: startID)
    } catch {
      if self.startID == startID {
        self.startID = nil
      }
      throw error
    }
  }

  private func prepareAndStart(
    locale: Locale,
    startID: UUID
  ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
    try await requestSpeechRecognitionPermission()
    try Task.checkCancellation()
    guard self.startID == startID else {
      throw CancellationError()
    }

    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      throw AppError.speech("選択中の言語は音声認識に対応していません。")
    }
    guard recognizer.isAvailable else {
      throw AppError.speech("音声認識を現在利用できません。")
    }

    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: TranscriptUpdate.self,
      throwing: Error.self,
      bufferingPolicy: .bufferingNewest(16)
    )

    self.recognizer = recognizer
    updateContinuation = continuation
    finalizedText = ""
    currentPartialText = ""
    isActive = true
    isFinishing = false
    self.startID = nil

    do {
      try startRecognitionTask()
    } catch {
      reset()
      throw error
    }
    return stream
  }

  func append(_ sample: AudioSample) async throws {
    guard isActive, let recognitionRequest else {
      throw AppError.speech("文字起こしが開始されていません。")
    }
    recognitionRequest.append(sample.buffer)
  }

  func finish() async throws {
    guard isActive else { return }
    isFinishing = true
    recognitionRequest?.endAudio()
  }

  func cancel() async {
    // start() が権限ダイアログ待ちなら、開始予約だけを無効化します。
    startID = nil
    guard isActive else { return }
    isFinishing = true
    recognitionTask?.cancel()
    updateContinuation?.finish(throwing: CancellationError())
    reset()
  }

  private func startRecognitionTask() throws {
    guard let recognizer else {
      throw AppError.speech("音声認識器を初期化できませんでした。")
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }

    recognitionRequest = request
    recognitionTask = recognizer.recognitionTask(with: request) {
      [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let errorDetails = error.map {
        let nsError = $0 as NSError
        return LegacyRecognitionError(
          domain: nsError.domain,
          code: nsError.code
        )
      }

      Task {
        await self?.handleRecognitionResult(
          text: text,
          isFinal: isFinal,
          error: errorDetails
        )
      }
    }
  }

  private func handleRecognitionResult(
    text: String?,
    isFinal: Bool,
    error: LegacyRecognitionError?
  ) async {
    guard isActive else { return }

    if let text {
      currentPartialText = text
      updateContinuation?.yield(
        TranscriptUpdate(
          finalizedText: finalizedText,
          volatileText: text
        )
      )
    }

    if isFinal {
      finalizedText = joined(finalizedText, currentPartialText)
      currentPartialText = ""
      updateContinuation?.yield(
        TranscriptUpdate(
          finalizedText: finalizedText,
          volatileText: ""
        )
      )

      recognitionTask = nil
      recognitionRequest = nil

      if isFinishing {
        updateContinuation?.finish()
        reset()
      } else {
        do {
          try startRecognitionTask()
        } catch {
          updateContinuation?.finish(throwing: error)
          reset()
        }
      }
      return
    }

    if let error {
      // 停止要求後でも、接続・認証エラーを正常終了として隠しません。
      // 正常終了時は通常isFinalが先に通知されるため、errorだけの通知は
      // 不完全な文字起こしとして明示的に失敗させます。
      updateContinuation?.finish(
        throwing: AppError.speech(
          "音声認識に失敗しました（\(error.domain):\(error.code)）。"
        )
      )
      reset()
    }
  }

  private func requestSpeechRecognitionPermission() async throws {
    let currentStatus = SFSpeechRecognizer.authorizationStatus()
    let status: SFSpeechRecognizerAuthorizationStatus

    if currentStatus == .notDetermined {
      status = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { newStatus in
          continuation.resume(returning: newStatus)
        }
      }
    } else {
      status = currentStatus
    }

    guard status == .authorized else {
      throw AppError.permissionDenied("音声認識")
    }
  }

  private func joined(_ first: String, _ second: String) -> String {
    [first, second]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func reset() {
    recognitionTask = nil
    recognitionRequest = nil
    recognizer = nil
    updateContinuation = nil
    startID = nil
    isActive = false
    isFinishing = false
    currentPartialText = ""
  }
}

private struct LegacyRecognitionError: Sendable {
  let domain: String
  let code: Int
}
