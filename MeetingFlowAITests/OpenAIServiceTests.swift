import Foundation
import XCTest

@testable import MeetingFlowAI

final class OpenAIServiceTests: XCTestCase {
  private var session: URLSession!

  override func setUp() {
    super.setUp()

    URLProtocolStub.handler = nil
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    session = URLSession(configuration: configuration)
  }

  override func tearDown() {
    URLProtocolStub.handler = nil
    session.invalidateAndCancel()
    session = nil
    super.tearDown()
  }

  func testAnalyzeSendsStrictSchemaAndBuildsMermaidFromFlow() async throws {
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"),
        "Bearer test-api-key"
      )
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Content-Type"),
        "application/json"
      )

      let body = try XCTUnwrap(request.httpBody)
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )

      XCTAssertEqual(json["model"] as? String, "gpt-5.5")
      XCTAssertEqual(json["store"] as? Bool, false)
      XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("test-api-key") ?? true)

      let input = try XCTUnwrap(json["input"] as? String)
      XCTAssertTrue(input.contains("受注フロー改善会議"))
      XCTAssertTrue(input.contains("受注内容を営業が確認する"))

      let instructions = try XCTUnwrap(json["instructions"] as? String)
      XCTAssertTrue(instructions.contains("推測または補完しない"))
      XCTAssertTrue(instructions.contains("ownerまたはdeadlineを空文字"))
      XCTAssertTrue(instructions.contains("priorityをMedium"))
      XCTAssertTrue(instructions.contains("JSON以外は出力しない"))

      let text = try XCTUnwrap(json["text"] as? [String: Any])
      let format = try XCTUnwrap(text["format"] as? [String: Any])
      XCTAssertEqual(format["type"] as? String, "json_schema")
      XCTAssertEqual(format["name"] as? String, "meeting_analysis")
      XCTAssertEqual(format["strict"] as? Bool, true)

      let schema = try XCTUnwrap(format["schema"] as? [String: Any])
      XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
      XCTAssertEqual(
        schema["required"] as? [String],
        ["summary", "todo", "flow"]
      )

      let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
      XCTAssertEqual(Set(properties.keys), ["summary", "todo", "flow"])
      XCTAssertNil(properties["mermaid"])

      let todo = try XCTUnwrap(properties["todo"] as? [String: Any])
      let todoItems = try XCTUnwrap(todo["items"] as? [String: Any])
      XCTAssertEqual(todoItems["additionalProperties"] as? Bool, false)
      XCTAssertEqual(
        todoItems["required"] as? [String],
        ["title", "owner", "deadline", "priority"]
      )
      let todoProperties = try XCTUnwrap(
        todoItems["properties"] as? [String: Any]
      )
      let priority = try XCTUnwrap(
        todoProperties["priority"] as? [String: Any]
      )
      XCTAssertEqual(
        priority["enum"] as? [String],
        ["High", "Medium", "Low"]
      )

      let flow = try XCTUnwrap(properties["flow"] as? [String: Any])
      let flowItems = try XCTUnwrap(flow["items"] as? [String: Any])
      XCTAssertEqual(flowItems["additionalProperties"] as? Bool, false)
      XCTAssertEqual(
        flowItems["required"] as? [String],
        ["id", "actor", "action", "next"]
      )
      let flowProperties = try XCTUnwrap(
        flowItems["properties"] as? [String: Any]
      )
      let next = try XCTUnwrap(flowProperties["next"] as? [String: Any])
      XCTAssertEqual(next["type"] as? String, "array")
      let transition = try XCTUnwrap(next["items"] as? [String: Any])
      XCTAssertEqual(transition["additionalProperties"] as? Bool, false)
      XCTAssertEqual(
        transition["required"] as? [String],
        ["to", "label"]
      )

      return Self.response(
        statusCode: 200,
        json: Self.completedResponseJSON(
          analysis: [
            "summary": "# 要点\n受注確認を標準化する。",
            "todo": [
              [
                "title": "確認手順を文書化する",
                "owner": "田中",
                "deadline": "2026-08-05",
                "priority": "High",
              ]
            ],
            "flow": [
              [
                "id": "1",
                "actor": "営業",
                "action": "受注確認",
                "next": [["to": "2", "label": ""]],
              ],
              [
                "id": "2",
                "actor": "管理部",
                "action": "在庫確認",
                "next": [],
              ],
            ],
          ]
        )
      )
    }

    let service = makeService(apiKey: "test-api-key")
    let result = try await service.analyze(
      title: "受注フロー改善会議",
      transcript: "受注内容を営業が確認する。その後、管理部が在庫を確認する。"
    )

    XCTAssertEqual(result.summary, "# 要点\n受注確認を標準化する。")
    XCTAssertEqual(result.todo.first?.owner, "田中")
    XCTAssertEqual(result.flow.map(\.id), ["1", "2"])
    XCTAssertEqual(
      result.flow.first?.next,
      [FlowTransition(to: "2", label: "")]
    )
    XCTAssertEqual(result.mermaid, MermaidGenerator.render(flow: result.flow))
    XCTAssertTrue(result.mermaid.contains("step_1 --> step_2"))
  }

  func testAnalyzeThrowsMissingAPIKeyBeforeSendingRequest() async {
    URLProtocolStub.handler = { _ in
      XCTFail("APIキーがない場合は通信しないこと")
      return Self.response(statusCode: 500, json: [:])
    }

    let service = makeService(apiKey: nil)

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "APIキー"
    )
  }

  func testAnalyzeMapsHTTPAuthenticationErrorToJapaneseAppError() async {
    URLProtocolStub.handler = { _ in
      Self.response(
        statusCode: 401,
        json: [
          "error": [
            "code": "invalid_api_key",
            "message": "Invalid API key",
          ]
        ]
      )
    }

    let service = makeService()

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "認証に失敗"
    )
  }

  func testAnalyzeMapsRefusalToJapaneseAppError() async {
    URLProtocolStub.handler = { _ in
      Self.response(
        statusCode: 200,
        json: [
          "status": "completed",
          "output": [
            [
              "type": "message",
              "content": [
                [
                  "type": "refusal",
                  "refusal": "Sensitive refusal detail",
                ]
              ],
            ]
          ],
          "incomplete_details": NSNull(),
          "error": NSNull(),
        ]
      )
    }

    let service = makeService()

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "解析を拒否"
    )
  }

  func testAnalyzeMapsIncompleteResponseToJapaneseAppError() async {
    URLProtocolStub.handler = { _ in
      Self.response(
        statusCode: 200,
        json: [
          "status": "incomplete",
          "output": [],
          "incomplete_details": ["reason": "max_output_tokens"],
          "error": NSNull(),
        ]
      )
    }

    let service = makeService()

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "出力上限"
    )
  }

  func testAnalyzeMapsMalformedStructuredOutputToJapaneseAppError() async {
    URLProtocolStub.handler = { _ in
      Self.response(
        statusCode: 200,
        json: Self.completedResponseJSON(analysisText: "{not-json}")
      )
    }

    let service = makeService()

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "JSONを解析できません"
    )
  }

  func testAnalyzeMapsURLSessionCancellationToAppError() async {
    URLProtocolStub.handler = { _ in
      throw URLError(.cancelled)
    }

    let service = makeService()

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "キャンセル"
    )
  }

  func testAnalyzeMapsAPIKeyProviderFailureWithoutSendingRequest() async {
    URLProtocolStub.handler = { _ in
      XCTFail("APIキーを読み込めない場合は通信しないこと")
      return Self.response(statusCode: 500, json: [:])
    }

    let service = OpenAIService(
      session: session,
      apiKeyProvider: {
        throw AppError.keychain("テスト用の読み込み失敗")
      }
    )

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "Keychain"
    )
  }

  func testAnalyzeMapsAPIKeyProviderCancellation() async {
    URLProtocolStub.handler = { _ in
      XCTFail("キャンセルされた場合は通信しないこと")
      return Self.response(statusCode: 500, json: [:])
    }

    let service = OpenAIService(
      session: session,
      apiKeyProvider: {
        throw CancellationError()
      }
    )

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "キャンセル"
    )
  }

  private func makeService(apiKey: String? = "test-api-key") -> OpenAIService {
    OpenAIService(
      session: session,
      apiKeyProvider: { apiKey }
    )
  }

  private func assertAppError<Result>(
    from operation: () async throws -> Result,
    contains expectedText: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("AppErrorが必要です。", file: file, line: line)
    } catch let error as AppError {
      XCTAssertTrue(
        error.localizedDescription.contains(expectedText),
        "実際のエラー: \(error.localizedDescription)",
        file: file,
        line: line
      )
    } catch {
      XCTFail(
        "AppError以外が返りました: \(error)",
        file: file,
        line: line
      )
    }
  }

  private static func completedResponseJSON(
    analysis: [String: Any]
  ) throws -> [String: Any] {
    let analysisData = try JSONSerialization.data(withJSONObject: analysis)
    let analysisText = try XCTUnwrap(String(data: analysisData, encoding: .utf8))
    return completedResponseJSON(analysisText: analysisText)
  }

  private static func completedResponseJSON(
    analysisText: String
  ) -> [String: Any] {
    [
      "status": "completed",
      "output": [
        [
          "type": "message",
          "content": [
            [
              "type": "output_text",
              "text": analysisText,
            ]
          ],
        ]
      ],
      "incomplete_details": NSNull(),
      "error": NSNull(),
    ]
  }

  private static func response(
    statusCode: Int,
    json: [String: Any]
  ) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: URL(string: "https://api.openai.com/v1/responses")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    let data = try! JSONSerialization.data(withJSONObject: json)
    return (response, data)
  }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  nonisolated(unsafe) static var handler: Handler?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(
        self,
        didFailWithError: URLError(.resourceUnavailable)
      )
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
