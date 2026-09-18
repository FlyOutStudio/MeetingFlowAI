import Foundation
import XCTest

@testable import MeetingFlowAI

final class ClaudeServiceTests: XCTestCase {
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
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://api.anthropic.com/v1/messages"
      )
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.timeoutInterval, 120)
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-api-key"),
        "test-api-key"
      )
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "anthropic-version"),
        "2023-06-01"
      )
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Content-Type"),
        "application/json"
      )
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

      let body = try XCTUnwrap(Self.bodyData(from: request))
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )

      XCTAssertEqual(json["model"] as? String, "claude-sonnet-5")
      XCTAssertEqual(json["max_tokens"] as? Int, 16_384)
      XCTAssertNil(json["store"])
      XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("test-api-key") ?? true)

      let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 1)
      XCTAssertEqual(messages[0]["role"] as? String, "user")
      let input = try XCTUnwrap(messages[0]["content"] as? String)
      XCTAssertTrue(input.contains("受注フロー改善会議"))
      XCTAssertTrue(input.contains("受注内容を営業が確認する"))

      let system = try XCTUnwrap(json["system"] as? String)
      XCTAssertTrue(system.contains("推測または補完しない"))
      XCTAssertTrue(system.contains("ownerまたはdeadlineを空文字"))
      XCTAssertTrue(system.contains("priorityをMedium"))
      XCTAssertTrue(system.contains("## 会議の目的・背景"))
      XCTAssertTrue(system.contains("次の対応"))
      XCTAssertTrue(system.contains("JSON以外は出力しない"))

      let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
      let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
      XCTAssertEqual(format["type"] as? String, "json_schema")

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
        json: try Self.completedResponseJSON(
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

    XCTAssertTrue(result.summary.contains("# 要点\n受注確認を標準化する。"))
    XCTAssertTrue(result.summary.contains("## 会議の目的・背景"))
    XCTAssertTrue(result.summary.contains("## 次の対応"))
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
          "type": "error",
          "error": [
            "type": "authentication_error",
            "message": "Invalid API key",
          ],
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
          "content": [
            [
              "type": "text",
              "text": "Sensitive refusal detail",
            ]
          ],
          "stop_reason": "refusal",
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

  func testAnalyzeMapsMaxTokensToJapaneseAppError() async {
    URLProtocolStub.handler = { _ in
      Self.response(
        statusCode: 200,
        json: [
          "content": [],
          "stop_reason": "max_tokens",
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

  func testAnalyzeAcceptsJSONCodeFence() async throws {
    URLProtocolStub.handler = { _ in
      let analysis = """
        ```json
        {"summary":"要約","todo":[],"flow":[]}
        ```
        """
      return Self.response(
        statusCode: 200,
        json: Self.completedResponseJSON(analysisText: analysis)
      )
    }

    let service = makeService()
    let result = try await service.analyze(title: "会議", transcript: "会議内容")

    XCTAssertTrue(result.summary.contains("要約"))
    XCTAssertTrue(result.summary.contains("## 会議の目的・背景"))
    XCTAssertTrue(result.flow.isEmpty)
  }

  func testAnalyzeNormalizesNonFatalFlowAndTodoIssues() async throws {
    URLProtocolStub.handler = { _ in
      return Self.response(
        statusCode: 200,
        json: try Self.completedResponseJSON(
          analysis: [
            "summary": "要約",
            "todo": [
              ["title": "  ", "owner": "", "deadline": "", "priority": "Medium"],
              ["title": "実行する", "owner": "", "deadline": "", "priority": "Unknown"],
            ],
            "flow": [
              [
                "id": "A",
                "actor": "営業",
                "action": "確認",
                "next": [["to": "missing", "label": "No"]],
              ],
              ["id": "A", "actor": "管理部", "action": "承認", "next": []],
              ["id": "B", "actor": "", "action": "  ", "next": []],
            ],
          ]
        )
      )
    }

    let service = makeService()
    let result = try await service.analyze(title: "会議", transcript: "会議内容")

    XCTAssertEqual(result.todo.map(\.title), ["実行する"])
    XCTAssertEqual(result.todo.first?.priority, .medium)
    XCTAssertEqual(result.flow.map(\.id), ["A", "A-2"])
    XCTAssertTrue(result.flow.allSatisfy { $0.next.isEmpty })
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

  func testAnalyzeMapsURLSessionTimeoutToJapaneseAppError() async {
    URLProtocolStub.handler = { _ in
      throw URLError(.timedOut)
    }

    let service = makeService()

    await assertAppError(
      from: {
        try await service.analyze(title: "会議", transcript: "会議内容")
      },
      contains: "時間内に完了"
    )
  }

  func testAnalyzeMapsAPIKeyProviderFailureWithoutSendingRequest() async {
    URLProtocolStub.handler = { _ in
      XCTFail("APIキーを読み込めない場合は通信しないこと")
      return Self.response(statusCode: 500, json: [:])
    }

    let service = ClaudeService(
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

    let service = ClaudeService(
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

  private func makeService(apiKey: String? = "test-api-key") -> ClaudeService {
    ClaudeService(
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
      _ = try await operation()
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

  /// URLSession may move `httpBody` into a stream before a custom URLProtocol
  /// receives the request, so tests support both representations.
  private static func bodyData(from request: URLRequest) throws -> Data? {
    if let body = request.httpBody {
      return body
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw stream.streamError ?? URLError(.cannotDecodeRawData)
      }
      if count == 0 {
        return body
      }
      body.append(contentsOf: buffer.prefix(count))
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
      "content": [
        [
          "type": "text",
          "text": analysisText,
        ]
      ],
      "stop_reason": "end_turn",
    ]
  }

  private static func response(
    statusCode: Int,
    json: [String: Any]
  ) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: URL(string: "https://api.anthropic.com/v1/messages")!,
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
