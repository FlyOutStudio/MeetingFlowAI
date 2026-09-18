# MeetingFlowAI

MeetingFlowAIは、対面会議やオンライン会議の音声をリアルタイムで文字起こしし、録音停止後に会議内容を業務で使える形へ構造化するmacOSネイティブアプリです。単なる議事録ではなく、議事録、ToDo、業務フローを一度に生成することを目的にしています。

> [!IMPORTANT]
> 録音モードは、対面会議向けの**マイク**と、オンライン会議向けの**選択アプリのシステム音声＋自分のマイク**の2種類です。オンラインモードでは、録音開始時にmacOS標準のScreenCaptureKit pickerが開きます。Zoomやブラウザなど対象の会議アプリを選択してください。画面映像は保存せず、選択したアプリの音声だけを自分のマイク音声と合わせて処理します。

## 主な機能

- 対面（マイク）／オンライン（選択アプリのシステム音声＋自分のマイク）の録音モード
- Start / Stopだけのシンプルな会議録音
- 録音中のリアルタイム文字起こしとスクロール表示
- Claude Messages API（`claude-sonnet-5`）とJSON Schemaによる構造化出力
- 目的・背景、主な議論、決定事項、未決事項、次の対応を必ず含むMarkdown形式の議事録
- 議事録の「次の対応」から、会議で明示された実行事項だけを抽出するToDo表
- 部門・担当者、アクション、次工程を保持する構造化業務フロー
- 構造化フローを正本として生成するMermaid `flowchart TD`
- Markdown（`.md`）、Mermaid（`.mmd`）、JSONの書き出し
- SwiftDataによる文字起こし・解析結果のローカル自動保存と会議履歴
- 過去の会議履歴の再表示、新しい会議への切り替え、履歴削除
- 既存音声ファイルの読み込みと文字起こし・Claude解析
- アプリ内設定からAnthropic APIキーをmacOS Keychainへ保存・更新・削除
- GitHub ReleasesからダウンロードできるUniversal `.app` ZIP
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
- Xcode 26以上（ソースからビルドする場合）
- Swift 6 / SwiftUI / Swift Concurrency

Speech FrameworkのAPI可用性に合わせ、実行時に音声認識方式を切り替えます。

| 実行環境 | 音声認識方式 |
| --- | --- |
| macOS 26以降 | `SpeechAnalyzer`を使用 |
| macOS 15〜25 | `SFSpeechRecognizer`による互換実装を使用 |

デプロイ対象はmacOS 15ですが、`SpeechAnalyzer`を含むすべてのコードをビルドするため、Xcode 26以降を使用してください。macOS 15〜25では新APIを呼ばず、レガシー実装へ分岐します。macOS 26でも端末が`SpeechTranscriber`に対応しない場合は互換実装へフォールバックします。

## MacBook Airで使う

1. Private repositoryへログインできるGitHubアカウントで、[Releases](https://github.com/FlyOutStudio/MeetingFlowAI/releases)から`MeetingFlowAI-macOS.zip`をダウンロードします。
2. ZIPを展開し、`MeetingFlowAI.app`をApplicationsフォルダへ移動します。
3. 初回だけFinderで`MeetingFlowAI.app`を右クリック（またはControlキーを押しながらクリック）し、「開く」を選びます。
4. それでもmacOSにブロックされた場合は、警告を閉じ、システム設定 > プライバシーとセキュリティで「このまま開く」を選び、再確認画面の「開く」を選びます。
5. アプリの「APIキー設定」を開き、自分のAnthropic APIキーを入力して「Keychainへ保存」を選びます。
6. 録音開始時に、マイクと音声認識へのアクセスを許可します。オンラインモードでは、画面収録とシステムオーディオ録音へのアクセスも許可し、macOS標準のpickerで対象の会議アプリを選択します。

### インストール済みアプリを更新する

1. MeetingFlowAIを終了します。
2. Releasesから新しい`MeetingFlowAI-macOS.zip`をダウンロードして展開します。
3. 新しい`MeetingFlowAI.app`をApplicationsフォルダへ移動し、「置き換える」を選びます。
4. Finderから起動します。macOSにブロックされた場合は、初回インストールと同じ右クリックの「開く」を使用します。

同じBundle Identifierを維持した通常の上書き更新では、SwiftDataの会議履歴とKeychainのAPIキーは残ります。アプリ本体の上書きではなく、AppCleanerなどで関連データまで削除すると履歴を失うため使用しないでください。更新前に重要な会議をMarkdownまたはJSONへExportしておくと安全です。

初回許可後は、Finderから通常どおりダブルクリックして起動できます。APIキーもログインKeychainから読み込むため、TerminalやXcodeは不要です。Appleの現行手順は[Macでアプリを安全に開く](https://support.apple.com/ja-jp/102445)で確認できます。

画面収録とシステムオーディオ録音を初めて許可した直後は、macOSの状態によってアプリの再起動が必要な場合があります。その場合はMeetingFlowAIを終了して開き直し、もう一度オンラインモードでStartを選んでください。スピーカー音がマイクへ回り込むと相手の音声が重複するため、オンライン会議ではヘッドフォンまたはイヤフォンの使用を推奨します。

> [!WARNING]
> 配布ZIPは無料運用のためAd Hoc署名であり、AppleのDeveloper ID署名やNotarizationではありません。入手元がこのPrivate repositoryのReleaseであることを確認した場合だけ「このまま開く」を許可してください。

## ソースから開発する

1. リポジトリを取得し、`MeetingFlowAI.xcodeproj`をXcodeで開きます。
2. `MeetingFlowAI`ターゲットのSigning & Capabilitiesで、ご自身のDevelopment Teamと必要に応じてBundle Identifierを設定します。
3. 実行先にMy Macを選択して実行します。
4. アプリの「APIキー設定」からキーをKeychainへ保存します。

開発時だけは、個人用SchemeのEnvironment Variablesへ次の値を追加する方法も利用できます。Keychain保存値がある場合はそちらを優先します。共有Schemeへ秘密値を登録しないでください。

```text
ANTHROPIC_API_KEY=your-development-key
```

録音開始時、macOSからマイクと音声認識の使用確認が表示されたら許可してください。オンラインモードでは、Start後にmacOS標準のScreenCaptureKit pickerが表示されるため、Zoomやブラウザなど音声を取り込む会議アプリを選択します。初回は画面収録とシステムオーディオ録音の許可も必要です。拒否した場合は、システム設定 > プライバシーとセキュリティ > マイク／音声認識／画面収録とシステムオーディオ録音から設定を変更できます。初回許可後に取り込みを開始できない場合は、アプリを終了して開き直してください。

オンライン会議では、スピーカーから再生した相手の音声をマイクも拾うと二重に録音されることがあります。相手の音声はシステム音声として直接取り込めるため、ヘッドフォンまたはイヤフォンを使用してください。

録音音声は文字起こしのため一時的にApplication Supportへ保存しますが、文字起こし確定後、キャンセル時、エラー停止時に自動削除します。異常終了で残った`.caf`も次回録音開始時に削除します。macOS 15〜25の互換実装では、オンデバイス音声認識に対応しない環境の場合、Speech FrameworkがAppleのサーバーを利用する可能性があります。

## 権限とSandbox

アプリはApp SandboxとHardened Runtimeを有効にし、次のSandbox権限だけを宣言します。

- マイク入力: 会議録音とリアルタイム文字起こし
- 外向きネットワーク接続: Claude Messages APIへの送信
- ユーザー選択ファイルの読み書き: Save Panelで選んだ場所へのExport

`Info.plist`はXcodeが自動生成し、`Configuration/MeetingFlowAI-Info.plist`に定義した`NSMicrophoneUsageDescription`、`NSScreenCaptureUsageDescription`、`NSSpeechRecognitionUsageDescription`をマージします。Sandbox権限の実体は`Configuration/MeetingFlowAI.entitlements`にあります。

オンラインモードのシステム音声は、ScreenCaptureKitとmacOS標準の共有pickerを通じて、利用者がその都度選択したアプリから取得します。このアクセスはmacOSのプライバシー設定で管理され、画面映像は録画ファイルへ保存しません。

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

マイク、音声認識、画面収録とシステムオーディオ録音の権限、App Sandboxを含む実アプリの動作確認にはXcodeでビルドした`.app`を使用してください。

## GitHub Actionsでの個人配布

`.github/workflows/macos-release.yml`は、Apple Developer Programの証明書やRepository Secretsを使わずに配布用ZIPを作成します。実行経路は、Actions画面からの手動実行と`v`で始まるタグのpushだけです。

ワークフローは次の処理を行います。

1. GitHub-hostedの`macos-26` runnerとXcode 26でユニットテスト
2. Intel／Apple Silicon両対応のUniversal Release build
3. `Configuration/MeetingFlowAI.entitlements`を埋め込んだAd Hoc署名
4. 2アーキテクチャ、App Sandbox権限、Hardened Runtime、署名を検証
5. `ditto`による`MeetingFlowAI-macOS.zip`の作成
6. ZIPを14日間保持するworkflow artifactとして保存

手動ビルドでは、GitHubのActionsタブから「Build macOS Release」を選び、「Run workflow」を実行します。完了後、workflow runのArtifactsから`MeetingFlowAI-macOS.zip`を取得できます。

リリースを作成する場合は、次のように`v`で始まるタグをpushします。

```bash
git tag v1.3.0
git push origin v1.3.0
```

タグのビルドに成功すると、GitHub Releaseが自動生成され、同じZIPがRelease assetとして添付されます。Release作成にはGitHubがJobごとに発行する`GITHUB_TOKEN`だけを使うため、Personal Access Tokenの登録は不要です。Private repositoryでも動作しますが、Actionsの実行時間とartifact storageは利用中のGitHubプランの割当対象です。

### 配布ZIPの署名と初回起動

この無料配布用ZIPはAd Hoc署名であり、Developer ID署名やAppleのNotarizationではありません。コード改変の検出とApp Sandboxの適用には署名を使いますが、配布者の身元をGatekeeperへ証明するものではないため、初回起動時に「開発元を確認できない」「Appleは悪意のあるソフトウェアかどうかを確認できない」旨の警告が表示されます。

信頼できるrepositoryまたはReleaseから取得したことを確認したうえで、次の手順で初回だけ許可します。

1. ZIPを展開し、`MeetingFlowAI.app`をApplicationsフォルダへ移動します。
2. 初回だけFinderでアプリを右クリック（またはControlキーを押しながらクリック）し、「開く」を選びます。
3. それでもmacOSにブロックされた場合はダイアログを閉じ、システム設定 > プライバシーとセキュリティを開いて、下へスクロールし「このまま開く」（Open Anyway）を選びます。
4. 再表示された確認画面で「開く」を選びます。

この操作は、入手元と内容を信頼できる場合だけ行ってください。配布物に`ANTHROPIC_API_KEY`は含まれません。初回起動後にアプリの設定画面から入力し、macOSのログインKeychainへ保存します。保存済みの秘密値を画面へ再表示したり、ソースコードや設定ファイルへ書き込んだりしません。

## 使い方

1. 初回だけ「APIキー設定」でAnthropic APIキーをKeychainへ保存します。
2. 会議タイトルを入力します。
3. 録音モードから「対面」または「オンライン」を選択します。
4. Startで録音とリアルタイム文字起こしを開始します。オンラインモードでは、表示されたmacOS標準のpickerで会議アプリを選択します。
5. Stopで録音を終了します。
6. 文字起こしがClaude Messages APIへ送られ、解析が終わると「議事録」「ToDo」「業務フロー」「Mermaid」の各タブが表示されます。
7. MermaidタブのCopyでソースをコピーするか、Exportでファイルを保存します。

次の会議へ進むときは、左側の「新しい会議」を選びます。過去の会議は「会議履歴」からいつでも開き直せます。すでにある音声を使う場合は「既存の音声を読み込む」から音声ファイルを選択します。読み込み元ファイルは変更・複製せず、文字起こしと解析結果だけを履歴へ保存します。

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
├── .github/
│   └── workflows/
│       └── macos-release.yml
├── Package.swift
├── Scripts/
│   └── build-release.sh
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
│   ├── AI/           # Claude Messages API、JSON Schema
│   └── Utils/        # Mermaid生成などの共通処理
└── MeetingFlowAITests/
```

MVVMを基本に、録音、音声認識、AI解析、SwiftData履歴、Exportをプロトコル境界で分離しています。SwiftUIから外部APIや保存方式の詳細を切り離すことで、各サービスの差し替えとユニットテストを容易にします。

引き継ぎ・運用時は、[SETUP.md](SETUP.md)、[OPERATIONS.md](OPERATIONS.md)、[ARCHITECTURE.md](ARCHITECTURE.md)、[CHANGELOG.md](CHANGELOG.md)、[TODO.md](TODO.md)も参照してください。

## APIキーを扱う際の重要事項

APIキーは利用者がアプリ内で入力し、macOSのログインKeychainへ保存します。保存済みキーは画面へ再表示せず、AI解析リクエストの直前にだけ読み込みます。APIキーをアプリ本体、`Info.plist`、共有Scheme、ソースコード、設定ファイルへ埋め込むと配布物から抽出できるため、この構成では採用していません。

複数利用者へ本格的に配布する場合は、利用者個人のAPIキーではなく、次の構成を検討してください。

- 自社バックエンド／プロキシでClaude APIを呼び、アプリには短命な認証トークンだけを渡す

いずれの場合も、利用者認証、レート制限、失効、ログからの機密情報除外を設計してください。会議内容は機密情報を含む可能性があるため、組織のデータ取扱方針とAnthropic側の設定を確認してから利用してください。

本アプリはClaude Messages APIをステートレスに呼び出し、会議タイトルと文字起こし以外のファイルは送信しません。文字起こしと解析結果はSwiftDataで利用者のMac内へ保存し、録音音声と読み込み元音声は保存しません。JSON SchemaによるStructured Outputsを使用しており、Anthropic側ではスキーマが処理最適化のため一時的にキャッシュされる場合があります。機密性の高い会議へ利用する前に、Anthropic組織の契約・データ保持設定と[API and data retention](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)を確認してください。
