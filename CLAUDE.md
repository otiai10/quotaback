# CLAUDE.md — Quotaback 引き継ぎメモ

## 名前
**Quotaback** = quota + quarterback。2アカウントの残量を見て「どっちで走らせるか」を判断する司令塔、というコンセプト。
（候補だったもの: Quota Relay, Cost Relay, Swell, Hopper など）
将来的には表示だけでなく「上限が近いアカウントから別アカウントへの切り替えを促す」方向に広げる可能性がある。
アイコン・ロゴはアメフト（ボール／QB）モチーフで「quota back（返金）」と誤読されないようにしたい。

## 最初のタスク（この順で）
1. ~~`swift build` を通す~~ ✅ 済（Apple Swift 6.4 / macOS 27 で無修正でビルド成功。zip の `Quotaback/` をリポジトリ直下に展開済み）
2. ~~Keychain からトークンを読めるか確認~~ ✅ 既定エントリで成功。仕事用の別エントリは存在しない → 持ち主を実行時判定する設計に変更（下記「アカウントと置き場所」）
3. ~~実レスポンスを見てパーサーと表示ラベルを合わせる~~ ✅ 済
5. **次**: `swift run Quotaback --once` で各置き場所の持ち主（`→ <email>`）が正しく出るか確認。もう一方のアカウントは `/login` で切り替えて一度取得すれば `state.json` に残る
4. ~~`.app` バンドル化とログイン時自動起動~~ ✅ 実装済み（`scripts/bundle.sh`、パネルの「ログイン時に起動」トグル）。実機での SMAppService 登録は未確認

## 目的
Claude Code の `/usage` に出る「利用上限の消費率」を、**2つのサブスクリプションアカウント分**、macOS のメニューバーに常時表示する。

- P: personal@example.com（個人）
- W: work@example.com（仕事）

スコープは `/usage` の上限表示のみ（Current session / Current week (all models) / Current week (<model>) / Usage credits）。トークン量やコスト集計は対象外。

## 構成
- SwiftPM の executableTarget、macOS 13+、SwiftUI `MenuBarExtra`（`.window` スタイル）
- `NSApp.setActivationPolicy(.accessory)` で Dock 非表示
- `Models.swift` 設定（`~/.config/quotaback/config.json`）、認証情報の置き場所 `CredentialSource`、表示用モデル、前回値 `Snapshot`（`state.json`）
- `Credentials.swift` 置き場所の自動検出、持ち主の判定（`.claude.json` の `oauthAccount.emailAddress`）、トークン読み取り
- `UsageClient.swift` usage API 呼び出しとレスポンス解析
- `UsageStore.swift` 定期更新（既定 300 秒、最短 60 秒）、置き場所→アカウントの割り当て、メニューバー文字列
- `App.swift` UI（ログイン時起動トグル含む）
- `Main.swift` エントリポイント。`--once` で UI なしの1回取得（動作確認用）
- `Tests/QuotabackTests` パーサー・表示ラベルのテスト（`limits` 形式は実レスポンス準拠、credits あり・旧形式は想定）
- `scripts/bundle.sh` release ビルド → `dist/Quotaback.app`（LSUIElement、ad-hoc 署名）

## API・認証の確認状況（2026-10-01）
`--once` で既定の Keychain エントリから取得が成功し、以下は**確認済み**：
- エンドポイント `GET https://api.anthropic.com/api/oauth/usage`、ヘッダー `anthropic-beta: oauth-2025-04-20`
- Keychain service 名 `Claude Code-credentials`、中身 `{"claudeAiOauth": {"accessToken", "expiresAt"(ms), ...}}`
- レスポンスの `limits` 配列が `/usage` の表示項目そのもの。`{kind, group, percent, severity, resets_at, scope, is_active}`
  - `kind`: `session` / `weekly_all` / `weekly_scoped`（`scope.model.display_name` にモデル名、例 "Fable"）
  - `group`: `session` / `weekly` → メニューバーのピーク値対象
  - トップレベルの `five_hour` / `seven_day` も残っているが、モデル別の週次枠（`seven_day_opus` 等）は `null` で、Fable 枠は `limits` にしか出ない
- Usage credits は `spend`（`used` / `limit` が `{amount_minor, currency, exponent}`）。`extra_usage.utilization` は `null`
- パーサーは `limits` 優先、無ければ旧方式（`utilization` を持つトップレベルのオブジェクトを拾う）にフォールバック。`spend.limit` が 0 なら credits 行は出さない
- ユーザーの `/usage` 表示（Current session / Current week (all models) / Current week (Fable) / Usage credits $0.00 / $0.00）と一致。以前のメモにあった「$57.97 / $200.00」は古い情報。`/usage` は上限 $0 でも credits 行を 100% で出すが Quotaback では出さない

### アカウントと置き場所
- このマシンの Keychain にある Claude Code のエントリは `Claude Code-credentials` **1つだけ**（`Claude Safe Storage` はデスクトップアプリの暗号化キーで無関係）。
  → 2アカウントは `/login` で1つのログインを切り替えて使っている可能性が高い。その場合、同時に取れるのはログイン中の1アカウントのみ
- そのため「置き場所の持ち主は実行時に `.claude.json` の `oauthAccount.emailAddress` で判定」「アカウントごとの前回値を `state.json` に保存して表示」という設計にした。設定のラベルは信用しない
- 最初の `--once` で `[P]` と表示していた値は、ラベルを信じていたため。実際の持ち主はおそらく仕事用（このセッションのログインが仕事用のため）

未確認：
- `~/.claude.json` の `oauthAccount.emailAddress` で持ち主が取れるか（記憶ベース。`--once` の `→ <email>` 表示で確認）
- 既定の Keychain エントリが P と W のどちらのものか（同上）
- `CLAUDE_CONFIG_DIR` 別の Keychain エントリ名（`Claude Code-credentials-<hash>` と思われるが未確認。必要なら `sources` で明示）
- `spend.limit > 0` の実レスポンス（テストは想定形式）
- 実レスポンスは `~/.config/quotaback/last-response-<email>.json` に保存される。形式が変わったらこれを見て `UsageClient.parse` を直す

## 設計上の決定（変えるならユーザーに確認）
- **トークンのリフレッシュをしない。** refresh token がローテーションされると Claude Code 側のログインが壊れる恐れがあるため、読み取り専用。期限切れはエラー表示し、ユーザーがそのアカウントで `claude` を起動して更新する
- Keychain は `SecItemCopyMatching` ではなく `/usr/bin/security` 経由で読む（他アプリのアイテムの ACL を扱いやすいため）
- 取得失敗時・未ログイン時は前回値を残す（`state.json`）。未ログインのアカウントはメニューバーで括弧付き
- メニューバーには各アカウントの上限枠（`limits` の group が session / weekly のもの）の最大値のみを出す。Usage credits は詳細パネルにだけ出す

## 既知の小さな問題
- 取得中に「設定を再読込」すると `refreshAll()` が早期 return するため、新しい設定での取得は次のタイマー（最大 `refreshSeconds`）まで待つ

## 今後のアイデア（未着手）
- WidgetKit のデスクトップウィジェット（サンドボックスのため App Group 経由のデータ受け渡しが必要）
