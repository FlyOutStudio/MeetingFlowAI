import SwiftUI

struct MeetingWorkspaceView: View {
  @ObservedObject var viewModel: MeetingViewModel

  var body: some View {
    HSplitView {
      ControlPanelView(viewModel: viewModel)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)

      VStack(spacing: 0) {
        TranscriptView(transcript: viewModel.transcript)
          .frame(minHeight: 240)

        if viewModel.shouldShowAnalysisTabs {
          Divider()
          AnalysisTabsView(viewModel: viewModel)
            .frame(minHeight: 330)
        }
      }
      .frame(minWidth: 620)
    }
    .frame(minWidth: 960, minHeight: 680)
    .alert(
      "エラー",
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
  }
}

private struct ControlPanelView: View {
  @ObservedObject var viewModel: MeetingViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Label("Meeting Flow AI", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.title2.bold())
        Text("会議を、次のアクションへ。")
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("会議タイトル")
          .font(.headline)
        TextField("例：受注〜発送フロー改善会議", text: $viewModel.meetingTitle)
          .textFieldStyle(.roundedBorder)
          .disabled(!viewModel.canStartRecording)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("録音モード")
          .font(.headline)
        Picker("録音モード", selection: $viewModel.captureMode) {
          ForEach(MeetingCaptureMode.allCases) { mode in
            Label(mode.displayName, systemImage: mode.systemImage)
              .tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .disabled(!viewModel.canStartRecording)

        Text(viewModel.captureMode.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if viewModel.captureMode == .onlineMeeting {
          Label(
            "録音開始後、会議アプリを選択します。初回の画面収録許可後は、アプリの再起動が必要な場合があります。",
            systemImage: "rectangle.on.rectangle.badge.gearshape"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 9, height: 9)
        Text(viewModel.phase.statusText)
          .font(.callout.weight(.medium))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.quaternary, in: Capsule())

      VStack(spacing: 10) {
        Button {
          viewModel.startRecording()
        } label: {
          Label("録音開始", systemImage: "record.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!viewModel.canStartRecording)

        Button {
          viewModel.stopRecording()
        } label: {
          Label("録音停止", systemImage: "stop.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!viewModel.canStopRecording)
      }

      if viewModel.phase.isBusy {
        VStack(alignment: .leading, spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Button("処理をキャンセル", role: .cancel) {
            viewModel.cancelProcessing()
          }
          .buttonStyle(.link)
        }
      }

      if viewModel.canRetryAnalysis {
        Button {
          viewModel.retryAnalysis()
        } label: {
          Label("AI生成を再試行", systemImage: "arrow.clockwise")
        }
      }

      if viewModel.analysis != nil {
        Menu {
          ForEach(ExportFormat.allCases) { format in
            Button(format.displayName) {
              viewModel.export(format)
            }
          }
        } label: {
          Label("書き出す", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .disabled(viewModel.isExporting)
      }

      Spacer()

      SettingsLink {
        Label("APIキー設定", systemImage: "key")
      }
      .buttonStyle(.link)

      Text("録音停止後は会議タイトルと文字起こしテキストだけをClaudeへ送信します。一時録音は処理後に自動削除されます。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(22)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var statusColor: Color {
    switch viewModel.phase {
    case .recording:
      .red
    case .starting, .stopping, .generating:
      .orange
    case .completed:
      .green
    default:
      .gray
    }
  }
}

private struct TranscriptView: View {
  let transcript: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("リアルタイム文字起こし", systemImage: "waveform")
          .font(.headline)
        Spacer()
        if !transcript.isEmpty {
          Text("\(transcript.count)文字")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      ScrollView {
        Text(
          transcript.isEmpty
            ? "録音を開始すると、ここに文字起こしが表示されます。"
            : transcript
        )
        .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
    .padding(20)
  }
}
