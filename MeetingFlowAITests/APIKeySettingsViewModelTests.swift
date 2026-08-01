import Foundation
import XCTest

@testable import MeetingFlowAI

final class APIKeySettingsViewModelTests: XCTestCase {
  @MainActor
  func testRefreshShowsConfiguredWithoutRevealingStoredKey() async throws {
    let store = APIKeyStoreStub(apiKey: "stored-secret")
    let viewModel = APIKeySettingsViewModel(apiKeyStore: store)

    viewModel.refresh()
    try await waitUntilIdle(viewModel)

    XCTAssertTrue(viewModel.isConfigured)
    XCTAssertTrue(viewModel.apiKeyInput.isEmpty)
  }

  @MainActor
  func testSaveTrimsKeyClearsInputAndDeleteRemovesIt() async throws {
    let store = APIKeyStoreStub()
    let viewModel = APIKeySettingsViewModel(apiKeyStore: store)

    viewModel.apiKeyInput = "  test-api-key-value\n"
    viewModel.save()
    try await waitUntilIdle(viewModel)

    XCTAssertTrue(viewModel.isConfigured)
    XCTAssertTrue(viewModel.apiKeyInput.isEmpty)
    let storedKey = try await store.loadAPIKey()
    XCTAssertEqual(storedKey, "test-api-key-value")

    viewModel.delete()
    try await waitUntilIdle(viewModel)

    XCTAssertFalse(viewModel.isConfigured)
    let deletedKey = try await store.loadAPIKey()
    XCTAssertNil(deletedKey)
  }

  @MainActor
  func testStoreFailureIsPresentedWithoutExposingInput() async throws {
    let expectedError = AppError.keychain("テスト用の保存失敗")
    let store = APIKeyStoreStub(saveError: expectedError)
    let viewModel = APIKeySettingsViewModel(apiKeyStore: store)
    viewModel.apiKeyInput = "sensitive-test-input"

    viewModel.save()
    try await waitUntilIdle(viewModel)

    XCTAssertEqual(viewModel.presentedError, expectedError)
    XCTAssertFalse(
      viewModel.presentedError?.localizedDescription.contains("sensitive-test-input")
        == true
    )
  }

  @MainActor
  private func waitUntilIdle(
    _ viewModel: APIKeySettingsViewModel,
    timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while viewModel.isBusy {
      guard Date() < deadline else {
        XCTFail("APIキー設定操作が完了しませんでした。")
        throw WaitError.timedOut
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private enum WaitError: Error {
    case timedOut
  }
}

private actor APIKeyStoreStub: APIKeyStoring {
  private var apiKey: String?
  private let saveError: AppError?

  init(apiKey: String? = nil, saveError: AppError? = nil) {
    self.apiKey = apiKey
    self.saveError = saveError
  }

  func loadAPIKey() async throws -> String? {
    apiKey
  }

  func saveAPIKey(_ apiKey: String) async throws {
    if let saveError {
      throw saveError
    }
    self.apiKey = apiKey
  }

  func deleteAPIKey() async throws {
    apiKey = nil
  }
}
