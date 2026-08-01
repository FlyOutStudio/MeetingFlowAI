import SwiftUI

@main
struct MeetingFlowAIApp: App {
  @StateObject private var viewModel = MeetingViewModel()

  var body: some Scene {
    WindowGroup {
      MeetingWorkspaceView(viewModel: viewModel)
    }
    .defaultSize(width: 1_180, height: 780)

    Settings {
      SettingsView()
    }
  }
}

private struct SettingsView: View {
  var body: some View {
    Form {
      LabeledContent("AIモデル", value: "gpt-5.5")
      LabeledContent("APIキー", value: "環境変数 OPENAI_API_KEY")
      Text("APIキーはアプリ内へ保存せず、個人用Xcode SchemeのEnvironment Variablesから読み取ります。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 460)
  }
}
