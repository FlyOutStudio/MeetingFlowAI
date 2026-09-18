import Foundation

// MARK: - Request

/// Claude Messages APIへ送るリクエスト。
///
/// SDKへ依存せず、会議解析に必要なフィールドだけを定義します。
struct ClaudeAPIRequest: Encodable {
  let model: String
  let maxTokens: Int
  let system: String
  let messages: [ClaudeInputMessage]
  let outputConfig: ClaudeOutputConfiguration

  enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case system
    case messages
    case outputConfig = "output_config"
  }
}

struct ClaudeInputMessage: Encodable {
  let role: String
  let content: String
}

struct ClaudeOutputConfiguration: Encodable {
  let format: ClaudeJSONSchemaFormat
}

struct ClaudeJSONSchemaFormat: Encodable {
  let type = "json_schema"
  let schema: MeetingAnalysisJSONSchema
}

// MARK: - Structured Outputs schema

/// `MeetingAnalysis`用のJSON Schema。
///
/// ClaudeのStructured Outputsに合わせ、すべてのobjectで
/// `additionalProperties: false`を指定し、全プロパティを必須にしています。
struct MeetingAnalysisJSONSchema: Encodable {
  let type = "object"
  let properties = MeetingAnalysisPropertiesSchema()
  let required = ["summary", "todo", "flow"]
  let additionalProperties = false
}

struct MeetingAnalysisPropertiesSchema: Encodable {
  let summary = StringJSONSchema(
    description: "会議の議事録を整理したMarkdown文字列。目的・背景、主な議論、決定事項、未決事項・確認事項、次の対応の見出しを必ず含め、発言にない内容を補わない。"
  )
  let todo = ArrayJSONSchema(items: TodoItemJSONSchema())
  let flow = ArrayJSONSchema(items: FlowStepJSONSchema())
}

struct TodoItemJSONSchema: Encodable {
  let type = "object"
  let properties = TodoItemPropertiesSchema()
  let required = ["title", "owner", "deadline", "priority"]
  let additionalProperties = false
}

struct TodoItemPropertiesSchema: Encodable {
  let title = StringJSONSchema(description: "実行する作業。")
  let owner = StringJSONSchema(
    description: "明示された担当者。不明な場合は空文字。"
  )
  let deadline = StringJSONSchema(
    description: "明示された期限。不明な場合は空文字。日付は可能ならYYYY-MM-DD。"
  )
  let priority = StringJSONSchema(
    description: "明示された優先度。不明な場合は中立のMedium。",
    allowedValues: ["High", "Medium", "Low"]
  )
}

struct FlowStepJSONSchema: Encodable {
  let type = "object"
  let properties = FlowStepPropertiesSchema()
  let required = ["id", "actor", "action", "next"]
  let additionalProperties = false
}

struct FlowStepPropertiesSchema: Encodable {
  let id = StringJSONSchema(description: "工程を一意に識別する短いID。")
  let actor = StringJSONSchema(
    description: "工程の実行者または部門。不明な場合は空文字。"
  )
  let action = StringJSONSchema(description: "工程で行う業務。")
  let next = ArrayJSONSchema(
    items: FlowTransitionJSONSchema()
  )
}

struct FlowTransitionJSONSchema: Encodable {
  let type = "object"
  let properties = FlowTransitionPropertiesSchema()
  let required = ["to", "label"]
  let additionalProperties = false
}

struct FlowTransitionPropertiesSchema: Encodable {
  let to = StringJSONSchema(description: "遷移先工程のid。")
  let label = StringJSONSchema(
    description: "Yes、No、承認などの分岐条件。無条件遷移は空文字。"
  )
}

struct ArrayJSONSchema<Items: Encodable>: Encodable {
  let type = "array"
  let items: Items
}

struct StringJSONSchema: Encodable {
  let type = "string"
  let description: String?
  let allowedValues: [String]?

  init(description: String? = nil, allowedValues: [String]? = nil) {
    self.description = description
    self.allowedValues = allowedValues
  }

  enum CodingKeys: String, CodingKey {
    case type
    case description
    case allowedValues = "enum"
  }
}

// MARK: - Response

/// Claude Messages API応答のうち、解析結果と停止理由だけを表します。
struct ClaudeAPIResponse: Decodable {
  let content: [ClaudeContentBlock]
  let stopReason: String?

  enum CodingKeys: String, CodingKey {
    case content
    case stopReason = "stop_reason"
  }
}

struct ClaudeContentBlock: Decodable {
  let type: String
  let text: String?
}
