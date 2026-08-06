# 変更履歴

## 1.3.0 - 2026-08-06

### Added

- SwiftDataによる文字起こし・解析結果のローカル自動保存
- 会議履歴の一覧、再表示、削除と「新しい会議」への切り替え
- 既存音声ファイルを選択して文字起こし・Claude解析する機能
- 初期SwiftDataスキーマと将来のデータ移行計画

### Changed

- アプリ内部バージョンをReleaseタグと一致する`1.3.0`へ更新
- タグとアプリ内部バージョンが一致しない場合にReleaseを停止する検証を追加
- 音声データは保存せず、文字起こしと解析結果だけを履歴へ保持する運用を明文化

### Tests

- 会議完了時の自動保存と履歴からの再表示を検証
- SwiftData履歴の追加・更新・取得・削除をインメモリDBで検証

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
