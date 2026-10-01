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
4. ~~`.app` バンドル化とログイン時自動起動~~ ✅ 実装済み（`scripts/bundle.sh`、パネルの「ログイン時に起動」トグル）。実機での SMAppService 登録は未確認
5. ~~観測と推定の仕組み~~ ✅ 実装済み（下記「観測と推定」）
6. ~~`--once` で持ち主が正しく出るか確認~~ ✅ 既定エントリ → W を確認
7. **次**: `/login` で P に切り替えて一度観測し（`--once` またはアプリの自動検知）、P の値が `latest.json` に残ること・W が `≥` 表示になることを確認

## 目的
Claude Code の `/usage` に出る「利用上限の消費率」を、**2つのサブスクリプションアカウント分**、macOS のメニューバーに常時表示する。

- P: personal@example.com（個人）
- W: work@example.com（仕事）

スコープは `/usage` の上限表示のみ（Current session / Current week (all models) / Current week (<model>) / Usage credits）。トークン量やコスト集計は対象外。

## 構成
- SwiftPM の executableTarget、macOS 13+、SwiftUI `MenuBarExtra`（`.window` スタイル）
- `NSApp.setActivationPolicy(.accessory)` で Dock 非表示
- `Core/` プロバイダに依存しない部分
  - `Observation.swift` `AccountKey`（`provider:account`）、`Cadence`（fixed / monthly / rolling / unknown）、`WindowObservation`、`ObservationBatch`
  - `ObservationLog.swift` `latest.json`（最新バッチ、毎回上書き）と `observations.jsonl`（値が変わったときだけ追記、35日で間引き）。旧 `state.json` は初回に取り込む
  - `Estimator.swift` 観測 + 今の時刻 → `WindowEstimate`（exact / atLeast / reset、known / projected / unknown、100% 到達見込み）。純粋関数
  - `UsageEngine.swift` actor。観測→記録、ログイン切り替え検知、取り違え防止、表示用 `AccountView` の生成。UI と `--once` の両方がこれを使う
  - `Provider.swift` `UsageProvider` プロトコルと `PollTarget`（owner / ownerStamp / fetch のクロージャ）
- `Claude/` Claude 固有
  - `ClaudeProvider.swift` `PollTarget` の生成、枠キー → `Cadence`（session=rolling 5h、weekly*=fixed 7d、spend=monthly）
  - `Credentials.swift` `CredentialSource`、置き場所の自動検出、持ち主の判定（`.claude.json` の `oauthAccount.emailAddress`）、トークン読み取りとハッシュ
  - `UsageClient.swift` usage API 呼び出しとレスポンス解析（`UsageWindow`）
- `Models.swift` 設定（`~/.config/quotaback/config.json`）。`AccountConfig.provider` は省略時 "claude"
- `UsageStore.swift` UI 用。5分ごとの全取得、15秒ごとの切り替え検知（検知したら3秒待って取得）と推定値の再計算、`config.json` の変更の自動反映（ディレクトリを DispatchSource で監視 + 15秒ごとの mtime 確認。壊れた JSON は無視して前の設定を維持）
- `App.swift` UI（ログイン時起動トグル含む）
- `Main.swift` エントリポイント。`--once` でアプリと同じ経路で1回観測・記録して結果と推定を表示
- `Tests/QuotabackTests` パーサー、認証情報、推定、保存、エンジン（取り違え防止・切り替え検知）のテスト
- `scripts/bundle.sh` release ビルド → `dist/Quotaback.app`（LSUIElement、ad-hoc 署名）

## 観測と推定
ログインしていないアカウントは取得しに行けないので、「最後に観測できた値」を頼りにする。**保存するのは観測した事実だけ、表示は毎回推定し直す。**
- 値：ログイン中→exact、未ログインでリセット前→atLeast（観測後も他端末で使われている可能性があるので下限。メニューバーは `≥`）、リセット時刻を過ぎた→reset（0 扱い）
- 次のリセット：時刻が未来なら known。過ぎたら fixed は周期を足して projected、monthly は月を足して projected、rolling（使い始めから数える）は unknown
- 100% 到達見込み：同じリセット周期（resets_at は秒未満が揺れるので1分以内なら同じとみなす）の履歴の最初と最後を直線で結ぶ。幅10分以上・増加・リセット前に達するときだけ
- 取り違え防止：`/login` では `.claude.json`（持ち主）と Keychain（トークン）が別々に更新されるので、(1) 取得後に持ち主を読み直して変わっていたら捨てる、(2) トークンのハッシュ → アカウントの対応をメモリに持ち、同じトークンが別の持ち主を名乗ったら一旦見送る。30秒以上たっても同じ組み合わせならそちらを正とし、前の持ち主に記録した最新バッチがそのトークン由来なら取り消す（`/login` の書き込み順に依存しないため）。見送ったら UsageStore が35秒後に最大2回取り直す。ハッシュもトークンも保存しない
- 切り替え検知：`.claude.json` は Claude Code がアトミックに書き換えるので DispatchSource ではなく15秒ごとに mtime を見て、変わったときだけ持ち主を読み直す
- 複数プロバイダ：保存キーは `provider:account`、枠の周期は観測ごとに `Cadence` として持つ。プロバイダを足すときは `UsageProvider` を実装して `Providers.all` に入れる

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
- そのため「置き場所の持ち主は実行時に `.claude.json` の `oauthAccount.emailAddress` で判定」「アカウントごとの最後の観測を保存して表示」という設計にした。設定のラベルは信用しない
- 最初の `--once` で `[P]` と表示していた値は、ラベルを信じていたため。実際の持ち主は仕事用（W）だった（下記で確認）
- **確認済み（2026-10-01 15:50）**: `--once` で `Keychain 'Claude Code-credentials' → work@example.com`。`~/.claude.json` の `oauthAccount.emailAddress` で持ち主が取れること、既定エントリが W のものであることを確認。`latest.json` への記録も確認

未確認：
- P（個人）はまだ一度も観測していない（`/login` で P に切り替えて観測する必要がある）
- `CLAUDE_CONFIG_DIR` 別の Keychain エントリ名（`Claude Code-credentials-<hash>` と思われるが未確認。必要なら `sources` で明示）
- `spend.limit > 0` の実レスポンス（テストは想定形式）
- 週次枠が本当に 7 日周期でずれずに続くか（projected の前提）。セッション枠を rolling とみなしている点も挙動からの推測
- `/login` で `.claude.json` と Keychain のどちらが先に書かれるか（どちらでも動くようにはしてある）

## 既知の小さな問題
- ログイン中のアカウントで、リセット時刻を過ぎてから次の取得までの間は「ログイン中」なのに「リセット済み」と出る
- 置き場所の自動検出は起動時と「設定を再読込」のときだけ
- `--once` の記録は、起動中のアプリが自分の保存で上書きすることがある
- 実レスポンスは `~/.config/quotaback/last-response-<email>.json` に保存される。形式が変わったらこれを見て `UsageClient.parse` を直す

## 設計上の決定（変えるならユーザーに確認）
- **トークンのリフレッシュをしない。** refresh token がローテーションされると Claude Code 側のログインが壊れる恐れがあるため、読み取り専用。期限切れはエラー表示し、ユーザーがそのアカウントで `claude` を起動して更新する
- Keychain は `SecItemCopyMatching` ではなく `/usr/bin/security` 経由で読む（他アプリのアイテムの ACL を扱いやすいため）
- 取得失敗時・未ログイン時は最後の観測を残す。未ログインのアカウントはメニューバーで `≥`（下限）
- メニューバーには各アカウントの上限枠（`limits` の group が session / weekly のもの）の最大値のみを出す。Usage credits は詳細パネルにだけ出す

## 今後のアイデア（未着手）
- WidgetKit のデスクトップウィジェット（サンドボックスのため App Group 経由のデータ受け渡しが必要）
