import AppKit
import SwiftUI

private enum AnalysisTab: Hashable {
  case summary
  case todo
  case workflow
  case mermaid
}

struct AnalysisTabsView: View {
  @ObservedObject var viewModel: MeetingViewModel
  @State private var selectedTab: AnalysisTab = .summary

  var body: some View {
    TabView(selection: $selectedTab) {
      tabContent {
        SummaryView(summary: viewModel.analysis?.summary ?? "")
      }
      .tabItem { Label("議事録", systemImage: "doc.text") }
      .tag(AnalysisTab.summary)

      tabContent {
        TodoTableView(items: viewModel.analysis?.todo ?? [])
      }
      .tabItem { Label("ToDo", systemImage: "checklist") }
      .tag(AnalysisTab.todo)

      tabContent {
        WorkflowTableView(steps: viewModel.analysis?.flow ?? [])
      }
      .tabItem {
        Label("業務フロー", systemImage: "point.3.connected.trianglepath.dotted")
      }
      .tag(AnalysisTab.workflow)

      tabContent {
        MermaidSourceView(viewModel: viewModel)
      }
      .tabItem { Label("Mermaid", systemImage: "chevron.left.forwardslash.chevron.right") }
      .tag(AnalysisTab.mermaid)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  @ViewBuilder
  private func tabContent<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    if viewModel.analysis != nil {
      content()
    } else if viewModel.phase == .transcriptReady {
      ContentUnavailableView(
        "分析結果はまだありません",
        systemImage: "arrow.clockwise",
        description: Text("AI生成を再試行してください。")
      )
    } else {
      VStack(spacing: 12) {
        ProgressView()
        Text(viewModel.phase.statusText)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct SummaryView: View {
  let summary: String

  var body: some View {
    ScrollView {
      Text(markdown)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18)
    }
  }

  private var markdown: AttributedString {
    (try? AttributedString(markdown: summary)) ?? AttributedString(summary)
  }
}

private struct TodoTableView: View {
  let items: [TodoItem]

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
        GridRow {
          tableHeader("タイトル")
          tableHeader("担当")
          tableHeader("期限")
          tableHeader("優先度")
        }
        Divider().gridCellColumns(4)

        if items.isEmpty {
          Text("ToDoは抽出されませんでした。")
            .foregroundStyle(.secondary)
            .gridCellColumns(4)
            .padding(.vertical, 12)
        } else {
          ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            GridRow {
              Text(item.title)
              Text(item.owner.isEmpty ? "—" : item.owner)
              Text(item.deadline.isEmpty ? "—" : item.deadline)
              PriorityBadge(priority: item.priority)
            }
            Divider().gridCellColumns(4)
          }
        }
      }
      .textSelection(.enabled)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private func tableHeader(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
  }
}

private struct PriorityBadge: View {
  let priority: TodoPriority

  var body: some View {
    Text(priority.localizedName)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.14), in: Capsule())
  }

  private var color: Color {
    switch priority {
    case .high:
      .red
    case .medium:
      .orange
    case .low:
      .blue
    }
  }
}

private struct WorkflowTableView: View {
  let steps: [FlowStep]

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
        GridRow {
          tableHeader("ID")
          tableHeader("担当・部門")
          tableHeader("アクション")
          tableHeader("次の工程")
        }
        Divider().gridCellColumns(4)

        if steps.isEmpty {
          Text("業務フローは抽出されませんでした。")
            .foregroundStyle(.secondary)
            .gridCellColumns(4)
            .padding(.vertical, 12)
        } else {
          ForEach(steps) { step in
            GridRow {
              Text(step.id).font(.body.monospaced())
              Text(step.actor.isEmpty ? "—" : step.actor)
              Text(step.action)
              Text(destinationText(for: step))
                .font(.body.monospaced())
            }
            Divider().gridCellColumns(4)
          }
        }
      }
      .textSelection(.enabled)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private func tableHeader(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
  }

  private func destinationText(for step: FlowStep) -> String {
    guard !step.next.isEmpty else { return "終端" }
    return step.next.map { transition in
      transition.label.isEmpty
        ? transition.to
        : "\(transition.label) → \(transition.to)"
    }.joined(separator: ", ")
  }
}

private struct MermaidSourceView: View {
  @ObservedObject var viewModel: MeetingViewModel

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Spacer()
        Button {
          copyMermaid()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(viewModel.analysis == nil)

        Button {
          viewModel.export(.mermaid)
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(viewModel.analysis == nil || viewModel.isExporting)
      }

      ScrollView([.horizontal, .vertical]) {
        Text(verbatim: viewModel.analysis?.mermaid ?? "")
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(16)
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
    .padding(14)
  }

  private func copyMermaid() {
    guard let mermaid = viewModel.analysis?.mermaid else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(mermaid, forType: .string)
  }
}
