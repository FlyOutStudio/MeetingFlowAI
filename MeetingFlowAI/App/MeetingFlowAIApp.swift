import Foundation
import SwiftUI

@main
@MainActor
struct MeetingFlowAIApp: App {
  @StateObject private var viewModel: MeetingViewModel
  @StateObject private var settingsViewModel: APIKeySettingsViewModel

  init() {
    let apiKeyStore = KeychainAPIKeyStore()
    let analysisService = ClaudeService(apiKeyProvider: {
      if let storedKey = try await apiKeyStore.loadAPIKey() {
        return storedKey
      }

      // Xcodeからの開発実行では、従来どおり個人用Schemeの環境変数も
      // 利用できます。Finder起動の配布版はKeychainを使用します。
      return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    })

    _viewModel = StateObject(
      wrappedValue: MeetingViewModel(analysisService: analysisService)
    )
    _settingsViewModel = StateObject(
      wrappedValue: APIKeySettingsViewModel(apiKeyStore: apiKeyStore)
    )
  }

  var body: some Scene {
    WindowGroup {
      MeetingWorkspaceView(viewModel: viewModel)
    }
    .defaultSize(width: 1_180, height: 780)

    Settings {
      APIKeySettingsView(viewModel: settingsViewModel)
    }
  }
}
