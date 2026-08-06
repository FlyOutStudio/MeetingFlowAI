import Foundation
import SwiftData

/// SwiftDataの初期スキーマです。将来フィールドを変更する場合は、新しい
/// VersionedSchemaとMigrationStageを追加して既存の議事録を引き継ぎます。
enum MeetingSchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)
  static var models: [any PersistentModel.Type] {
    [StoredMeeting.self]
  }
}

enum MeetingDataMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [MeetingSchemaV1.self]
  }

  static var stages: [MigrationStage] {
    []
  }
}

@Model
final class StoredMeeting {
  @Attribute(.unique) var id: UUID
  var title: String
  var transcript: String
  var analysisJSON: Data?
  var captureModeRawValue: String?
  var sourceRawValue: String
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID,
    title: String,
    transcript: String,
    analysisJSON: Data?,
    captureModeRawValue: String?,
    sourceRawValue: String,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.title = title
    self.transcript = transcript
    self.analysisJSON = analysisJSON
    self.captureModeRawValue = captureModeRawValue
    self.sourceRawValue = sourceRawValue
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

enum MeetingSource: String, Codable, Equatable, Sendable {
  case recording
  case importedAudio

  var displayName: String {
    switch self {
    case .recording:
      "録音"
    case .importedAudio:
      "音声ファイル"
    }
  }
}

struct MeetingRecord: Equatable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let transcript: String
  let analysis: MeetingAnalysis?
  let captureMode: MeetingCaptureMode?
  let source: MeetingSource
  let createdAt: Date
  let updatedAt: Date
}
