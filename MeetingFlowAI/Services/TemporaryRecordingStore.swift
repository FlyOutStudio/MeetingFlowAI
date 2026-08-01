import Foundation

/// 文字起こし中だけ保持する一時録音ファイルを管理します。
enum TemporaryRecordingStore {
  static func makeURL() throws -> URL {
    let recordingsDirectory = try directory()

    // 異常終了で残った一時録音は、次回セッション開始時に回収します。
    let staleRecordings = try FileManager.default.contentsOfDirectory(
      at: recordingsDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "caf" }
    for staleRecording in staleRecordings {
      try FileManager.default.removeItem(at: staleRecording)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let filename =
      "meeting-\(formatter.string(from: Date()))-\(UUID().uuidString).caf"
    return recordingsDirectory.appendingPathComponent(filename)
  }

  static func discard(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private static func directory() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let recordingsDirectory =
      applicationSupport
      .appendingPathComponent("MeetingFlowAI", isDirectory: true)
      .appendingPathComponent("Recordings", isDirectory: true)

    try FileManager.default.createDirectory(
      at: recordingsDirectory,
      withIntermediateDirectories: true
    )
    return recordingsDirectory
  }
}
