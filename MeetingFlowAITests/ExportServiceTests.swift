import Foundation
import XCTest

@testable import MeetingFlowAI

final class ExportServiceTests: XCTestCase {
  private let analysis = MeetingAnalysis(
    summary: "- 決定事項: 在庫を確認する",
    todo: [
      TodoItem(
        title: "在庫|一覧を更新",
        owner: "田中\n佐藤",
        deadline: "2026-08-05",
        priority: .high
      )
    ],
    flow: [
      FlowStep(
        id: "1",
        actor: "営業",
        action: "受注確認",
        next: [FlowTransition(to: "2", label: "")]
      ),
      FlowStep(id: "2", actor: "管理部", action: "在庫確認", next: []),
    ]
  )

  func testMarkdownContainsAllStructuredSections() {
    let content = ExportService.markdownContent(
      for: analysis,
      title: "週次会議\n2026"
    )

    XCTAssertTrue(content.hasPrefix("# 週次会議 2026\n"))
    XCTAssertTrue(content.contains("## 議事録"))
    XCTAssertTrue(content.contains("## ToDo"))
    XCTAssertTrue(content.contains("在庫\\|一覧を更新"))
    XCTAssertTrue(content.contains("田中<br>佐藤"))
    XCTAssertTrue(content.contains("## 業務フロー"))
    XCTAssertTrue(content.contains("## Mermaid"))
    XCTAssertTrue(content.contains("step_1 --> step_2"))
    XCTAssertTrue(content.hasSuffix("```\n"))
  }

  func testMermaidContentIsRegeneratedFromFlow() {
    let expected = MermaidGenerator.render(flow: analysis.flow) + "\n"
    XCTAssertEqual(ExportService.mermaidContent(for: analysis), expected)
  }

  func testJSONContainsAllContractFieldsAndCanonicalMermaid() throws {
    let content = try ExportService.jsonContent(for: analysis)
    let data = try XCTUnwrap(content.data(using: .utf8))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(Set(object.keys), ["summary", "todo", "flow", "mermaid"])
    XCTAssertEqual(object["summary"] as? String, analysis.summary)
    XCTAssertEqual(object["mermaid"] as? String, MermaidGenerator.render(flow: analysis.flow))
    XCTAssertEqual((object["todo"] as? [[String: Any]])?.count, 1)
    let flow = try XCTUnwrap(object["flow"] as? [[String: Any]])
    XCTAssertEqual(flow.count, 2)
    let transitions = try XCTUnwrap(flow.first?["next"] as? [[String: String]])
    XCTAssertEqual(transitions, [["to": "2", "label": ""]])
    XCTAssertTrue(content.hasSuffix("\n"))
  }

  func testContentRoutesToRequestedFormat() throws {
    XCTAssertEqual(
      try ExportService.content(for: analysis, format: .mermaid),
      ExportService.mermaidContent(for: analysis)
    )
    XCTAssertEqual(
      try ExportService.content(for: analysis, format: .json),
      try ExportService.jsonContent(for: analysis)
    )
    XCTAssertEqual(
      try ExportService.content(for: analysis, format: .markdown, title: "会議"),
      ExportService.markdownContent(for: analysis, title: "会議")
    )
  }

  func testEmptyCollectionsHaveReadablePlaceholders() {
    let empty = MeetingAnalysis(summary: "", todo: [], flow: [])
    let content = ExportService.markdownContent(for: empty)

    XCTAssertEqual(
      content.components(separatedBy: "| — | — | — | — |").count - 1,
      2
    )
  }
}
