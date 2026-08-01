import Foundation

/// 会議音声をどこから取得するかを表します。
enum MeetingCaptureMode: String, CaseIterable, Identifiable, Sendable {
  case microphone
  case onlineMeeting

  var id: Self { self }

  var displayName: String {
    switch self {
    case .microphone:
      "対面会議"
    case .onlineMeeting:
      "オンライン会議"
    }
  }

  var description: String {
    switch self {
    case .microphone:
      "Macのマイク入力を録音します。"
    case .onlineMeeting:
      "選択した会議アプリの音声と自分のマイクを録音します。イヤホンの使用を推奨します。"
    }
  }

  var systemImage: String {
    switch self {
    case .microphone:
      "person.2.wave.2"
    case .onlineMeeting:
      "macbook.and.iphone"
    }
  }
}
