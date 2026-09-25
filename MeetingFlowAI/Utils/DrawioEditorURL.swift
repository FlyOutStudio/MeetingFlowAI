import Foundation

/// Mermaidを編集可能なdraw.io図として直接開くURLを組み立てます。
enum DrawioEditorURL {
  private struct CreateRequest: Encodable {
    let type = "mermaid"
    let data: String
    let layout = "verticalFlow"
  }

  static func make(mermaid: String) -> URL? {
    guard
      let requestData = try? JSONEncoder().encode(CreateRequest(data: mermaid)),
      let request = String(data: requestData, encoding: .utf8),
      let encodedRequest = request.addingPercentEncoding(
        withAllowedCharacters: urlValueAllowedCharacters
      ),
      var components = URLComponents(string: "https://app.diagrams.net/")
    else {
      return nil
    }

    components.queryItems = [
      URLQueryItem(name: "grid", value: "0"),
      URLQueryItem(name: "pv", value: "0"),
    ]
    components.percentEncodedFragment = "create=\(encodedRequest)"
    return components.url
  }

  /// URL fragmentの値は、JSONの記号やMermaid本文の`#`・`&`を必ず
  /// エスケープし、URLの構造として解釈されないようにします。
  private static let urlValueAllowedCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )
}
