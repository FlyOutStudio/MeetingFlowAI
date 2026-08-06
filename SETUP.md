# セットアップ

## 必要な環境

- macOS 15以上
- Xcode 26以上
- Swift 6
- Anthropic Consoleで発行したAPIキー

## 初回セットアップ

1. `MeetingFlowAI.xcodeproj`をXcodeで開きます。
2. `MeetingFlowAI`ターゲットのSigning & CapabilitiesでDevelopment Teamを選択します。
3. 実行先にMy Macを選び、BuildまたはRunを実行します。
4. 起動したアプリの「APIキー設定」でAnthropic APIキーをKeychainへ保存します。
5. 初回録音時に、マイクと音声認識を許可します。オンライン会議では画面収録とシステムオーディオ録音も許可します。

APIキーはソースや共有Schemeへ保存しないでください。開発時だけ環境変数を使う場合は、`.env.example`を値の一覧として参照し、個人用SchemeのRun > Argumentsへ`ANTHROPIC_API_KEY`を設定します。本アプリは`.env`を自動読込しません。

## ビルドとテスト

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

Swift Packageとして確認する場合は`swift build`と`swift test`を使用します。音声・Sandbox・ScreenCaptureKitの実機確認はXcodeでビルドしたアプリで行ってください。

## API設定

| 項目 | 値 |
| --- | --- |
| Endpoint | `https://api.anthropic.com/v1/messages` |
| Model | `claude-sonnet-5` |
| API version | `2023-06-01` |
| Environment variable | `ANTHROPIC_API_KEY` |
| Keychain account | `ANTHROPIC_API_KEY` |

旧版で保存した`OPENAI_API_KEY`はClaudeへ送信されません。Claude版を初めて起動した際は、Anthropic APIキーを新しく保存してください。
