import SwiftUI

struct BusinessInterviewView: View {
  @ObservedObject var viewModel: MeetingViewModel
  @State private var editingItem: InterviewItem?
  @State private var showingReplacementConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("出所と人の確認状態は別に管理します。根拠との対応を確認してから「確認済みにする」を押してください。")
          .font(.callout).foregroundStyle(.secondary)
        if let interview = viewModel.analysis?.businessInterview {
          sections(interview, editable: true)
        } else {
          Text("業務ヒアリングはまだありません。再生成すると抽出します。")
        }
        if let candidate = viewModel.analysis?.interviewCandidate {
          Divider()
          Text("再解析の候補").font(.title3.bold())
          Text("編集・確認した内容は上に保持しています。候補を採用すると、業務ヒアリング全体を置き換えます。")
          HStack {
            Button("候補へ置き換える") { showingReplacementConfirmation = true }
            Button("候補を破棄") { viewModel.dismissInterviewCandidate() }
          }
          .disabled(!viewModel.canSwitchMeeting)
          sections(candidate, editable: false)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(item: $editingItem) { item in
      InterviewEditView(item: item) { content, origin, quotes in
        viewModel.editInterviewItem(id: item.id, content: content, origin: origin, quotes: quotes)
      }
    }
    .alert("業務ヒアリングを候補で置き換えますか？", isPresented: $showingReplacementConfirmation) {
      Button("置き換える", role: .destructive) { viewModel.acceptInterviewCandidate() }
      Button("キャンセル", role: .cancel) {}
    } message: {
      Text("現在の編集内容と確認状態を退避し、候補を未確認として採用します。「再生成前の結果に戻す」で退避内容を復元できます。")
    }
  }

  private func sections(_ interview: BusinessInterview, editable: Bool) -> some View {
    ForEach(InterviewSection.allCases, id: \.self) { section in
      VStack(alignment: .leading, spacing: 12) {
        Text(section.title).font(.headline)
        let items = interview.items.filter { $0.section == section }
        if items.isEmpty { Text("該当する内容は抽出されていません。未確認です。").foregroundStyle(.secondary) }
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(item.origin.title)
              Text("人の確認：\(item.review.title)")
                .foregroundStyle(item.review == .confirmed ? Color.green : Color.secondary)
              if item.humanEdited { Text("人が編集").foregroundStyle(.secondary) }
            }
            .font(.caption)
            Text(verbatim: item.content.text).textSelection(.enabled)
            if section == .currentProcess {
              Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                field("担当者", item.content.actor)
                field("作業", item.content.action)
                field("入力", item.content.input)
                field("道具", item.content.tools)
                field("出力", item.content.output)
                field("例外", item.content.exceptions)
              }.textSelection(.enabled)
            }
            ForEach(item.evidence) { reference in
              InterviewEvidenceButton(reference: reference, transcript: interview.sourceTranscript)
            }
            if editable {
              HStack {
                Button("編集") { editingItem = item }
                Button("確認済みにする") { viewModel.confirmInterviewItem(id: item.id) }
                  .disabled(item.review == .confirmed)
              }.disabled(!viewModel.canSwitchMeeting)
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private func field(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(verbatim: value).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct InterviewEvidenceButton: View {
  let reference: InterviewEvidence
  let transcript: String
  @State private var showingSource = false

  var body: some View {
    Button { showingSource = true } label: {
      Label("根拠原文：\(reference.quote)", systemImage: "text.quote")
        .lineLimit(2).multilineTextAlignment(.leading)
    }
    .buttonStyle(.link)
    .popover(isPresented: $showingSource) {
      VStack(alignment: .leading, spacing: 12) {
        Text("解析時に保存した原文").font(.headline)
        Text("話者・時刻は記録されていません。強調部分が根拠の該当箇所です。")
          .font(.caption).foregroundStyle(.secondary)
        ScrollViewReader { proxy in
          ScrollView {
            if let range = reference.range(in: transcript) {
              VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: String(transcript[..<range.lowerBound]))
                Text(verbatim: String(transcript[range]))
                  .bold().padding(4).background(.yellow.opacity(0.25)).id("evidence")
                Text(verbatim: String(transcript[range.upperBound...]))
              }
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Text("保存した原文と根拠が一致しません。")
            }
          }
          .onAppear { proxy.scrollTo("evidence", anchor: .center) }
        }
        Button("閉じる") { showingSource = false }
      }.padding(18).frame(width: 560, height: 420)
    }
  }
}

private struct InterviewEditView: View {
  let item: InterviewItem
  let save: (InterviewContent, InterviewOrigin, [String]) -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var content: InterviewContent
  @State private var origin: InterviewOrigin
  private struct QuoteDraft: Identifiable {
    let id = UUID()
    var text: String
  }

  @State private var quotes: [QuoteDraft]
  @State private var failed = false

  init(item: InterviewItem, save: @escaping (InterviewContent, InterviewOrigin, [String]) -> Bool) {
    self.item = item
    self.save = save
    _content = State(initialValue: item.content)
    _origin = State(initialValue: item.origin)
    _quotes = State(initialValue: item.evidence.map { QuoteDraft(text: $0.quote) })
  }

  private func quoteBinding(id: UUID) -> Binding<String> {
    Binding(
      get: { quotes.first(where: { $0.id == id })?.text ?? "" },
      set: { text in
        guard let index = quotes.firstIndex(where: { $0.id == id }) else { return }
        quotes[index].text = text
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(item.section.title)を編集").font(.title2)
      Text("内容・出所・根拠を変更すると未確認に戻ります。原文にない情報は「未確認」としてください。")
        .font(.caption)
      ScrollView {
        Form {
          TextField("内容", text: $content.text, axis: .vertical)
          Picker("出所", selection: $origin) {
            ForEach(InterviewOrigin.allCases, id: \.self) { origin in
              Text(origin.title).tag(origin)
            }
          }
          if item.section == .currentProcess {
            TextField("担当者", text: $content.actor)
            TextField("作業", text: $content.action)
            TextField("入力", text: $content.input)
            TextField("道具", text: $content.tools)
            TextField("出力", text: $content.output)
            TextField("例外", text: $content.exceptions)
          }
          ForEach(quotes) { quote in
            TextField("根拠原文", text: quoteBinding(id: quote.id), axis: .vertical)
          }
          HStack {
            Button("根拠を追加") { quotes.append(QuoteDraft(text: "")) }
            Button("最後の根拠を削除") { _ = quotes.popLast() }.disabled(quotes.count <= 1)
          }
        }.textFieldStyle(.roundedBorder)
      }
      if failed {
        Text("保存できませんでした。根拠の抜粋を確認してください。保存先のエラーがある場合は、編集内容を控えてから閉じ、エラー表示を確認してください。")
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("キャンセル") { dismiss() }
        Button("保存") {
          if save(content, origin, quotes.map(\.text)) { dismiss() } else { failed = true }
        }.buttonStyle(.borderedProminent)
      }
    }.padding(22).frame(width: 620, height: 590)
  }
}
