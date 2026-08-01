import Foundation

#if compiler(>=6.2)
  import Speech
#endif

struct TranscriptUpdate: Equatable, Sendable {
  let finalizedText: String
  let volatileText: String

  var displayText: String {
    [finalizedText, volatileText]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: finalizedText.isEmpty ? "" : " ")
  }
}

protocol SpeechServicing: Sendable {
  func start(
    locale: Locale
  ) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
  func append(_ sample: AudioSample) async throws
  func finish() async throws
  func cancel() async
}

enum SpeechServiceFactory {
  static func make() -> any SpeechServicing {
    // SpeechAnalyzer は macOS 26 SDKで追加されたため、古いSDKでもソースを
    // ビルドできるようコンパイラと実行OSの両方で分岐します。
    #if compiler(>=6.2)
      if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
        return SpeechAnalyzerService()
      }
    #endif

    return LegacySpeechService()
  }
}
