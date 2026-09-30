# Quotaback

Claude Code の `/usage`（Current session / Current week の消費率）を、複数アカウント分メニューバーに表示する常駐アプリ。

```
P 13% · W 43%     ← 各アカウントの「一番埋まっている枠」の %
```

クリックすると各アカウントの枠ごとの詳細とリセット時刻が出ます。

> ⚠️ `api.anthropic.com/api/oauth/usage` は Claude Code が内部で使っている **非公開 API** です。
> 予告なく変わる可能性があります。生レスポンスは `~/.config/quotaback/last-response-<label>.json` に保存されるので、壊れたらそれを見て `UsageClient.parse` を直してください。

## ビルド・起動

```sh
swift run                    # 開発中（メニューバーに常駐）
swift run Quotaback --once   # UI なしで全アカウントを1回取得して結果を表示（動作確認用）
swift test                   # パーサーのテスト
./scripts/bundle.sh          # dist/Quotaback.app を作る（常用）
open dist/Quotaback.app
```

Xcode で開く場合は `open Package.swift`。

## 設定

初回起動で `~/.config/quotaback/config.json` が作られます。2アカウント分をこう書く：

```json
{
  "refreshSeconds": 300,
  "accounts": [
    { "label": "P", "name": "personal@example.com",           "keychainService": "Claude Code-credentials" },
    { "label": "W", "name": "work@example.com", "keychainService": "Claude Code-credentials-XXXXXXXX" }
  ]
}
```

- `keychainService`: Keychain の service 名。`CLAUDE_CONFIG_DIR` を分けている場合、別名のエントリになっているはずなので次で確認：
  ```sh
  security dump-keychain | grep '"svce"' | grep -i claude
  ```
- Keychain ではなくファイルに credentials がある場合は `"credentialsPath": "~/.claude-work/.credentials.json"` を代わりに指定。
- 編集後はメニューの「設定を再読込」。

## 挙動メモ

- **トークンのリフレッシュはしません**（refresh token のローテーションで Claude Code 側のログインを壊さないため）。期限切れになったら、そのアカウントで `claude` を一度起動すれば Claude Code が更新します。
- 初回は Keychain のアクセス許可ダイアログが出ます。「常に許可」でOK。
- 更新間隔は最短 60 秒。非公開 API なので叩きすぎないよう既定は 5 分。

## ログイン時に自動起動

`dist/Quotaback.app` を `/Applications` などに置いて起動し、パネルの「ログイン時に起動」にチェック（`SMAppService`）。
`.app` から起動したときだけ表示されます（`swift run` では出ません）。
