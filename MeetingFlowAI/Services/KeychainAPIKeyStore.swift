import Foundation
import Security

/// Anthropic APIキーの保存先をUIやAIサービスから分離する境界です。
///
/// Keychain APIは同期APIですが、async protocolとactorで包むことでMainActorを
/// ブロックせず、Swift 6のstrict concurrency下でも安全に利用できます。
protocol APIKeyStoring: Sendable {
  func loadAPIKey() async throws -> String?
  func saveAPIKey(_ apiKey: String) async throws
  func deleteAPIKey() async throws
}

/// SecItem APIを差し替え可能にする、型付きの低レベル境界です。
/// テストでは実際のログインキーチェーンを変更せずに振る舞いを検証できます。
protocol KeychainAccessing: Sendable {
  func read(service: String, account: String) throws -> Data?
  func upsert(_ data: Data, service: String, account: String) throws
  func delete(service: String, account: String) throws
}

/// APIキーをmacOSのログインキーチェーンへ保存します。
/// 環境変数fallbackは保存済み状態と混同しないようcomposition rootで合成します。
actor KeychainAPIKeyStore: APIKeyStoring {
  static let defaultService = "jp.flyoutstudio.MeetingFlowAI"
  static let defaultAccount = "ANTHROPIC_API_KEY"

  private let service: String
  private let account: String
  private let keychain: any KeychainAccessing

  init(
    service: String = KeychainAPIKeyStore.defaultService,
    account: String = KeychainAPIKeyStore.defaultAccount,
    keychain: any KeychainAccessing = SecurityKeychainClient()
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  func loadAPIKey() async throws -> String? {
    let storedData: Data?
    do {
      storedData = try keychain.read(service: service, account: account)
    } catch {
      throw Self.appError(error, operation: "読み込み")
    }

    if let storedData {
      guard let storedKey = String(data: storedData, encoding: .utf8) else {
        throw AppError.keychain("保存済みAPIキーの形式が正しくありません。")
      }

      let normalized = Self.normalized(storedKey)
      if !normalized.isEmpty {
        return normalized
      }
    }

    return nil
  }

  func saveAPIKey(_ apiKey: String) async throws {
    let normalized = Self.normalized(apiKey)
    guard !normalized.isEmpty else {
      throw AppError.keychain("空のAPIキーは保存できません。")
    }

    do {
      try keychain.upsert(
        Data(normalized.utf8),
        service: service,
        account: account
      )
    } catch {
      throw Self.appError(error, operation: "保存")
    }
  }

  func deleteAPIKey() async throws {
    do {
      try keychain.delete(service: service, account: account)
    } catch {
      throw Self.appError(error, operation: "削除")
    }
  }

  nonisolated private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func appError(
    _ error: Error,
    operation: String
  ) -> AppError {
    if let appError = error as? AppError {
      return appError
    }

    if let keychainError = error as? KeychainClientError {
      if case .status(let status) = keychainError {
        return .keychain(
          "APIキーを\(operation)できませんでした（OSStatus: \(status)）。"
        )
      }
    }

    return .keychain("APIキーを\(operation)できませんでした。")
  }
}

/// Ad Hoc署名アプリでも利用できる、macOSのfile-based login keychain実装です。
///
/// `kSecUseDataProtectionKeychain`、access group、アクセシビリティ属性は、
/// provisioningされたapplication-identifierを前提にするため指定しません。
struct SecurityKeychainClient: KeychainAccessing {
  func read(service: String, account: String) throws -> Data? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
      guard let data = result as? Data else {
        throw KeychainClientError.unexpectedItem
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainClientError.status(status)
    }
  }

  func upsert(_ data: Data, service: String, account: String) throws {
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      attributes as CFDictionary
    )

    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = query
      addQuery[kSecValueData as String] = data
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

      // 別プロセスが同時に追加した場合も、最後の保存操作を反映します。
      if addStatus == errSecDuplicateItem {
        let retryStatus = SecItemUpdate(
          query as CFDictionary,
          attributes as CFDictionary
        )
        guard retryStatus == errSecSuccess else {
          throw KeychainClientError.status(retryStatus)
        }
        return
      }

      guard addStatus == errSecSuccess else {
        throw KeychainClientError.status(addStatus)
      }
    default:
      throw KeychainClientError.status(updateStatus)
    }
  }

  func delete(service: String, account: String) throws {
    let status = SecItemDelete(
      baseQuery(service: service, account: account) as CFDictionary
    )

    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainClientError.status(status)
    }
  }

  private func baseQuery(
    service: String,
    account: String
  ) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

private enum KeychainClientError: Error, Sendable {
  case status(OSStatus)
  case unexpectedItem
}
