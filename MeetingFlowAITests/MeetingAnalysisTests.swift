import Foundation
import XCTest

@testable import MeetingFlowAI

final class MeetingAnalysisTests: XCTestCase {
  func testInitializerGeneratesMermaidFromFlow() {
    let flow = [
      FlowStep(
        id: "1",
        actor: "営業",
        action: "受注確認",
        next: [FlowTransition(to: "2", label: "")]
      ),
      FlowStep(id: "2", actor: "管理部", action: "在庫確認", next: []),
    ]

    let analysis = MeetingAnalysis(
      summary: "要約",
      todo: [],
      flow: flow
    )

    XCTAssertEqual(analysis.mermaid, MermaidGenerator.render(flow: flow))
  }

  func testDecoderDoesNotRequireMermaidAndGeneratesItFromFlow() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [],
        "flow": [
          {"id": "A", "actor": "営業", "action": "確認", "next": []}
        ]
      }
      """

    let analysis = try JSONDecoder().decode(
      MeetingAnalysis.self,
      from: XCTUnwrap(source.data(using: .utf8))
    )

    XCTAssertEqual(
      analysis.mermaid,
      "flowchart TD\n    step_1[\"営業<br/>確認\"]"
    )
  }

  func testDecoderIgnoresExportedMermaidAndRegeneratesIt() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [],
        "flow": [
          {"id": "A", "actor": "営業", "action": "確認", "next": []}
        ],
        "mermaid": "flowchart LR\\ntrusting --> this_would_be_wrong"
      }
      """

    let analysis = try JSONDecoder().decode(
      MeetingAnalysis.self,
      from: XCTUnwrap(source.data(using: .utf8))
    )

    XCTAssertEqual(
      analysis.mermaid,
      "flowchart TD\n    step_1[\"営業<br/>確認\"]"
    )
    XCTAssertFalse(analysis.mermaid.contains("this_would_be_wrong"))
  }

  func testDecoderRejectsDuplicateFlowIDsAfterTrimming() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [],
        "flow": [
          {"id": "A", "actor": "営業", "action": "確認", "next": []},
          {"id": " A ", "actor": "管理部", "action": "承認", "next": []}
        ]
      }
      """

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        MeetingAnalysis.self,
        from: XCTUnwrap(source.data(using: .utf8))
      )
    ) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("dataCorrupted以外のエラーです: \(error)")
      }
      XCTAssertTrue(context.debugDescription.contains("unique"))
    }
  }

  func testDecoderRejectsUnknownTransitionDestination() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [],
        "flow": [
          {
            "id": "A",
            "actor": "営業",
            "action": "確認",
            "next": [{"to": "missing", "label": "No"}]
          }
        ]
      }
      """

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        MeetingAnalysis.self,
        from: XCTUnwrap(source.data(using: .utf8))
      )
    ) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("dataCorrupted以外のエラーです: \(error)")
      }
      XCTAssertTrue(context.debugDescription.contains("unknown destination"))
    }
  }

  func testDecoderRejectsWhitespaceOnlyFlowAction() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [],
        "flow": [
          {"id": "A", "actor": "", "action": "   ", "next": []}
        ]
      }
      """

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        MeetingAnalysis.self,
        from: XCTUnwrap(source.data(using: .utf8))
      )
    ) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("dataCorrupted以外のエラーです: \(error)")
      }
      XCTAssertTrue(context.debugDescription.contains("action"))
    }
  }

  func testDecoderRejectsWhitespaceOnlyTodoTitle() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [
          {"title": "  ", "owner": "", "deadline": "", "priority": "Medium"}
        ],
        "flow": []
      }
      """

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        MeetingAnalysis.self,
        from: XCTUnwrap(source.data(using: .utf8))
      )
    ) { error in
      guard case DecodingError.dataCorrupted(let context) = error else {
        return XCTFail("dataCorrupted以外のエラーです: \(error)")
      }
      XCTAssertTrue(context.debugDescription.contains("todo.title"))
    }
  }

  func testAIDecoderNormalizesNonFatalContractDifferences() throws {
    let source = """
      {
        "summary": "要約",
        "todo": [
          {"title": " ", "owner": "", "deadline": "", "priority": "Medium"},
          {"title": "実行", "owner": "", "deadline": "", "priority": "Unknown"}
        ],
        "flow": [
          {"id": "A", "actor": "営業", "action": "確認", "next": [{"to": "missing", "label": "No"}]},
          {"id": "A", "actor": "管理部", "action": "承認", "next": []},
          {"id": "B", "actor": "", "action": " ", "next": []}
        ]
      }
      """

    let analysis = try MeetingAnalysis.decodeAIOutput(
      from: XCTUnwrap(source.data(using: .utf8))
    )

    XCTAssertEqual(analysis.todo.map(\.title), ["実行"])
    XCTAssertEqual(analysis.todo.first?.priority, .medium)
    XCTAssertEqual(analysis.flow.map(\.id), ["A", "A-2"])
    XCTAssertTrue(analysis.flow.allSatisfy { $0.next.isEmpty })
  }

  func testAIDecoderAddsMissingMinutesSections() throws {
    let source = """
      {
        "summary": "受注確認の運用を見直すことで合意した。",
        "todo": [],
        "flow": []
      }
      """

    let analysis = try MeetingAnalysis.decodeAIOutput(
      from: XCTUnwrap(source.data(using: .utf8))
    )

    XCTAssertTrue(analysis.summary.contains("受注確認の運用を見直すことで合意した。"))
    for section in [
      "会議の目的・背景",
      "主な議論",
      "決定事項",
      "未決事項・確認事項",
      "次の対応",
    ] {
      XCTAssertTrue(analysis.summary.contains("## \(section)"))
    }
  }

  func testAIDecoderTreatsMissingOrNullFieldsAsEmptyValues() throws {
    let source = """
      {
        "summary": null,
        "todo": [
          {"title": "確認", "owner": null, "deadline": null, "priority": null},
          {"owner": "田中"}
        ],
        "flow": [
          {"id": "A", "actor": null, "action": "確認", "next": null},
          {"id": "B", "actor": "営業", "action": "共有", "next": [{"to": "A"}]}
        ]
      }
      """

    let analysis = try MeetingAnalysis.decodeAIOutput(
      from: XCTUnwrap(source.data(using: .utf8))
    )

    XCTAssertTrue(analysis.summary.contains("## 会議の目的・背景"))
    XCTAssertEqual(analysis.todo.count, 1)
    XCTAssertEqual(analysis.todo.first?.owner, "")
    XCTAssertEqual(analysis.todo.first?.deadline, "")
    XCTAssertEqual(analysis.todo.first?.priority, .medium)
    XCTAssertEqual(analysis.flow.map(\.id), ["A", "B"])
    XCTAssertEqual(analysis.flow[1].next, [FlowTransition(to: "A", label: "")])
  }

  func testPriorityUsesSchemaRawValues() throws {
    XCTAssertEqual(TodoPriority.allCases.map(\.rawValue), ["High", "Medium", "Low"])

    let item = TodoItem(
      title: "在庫確認",
      owner: "田中",
      deadline: "2026-08-05",
      priority: .high
    )
    let data = try JSONEncoder().encode(item)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: String]
    )

    XCTAssertEqual(object["priority"], "High")
    XCTAssertEqual(item.priority.localizedName, "高")
  }
}
