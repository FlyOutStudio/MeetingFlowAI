import XCTest

@testable import MeetingFlowAI

final class MermaidGeneratorTests: XCTestCase {
  func testRenderCreatesNodesAndEdgesInArrayOrder() {
    let flow = [
      FlowStep(
        id: "order 1",
        actor: "営業",
        action: "受注確認",
        next: [FlowTransition(to: "stock/check", label: "")]
      ),
      FlowStep(
        id: " stock/check ",
        actor: "管理部",
        action: "在庫確認",
        next: [FlowTransition(to: "shipping", label: "")]
      ),
      FlowStep(id: "shipping", actor: "物流", action: "発送", next: []),
    ]

    let expected = """
      flowchart TD
          step_1["営業<br/>受注確認"]
          step_2["管理部<br/>在庫確認"]
          step_3["物流<br/>発送"]
          step_1 --> step_2
          step_2 --> step_3
      """

    XCTAssertEqual(MermaidGenerator.render(flow: flow), expected)
    XCTAssertEqual(MermaidGenerator.generate(from: flow), expected)
  }

  func testRenderCreatesDecisionNodeAndLabeledBranches() {
    let flow = [
      FlowStep(
        id: "1",
        actor: "管理部",
        action: "在庫あり",
        next: [
          FlowTransition(to: "2", label: "Yes"),
          FlowTransition(to: "3", label: "No"),
        ]
      ),
      FlowStep(id: "2", actor: "物流", action: "発送", next: []),
      FlowStep(id: "3", actor: "購買", action: "発注", next: []),
    ]

    let rendered = MermaidGenerator.render(flow: flow)
    XCTAssertTrue(rendered.contains("step_1{\"管理部<br/>在庫あり\"}"))
    XCTAssertTrue(rendered.contains("step_1 -->|Yes| step_2"))
    XCTAssertTrue(rendered.contains("step_1 -->|No| step_3"))
  }

  func testRenderOfEmptyFlowIsValidEmptyChart() {
    XCTAssertEqual(MermaidGenerator.render(flow: []), "flowchart TD")
  }

  func testRenderEscapesNodeAndTransitionLabels() {
    let flow = [
      FlowStep(
        id: "1",
        actor: "営業 & \"CS\"",
        action: "確認<承認>\n連絡",
        next: [FlowTransition(to: "2", label: "承認|例外")]
      ),
      FlowStep(id: "2", actor: "管理部", action: "完了", next: []),
    ]

    let rendered = MermaidGenerator.render(flow: flow)
    XCTAssertTrue(
      rendered.contains(
        "step_1[\"営業 &amp; &quot;CS&quot;<br/>確認&lt;承認&gt;<br/>連絡\"]"
      )
    )
    XCTAssertTrue(rendered.contains("step_1 -->|承認&#124;例外| step_2"))
  }
}
