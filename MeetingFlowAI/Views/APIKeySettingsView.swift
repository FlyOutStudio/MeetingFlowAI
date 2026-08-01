import SwiftUI

struct APIKeySettingsView: View {
  @ObservedObject var viewModel: APIKeySettingsViewModel
  @State private var confirmsDeletion = false

  var body: some View {
    Form {
      Section("OpenAI") {
        LabeledContent("AIモデル", value: "gpt-5.5")

        LabeledContent("APIキー") {
          Label(
            viewModel.isConfigured ? "Keychainに保存済み" : "未設定",
            systemImage: viewModel.isConfigured
              ? "checkmark.circle.fill" : "exclamationmark.circle"
          )
          .foregroundStyle(viewModel.isConfigured ? .green : .gray)
        }

        SecureField("OpenAI APIキーを入力", text: $viewModel.apiKeyInput)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isBusy)
          .onSubmit { viewModel.save() }

        HStack {
          Button("Keychainへ保存") {
            viewModel.save()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!viewModel.canSave)

          if viewModel.isBusy {
            ProgressView()
              .controlSize(.small)
          }

          Spacer()

          if viewModel.isConfigured {
            Button("保存済みキーを削除", role: .destructive) {
              confirmsDeletion = true
            }
            .disabled(viewModel.isBusy)
          }
        }

        if let statusMessage = viewModel.statusMessage {
          Text(statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("セキュリティ") {
        Text("APIキーはmacOSのログインKeychainへ保存します。保存済みの値を画面へ再表示したり、ソースコードや設定ファイルへ書き込んだりしません。")
        Text("Xcodeの個人用SchemeにOPENAI_API_KEYがある場合は、Keychain未設定時の開発用フォールバックとして利用します。")
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 520)
    .task { viewModel.refresh() }
    .alert(
      "APIキー設定エラー",
      isPresented: Binding(
        get: { viewModel.presentedError != nil },
        set: { if !$0 { viewModel.dismissError() } }
      ),
      presenting: viewModel.presentedError
    ) { _ in
      Button("閉じる", role: .cancel) {
        viewModel.dismissError()
      }
    } message: { error in
      Text(
        [error.errorDescription, error.recoverySuggestion]
          .compactMap { $0 }
          .joined(separator: "\n\n")
      )
    }
    .confirmationDialog(
      "保存済みのAPIキーを削除しますか？",
      isPresented: $confirmsDeletion
    ) {
      Button("削除", role: .destructive) {
        viewModel.delete()
      }
      Button("キャンセル", role: .cancel) {}
    }
  }
}
