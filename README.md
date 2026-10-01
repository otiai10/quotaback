# Quotaback

Claude Code の `/usage`（Current session / Current week の消費率）を、複数アカウント分メニューバーに表示する常駐アプリ。

```
P 13% · W 43%     ← 各アカウントの「一番埋まっている枠」の %
```

クリックすると各アカウントの枠ごとの詳細とリセット時刻が出ます。

> ⚠️ `api.anthropic.com/api/oauth/usage` は Claude Code が内部で使っている **非公開 API** です。
> 予告なく変わる可能性があります。生レスポンスは `~/.config/quotaback/last-response-<email>.json` に保存されるので、壊れたらそれを見て `UsageClient.parse` を直してください。

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

初回起動で `~/.config/quotaback/config.json` が作られます。表示したいアカウントをメールアドレスで並べるだけ：

```json
{
  "refreshSeconds": 300,
  "accounts": [
    { "label": "P", "name": "personal@example.com" },
    { "label": "W", "name": "work@example.com" }
  ]
}
```

### どのトークンが誰のものか

Claude Code の認証情報の置き場所（Keychain の `Claude Code-credentials` や `<CLAUDE_CONFIG_DIR>/.credentials.json`）には、**最後にログインしたアカウント**のトークンしか入っていません。
Quotaback は置き場所ごとに `.claude.json` の `oauthAccount.emailAddress` を見て持ち主を判定し、`accounts` の `name` と突き合わせます。

- 置き場所は自動検出：既定の Keychain エントリ、`$CLAUDE_CONFIG_DIR/.credentials.json`、`~/.claude*/.credentials.json`
- **`/login` で1つのログインを切り替えて使っている場合**：ログイン中のアカウントだけが更新され、もう一方は前回の値が括弧付きで出ます（`P (43%) · W 17%`）。前回値は `~/.config/quotaback/state.json` に保存。リセット時刻を過ぎた枠は「リセット済み」
- **`CLAUDE_CONFIG_DIR` を分けている場合**：それぞれ別の置き場所として自動で拾われ、両方同時に更新されます
- 設定に無いアカウントや持ち主が分からない置き場所は `?` ラベルで出ます
- 自動検出で足りなければ `sources` で明示（指定すると自動検出はしない）：
  ```json
  "sources": [
    { "keychainService": "Claude Code-credentials" },
    { "credentialsPath": "~/.claude-work/.credentials.json" },
    { "keychainService": "Claude Code-credentials-xxxxxxxx", "email": "w@example.com" }
  ]
  ```
  `profilePath` で持ち主判定に使う `.claude.json` を、`email` で持ち主そのものを指定できます。
- 何がどう判定されたかは `swift run Quotaback --once` で確認できます（トークンは表示しません）
- 編集後はメニューの「設定を再読込」。

## 挙動メモ

- **トークンのリフレッシュはしません**（refresh token のローテーションで Claude Code 側のログインを壊さないため）。期限切れになったら、そのアカウントで `claude` を一度起動すれば Claude Code が更新します。
- 初回は Keychain のアクセス許可ダイアログが出ます。「常に許可」でOK。
- 更新間隔は最短 60 秒。非公開 API なので叩きすぎないよう既定は 5 分。

## ログイン時に自動起動

`dist/Quotaback.app` を `/Applications` などに置いて起動し、パネルの「ログイン時に起動」にチェック（`SMAppService`）。
`.app` から起動したときだけ表示されます（`swift run` では出ません）。
