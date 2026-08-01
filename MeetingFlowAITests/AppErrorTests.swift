import XCTest

@testable import MeetingFlowAI

final class AppErrorTests: XCTestCase {
  func testErrorsProvideJapaneseDescriptions() {
    XCTAssertEqual(
      AppError.missingAPIKey.errorDescription,
      "OpenAI APIキーが設定されていません。"
    )
    XCTAssertEqual(
      AppError.export("ディスク容量不足").errorDescription,
      "ファイルの保存に失敗しました。（ディスク容量不足）"
    )
    XCTAssertEqual(
      AppError.cancelled.errorDescription,
      "処理をキャンセルしました。"
    )
    XCTAssertEqual(
      AppError.permissionDenied("マイク").errorDescription,
      "マイクへのアクセスが許可されていません。"
    )
  }

  func testEmptyUnderlyingMessageDoesNotAddEmptyParentheses() {
    XCTAssertEqual(
      AppError.recording("  \n").errorDescription,
      "録音に失敗しました。"
    )
  }

  func testPermissionErrorsHaveRecoverySuggestions() {
    XCTAssertNotNil(AppError.microphonePermissionDenied.recoverySuggestion)
    XCTAssertNotNil(AppError.speechRecognitionPermissionDenied.recoverySuggestion)
    XCTAssertNil(AppError.cancelled.recoverySuggestion)
  }
}
