import Foundation

/// 会議セッション全体の状態遷移を表します。
enum SessionPhase: Equatable, Sendable {
  case idle
  case starting
  case importing
  case recording
  case stopping
  case transcriptReady
  case generating
  case completed

  var isBusy: Bool {
    switch self {
    case .starting, .importing, .stopping, .generating:
      true
    default:
      false
    }
  }

  var statusText: String {
    switch self {
    case .idle:
      "待機中"
    case .starting:
      "録音を準備中"
    case .importing:
      "音声ファイルを文字起こし中"
    case .recording:
      "録音中"
    case .stopping:
      "文字起こしを確定中"
    case .transcriptReady:
      "文字起こし完了"
    case .generating:
      "業務フローを生成中"
    case .completed:
      "生成完了"
    }
  }
}
