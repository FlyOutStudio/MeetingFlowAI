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

extension MeetingAnalysis {
  /// ClaudeのStructured Outputをアプリの正規モデルへ変換します。
  ///
  /// Structured OutputのJSON Schemaでは、複数の工程間にまたがる参照整合性や
  /// 空文字列の禁止までは表現できません。まず通常の厳密decodeを試し、AI応答
  /// に限って非致命的な揺れを正規化します。ExportやSwiftDataからの復元は
  /// 通常の`JSONDecoder`を使うため、保存データの契約は緩めません。
  static func decodeAIOutput(from data: Data) throws -> MeetingAnalysis {
    do {
      return try JSONDecoder()
        .decode(MeetingAnalysis.self, from: data)
        .withRequiredMinutesSections()
    } catch {
      let payload = try JSONDecoder().decode(AIMeetingAnalysisPayload.self, from: data)
      return payload.normalized().withRequiredMinutesSections()
    }
  }

  /// AI出力だけは、議事録タブで必要な見出しを常に表示する。
  /// 保存済みの議事録やExport JSONのdecode契約は変更しない。
  private func withRequiredMinutesSections() -> MeetingAnalysis {
    MeetingAnalysis(
      summary: MinutesSummaryFormatter.normalized(summary),
      todo: todo,
      flow: flow
    )
  }
}

private enum MinutesSummaryFormatter {
  static let requiredSections = [
    "会議の目的・背景",
    "主な議論",
    "決定事項",
    "未決事項・確認事項",
    "次の対応",
  ]

  static func normalized(_ summary: String) -> String {
    var blocks: [String] = []
    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      blocks.append(trimmed)
    }

    for section in requiredSections where !containsHeading(section, in: trimmed) {
      blocks.append("## \(section)\n- 会議内で明確になりませんでした。")
    }

    return blocks.joined(separator: "\n\n")
  }

  private static func containsHeading(_ section: String, in summary: String) -> Bool {
    let expectedHeading = "## \(section)"
    return summary
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .contains { $0 == expectedHeading || $0.hasPrefix("\(expectedHeading) ") }
  }
}

private struct AIMeetingAnalysisPayload: Decodable {
  let summary: String
  let todo: [AITodoItem]
  let flow: [AIFlowStep]

  private enum CodingKeys: String, CodingKey {
    case summary
    case todo
    case flow
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = container.string(forKey: .summary)
    todo = container.array(of: AITodoItem.self, forKey: .todo)
    flow = container.array(of: AIFlowStep.self, forKey: .flow)
  }

  func normalized() -> MeetingAnalysis {
    let normalizedTodo = todo.compactMap { item -> TodoItem? in
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }

      return TodoItem(
        title: title,
        owner: item.owner.trimmingCharacters(in: .whitespacesAndNewlines),
        deadline: item.deadline.trimmingCharacters(in: .whitespacesAndNewlines),
        priority: TodoPriority(rawValue: item.priority) ?? .medium
      )
    }

    let validSteps = flow.filter {
      !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var usedIDs = Set<String>()
    var firstIDBySourceID: [String: String] = [:]
    var normalizedSteps: [(source: AIFlowStep, id: String)] = []

    for (index, step) in validSteps.enumerated() {
      let sourceID = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let baseID = sourceID.isEmpty ? "step-\(index + 1)" : sourceID
      var candidateID = baseID
      var suffix = 2
      while usedIDs.contains(candidateID) {
        candidateID = "\(baseID)-\(suffix)"
        suffix += 1
      }

      usedIDs.insert(candidateID)
      if !sourceID.isEmpty, firstIDBySourceID[sourceID] == nil {
        firstIDBySourceID[sourceID] = candidateID
      }
      normalizedSteps.append((source: step, id: candidateID))
    }

    let normalizedFlow = normalizedSteps.map { entry in
      FlowStep(
        id: entry.id,
        actor: entry.source.actor.trimmingCharacters(in: .whitespacesAndNewlines),
        action: entry.source.action.trimmingCharacters(in: .whitespacesAndNewlines),
        next: entry.source.next.compactMap { transition in
          let sourceDestination = transition.to.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          guard let destination = firstIDBySourceID[sourceDestination] else {
            return nil
          }
          return FlowTransition(
            to: destination,
            label: transition.label.trimmingCharacters(
              in: .whitespacesAndNewlines
            )
          )
        }
      )
    }

    return MeetingAnalysis(
      summary: summary,
      todo: normalizedTodo,
      flow: normalizedFlow
    )
  }
}

private struct AITodoItem: Decodable {
  let title: String
  let owner: String
  let deadline: String
  let priority: String

  private enum CodingKeys: String, CodingKey {
    case title
    case owner
    case deadline
    case priority
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = container.string(forKey: .title)
    owner = container.string(forKey: .owner)
    deadline = container.string(forKey: .deadline)
    priority = container.string(forKey: .priority)
  }
}

private struct AIFlowStep: Decodable {
  let id: String
  let actor: String
  let action: String
  let next: [AIFlowTransition]

  private enum CodingKeys: String, CodingKey {
    case id
    case actor
    case action
    case next
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = container.string(forKey: .id)
    actor = container.string(forKey: .actor)
    action = container.string(forKey: .action)
    next = container.array(of: AIFlowTransition.self, forKey: .next)
  }
}

private struct AIFlowTransition: Decodable {
  let to: String
  let label: String

  private enum CodingKeys: String, CodingKey {
    case to
    case label
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    to = container.string(forKey: .to)
    label = container.string(forKey: .label)
  }
}

private extension KeyedDecodingContainer {
  /// Structured Outputから外れた`null`や省略は、AI応答に限って未入力値として扱う。
  /// 値の型が異なる場合も空値にし、保存済みデータのデコード契約は緩めない。
  func string(forKey key: Key) -> String {
    (try? decodeIfPresent(String.self, forKey: key)) ?? ""
  }

  func array<Element: Decodable>(
    of type: Element.Type,
    forKey key: Key
  ) -> [Element] {
    (try? decodeIfPresent([Element].self, forKey: key)) ?? []
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
