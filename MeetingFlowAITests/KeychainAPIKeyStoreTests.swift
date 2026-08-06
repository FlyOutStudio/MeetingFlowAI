import Foundation
import XCTest

@testable import MeetingFlowAI

final class KeychainAPIKeyStoreTests: XCTestCase {
  func testSaveLoadAndDeleteUseKeychain() async throws {
    let keychain = KeychainAccessingStub()
    let store = KeychainAPIKeyStore(keychain: keychain)

    let initiallyLoadedKey = try await store.loadAPIKey()
    XCTAssertNil(initiallyLoadedKey)

    try await store.saveAPIKey("  keychain-key\n")
    let savedKey = try await store.loadAPIKey()
    XCTAssertEqual(savedKey, "keychain-key")

    try await store.deleteAPIKey()
    let keyAfterDeletion = try await store.loadAPIKey()
    XCTAssertNil(keyAfterDeletion)

    let snapshot = keychain.snapshot()
    XCTAssertEqual(snapshot.savedData, nil)
    XCTAssertEqual(snapshot.upserts, 1)
    XCTAssertEqual(snapshot.deletes, 1)
    XCTAssertEqual(snapshot.lastService, KeychainAPIKeyStore.defaultService)
    XCTAssertEqual(snapshot.lastAccount, KeychainAPIKeyStore.defaultAccount)
    XCTAssertEqual(KeychainAPIKeyStore.defaultAccount, "ANTHROPIC_API_KEY")
  }

  func testWhitespaceStoredValueIsTreatedAsMissing() async throws {
    let store = KeychainAPIKeyStore(
      keychain: KeychainAccessingStub(savedData: Data(" \n ".utf8))
    )

    let loadedKey = try await store.loadAPIKey()
    XCTAssertNil(loadedKey)
  }

  func testEmptyAPIKeyIsRejectedWithoutWriting() async {
    let keychain = KeychainAccessingStub()
    let store = KeychainAPIKeyStore(keychain: keychain)

    await assertKeychainError {
      try await store.saveAPIKey(" \n ")
    }
    XCTAssertEqual(keychain.snapshot().upserts, 0)
  }

  func testInvalidStoredUTF8IsReportedAsJapaneseAppError() async {
    let keychain = KeychainAccessingStub(savedData: Data([0xFF]))
    let store = KeychainAPIKeyStore(keychain: keychain)

    await assertKeychainError {
      _ = try await store.loadAPIKey()
    }
  }

  func testBackendFailureIsMappedWithoutExposingUnderlyingDetails() async {
    let keychain = KeychainAccessingStub(readError: TestBackendError.sensitive)
    let store = KeychainAPIKeyStore(keychain: keychain)

    do {
      _ = try await store.loadAPIKey()
      XCTFail("Keychain読み込みエラーが必要です。")
    } catch let error as AppError {
      XCTAssertTrue(error.localizedDescription.contains("Keychain"))
      XCTAssertTrue(error.localizedDescription.contains("読み込み"))
      XCTAssertFalse(error.localizedDescription.contains("sensitive"))
    } catch {
      XCTFail("AppError以外が返りました: \(error)")
    }
  }

  private func assertKeychainError(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Keychainエラーが必要です。", file: file, line: line)
    } catch let error as AppError {
      XCTAssertTrue(
        error.localizedDescription.contains("Keychain"),
        "実際のエラー: \(error.localizedDescription)",
        file: file,
        line: line
      )
    } catch {
      XCTFail("AppError以外が返りました: \(error)", file: file, line: line)
    }
  }
}

private enum TestBackendError: Error, Sendable {
  case sensitive
}

private struct KeychainSnapshot: Sendable {
  let savedData: Data?
  let upserts: Int
  let deletes: Int
  let lastService: String?
  let lastAccount: String?
}

private final class KeychainAccessingStub: KeychainAccessing, @unchecked Sendable {
  private let lock = NSLock()
  private var savedData: Data?
  private var upsertCount = 0
  private var deleteCount = 0
  private var lastService: String?
  private var lastAccount: String?
  private let readError: (any Error & Sendable)?

  init(
    savedData: Data? = nil,
    readError: (any Error & Sendable)? = nil
  ) {
    self.savedData = savedData
    self.readError = readError
  }

  func read(service: String, account: String) throws -> Data? {
    try lock.withLock {
      lastService = service
      lastAccount = account
      if let readError {
        throw readError
      }
      return savedData
    }
  }

  func upsert(_ data: Data, service: String, account: String) throws {
    lock.withLock {
      lastService = service
      lastAccount = account
      savedData = data
      upsertCount += 1
    }
  }

  func delete(service: String, account: String) throws {
    lock.withLock {
      lastService = service
      lastAccount = account
      savedData = nil
      deleteCount += 1
    }
  }

  func snapshot() -> KeychainSnapshot {
    lock.withLock {
      KeychainSnapshot(
        savedData: savedData,
        upserts: upsertCount,
        deletes: deleteCount,
        lastService: lastService,
        lastAccount: lastAccount
      )
    }
  }
}
