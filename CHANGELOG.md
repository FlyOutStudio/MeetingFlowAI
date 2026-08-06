# 変更履歴

## 2026-08-06

### Changed

- 会議解析APIをOpenAI Responses APIからClaude Messages APIへ変更
- 解析モデルを`claude-sonnet-5`へ変更
- Claude Structured Outputsの`output_config.format`へ既存の`MeetingAnalysis` JSON Schemaを接続
- 認証ヘッダーを`x-api-key`、API versionを`anthropic-version: 2023-06-01`へ変更
- APIキー環境変数とKeychain accountを`ANTHROPIC_API_KEY`へ変更
- Claudeの拒否、出力上限、入力上限、HTTPエラーに対応する利用者向けエラーを追加

### Unchanged

- macOS Speech Frameworkによる文字起こし
- 録音モード、一時録音削除、画面構成
- `MeetingAnalysis`、Mermaid生成、Export形式

### Tests

- Claude向けリクエストヘッダー、モデル、Structured Outputs schema、レスポンス、拒否、上限、認証、キャンセルの単体テストへ置換
