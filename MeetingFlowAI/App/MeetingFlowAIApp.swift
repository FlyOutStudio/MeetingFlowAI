import Foundation
import SwiftData
import SwiftUI

@main
@MainActor
struct MeetingFlowAIApp: App {
  private let modelContainer: ModelContainer
  @StateObject private var viewModel: MeetingViewModel
  @StateObject private var settingsViewModel: APIKeySettingsViewModel

  init() {
    let schema = Schema(versionedSchema: MeetingSchemaV1.self)
    let configuration = ModelConfiguration(
      "MeetingHistory",
      schema: schema
    )
    let container: ModelContainer
    do {
      container = try ModelContainer(
        for: schema,
        migrationPlan: MeetingDataMigrationPlan.self,
        configurations: [configuration]
      )
    } catch {
      fatalError("会議履歴の保存領域を準備できませんでした: \(error)")
    }

    let apiKeyStore = KeychainAPIKeyStore()
    let analysisService = ClaudeService(apiKeyProvider: {
      if let storedKey = try await apiKeyStore.loadAPIKey() {
        return storedKey
      }

      // Xcodeからの開発実行では、従来どおり個人用Schemeの環境変数も
      // 利用できます。Finder起動の配布版はKeychainを使用します。
      return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    })

    modelContainer = container
    _viewModel = StateObject(
      wrappedValue: MeetingViewModel(
        analysisService: analysisService,
        meetingHistoryStore: MeetingHistoryStore(
          modelContext: ModelContext(container)
        )
      )
    )
    _settingsViewModel = StateObject(
      wrappedValue: APIKeySettingsViewModel(apiKeyStore: apiKeyStore)
    )
  }

  var body: some Scene {
    WindowGroup {
      MeetingWorkspaceView(viewModel: viewModel)
        .modelContainer(modelContainer)
    }
    .defaultSize(width: 1_180, height: 780)

    Settings {
      APIKeySettingsView(viewModel: settingsViewModel)
    }
  }
}
