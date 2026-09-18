import SwiftUI
import UniformTypeIdentifiers

struct MeetingWorkspaceView: View {
  @ObservedObject var viewModel: MeetingViewModel

  var body: some View {
    HSplitView {
      MeetingHistorySidebar(viewModel: viewModel)
        .frame(
          minWidth: 220,
          idealWidth: 250,
          maxWidth: 300,
          maxHeight: .infinity,
          alignment: .top
        )

      ControlPanelView(viewModel: viewModel)
        .frame(
          minWidth: 260,
          idealWidth: 300,
          maxWidth: 340,
          maxHeight: .infinity,
          alignment: .top
        )

      VStack(spacing: 0) {
        TranscriptView(transcript: viewModel.transcript)
          .frame(minHeight: 240)

        if viewModel.shouldShowAnalysisTabs {
          Divider()
          AnalysisTabsView(viewModel: viewModel)
            .frame(minHeight: 330)
        }
      }
      .frame(minWidth: 620, maxHeight: .infinity, alignment: .top)
    }
    .frame(
      minWidth: 1_120,
      maxWidth: .infinity,
      minHeight: 680,
      maxHeight: .infinity,
      alignment: .topLeading
    )
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

private struct MeetingHistorySidebar: View {
  @ObservedObject var viewModel: MeetingViewModel
  @State private var meetingPendingDeletion: MeetingRecord?

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Label("会議履歴", systemImage: "clock.arrow.circlepath")
          .font(.headline)
        Spacer()
      }

      Button {
        viewModel.newMeeting()
      } label: {
        Label("新しい会議", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canSwitchMeeting)

      if viewModel.meetings.isEmpty {
        ContentUnavailableView(
          "履歴はまだありません",
          systemImage: "text.document",
          description: Text("録音または音声ファイルの解析後に自動保存されます。")
        )
      } else {
        List(selection: selectedMeetingBinding) {
          ForEach(viewModel.meetings) { meeting in
            VStack(alignment: .leading, spacing: 5) {
              Text(meeting.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
              Text(meeting.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
              Label(meeting.source.displayName, systemImage: sourceImage(meeting.source))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .tag(meeting.id)
            .contextMenu {
              Button("削除", role: .destructive) {
                meetingPendingDeletion = meeting
              }
            }
          }
        }
        .listStyle(.sidebar)
      }
    }
    .padding(14)
    .background(Color(nsColor: .windowBackgroundColor))
    .alert(
      "会議履歴を削除しますか？",
      isPresented: Binding(
        get: { meetingPendingDeletion != nil },
        set: { if !$0 { meetingPendingDeletion = nil } }
      ),
      presenting: meetingPendingDeletion
    ) { meeting in
      Button("削除", role: .destructive) {
        viewModel.deleteMeeting(id: meeting.id)
        meetingPendingDeletion = nil
      }
      Button("キャンセル", role: .cancel) {
        meetingPendingDeletion = nil
      }
    } message: { meeting in
      Text("「\(meeting.title)」の文字起こしと解析結果を削除します。この操作は取り消せません。")
    }
  }

  private var selectedMeetingBinding: Binding<UUID?> {
    Binding(
      get: { viewModel.selectedMeetingID },
      set: { id in
        guard let id else { return }
        viewModel.selectMeeting(id: id)
      }
    )
  }

  private func sourceImage(_ source: MeetingSource) -> String {
    switch source {
    case .recording:
      "record.circle"
    case .importedAudio:
      "waveform.badge.plus"
    }
  }
}

private struct ControlPanelView: View {
  @ObservedObject var viewModel: MeetingViewModel
  @State private var isAudioImporterPresented = false

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
        HStack(spacing: 8) {
          TextField("例：受注〜発送フロー改善会議", text: $viewModel.meetingTitle)
            .textFieldStyle(.roundedBorder)
            .disabled(!viewModel.canStartRecording)
            .onSubmit {
              viewModel.saveMeetingTitle()
            }

          Button("保存") {
            viewModel.saveMeetingTitle()
          }
          .disabled(!viewModel.canSaveMeetingTitle)
        }

        if viewModel.canSaveMeetingTitle {
          Text("変更後は保存を押すか、Enterキーで履歴へ反映します。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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

        Button {
          isAudioImporterPresented = true
        } label: {
          Label("既存の音声を読み込む", systemImage: "waveform.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.canSwitchMeeting)
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
          Label(
            viewModel.analysis == nil ? "AI生成を再試行" : "議事録を再生成",
            systemImage: "arrow.clockwise"
          )
        }

        if viewModel.analysis != nil {
          Text("議事録・ToDo・業務フローを最新のAI結果で置き換えます。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if viewModel.canRestorePreviousAnalysis {
        Button {
          viewModel.restorePreviousAnalysis()
        } label: {
          Label("再生成前の結果に戻す", systemImage: "arrow.uturn.backward")
        }

        Text("再生成前に自動保存した議事録・ToDo・業務フローへ戻します。")
          .font(.caption)
          .foregroundStyle(.secondary)
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

      Text("文字起こしと解析結果はこのMacへ自動保存されます。Claudeへ送るのは会議タイトルと文字起こしだけです。録音・読み込み元の音声は保存しません。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(22)
    .background(Color(nsColor: .controlBackgroundColor))
    .fileImporter(
      isPresented: $isAudioImporterPresented,
      allowedContentTypes: [.audio],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          viewModel.importAudio(from: url)
        }
      case .failure(let error):
        viewModel.handleAudioImportSelectionError(error)
      }
    }
  }

  private var statusColor: Color {
    switch viewModel.phase {
    case .recording:
      .red
    case .starting, .importing, .stopping, .generating:
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
