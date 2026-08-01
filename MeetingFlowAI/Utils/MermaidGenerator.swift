import Foundation

/// 構造化された業務フローから Mermaid を生成します。
enum MermaidGenerator {
  /// 配列順を維持して Mermaid の flowchart を生成します。
  ///
  /// ノードIDには入力値を直接使わず、配列順の安全なIDを割り当てます。
  /// そのため、AIが空白や記号を含むIDを返しても Mermaid の構文を壊しません。
  static func render(flow: [FlowStep]) -> String {
    var lines = ["flowchart TD"]
    var firstNodeByFlowID: [String: String] = [:]

    for (index, step) in flow.enumerated() {
      let nodeID = nodeID(at: index)
      let flowID = normalizedFlowID(step.id)
      if firstNodeByFlowID[flowID] == nil {
        firstNodeByFlowID[flowID] = nodeID
      }

      let actor = escapedLabel(step.actor)
      let action = escapedLabel(step.action)
      let label: String

      if actor.isEmpty {
        label = action
      } else if action.isEmpty {
        label = actor
      } else {
        label = "\(actor)<br/>\(action)"
      }

      if step.next.count > 1 {
        lines.append("    \(nodeID){\"\(label)\"}")
      } else {
        lines.append("    \(nodeID)[\"\(label)\"]")
      }
    }

    for (index, step) in flow.enumerated() {
      for transition in step.next {
        let next = transition.to.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        guard let destination = firstNodeByFlowID[next] else {
          continue
        }

        let edgeLabel = escapedLabel(transition.label)
        if edgeLabel.isEmpty {
          lines.append("    \(nodeID(at: index)) --> \(destination)")
        } else {
          lines.append(
            "    \(nodeID(at: index)) -->|\(edgeLabel)| \(destination)"
          )
        }
      }
    }

    return lines.joined(separator: "\n")
  }

  /// 呼び出し側の自然な表現に合わせた別名です。
  static func generate(from steps: [FlowStep]) -> String {
    render(flow: steps)
  }

  private static func nodeID(at index: Int) -> String {
    "step_\(index + 1)"
  }

  private static func normalizedFlowID(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func escapedLabel(_ source: String) -> String {
    source
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "|", with: "&#124;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\r\n", with: "<br/>")
      .replacingOccurrences(of: "\r", with: "<br/>")
      .replacingOccurrences(of: "\n", with: "<br/>")
  }
}
