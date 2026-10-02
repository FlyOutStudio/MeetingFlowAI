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
      let analysis: MeetingAnalysis?
      let analysisLoadError: String?
      do {
        analysis = try stored.analysisJSON.map { try decoder.decode(MeetingAnalysis.self, from: $0) }
        analysisLoadError = nil
      } catch {
        analysis = nil
        analysisLoadError = "保存済みの解析結果を読み込めません。原文と保存データを保護するため、この会議は読み取り専用です。"
      }
      return MeetingRecord(
        id: stored.id,
        title: stored.title,
        transcript: stored.transcript,
        analysis: analysis,
        captureMode: stored.captureModeRawValue.flatMap(MeetingCaptureMode.init),
        source: MeetingSource(rawValue: stored.sourceRawValue) ?? .recording,
        createdAt: stored.createdAt,
        updatedAt: stored.updatedAt,
        analysisLoadError: analysisLoadError
      )
    }
  }

  func upsert(_ record: MeetingRecord) throws {
    let storedMeetings = try modelContext.fetch(FetchDescriptor<StoredMeeting>())
    let analysisJSON = try record.analysis.map { try encoder.encode($0) }

    if let stored = storedMeetings.first(where: { $0.id == record.id }) {
      // A failed read must never be converted to a successful write of nil.
      // Preserve the original bytes for recovery, even for non-UI callers.
      if let data = stored.analysisJSON {
        do { _ = try decoder.decode(MeetingAnalysis.self, from: data) }
        catch { throw AppError.storage("読み込めない解析結果があるため、この会議は上書きできません。") }
      }
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

    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  func delete(id: UUID) throws {
    let storedMeetings = try modelContext.fetch(FetchDescriptor<StoredMeeting>())
    guard let stored = storedMeetings.first(where: { $0.id == id }) else { return }
    modelContext.delete(stored)
    try modelContext.save()
  }
}
