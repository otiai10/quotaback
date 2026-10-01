# Quotaback

Claude Code の `/usage`（Current session / Current week の消費率）と OpenAI Codex CLI の `/status`（5h limit / Weekly limit）を、複数アカウント分メニューバーに表示する常駐アプリ。

```
P 13% · W ≥43%    ← 各アカウントの「一番埋まっている枠」の %
```

- `43%` … いまログイン中で、直近（10分以内）に観測できた値
- `≥43%` … **最後に観測できた値**（ログインしていないアカウント、または観測が10分より古いとき）。観測後も他の端末などで使われているかもしれないので「少なくともこれだけ」という下限
- `!` … 取得エラー、`–` … まだ一度も観測していない

左クリックでパネル、右クリック（または control＋クリック）で「更新 / ログイン時に起動 / 終了」のメニュー。
パネルには各アカウントの枠ごとの詳細、リセット時刻（過ぎていれば周期から推定）、最終観測時刻、今のペースで上限に達しそうな時刻が出ます。

> ⚠️ `api.anthropic.com/api/oauth/usage` は Claude Code が内部で使っている **非公開 API** です。
> 予告なく変わる可能性があります。生レスポンスは `~/.config/quotaback/last-response-<email>.json` に保存されるので、壊れたらそれを見て `UsageClient.parse` を直してください。

## ビルド・起動

```sh
swift run                    # 開発中（メニューバーに常駐）
swift run Quotaback --once   # UI なしで1回観測・記録して結果を表示（動作確認用）
swift test
./scripts/bundle.sh          # dist/Quotaback.app を作る（常用）
open dist/Quotaback.app
```

Xcode で開く場合は `open Package.swift`。

## 設定

初回起動で `~/.config/quotaback/config.json` が作られます。表示したいアカウントをメールアドレスで並べるだけ（空のままでも、観測できたアカウントはメールの頭文字をラベルにして出ます）：

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
- **`/login` で1つのログインを切り替えて使っている場合**：ログイン中のアカウントだけが更新され、もう一方は最後に観測した値が `≥` 付きで出ます（`P ≥43% · W 17%`）。切り替えは2秒ごとに `.claude.json` の更新時刻を見て検知し、1秒待って取得します。パネルを開いたときも確認し、直近の取得から15秒以上経っていれば取り直します
- 切り替えの途中（`.claude.json` と Keychain の片方だけが新しいアカウント）に取得した値は、取り違えを防ぐため記録しません。30秒ほど後に取り直し、同じ組み合わせが続けばそれを正とします（前のアカウントに取り違えて記録していた分は取り消し）
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
- 何がどう判定されたかは `swift run Quotaback --once` で確認できます（トークンは表示しません）。アプリ起動中は、`--once` の記録がアプリ側の保存で上書きされることがあるので、メニューバーの項目の右クリックメニューの「更新」を使うかアプリを終了してから
- `config.json` は保存すると自動で反映されます（ラベルや表示名だけの変更なら取得し直さない）。JSON が壊れているときは前の設定のまま動き、パネルにエラーが出ます
- `label` には絵文字も使えます（`"label": "💼"`）

### Codex

Codex は API を呼ばず、Codex CLI 自身がセッションログ（`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`）に書く `rate_limits` の最新の記録を読みます。トークンは使いません。

- 置き場所は `$CODEX_HOME`（設定されていれば）と `~/.codex`。`auth.json` があるものだけ対象
- 持ち主は `auth.json` の `id_token`（JWT）の `email` で判定（署名は検証しない）
- 値は**ログに記録された時刻の観測**として扱います。Codex を使っていない間は値が古くなるので `≥`（下限）で出ます
- ログには誰のセッションかが書かれていないので、`auth.json` の `last_refresh`（ログイン・トークン更新のたびに書かれる）より前の記録は使いません。ログインし直した直後は、Codex を一度使うまで前回の値が `≥` で出ます
- 設定に書くときは `"provider": "codex"`：
  ```json
  { "label": "🤖", "name": "you@example.com", "provider": "codex" }
  ```
  書かなくても、観測できたアカウントはメールの頭文字をラベルにして出ます

## 観測と推定

ログインしていないアカウントの使用量は取りに行けないので、「最後に観測できた値」から推定します。保存するのは観測した事実だけで、表示はその都度計算し直します。

| 状態 | 表示 |
|---|---|
| ログイン中・観測が10分以内・リセット前 | `43%`（そのまま） |
| 未ログイン、または観測が10分より古い・リセット前 | `≥43%`（下限） |
| リセット時刻を過ぎた | 「リセット済み」（0 から数え直し） |

次のリセット時刻：
- 週次枠：過ぎたら 7 日周期で推定（「推定」と表示）
- Usage credits：月単位で推定
- セッション枠（Claude の Current session、Codex の 5h limit）：使い始めた時点から数えるため、リセット後は分からない

消費ペース：同じリセット周期内の観測が 10 分以上の幅であれば、最初と最後を結んだ直線で 100% 到達時刻を出します（リセットより前に達する場合だけ）。

保存先（`~/.config/quotaback/`）：
- `latest.json` … アカウントごとの最新の観測（毎回上書き）
- `observations.jsonl` … 値が変わったときだけ追記する履歴（35日で間引き）
- `last-response-<email>.json` … 生レスポンス（デバッグ用）
- `activity.log` … 切り替えの検知と取得の結果（`switch … → …` / `refresh(理由) … → recorded|skipped|failed`）。自動で反映されなかったときはここを見る。512KB を超えたら古い半分を捨てる

トークンやそのハッシュは保存しません。

## 挙動メモ

- **トークンのリフレッシュはしません**（refresh token のローテーションで Claude Code 側のログインを壊さないため）。期限切れになったら、そのアカウントで `claude` を一度起動すれば Claude Code が更新します。
- 初回は Keychain のアクセス許可ダイアログが出ます。「常に許可」でOK。
- 更新間隔は最短 60 秒。非公開 API なので叩きすぎないよう既定は 5 分。

## ログイン時に自動起動

`dist/Quotaback.app` を `/Applications` などに置いて起動し、メニューバーの項目を右クリックして「ログイン時に起動」にチェック（`SMAppService`）。
この項目は `.app` から起動したときだけ出ます（`swift run` では出ません）。
