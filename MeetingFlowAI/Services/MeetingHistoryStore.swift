import Foundation
import SwiftData

@MainActor
protocol MeetingHistoryStoring {
  func fetchAll() throws -> [MeetingRecord]
  func upsert(_ record: MeetingRecord) throws
  func delete(id: UUID) throws
}

@MainActor
final class MeetingHistoryStore: MeetingHistoryStoring {
  private let modelContext: ModelContext
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func fetchAll() throws -> [MeetingRecord] {
    let descriptor = FetchDescriptor<StoredMeeting>(
      sortBy: [SortDescriptor(\StoredMeeting.updatedAt, order: .reverse)]
    )

    return try modelContext.fetch(descriptor).map { stored in
      MeetingRecord(
        id: stored.id,
        title: stored.title,
        transcript: stored.transcript,
        analysis: stored.analysisJSON.flatMap {
          try? decoder.decode(MeetingAnalysis.self, from: $0)
        },
        captureMode: stored.captureModeRawValue.flatMap(MeetingCaptureMode.init),
        source: MeetingSource(rawValue: stored.sourceRawValue) ?? .recording,
        createdAt: stored.createdAt,
        updatedAt: stored.updatedAt
      )
    }
  }

  func upsert(_ record: MeetingRecord) throws {
    let storedMeetings = try modelContext.fetch(FetchDescriptor<StoredMeeting>())
    let analysisJSON = try record.analysis.map { try encoder.encode($0) }

    if let stored = storedMeetings.first(where: { $0.id == record.id }) {
      stored.title = record.title
      stored.transcript = record.transcript
      stored.analysisJSON = analysisJSON
      stored.captureModeRawValue = record.captureMode?.rawValue
      stored.sourceRawValue = record.source.rawValue
      stored.updatedAt = record.updatedAt
    } else {
      modelContext.insert(
        StoredMeeting(
          id: record.id,
          title: record.title,
          transcript: record.transcript,
          analysisJSON: analysisJSON,
          captureModeRawValue: record.captureMode?.rawValue,
          sourceRawValue: record.source.rawValue,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt
        )
      )
    }

    try modelContext.save()
  }

  func delete(id: UUID) throws {
    let storedMeetings = try modelContext.fetch(FetchDescriptor<StoredMeeting>())
    guard let stored = storedMeetings.first(where: { $0.id == id }) else { return }
    modelContext.delete(stored)
    try modelContext.save()
  }
}
