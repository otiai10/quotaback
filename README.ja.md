# Quotaback

[English](README.md) | 日本語

Claude Code と Codex の利用上限をどれだけ使ったかを、アカウントごとに macOS のメニューバーに出すアプリです。次にどのアカウントで走らせるかを決めるのに使います。

<p align="center">
  <img src="docs/images/panel-ja-light.png" width="340" alt="Quotaback のパネル。個人と仕事の Claude アカウント、Codex アカウントの利用上限">
</p>

## できること

- **全アカウントをひと目で。** メニューバーに各アカウントのいちばん使っている枠の % を出します（例：`🏈 46% · ⭐️ ≥31% · 🤖 0%`）。
- **`/usage` や `/status` と同じ枠。** Claude Code は Current session、Current week（全モデル・モデル別）、Usage credits。Codex は 5h limit と Weekly limit です。
- **上限に届く時刻の見込み。** 今のペースだとリセット前に 100% に届く場合、バーがオレンジになり、届く時刻を出します。
- **ログインしていないアカウントも。** 取得できるのはログイン中のアカウントだけなので、それ以外は最後に観測した値を下限（`≥`）として出します。`/login` で切り替えると数秒で気づきます。
- **分析。** 週ごとのリセット時点でどこまで使ったかと、今の周期の進み具合をグラフで見られます。

## インストール

```sh
brew install --cask otiai10/tap/quotaback
```

[Releases](https://github.com/otiai10/quotaback/releases) から `Quotaback-<version>.zip` をダウンロードし、`Quotaback.app` を `/Applications` に移しても使えます。配布物は署名と公証済みで、macOS 13 以降の Apple シリコン搭載 Mac で動きます。

ソースからビルドする場合（Xcode か Swift 5.9 以降が必要）:

```sh
git clone https://github.com/otiai10/quotaback.git
cd quotaback
make install   # ビルドして ~/Applications に入れる
```

## 使い方

使いたいアカウントで、Claude Code（または Codex）を一度起動してください。ログインしているのを見つけた時点で、そのアカウントが表示されます。

- メニューバーの項目を**クリック**するとパネルが開きます。枠ごとの消費率、リセット時刻、このペースで上限に届く時刻が並びます。ロゴの横の緑の点が、今ログインしているアカウントの印です。
- **右クリック**で「更新」「ログイン時に起動」「終了」を選べます。
- パネル下の「**分析**」で、次の2つのグラフのウィンドウが開きます。

<p align="center">
  <img src="docs/images/analytics-ja-light.png" width="640" alt="分析ウィンドウ。週ごとのリセット時点の消費率のヒートマップと、今の周期のバーンダウン">
</p>

- **リセット時の最終到達 %**：週次の枠ごとに、リセットの時点でどこまで使ったか。斜線のマスは、最後にログインしていなかったので下限です。
- **今の周期のバーンダウン**：ログイン中のアカウントの枠が、周期の中でどう増えているか。対角線は、リセットでちょうど 100% になる均等なペースです。

## 設定

設定は `~/.config/quotaback/config.json` に書きます（パネルの「設定を開く」で開けます）。保存するとすぐに反映されます。

```json
{
  "language": "ja",
  "refreshSeconds": 300,
  "accounts": [
    { "email": "personal@example.com", "emoji": "🏈", "label": "個人" },
    { "email": "work@example.com", "emoji": "💼", "label": "仕事" },
    { "email": "personal@example.com", "provider": "codex", "emoji": "🤖" }
  ]
}
```

| キー | |
|---|---|
| `language` | `en`（既定）か `ja` |
| `refreshSeconds` | 取得の間隔（秒、既定は 300） |
| `accounts[].email` | アカウント。観測したアカウントはメールアドレスだけで自動的に書き足されます |
| `accounts[].provider` | `claude`（既定）か `codex` |
| `accounts[].emoji` | メニューバーとパネルでアカウントの印にする絵文字 |
| `accounts[].label` | パネルに出す名前。無ければメールアドレスの `@` より前を使います。`emoji` が無いとき、メニューバーには `label`、それも無ければメールアドレスの頭文字を出します |

## しくみ

- **Claude Code**：Claude Code が Keychain に置いている OAuth トークン（`Claude Code-credentials`）を読み、`/usage` と同じ API を呼びます。トークンは読むだけで、更新も保存もしません。期限が切れたら、そのアカウントで `claude` を一度起動してください。
- **Codex CLI**：API は呼びません。`~/.codex/sessions` のセッションログから、最新の `rate_limits` を読みます。
- **トークンの持ち主**は、設定ではなく実行時に `~/.claude.json`（`oauthAccount.emailAddress`）や Codex の `auth.json` から判断します。
- **データ**：観測した値は手元の `~/.config/quotaback/` にだけ保存します。下限、リセット時刻の推定、100% に届く時刻は、表示のたびにそこから計算し直します。

> [!WARNING]
> Claude の利用状況の API（`api.anthropic.com/api/oauth/usage`）は公開されていないもので、予告なく変わる可能性があります。

## 開発

```sh
swift run          # ソースから起動
make test          # テスト
make screenshots   # docs/images の画像を合成データから描き直す
```

### リリース

`make release` で `dist/Quotaback-<version>.zip` を作ります。Keychain にある Developer ID Application 証明書で署名し、`quotaback-notary` プロファイル（`xcrun notarytool store-credentials` で作る）で公証して staple したうえで、HEAD にローカルで `v<version>` のタグを打ちます。`VERSION` を指定しなければ、最新のタグの patch を1つ上げます。

そのあと、タグを push して GitHub の Release に zip を添付し、[otiai10/homebrew-tap](https://github.com/otiai10/homebrew-tap/blob/main/Casks/quotaback.rb) の `version` と `sha256`（`make release` が表示します）を更新します。
