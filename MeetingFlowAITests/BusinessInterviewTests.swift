import Foundation
import XCTest
@testable import MeetingFlowAI

enum InterviewFixture {
  static let transcript = "営業が申込書を受け取り、台帳に入力します。二重入力が課題です。自動化を提案します。通知を必須にすることで合意しました。"
  static func interview() throws -> BusinessInterview {
    BusinessInterview(sourceTranscript: transcript, items: [
      InterviewItem(section: .currentProcess,
        content: InterviewContent(text: "申込書の入力", actor: "営業", action: "入力", input: "申込書", tools: "台帳"),
        origin: .proposed, evidence: [try .resolve("営業が申込書を受け取り、台帳に入力します。", in: transcript)]),
      InterviewItem(section: .problem, content: InterviewContent(text: "二重入力"),
        origin: .proposed, evidence: [try .resolve("二重入力が課題です。", in: transcript)]),
      InterviewItem(section: .requirement, content: InterviewContent(text: "通知を必須にする"),
        origin: .agreed, evidence: [try .resolve("通知を必須にすることで合意しました。", in: transcript)]),
      InterviewItem(section: .question, content: InterviewContent(text: "自動化の対象範囲は未確認"),
        origin: .aiSuggestion, evidence: [try .resolve("自動化を提案します。", in: transcript)]),
    ])
  }

  static func analysis() throws -> MeetingAnalysis {
    MeetingAnalysis(summary: "業務ヒアリング", todo: [], flow: [], businessInterview: try interview())
  }

  static func aiData(quotes: [String], origin: String = "proposed") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "summary": "申込書について議論した。", "todo": [], "flow": [],
      "businessInterview": ["items": [[
        "section": "requirement", "origin": origin, "quotes": quotes,
        "review": "confirmed", "humanEdited": true,
        "content": ["text": "入力を自動化", "actor": "", "action": "", "input": "", "tools": "", "output": "", "exceptions": ""]
      ]]]
    ])
  }
}

final class BusinessInterviewTests: XCTestCase {
  func testLegacyJSONStillDecodesAndOmitsOptionalPayload() throws {
    let data = Data(#"{"summary":"過去の会議","todo":[],"flow":[],"mermaid":"ignored"}"#.utf8)
    let analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: data)
    XCTAssertNil(analysis.businessInterview)
    XCTAssertNil(analysis.interviewCandidate)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) as? [String: Any])
    XCTAssertNil(json["businessInterview"])
  }

  func testEditConfirmAndReeditRequireHumanReview() throws {
    var interview = try InterviewFixture.interview()
    let id = interview.items[0].id
    try interview.items[0].confirm(in: interview.sourceTranscript)
    XCTAssertEqual(interview.items[0].review, .confirmed)
    var content = interview.items[0].content
    content.exceptions = "例外時の担当者は未確認"
    try interview.items[0].edit(content: content, origin: .proposed,
      quotes: interview.items[0].evidence.map(\.quote), transcript: interview.sourceTranscript)
    XCTAssertEqual(interview.items[0].review, .unreviewed)
    XCTAssertTrue(interview.items[0].humanEdited)
    XCTAssertEqual(interview.items[0].id, id)
    try interview.items[0].confirm(in: interview.sourceTranscript)
    XCTAssertEqual(interview.items[0].review, .confirmed)
  }

  func testNoopSaveDoesNotInvalidateConfirmation() throws {
    var item = try InterviewFixture.interview().items[0]
    try item.confirm(in: InterviewFixture.transcript)
    try item.edit(content: item.content, origin: item.origin,
      quotes: item.evidence.map(\.quote), transcript: InterviewFixture.transcript)
    XCTAssertEqual(item.review, .confirmed)
    XCTAssertFalse(item.humanEdited)
  }

  func testChangingOriginOrEvidenceInvalidatesConfirmation() throws {
    var item = try InterviewFixture.interview().items[0]
    try item.confirm(in: InterviewFixture.transcript)
    try item.edit(content: item.content, origin: .agreed, quotes: item.evidence.map(\.quote), transcript: InterviewFixture.transcript)
    XCTAssertEqual(item.review, .unreviewed)
    try item.confirm(in: InterviewFixture.transcript)
    try item.edit(content: item.content, origin: item.origin, quotes: ["台帳に入力します。"], transcript: InterviewFixture.transcript)
    XCTAssertEqual(item.review, .unreviewed)
  }

  func testMissingInventedAndAmbiguousEvidenceRejected() throws {
    for quotes in [[], [""], ["承認権限は部長にある。"], ["二重入力が課題です。", "二重入力が課題です。"]] as [[String]] {
      XCTAssertThrowsError(try MeetingAnalysis.decodeAIOutput(from: InterviewFixture.aiData(quotes: quotes), transcript: InterviewFixture.transcript))
    }
    XCTAssertThrowsError(try InterviewEvidence.resolve("確認", in: "確認してから確認する"))
    XCTAssertThrowsError(try InterviewEvidence.resolve("aaa", in: "aaaa"))
    XCTAssertNoThrow(try InterviewEvidence.resolve("確認してから", in: "確認してから確認する"))
  }

  func testRejectedEditLeavesItemIntact() throws {
    var item = try InterviewFixture.interview().items[0]
    try item.confirm(in: InterviewFixture.transcript)
    let before = item
    XCTAssertThrowsError(try item.edit(content: InterviewContent(text: "変更"), origin: .aiSuggestion,
      quotes: ["捏造した原文"], transcript: InterviewFixture.transcript))
    XCTAssertEqual(item, before)
  }

  func testAIReviewAndCandidateCannotBeInjected() throws {
    let raw = try InterviewFixture.aiData(quotes: ["自動化を提案します。"])
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    object["interviewCandidate"] = ["review": "confirmed"]
    let data = try JSONSerialization.data(withJSONObject: object)
    let result = try MeetingAnalysis.decodeAIOutput(from: data, transcript: InterviewFixture.transcript)
    let item = try XCTUnwrap(result.businessInterview?.items.first)
    XCTAssertEqual(item.review, .unreviewed)
    XCTAssertFalse(item.humanEdited)
    XCTAssertEqual(item.content.actor, "未確認")
    XCTAssertNil(result.interviewCandidate)
    var confirmed = try InterviewFixture.interview()
    try confirmed.items[0].confirm(in: confirmed.sourceTranscript)
    let reset = try confirmed.asAIResult(transcript: InterviewFixture.transcript)
    XCTAssertEqual(reset.items[0].review, .unreviewed)
    XCTAssertThrowsError(try confirmed.asAIResult(transcript: "別の会議"))
  }

  func testOriginPreservedIndependentlyOfHumanConfirmation() throws {
    for origin in InterviewOrigin.allCases {
      let data = try InterviewFixture.aiData(quotes: ["自動化を提案します。"], origin: origin.rawValue)
      var interview = try XCTUnwrap(MeetingAnalysis.decodeAIOutput(from: data, transcript: InterviewFixture.transcript).businessInterview)
      try interview.items[0].confirm(in: interview.sourceTranscript)
      XCTAssertEqual(interview.items[0].origin, origin)
      XCTAssertEqual(interview.items[0].review, .confirmed)
    }
  }

  func testStableReferenceRoundTripWithUnicodeAndNewlines() throws {
    let transcript = "先頭😀\n営業が確認。\n末尾"
    let reference = try InterviewEvidence.resolve("営業が確認。", in: transcript)
    XCTAssertEqual(reference.startUTF16, 5)
    let restored = try JSONDecoder().decode(InterviewEvidence.self, from: JSONEncoder().encode(reference))
    XCTAssertEqual(restored, reference)
    XCTAssertEqual(String(transcript[try XCTUnwrap(restored.range(in: transcript))]), "営業が確認。")
    XCTAssertNil(restored.range(in: "編集された原文"))
    XCTAssertNil(InterviewEvidence(startUTF16: Int.max, lengthUTF16: 1, quote: "x").range(in: transcript))
    XCTAssertNil(InterviewEvidence(startUTF16: 0, lengthUTF16: Int.max, quote: "x").range(in: transcript))
  }

  func testEvidenceRejectsPartialGraphemesAndPreservesExactUnicode() throws {
    let decomposed = "か\u{3099}"
    let source = "前\(decomposed)後"
    let reference = try InterviewEvidence.resolve(decomposed, in: source)
    XCTAssertEqual(reference.lengthUTF16, 2)
    XCTAssertNotNil(reference.range(in: source))
    // Visually equivalent precomposed text is not an exact excerpt.
    XCTAssertThrowsError(try InterviewEvidence.resolve("が", in: source))
    XCTAssertThrowsError(try InterviewEvidence.resolve("\u{3099}", in: source))
    XCTAssertThrowsError(try InterviewEvidence.resolve("\u{0301}", in: "a\u{0301}\u{0301}"))
    let family = "👩‍👩‍👧‍👦"
    XCTAssertThrowsError(try InterviewEvidence.resolve("👩", in: family))
    XCTAssertNoThrow(try InterviewEvidence.resolve(family, in: "前\(family)後"))
    XCTAssertNil(InterviewEvidence(startUTF16: 1, lengthUTF16: 1, quote: "x").range(in: "😀"))
    XCTAssertNil(InterviewEvidence(startUTF16: 2, lengthUTF16: 1, quote: "\u{3099}").range(in: source))
  }

  func testMalformedPayloadDoesNotFallBackToLegacyNormalization() throws {
    let data = Data(#"{"summary":"要約","todo":[],"flow":[],"businessInterview":{"items":[{"section":"problem"}]}}"#.utf8)
    XCTAssertThrowsError(try MeetingAnalysis.decodeAIOutput(from: data, transcript: InterviewFixture.transcript))
  }

  func testJSONAndMarkdownPreserveReviewEvidenceAndCandidate() throws {
    var analysis = try InterviewFixture.analysis()
    try analysis.businessInterview?.items[0].confirm(in: InterviewFixture.transcript)
    analysis.interviewCandidate = try InterviewFixture.interview()
    let json = try ExportService.jsonContent(for: analysis)
    XCTAssertEqual(try JSONDecoder().decode(MeetingAnalysis.self, from: Data(json.utf8)), analysis)
    let markdown = ExportService.markdownContent(for: analysis)
    for value in ["現状の業務", "課題", "要件", "確認事項", "会議で合意", "提案中", "AI提案", "確認済み", "未確認", "再解析の候補（未採用）", InterviewFixture.transcript, "[根拠原文](#interview-"] {
      XCTAssertTrue(markdown.contains(value), value)
    }
  }

  func testCorruptSavedReferenceRejectedOnDecode() throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(InterviewFixture.analysis())) as? [String: Any])
    var interview = try XCTUnwrap(object["businessInterview"] as? [String: Any])
    interview["sourceTranscript"] = "別の原文"
    object["businessInterview"] = interview
    XCTAssertThrowsError(try JSONDecoder().decode(MeetingAnalysis.self, from: JSONSerialization.data(withJSONObject: object)))
  }

  @MainActor
  func testPreviousAnalysisDiskRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    var analysis = try InterviewFixture.analysis()
    try analysis.businessInterview?.items[0].confirm(in: InterviewFixture.transcript)
    analysis.interviewCandidate = try InterviewFixture.interview()
    try PreviousAnalysisStore(directoryURL: directory).save(analysis, for: id)
    XCTAssertEqual(try PreviousAnalysisStore(directoryURL: directory).load(for: id), analysis)
  }
}
