import Foundation

/// 画面に表示できる、アプリ共通のエラーです。
///
/// Sendable ではない `Error` を保持せず、境界で安全な文字列へ変換することで
/// Swift Concurrency のタスク間でもそのまま受け渡せます。
enum AppError: LocalizedError, Equatable, Sendable {
  case permissionDenied(String)
  case microphonePermissionDenied
  case speechRecognitionPermissionDenied
  case speechRecognizerUnavailable
  case recording(String)
  case speech(String)
  case missingAPIKey
  case openAI(String)
  case invalidResponse(String)
  case keychain(String)
  case export(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .permissionDenied(let resource):
      "\(resource)へのアクセスが許可されていません。"
    case .microphonePermissionDenied:
      "マイクへのアクセスが許可されていません。"
    case .speechRecognitionPermissionDenied:
      "音声認識へのアクセスが許可されていません。"
    case .speechRecognizerUnavailable:
      "現在、音声認識を利用できません。"
    case .recording(let message):
      "録音に失敗しました。\(detail(message))"
    case .speech(let message):
      "文字起こしに失敗しました。\(detail(message))"
    case .missingAPIKey:
      "OpenAI APIキーが設定されていません。"
    case .openAI(let message):
      "AIによる会議分析に失敗しました。\(detail(message))"
    case .invalidResponse(let message):
      "AIから不正な応答を受信しました。\(detail(message))"
    case .keychain(let message):
      "APIキーをKeychainで処理できませんでした。\(detail(message))"
    case .export(let message):
      "ファイルの保存に失敗しました。\(detail(message))"
    case .cancelled:
      "処理をキャンセルしました。"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .permissionDenied(let resource):
      "システム設定の「プライバシーとセキュリティ」で「\(resource)」へのアクセスを許可してください。"
    case .microphonePermissionDenied:
      "システム設定の「プライバシーとセキュリティ」>「マイク」で、このアプリを許可してください。"
    case .speechRecognitionPermissionDenied:
      "システム設定の「プライバシーとセキュリティ」>「音声認識」で、このアプリを許可してください。"
    case .missingAPIKey:
      "アプリの「APIキー設定」を開き、OpenAI APIキーをKeychainへ保存してください。"
    case .speechRecognizerUnavailable:
      "ネットワーク接続を確認し、しばらく待ってから再試行してください。"
    case .keychain:
      "Macのログインキーチェーンがロックされていないか確認し、もう一度お試しください。"
    case .recording, .speech, .openAI, .invalidResponse, .export:
      "内容を確認して、もう一度お試しください。"
    case .cancelled:
      nil
    }
  }

  private func detail(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "" : "（\(trimmed)）"
  }
}
