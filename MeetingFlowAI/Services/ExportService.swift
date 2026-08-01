import AppKit
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case mermaid
  case json

  var id: Self { self }

  var displayName: String {
    switch self {
    case .markdown:
      "Markdown"
    case .mermaid:
      "Mermaid"
    case .json:
      "JSON"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown:
      "md"
    case .mermaid:
      "mmd"
    case .json:
      "json"
    }
  }

  @MainActor
  fileprivate var contentType: UTType {
    switch self {
    case .markdown:
      UTType(filenameExtension: fileExtension) ?? .plainText
    case .mermaid:
      UTType(filenameExtension: fileExtension) ?? .plainText
    case .json:
      .json
    }
  }
}

/// 会議分析を各ファイル形式へ変換し、macOSの保存パネルから保存します。
struct ExportService: Sendable {
  /// UIやファイルシステムに依存しない、テスト可能なコンテンツ生成です。
  static func content(
    for analysis: MeetingAnalysis,
    format: ExportFormat,
    title: String = "会議分析"
  ) throws -> String {
    switch format {
    case .markdown:
      markdownContent(for: analysis, title: title)
    case .mermaid:
      mermaidContent(for: analysis)
    case .json:
      try jsonContent(for: analysis)
    }
  }

  static func markdownContent(
    for analysis: MeetingAnalysis,
    title: String = "会議分析"
  ) -> String {
    let titleCandidate = singleLine(title)
    let normalizedTitle = titleCandidate.isEmpty ? "会議分析" : titleCandidate
    var lines = [
      "# \(normalizedTitle)",
      "",
      "## 議事録",
      "",
      analysis.summary,
      "",
      "## ToDo",
      "",
      "| タイトル | 担当 | 期限 | 優先度 |",
      "| --- | --- | --- | --- |",
    ]

    if analysis.todo.isEmpty {
      lines.append("| — | — | — | — |")
    } else {
      lines.append(
        contentsOf: analysis.todo.map { item in
          "| \(tableCell(item.title)) | \(tableCell(item.owner)) | \(tableCell(item.deadline)) | \(item.priority.rawValue) |"
        })
    }

    lines.append(contentsOf: [
      "",
      "## 業務フロー",
      "",
      "| ID | 担当 | アクション | 次の処理 |",
      "| --- | --- | --- | --- |",
    ])

    if analysis.flow.isEmpty {
      lines.append("| — | — | — | — |")
    } else {
      lines.append(
        contentsOf: analysis.flow.map { step in
          let destinations = step.next.map { transition in
            if transition.label.isEmpty {
              return transition.to
            }
            return "\(transition.label) → \(transition.to)"
          }.joined(separator: ", ")
          return
            "| \(tableCell(step.id)) | \(tableCell(step.actor)) | \(tableCell(step.action)) | \(tableCell(destinations)) |"
        })
    }

    lines.append(contentsOf: [
      "",
      "## Mermaid",
      "",
      "```mermaid",
      MermaidGenerator.render(flow: analysis.flow),
      "```",
      "",
    ])

    return lines.joined(separator: "\n")
  }

  static func mermaidContent(for analysis: MeetingAnalysis) -> String {
    MermaidGenerator.render(flow: analysis.flow) + "\n"
  }

  static func jsonContent(for analysis: MeetingAnalysis) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    do {
      let data = try encoder.encode(analysis)
      guard let content = String(data: data, encoding: .utf8) else {
        throw AppError.export("JSONをUTF-8文字列へ変換できませんでした。")
      }
      return content + "\n"
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.export(error.localizedDescription)
    }
  }

  /// 保存パネルを表示し、選択された場所へ非同期で書き込みます。
  /// ユーザーがパネルを閉じた場合は `nil` を返します。
  @MainActor
  @discardableResult
  func save(
    analysis: MeetingAnalysis,
    format: ExportFormat,
    title: String = "会議分析"
  ) async throws -> URL? {
    try checkCancellation()

    let content = try Self.content(for: analysis, format: format, title: title)
    let panel = NSSavePanel()
    panel.title = "\(format.displayName)を書き出す"
    panel.prompt = "保存"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.allowedContentTypes = [format.contentType]
    panel.nameFieldStringValue = "\(Self.fileNameStem(from: title)).\(format.fileExtension)"

    let response = await panel.begin()

    guard response == .OK, let destination = panel.url else {
      return nil
    }

    try checkCancellation()

    do {
      try await Task.detached(priority: .userInitiated) {
        try content.write(to: destination, atomically: true, encoding: .utf8)
      }.value
      return destination
    } catch is CancellationError {
      throw AppError.cancelled
    } catch {
      throw AppError.export(error.localizedDescription)
    }
  }

  /// `save` の意図を呼び出し側で明示したい場合の別名です。
  @MainActor
  @discardableResult
  func export(
    analysis: MeetingAnalysis,
    format: ExportFormat,
    title: String = "会議分析"
  ) async throws -> URL? {
    try await save(analysis: analysis, format: format, title: title)
  }

  private static func tableCell(_ source: String) -> String {
    let normalized =
      source
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\r\n", with: "<br>")
      .replacingOccurrences(of: "\r", with: "<br>")
      .replacingOccurrences(of: "\n", with: "<br>")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return normalized.isEmpty ? "—" : normalized
  }

  private static func singleLine(_ source: String) -> String {
    source
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func fileNameStem(from title: String) -> String {
    let invalidCharacters = CharacterSet(charactersIn: "/:\\")
      .union(.newlines)
      .union(.controlCharacters)
    let components = title.components(separatedBy: invalidCharacters)
    let sanitized =
      components
      .filter { !$0.isEmpty }
      .joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return sanitized.isEmpty ? "会議分析" : sanitized
  }

  private func checkCancellation() throws {
    if Task.isCancelled {
      throw AppError.cancelled
    }
  }
}
