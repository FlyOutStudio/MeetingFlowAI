import Foundation

// MARK: - Request

/// OpenAI Responses APIへ送るリクエスト。
///
/// API SDKへ依存せず、必要なフィールドだけを型として定義することで、
/// APIの送受信境界を小さく保っています。
struct ResponsesAPIRequest: Encodable {
  let model: String
  let instructions: String
  let input: String
  let text: ResponsesTextConfiguration
  let store: Bool
}

struct ResponsesTextConfiguration: Encodable {
  let format: ResponsesJSONSchemaFormat
}

struct ResponsesJSONSchemaFormat: Encodable {
  let type = "json_schema"
  let name: String
  let strict = true
  let schema: MeetingAnalysisJSONSchema
}

// MARK: - Structured Outputs schema

/// `MeetingAnalysis`用のJSON Schema。
///
/// Structured Outputsのstrictモードに合わせ、すべてのobjectで
/// `additionalProperties: false`を指定し、全プロパティを必須にしています。
struct MeetingAnalysisJSONSchema: Encodable {
  let type = "object"
  let properties = MeetingAnalysisPropertiesSchema()
  let required = ["summary", "todo", "flow"]
  let additionalProperties = false
}

struct MeetingAnalysisPropertiesSchema: Encodable {
  let summary = StringJSONSchema(
    description: "会議の要点を整理したMarkdown文字列。発言にない内容を補わない。"
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

/// Responses APIのうち、解析結果の取得とエラー判定に必要な部分だけを表します。
struct ResponsesAPIResponse: Decodable {
  let status: String
  let output: [ResponsesOutputItem]
  let incompleteDetails: ResponsesIncompleteDetails?

  enum CodingKeys: String, CodingKey {
    case status
    case output
    case incompleteDetails = "incomplete_details"
  }
}

struct ResponsesOutputItem: Decodable {
  let type: String
  let content: [ResponsesOutputContent]?
}

struct ResponsesOutputContent: Decodable {
  let type: String
  let text: String?
  let refusal: String?
}

struct ResponsesIncompleteDetails: Decodable {
  let reason: String?
}
