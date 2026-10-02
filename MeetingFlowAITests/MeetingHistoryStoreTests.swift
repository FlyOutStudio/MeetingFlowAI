import Foundation
import SwiftData
import XCTest

@testable import MeetingFlowAI

final class MeetingHistoryStoreTests: XCTestCase {
  @MainActor
  func testInterviewRoundTripAcrossContexts() throws {
    let schema = Schema(versionedSchema: MeetingSchemaV1.self)
    let configuration = ModelConfiguration("InterviewHistoryTests", schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, migrationPlan: MeetingDataMigrationPlan.self, configurations: [configuration])
    var analysis = try InterviewFixture.analysis()
    try analysis.businessInterview?.items[0].confirm(in: InterviewFixture.transcript)
    analysis.interviewCandidate = try InterviewFixture.interview()
    let record = MeetingRecord(id: UUID(), title: "保存", transcript: InterviewFixture.transcript,
      analysis: analysis, captureMode: nil, source: .importedAudio, createdAt: Date(), updatedAt: Date())
    try MeetingHistoryStore(modelContext: ModelContext(container)).upsert(record)
    let restored = try MeetingHistoryStore(modelContext: ModelContext(container)).fetchAll()
    XCTAssertEqual(restored, [record])
  }

  @MainActor
  func testCorruptInterviewIsIsolatedAndRawBytesAreProtected() throws {
    let schema = Schema(versionedSchema: MeetingSchemaV1.self)
    let configuration = ModelConfiguration("CorruptInterviewTests", schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, migrationPlan: MeetingDataMigrationPlan.self, configurations: [configuration])
    let context = ModelContext(container)
    let corruptData = Data(#"{"summary":"要約","todo":[],"flow":[],"businessInterview":{"items":[]}}"#.utf8)
    let id = UUID()
    context.insert(StoredMeeting(id: id, title: "破損テスト", transcript: InterviewFixture.transcript,
      analysisJSON: corruptData, captureModeRawValue: nil,
      sourceRawValue: MeetingSource.importedAudio.rawValue, createdAt: Date(), updatedAt: Date()))
    try context.save()
    let store = MeetingHistoryStore(modelContext: context)
    let healthy = MeetingRecord(id: UUID(), title: "正常", transcript: InterviewFixture.transcript,
      analysis: try InterviewFixture.analysis(), captureMode: nil, source: .importedAudio,
      createdAt: Date(), updatedAt: Date())
    try store.upsert(healthy)
    let records = try store.fetchAll()
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records.first(where: { $0.id == healthy.id }), healthy)
    let corrupt = try XCTUnwrap(records.first(where: { $0.id == id }))
    XCTAssertNil(corrupt.analysis)
    XCTAssertNotNil(corrupt.analysisLoadError)
    XCTAssertEqual(corrupt.transcript, InterviewFixture.transcript)
    XCTAssertThrowsError(try store.upsert(corrupt))
    let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredMeeting>()).first(where: { $0.id == id }))
    XCTAssertEqual(stored.analysisJSON, corruptData)
  }

  @MainActor
  func testUpsertFetchAndDelete() throws {
    let schema = Schema(versionedSchema: MeetingSchemaV1.self)
    let configuration = ModelConfiguration(
      "MeetingHistoryTests",
      schema: schema,
      isStoredInMemoryOnly: true
    )
    let container = try ModelContainer(
      for: schema,
      migrationPlan: MeetingDataMigrationPlan.self,
      configurations: [configuration]
    )
    let store = MeetingHistoryStore(modelContext: ModelContext(container))
    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let analysis = MeetingAnalysis(
      summary: "要約",
      todo: [],
      flow: [
        FlowStep(
          id: "1",
          actor: "担当",
          action: "確認",
          next: []
        )
      ]
    )

    try store.upsert(
      MeetingRecord(
        id: id,
        title: "初回",
        transcript: "文字起こし",
        analysis: nil,
        captureMode: .microphone,
        source: .recording,
        createdAt: createdAt,
        updatedAt: createdAt
      )
    )
    try store.upsert(
      MeetingRecord(
        id: id,
        title: "更新後",
        transcript: "文字起こし",
        analysis: analysis,
        captureMode: .microphone,
        source: .recording,
        createdAt: createdAt,
        updatedAt: createdAt.addingTimeInterval(60)
      )
    )

    let fetched = try store.fetchAll()
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].title, "更新後")
    XCTAssertEqual(fetched[0].analysis, analysis)
    XCTAssertEqual(fetched[0].createdAt, createdAt)

    try store.delete(id: id)
    XCTAssertTrue(try store.fetchAll().isEmpty)
  }
}
