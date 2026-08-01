# MeetingFlowAI

MeetingFlowAIは、会議のマイク音声をリアルタイムで文字起こしし、録音停止後に会議内容を業務で使える形へ構造化するmacOSネイティブアプリです。単なる議事録ではなく、議事録、ToDo、業務フローを一度に生成することを目的にしています。

> [!IMPORTANT]
> 現在の録音対象は**マイク入力のみ**です。Macのシステム音声を直接取り込む機能は含みません。オンライン会議の相手側の音声は、スピーカーからマイクへ回り込んだ場合を除き録音されません。

## 主な機能

- Start / Stopだけのシンプルな会議録音
- 録音中のリアルタイム文字起こしとスクロール表示
- OpenAI Responses API（`gpt-5.5`）とJSON Schemaによる構造化出力
- Markdown形式の議事録
- タイトル、担当、期限、優先度を持つToDo表
- 部門・担当者、アクション、次工程を保持する構造化業務フロー
- 構造化フローを正本として生成するMermaid `flowchart TD`
- Markdown（`.md`）、Mermaid（`.mmd`）、JSONの書き出し
- 文字起こし確定後の一時録音ファイル自動削除
- 処理のキャンセル、エラー表示、ダークモード

解析結果では、表示用のMermaidだけでなく次のような`flow`配列を保持します。この中間表現を変換元にすることで、将来Miro、draw.io、BPMN、Notion、Google Docs、Google Driveなどの連携を追加しやすい設計です。

```json
{
  "id": "1",
  "actor": "営業",
  "action": "受注確認",
  "next": [
    { "to": "2", "label": "承認" },
    { "to": "3", "label": "差戻し" }
  ]
}
```

`next`を遷移配列にしているため、単一路線だけでなく、Yes/Noや承認/差戻しのような条件分岐も欠落なくMermaidへ変換できます。終端は空配列、無条件遷移は`label`を空文字にします。

## 動作環境と音声認識

- macOS 15以上
- Xcode 26以上（必須）
- Swift 6 / SwiftUI / Swift Concurrency

Speech FrameworkのAPI可用性に合わせ、実行時に音声認識方式を切り替えます。

| 実行環境 | 音声認識方式 |
| --- | --- |
| macOS 26以降 | `SpeechAnalyzer`を使用 |
| macOS 15〜25 | `SFSpeechRecognizer`による互換実装を使用 |

デプロイ対象はmacOS 15ですが、`SpeechAnalyzer`を含むすべてのコードをビルドするため、Xcode 26以降を使用してください。macOS 15〜25では新APIを呼ばず、レガシー実装へ分岐します。macOS 26でも端末が`SpeechTranscriber`に対応しない場合は互換実装へフォールバックします。

## セットアップ

1. リポジトリを取得し、`MeetingFlowAI.xcodeproj`をXcodeで開きます。
2. `MeetingFlowAI`ターゲットのSigning & Capabilitiesで、ご自身のDevelopment Teamと必要に応じてBundle Identifierを設定します。
3. Product > Scheme > Manage Schemesを開き、`MeetingFlowAI`を複製して`MeetingFlowAI-Local`などの名前を付けます。
4. 複製したSchemeのSharedチェックを外し、個人用Schemeとして保存します。
5. 個人用Schemeを選び、Edit Scheme > Run > Argumentsを開きます。
6. Environment Variablesへ`OPENAI_API_KEY`を追加し、開発用APIキーを入力してチェックを有効にします。
7. 実行先にMy Macを選択して実行します。

共有Schemeには環境変数を登録していません。個人用Schemeは`xcuserdata`配下に保存されるため、APIキーを含むSchemeを共有・コミットしないでください。アプリは次の環境変数からキーを読み取ります。

```text
OPENAI_API_KEY=your-development-key
```

録音開始時、macOSからマイクと音声認識の使用確認が表示されたら許可してください。拒否した場合は、システム設定 > プライバシーとセキュリティ > マイク／音声認識から設定を変更できます。

録音音声は文字起こしのため一時的にApplication Supportへ保存しますが、文字起こし確定後、キャンセル時、エラー停止時に自動削除します。異常終了で残った`.caf`も次回録音開始時に削除します。macOS 15〜25の互換実装では、オンデバイス音声認識に対応しない環境の場合、Speech FrameworkがAppleのサーバーを利用する可能性があります。

## 権限とSandbox

アプリはApp SandboxとHardened Runtimeを有効にし、次の権限だけを宣言します。

- マイク入力: 会議録音とリアルタイム文字起こし
- 外向きネットワーク接続: OpenAI Responses APIへの送信
- ユーザー選択ファイルの読み書き: Save Panelで選んだ場所へのExport

`Info.plist`はXcodeが自動生成し、`NSMicrophoneUsageDescription`と`NSSpeechRecognitionUsageDescription`はBuild Settingsから注入します。権限の実体は`Configuration/MeetingFlowAI.entitlements`にあります。

## ビルドとテスト

XcodeからはProduct > Build、Product > Testを使用します。コマンドラインではプロジェクトルートで次を実行します。

```bash
xcodebuild \
  -project MeetingFlowAI.xcodeproj \
  -scheme MeetingFlowAI \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project MeetingFlowAI.xcodeproj \
  -scheme MeetingFlowAI \
  -destination 'platform=macOS' \
  test
```

Swift Packageとして型チェックとユニットテストを行うこともできます。

```bash
swift build
swift test
```

マイク、音声認識の権限、App Sandboxを含む実アプリの動作確認にはXcodeでビルドした`.app`を使用してください。

## 使い方

1. 会議タイトルを入力します。
2. Startで録音とリアルタイム文字起こしを開始します。
3. Stopで録音を終了します。
4. 文字起こしがOpenAI Responses APIへ送られ、解析が終わると「議事録」「ToDo」「業務フロー」「Mermaid」の各タブが表示されます。
5. MermaidタブのCopyでソースをコピーするか、Exportでファイルを保存します。

AI解析中の処理はキャンセルできます。通信、権限、APIキー、構造化レスポンスの問題は画面上にエラーとして表示されます。

## Export

| 形式 | 拡張子 | 内容 |
| --- | --- | --- |
| Markdown | `.md` | 会議タイトル、議事録、ToDo、業務フロー |
| Mermaid | `.mmd` | Mermaidソース |
| JSON | `.json` | 議事録、ToDo、`flow`、Mermaidを含む構造化データ |

保存先はmacOSのSave Panelでユーザーが選択します。Sandbox外の任意パスへアプリが無断で書き込むことはありません。

## プロジェクト構成

```text
MeetingFlowAI/
├── Package.swift
├── Configuration/
│   └── MeetingFlowAI.entitlements
├── MeetingFlowAI.xcodeproj/
├── MeetingFlowAI/
│   ├── App/          # アプリのエントリーポイント
│   ├── Models/       # 会議、ToDo、構造化フローのモデル
│   ├── Views/        # SwiftUI画面
│   ├── ViewModels/   # 画面状態と処理の調停
│   ├── Services/     # 録音、Exportなどのサービス
│   ├── Speech/       # OSバージョン別の音声認識
│   ├── AI/           # Responses API、JSON Schema
│   └── Utils/        # Mermaid生成などの共通処理
└── MeetingFlowAITests/
```

MVVMを基本に、録音、音声認識、AI解析、Exportをプロトコル境界で分離しています。SwiftUIから外部APIの詳細を切り離すことで、各サービスの差し替えとユニットテストを容易にします。

## APIキーを扱う際の重要事項

環境変数はローカル開発には適していますが、一般ユーザーへ配布するアプリの秘密保持手段にはなりません。APIキーをアプリ本体、`Info.plist`、Scheme、ソースコード、設定ファイルへ埋め込むと、配布物から抽出できます。

配布版では、次のいずれかの構成に変更してください。

- 自社バックエンド／プロキシでOpenAI APIを呼び、アプリには短命な認証トークンだけを渡す
- ユーザー自身のAPIキーを入力してもらい、Keychainへ保存する

いずれの場合も、利用者認証、レート制限、失効、ログからの機密情報除外を設計してください。会議内容は機密情報を含む可能性があるため、組織のデータ取扱方針とOpenAI側の設定を確認してから利用してください。

本アプリはResponses APIリクエストに`store: false`を指定しています。これはResponses APIのApplication Stateを保存しないための指定ですが、Zero Data Retention（ZDR）を保証するものではなく、不正利用監視ログなどの保持とは別の設定です。機密性の高い会議へ利用する前に、OpenAI組織／プロジェクトのData Controlsと、[エンドポイント別のデータ保持方針](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint)を確認してください。
