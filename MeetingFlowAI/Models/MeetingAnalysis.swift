import Foundation

/// AI が生成した会議分析の全体像です。
///
/// `flow` を業務フローの正本とし、`mermaid` は常に `flow` から再生成します。
/// これにより、将来 Miro・BPMN・draw.io などの出力を追加しても、表示形式間で
/// 内容が食い違いません。
struct MeetingAnalysis: Codable, Equatable, Sendable {
  let summary: String
  let todo: [TodoItem]
  let flow: [FlowStep]
  var mermaid: String { MermaidGenerator.render(flow: flow) }

  init(
    summary: String,
    todo: [TodoItem],
    flow: [FlowStep]
  ) {
    self.summary = summary
    self.todo = todo
    self.flow = flow
  }

  private enum CodingKeys: String, CodingKey {
    case summary
    case todo
    case flow
    case mermaid
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let summary = try container.decode(String.self, forKey: .summary)
    let todo = try container.decode([TodoItem].self, forKey: .todo)
    let flow = try container.decode([FlowStep].self, forKey: .flow)

    try Self.validate(todo: todo, flow: flow, codingPath: decoder.codingPath)

    // Responses APIはsummary/todo/flowだけを返します。Export JSONにmermaidが
    // 含まれていても読み捨て、常にflowから計算することで正本を一つに保ちます。
    self.init(summary: summary, todo: todo, flow: flow)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(summary, forKey: .summary)
    try container.encode(todo, forKey: .todo)
    try container.encode(flow, forKey: .flow)
    try container.encode(mermaid, forKey: .mermaid)
  }

  /// Mermaid・Miro・BPMNなど全出力の正本になるため、参照の不整合を
  /// API境界で拒否します。循環や自己参照は実業務であり得るため許可します。
  private static func validate(
    todo: [TodoItem],
    flow: [FlowStep],
    codingPath: [any CodingKey]
  ) throws {
    guard
      todo.allSatisfy({
        !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription: "todo.title must not be empty"
        )
      )
    }

    let ids = flow.map {
      $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard ids.allSatisfy({ !$0.isEmpty }) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription: "flow.id must not be empty"
        )
      )
    }

    guard Set(ids).count == ids.count else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription: "flow.id must be unique"
        )
      )
    }

    guard
      flow.allSatisfy({
        !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: codingPath,
          debugDescription: "flow.action must not be empty"
        )
      )
    }

    let knownIDs = Set(ids)
    for transition in flow.flatMap(\.next) {
      let destination = transition.to.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !destination.isEmpty, knownIDs.contains(destination) else {
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: codingPath,
            debugDescription: "flow.next contains an unknown destination"
          )
        )
      }
    }
  }
}

/// 会議から抽出した実行項目です。
struct TodoItem: Codable, Equatable, Hashable, Sendable {
  let title: String
  let owner: String
  let deadline: String
  let priority: TodoPriority
}

/// Responses API と授受する優先度。raw value は JSON Schema の列挙値と一致します。
enum TodoPriority: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case high = "High"
  case medium = "Medium"
  case low = "Low"

  var localizedName: String {
    switch self {
    case .high:
      "高"
    case .medium:
      "中"
    case .low:
      "低"
    }
  }
}

/// 業務フローを構成する一つの処理です。
/// `next` は0件なら終端、複数件なら条件分岐を表します。
struct FlowStep: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: String
  let actor: String
  let action: String
  let next: [FlowTransition]
}

/// 工程間の有向遷移です。`label`は「Yes」「承認」などの分岐条件で、
/// 無条件遷移では空文字列にします。
struct FlowTransition: Codable, Equatable, Hashable, Sendable {
  let to: String
  let label: String
}
