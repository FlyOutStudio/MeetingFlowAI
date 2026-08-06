import Foundation
import SwiftData
import XCTest

@testable import MeetingFlowAI

final class MeetingHistoryStoreTests: XCTestCase {
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
