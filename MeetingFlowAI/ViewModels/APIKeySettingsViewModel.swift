import Combine
import Foundation

/// APIキー設定画面の状態を管理します。保存済みの秘密値は画面へ戻さず、
/// Keychainに値が存在するかどうかだけを公開します。
@MainActor
final class APIKeySettingsViewModel: ObservableObject {
  @Published var apiKeyInput = ""
  @Published private(set) var isConfigured = false
  @Published private(set) var isBusy = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var presentedError: AppError?

  private let apiKeyStore: any APIKeyStoring
  private var operationTask: Task<Void, Never>?

  init(apiKeyStore: any APIKeyStoring) {
    self.apiKeyStore = apiKeyStore
  }

  var canSave: Bool {
    !isBusy
      && !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func refresh() {
    guard !isBusy else { return }
    startOperation { [apiKeyStore] in
      let storedKey = try await apiKeyStore.loadAPIKey()
      return storedKey == nil ? .notConfigured : .configured
    }
  }

  func save() {
    guard canSave else {
      if apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        presentedError = .keychain("保存するAPIキーを入力してください。")
      }
      return
    }

    let normalizedKey = apiKeyInput.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    startOperation { [apiKeyStore] in
      try await apiKeyStore.saveAPIKey(normalizedKey)
      return .saved
    }
  }

  func delete() {
    guard !isBusy else { return }
    startOperation { [apiKeyStore] in
      try await apiKeyStore.deleteAPIKey()
      return .deleted
    }
  }

  func dismissError() {
    presentedError = nil
  }

  private func startOperation(
    _ operation: @escaping @Sendable () async throws -> OperationResult
  ) {
    operationTask?.cancel()
    isBusy = true
    presentedError = nil

    operationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.isBusy = false }

      do {
        let result = try await operation()
        try Task.checkCancellation()
        self.apply(result)
      } catch is CancellationError {
        // 新しい設定操作に置き換わった場合は表示しません。
      } catch let error as AppError {
        self.presentedError = error
      } catch {
        self.presentedError = .keychain("APIキー設定を更新できませんでした。")
      }
    }
  }

  private func apply(_ result: OperationResult) {
    switch result {
    case .configured:
      isConfigured = true
      statusMessage = nil
    case .notConfigured:
      isConfigured = false
      statusMessage = nil
    case .saved:
      isConfigured = true
      apiKeyInput = ""
      statusMessage = "APIキーをKeychainへ保存しました。"
    case .deleted:
      isConfigured = false
      apiKeyInput = ""
      statusMessage = "保存済みAPIキーを削除しました。"
    }
  }

  private enum OperationResult: Sendable {
    case configured
    case notConfigured
    case saved
    case deleted
  }
}
