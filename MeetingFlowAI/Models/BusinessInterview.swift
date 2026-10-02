import Foundation

enum InterviewSection: String, Codable, CaseIterable, Hashable, Sendable {
  case currentProcess, problem, requirement, question

  var title: String {
    switch self {
    case .currentProcess: "現状の業務"
    case .problem: "課題"
    case .requirement: "要件"
    case .question: "確認事項"
    }
  }
}

enum InterviewOrigin: String, Codable, CaseIterable, Hashable, Sendable {
  case agreed, proposed, aiSuggestion

  var title: String {
    switch self {
    case .agreed: "会議で合意"
    case .proposed: "提案中"
    case .aiSuggestion: "AI提案"
    }
  }
}

enum InterviewReview: String, Codable, Hashable, Sendable {
  case unreviewed, confirmed
  var title: String { self == .confirmed ? "確認済み" : "未確認" }
}

/// UTF-16 offsets refer only to the immutable transcript stored in BusinessInterview.
/// No speaker or timestamp is inferred. Repeated quotes must be disambiguated by context.
struct InterviewEvidence: Codable, Equatable, Identifiable, Sendable {
  let startUTF16: Int
  let lengthUTF16: Int
  let quote: String
  var id: String { "\(startUTF16):\(lengthUTF16)" }

  static func resolve(_ quote: String, in transcript: String) throws -> Self {
    guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw invalidEvidence
    }
    let source = transcript as NSString
    let match = source.range(of: quote, options: .literal)
    guard match.location != NSNotFound, match.length > 0 else { throw invalidEvidence }
    // Advance one UTF-16 unit, not one grapheme: this also detects overlaps and
    // repeated combining scalars within a single displayed character.
    let nextOffset = match.location + 1
    let remaining = NSRange(location: nextOffset, length: source.length - nextOffset)
    guard source.range(of: quote, options: .literal, range: remaining).location == NSNotFound else {
      throw invalidEvidence
    }
    let reference = Self(startUTF16: match.location, lengthUTF16: match.length, quote: quote)
    guard reference.range(in: transcript) != nil else { throw invalidEvidence }
    return reference
  }

  func range(in transcript: String) -> Range<String.Index>? {
    let count = transcript.utf16.count
    guard startUTF16 >= 0, lengthUTF16 > 0, startUTF16 <= count,
      lengthUTF16 <= count - startUTF16,
      let range = Range(NSRange(location: startUTF16, length: lengthUTF16), in: transcript),
      transcript.indices.contains(range.lowerBound),
      (range.upperBound == transcript.endIndex || transcript.indices.contains(range.upperBound)),
      Array(transcript[range].utf16) == Array(quote.utf16)
    else { return nil }
    return range
  }

  static var invalidEvidence: AppError {
    .invalidResponse("業務ヒアリングの根拠が原文と一致しないか、箇所を特定できません。原文の抜粋を確認してください。")
  }
}

struct InterviewContent: Codable, Equatable, Sendable {
  var text: String
  var actor: String = "未確認"
  var action: String = "未確認"
  var input: String = "未確認"
  var tools: String = "未確認"
  var output: String = "未確認"
  var exceptions: String = "未確認"

  mutating func normalizeUnknowns() {
    for key in [\Self.text, \.actor, \.action, \.input, \.tools, \.output, \.exceptions] {
      if self[keyPath: key].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        self[keyPath: key] = "未確認"
      }
    }
  }
}

struct InterviewItem: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let section: InterviewSection
  private(set) var content: InterviewContent
  private(set) var origin: InterviewOrigin
  private(set) var evidence: [InterviewEvidence]
  private(set) var review: InterviewReview = .unreviewed
  private(set) var humanEdited = false

  init(section: InterviewSection, content: InterviewContent,
       origin: InterviewOrigin, evidence: [InterviewEvidence]) {
    id = UUID()
    self.section = section
    self.content = content
    self.content.normalizeUnknowns()
    self.origin = origin
    self.evidence = evidence
  }

  mutating func edit(content: InterviewContent, origin: InterviewOrigin,
                     quotes: [String], transcript: String) throws {
    let references = try quotes.map { try InterviewEvidence.resolve($0, in: transcript) }
    guard !references.isEmpty, Set(references.map(\.id)).count == references.count else {
      throw InterviewEvidence.invalidEvidence
    }
    var normalized = content
    normalized.normalizeUnknowns()
    guard normalized != self.content || origin != self.origin || references != evidence else { return }
    self.content = normalized
    self.origin = origin
    evidence = references
    review = .unreviewed
    humanEdited = true
  }

  mutating func confirm(in transcript: String) throws {
    guard !evidence.isEmpty, evidence.allSatisfy({ $0.range(in: transcript) != nil }) else {
      throw InterviewEvidence.invalidEvidence
    }
    review = .confirmed
  }

  /// Called at the service boundary even when a test/provider supplies a persisted model.
  mutating func resetAIReview() {
    review = .unreviewed
    humanEdited = false
  }
}

struct BusinessInterview: Codable, Equatable, Sendable {
  let sourceTranscript: String
  var items: [InterviewItem]

  var hasHumanWork: Bool { items.contains { $0.humanEdited || $0.review == .confirmed } }

  func validate() throws {
    guard Set(items.map(\.id)).count == items.count,
      items.allSatisfy({ !$0.evidence.isEmpty
        && Set($0.evidence.map(\.id)).count == $0.evidence.count
        && $0.evidence.allSatisfy {
        $0.range(in: sourceTranscript) != nil
      } })
    else { throw InterviewEvidence.invalidEvidence }
  }

  func asAIResult(transcript: String) throws -> Self {
    guard Array(sourceTranscript.utf16) == Array(transcript.utf16) else { throw InterviewEvidence.invalidEvidence }
    try validate()
    var result = self
    for index in result.items.indices { result.items[index].resetAIReview() }
    return result
  }
}

/// Deliberately excludes review state, IDs, offsets, and the source transcript.
/// These are owned by the app, never accepted from the language model.
struct AIInterviewPayload: Decodable {
  let items: [Item]
  struct Item: Decodable {
    let section: InterviewSection
    let content: InterviewContent
    let origin: InterviewOrigin
    let quotes: [String]
  }

  func validated(transcript: String) throws -> BusinessInterview {
    let result = BusinessInterview(sourceTranscript: transcript, items: try items.map { item in
      guard !item.quotes.isEmpty else { throw InterviewEvidence.invalidEvidence }
      return InterviewItem(section: item.section, content: item.content, origin: item.origin,
        evidence: try item.quotes.map { try InterviewEvidence.resolve($0, in: transcript) })
    })
    try result.validate()
    return result
  }
}
