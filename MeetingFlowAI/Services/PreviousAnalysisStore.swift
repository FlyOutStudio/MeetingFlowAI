import Foundation

@MainActor
protocol PreviousAnalysisStoring {
  func save(_ analysis: MeetingAnalysis, for meetingID: UUID) throws
  func load(for meetingID: UUID) throws -> MeetingAnalysis?
  func hasSavedAnalysis(for meetingID: UUID) -> Bool
}

/// AI再生成の直前の解析結果を端末内へ退避します。
///
/// SwiftDataの会議履歴を上書きする前に一つ前の解析を別ファイルとして保存し、
/// 不適切な再生成結果でも利用者が元へ戻せるようにします。
@MainActor
final class PreviousAnalysisStore: PreviousAnalysisStoring {
  private let directoryURL: URL
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    directoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
  }

  func save(_ analysis: MeetingAnalysis, for meetingID: UUID) throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    try encoder.encode(analysis).write(to: fileURL(for: meetingID), options: .atomic)
  }

  func load(for meetingID: UUID) throws -> MeetingAnalysis? {
    let url = fileURL(for: meetingID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try decoder.decode(MeetingAnalysis.self, from: Data(contentsOf: url))
  }

  func hasSavedAnalysis(for meetingID: UUID) -> Bool {
    fileManager.fileExists(atPath: fileURL(for: meetingID).path)
  }

  private func fileURL(for meetingID: UUID) -> URL {
    directoryURL.appendingPathComponent("\(meetingID.uuidString).json")
  }

  private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
    let applicationSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    return applicationSupportURL
      .appendingPathComponent("MeetingFlowAI", isDirectory: true)
      .appendingPathComponent("PreviousAnalyses", isDirectory: true)
  }
}
