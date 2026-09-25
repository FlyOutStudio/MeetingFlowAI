import Foundation
import XCTest

@testable import MeetingFlowAI

final class DrawioEditorURLTests: XCTestCase {
  func testMakeCreatesEditableMermaidDiagramURL() throws {
    let mermaid = """
      flowchart TD
          start[\"開始 & 確認\"] --> end[\"完了 #1\"]
      """

    let url = try XCTUnwrap(DrawioEditorURL.make(mermaid: mermaid))
    let components = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "app.diagrams.net")
    XCTAssertEqual(components.queryItems?.first?.name, "grid")
    XCTAssertEqual(components.queryItems?.first?.value, "0")
    XCTAssertEqual(components.queryItems?.last?.name, "pv")
    XCTAssertEqual(components.queryItems?.last?.value, "0")

    let fragment = try XCTUnwrap(components.percentEncodedFragment)
    XCTAssertTrue(fragment.hasPrefix("create="))
    let encodedRequest = String(fragment.dropFirst("create=".count))
    let request = try XCTUnwrap(encodedRequest.removingPercentEncoding)
    let jsonData = try XCTUnwrap(request.data(using: .utf8))
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    )

    XCTAssertEqual(json["type"] as? String, "mermaid")
    XCTAssertEqual(json["data"] as? String, mermaid)
    XCTAssertEqual(json["layout"] as? String, "verticalFlow")
  }
}
