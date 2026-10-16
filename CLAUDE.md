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
4. ~~`.app` バンドル化とログイン時自動起動~~ ✅ 実装済み（`scripts/bundle.sh`、メニューバーの項目の右クリックメニューの「ログイン時に起動」）。実機での SMAppService 登録は未確認
5. ~~観測と推定の仕組み~~ ✅ 実装済み（下記「観測と推定」）
6. ~~`--once` で持ち主が正しく出るか確認~~ ✅ 既定エントリ → W を確認
7. ~~`/login` で P に切り替えて観測~~ ✅ アプリが切り替えを自動検知して P を記録、W は `≥` の下限表示になることを確認（2026-10-01 16:40）

## 目的
Claude Code の `/usage` に出る「利用上限の消費率」を、**2つのサブスクリプションアカウント分**、macOS のメニューバーに常時表示する。OpenAI Codex CLI の利用上限（`/status` の 5h limit / Weekly limit）も同じ仕組みで出す。

- P: 個人アカウント
- W: 仕事用アカウント

（実際のメールアドレスは `~/.config/quotaback/config.json` にだけ書く。リポジトリは public なので、コード・ドキュメント・テストには入れない）

スコープは `/usage` の上限表示（Current session / Current week (all models) / Current week (<model>) / Usage credits）と Codex の上限表示のみ。トークン量やコスト集計は対象外。

## 構成
- SwiftPM の executableTarget、macOS 13+。メニューバーは `NSStatusItem` + `NSPopover`（中身は SwiftUI、`NSHostingController.sizingOptions = .preferredContentSize` で大きさを追従）
  - 当初は SwiftUI `MenuBarExtra(.window)` だったが、畳んで中身が縮んでもウィンドウが縮まず、上下に空白が残った（外から setFrame しても直らず）ので置き換えた
- `NSApp.setActivationPolicy(.accessory)` で Dock 非表示
- `Core/` プロバイダに依存しない部分
  - `Observation.swift` `AccountKey`（`provider:account`）、`Cadence`（fixed / monthly / rolling / unknown）、`WindowObservation`、`ObservationBatch`、`CycleSummary`（閉じた周期の要約）
  - `ObservationLog.swift` `latest.json`（最新バッチ、毎回上書き）と `observations.jsonl`（値が変わったときだけ追記、35日で間引き）と `cycles.jsonl`（閉じた周期ごとに1行、間引かない。`summarizeClosedCycles` / `rebuildCycles`）。旧 `state.json` は初回に取り込む
  - `Estimator.swift` 観測 + 今の時刻 → `WindowEstimate`（exact / atLeast / reset、known / projected / unknown、100% 到達見込み）。純粋関数
  - `UsageEngine.swift` actor。観測→記録、ログイン切り替え検知、取り違え防止、表示用 `AccountView` の生成。UI と `--once` の両方がこれを使う
  - `Provider.swift` `UsageProvider` プロトコルと `PollTarget`（owner / ownerStamp / fetch のクロージャ）
- `Claude/` Claude 固有
  - `ClaudeProvider.swift` `PollTarget` の生成（取得 → 生レスポンスを `last-response-<email>.json` に保存 → 解析）、`kind` → `Cadence`（`cadence(forKind:)`。session=rolling 5h、weekly*=fixed 7d、spend=monthly）。`cadence(forWindowKey:)` は保存済みのキーから引く版で、旧 `state.json` の取り込みでも使う
  - `Credentials.swift` `CredentialSource`、置き場所の自動検出、持ち主の判定（`.claude.json` の `oauthAccount.emailAddress`）、トークン読み取りとハッシュ
  - `UsageClient.swift` usage API 呼び出し（`fetch` は `Data` を返すだけでファイルは書かない）とレスポンス解析（`parse` が `[WindowObservation]` を直接返す）
- `Codex/` Codex 固有（API は呼ばない）
  - `CodexProvider.swift` `CodexHome`（`$CODEX_HOME` / `~/.codex`）。持ち主は `auth.json` の `id_token` の `email`。`last_refresh` より前の記録は使わない（`UsageError.noObservation`）
  - `CodexRolloutReader.swift` `sessions/YYYY/MM/DD/rollout-*.jsonl` を新しい順に末尾 1MB だけ読み、最新の `token_count` の `rate_limits` を取る。枠は `window_minutes` で区別（300=5h limit/rolling、10080=Weekly limit/fixed 7d）。`resets_at`（epoch）と旧形式の `resets_in_seconds` の両方に対応
- `Core/UsageError.swift` 取得失敗の種類。`noObservation` は「持ち主は分かるが新しい観測なし」で、エラーを出さずにログイン中のまま前回値を下限で出す
- `Models.swift` 設定（`~/.config/quotaback/config.json`）。`AccountConfig.provider` は省略時 "claude"
  - アカウントは `email`（識別子）と任意の `emoji`・`label`。メニューバーは emoji → label → メールの頭文字。パネルの見出しは emoji ＋（label、無ければメールの @ より前。別のメールと重なるときだけ全体）。旧キー `name` も `email` として読む（書くときは `email`）
  - 「観測できたアカウントは必ず config.json にある」状態を保つ。取得のたびに（`--once` も）、設定に無いアカウントを `email` だけで末尾に書き足す（`AppConfig.registerAccounts`）。書く直前にファイルを読み直して足すだけで、読めない（壊れている）ときは触らない。持ち主不明（"?" 始まり）は足さない
- `Core/L10n.swift` 文言（en / ja）。画面・エラー・`--once` の文字列はすべてここに置く。言語は config.json の `language`、省略時は英語。枠の名前（"Current session" など）は Claude Code / Codex の表示に合わせて英語のまま。エラーなどは取得時に文字列にするので、`language` を変えたら取り直す
- `Core/ActivityLog.swift` `activity.log` に切り替え検知と取得結果を追記（トークンは書かない）。テストでは `ActivityLog.url` を一時ディレクトリに向けること
- `UsageStore.swift` UI 用。5分ごとの全取得（置き場所もこのとき探し直す）、2秒ごとの切り替え検知（mtime が変わったときだけ `.claude.json` を読む。検知したら1秒待って取得、見送られたら5秒後と35秒後に取り直し）、パネルを開いたときの確認（直近の取得から15秒以上なら取得）、15秒ごとの推定値の再計算、`config.json` の変更の自動反映（ディレクトリを DispatchSource で監視 + 15秒ごとの mtime 確認。壊れた JSON は無視して前の設定を維持）
- `App.swift` `AppDelegate`（ステータス項目とポップオーバー、右クリックメニュー「更新 / ログイン時に起動 / 終了」）と UI。ポップオーバーは `.transient` だが、macOS 14+ では `NSApp.activate` が効かないことがあり外側クリックで閉じなかったので、表示中だけ `NSEvent.addGlobalMonitorForEvents`（マウスのみ、権限不要）で他アプリへのクリックを拾って閉じる。パネルのフッターは取得時刻と「Analytics（分析）」「設定を開く」だけ。`Main.swift` から `NSApplication.run()` で起動
- `ProviderIcon.swift` パネル見出しのプロバイダのロゴ（Simple Icons の SVG パスを埋め込み、`NSImage` でテンプレート画像にする）。読めないときは名前の文字で出す
- パネルの見た目は `PanelRenderTests` が合成データで PNG に出す（`QUOTABACK_RENDER_DIR`）。README（英語 `README.md`、日本語 `README.ja.md`）の画像 `docs/images/` は `make screenshots` でこれと `AnalyticsRenderTests` から作り直す。バーは `ProgressView` だと画像化できないので SwiftUI の `UsageBar`
- `AnalyticsView.swift` Analytics ウィンドウ（`AnalyticsWindowController` が `NSWindow` を1つだけ持ち、開くときに `NSApp.activate`。`.accessory` でメインメニューが無いので ⌘W はウィンドウ側で処理）。縦に2枚: (1) 週次枠（cadence が fixed）のリセット時の最終到達 % のヒートマップ（行＝アカウント×枠、列＝暦週、直近8週。SwiftUI の `Grid` で描く。濃さ＝%、100% は枠線、下限は斜線、データなしは「–」）、(2) ログイン中の上限枠の今の周期のバーンダウン（Swift Charts。横軸は周期の経過率、対角線が理想ペース、点線が 100% 到達見込み。点線が 100% に届く位置の真上に、系列色で「M/d (曜)」と「HH:mm」の2行を出し、ホバーでリセット時刻と何日前かを `.help` で出す。ラベルは `chartOverlay` で同じ高さに置き、重なるかはみ出すときだけ `AnalyticsModel.spread` が横にずらす（ずらす量が最小になるよう、重なる組をそれぞれの希望位置の平均に寄せる。入りきらなければ均等に詰める））。以前あった「アカウントの偏り」（P と W の weekly_all を週ごとに並べた棒）はヒートマップと重複するので削除した。見直すなら「片方が上限に届いた週に、もう片方に余りがあったか（切り替え漏れ）」を見せる形にする。中身は `AnalyticsCharts(input:)` で、アプリ無しで描ける（`AnalyticsRenderTests` が合成データで PNG を出す。`QUOTABACK_RENDER_DIR` で出力先を指定）
- `Core/AnalyticsModel.swift` チャート用のデータ整形（純粋関数）。`AnalyticsInput`（`UsageEngine.analytics` が要約・タイトル・ログイン中の枠の点列をまとめて返す。`UsageStore` はウィンドウが開いている間だけ更新）。下限扱いは `resetsAt - lastObservedAt` が15分超。要約の無い周期（間、および最後の要約からリセット済みの分）は値なしの棒で「データなし」（0% にしない）
- `Main.swift` エントリポイント。`--once` でアプリと同じ経路で1回観測・記録して結果と推定を表示。`--rebuild-cycles` で `cycles.jsonl` を生ログから作り直す
- `Tests/QuotabackTests` パーサー、認証情報、推定、保存、エンジン（取り違え防止・切り替え検知）のテスト
- `scripts/bundle.sh` release ビルド → `dist/Quotaback.app`（LSUIElement）。署名は `SIGN_IDENTITY`、無ければ Keychain の「Developer ID Application」（Hardened Runtime + タイムスタンプ。公証の前提）、それも無ければ ad-hoc。`SIGN_IDENTITY=-` で ad-hoc を強制
- `scripts/release.sh`（`make release`）配布用の `dist/Quotaback-<version>.zip`。Developer ID で署名 → 公証（Keychain のプロファイル `quotaback-notary`、または CI 用に `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER`）→ staple → zip、最後に cask 用の sha256 を出す。バージョンは `VERSION`、無ければ HEAD の `v1.2.3` タグ、それも無ければ最新の `v*.*.*` タグの patch を1つ上げる（タグが無ければ 0.1.0）。成功したら HEAD に `v<version>` の注釈付きタグをローカルで打つ（push はしない）。同じタグが別のコミットにあれば止まる。未コミットの変更があると止まる
- `scripts/publish.sh`（`make publish`）`make release` の成果物を公開する。zip の中身が そのバージョンかつ公証済みかを確かめ、タグのコミットが origin/main にあることを確かめてから、タグの push → `gh release create` → `otiai10/homebrew-tap` の `Casks/quotaback.rb` の version / sha256 を更新して push。手元の git / gh の認証を使う。済んだ手順は飛ばすので再実行できる。バージョンは `VERSION`、無ければ HEAD のタグ
- `Makefile` `make install` で bundle.sh → `~/Applications/Quotaback.app` に置き換え（`PREFIX` で変更可）。起動中なら終了させて、置き換え後に起動し直す。`make uninstall` もある

## 観測と推定
ログインしていないアカウントは取得しに行けないので、「最後に観測できた値」を頼りにする。**保存するのは観測した事実だけ、表示は毎回推定し直す。**
- 値：ログイン中かつ観測から10分以内→exact、それ以外でリセット前→atLeast（観測後も他端末で使われている可能性があるので下限。メニューバーは `≥`）。観測時刻はプロバイダが `FetchedUsage.asOf` で渡せる（Codex はログの記録時刻）、リセット時刻を過ぎた→reset（0 扱い）
- 次のリセット：時刻が未来なら known。過ぎたら fixed は周期を足して projected、monthly は月を足して projected、rolling（使い始めから数える）は unknown
- 100% 到達見込み：同じリセット周期（resets_at は秒未満が揺れるので1分以内なら同じとみなす）の履歴の最初と最後を直線で結ぶ。幅10分以上・増加・リセット前に達するときだけ
- 取り違え防止：`/login` では `.claude.json`（持ち主）と Keychain（トークン）が別々に更新されるので、(1) 取得後に持ち主を読み直して変わっていたら捨てる、(2) トークンのハッシュ → アカウントの対応をメモリに持ち、同じトークンが別の持ち主を名乗ったら一旦見送る。30秒以上たっても同じ組み合わせならそちらを正とし、前の持ち主にそのトークンで記録したバッチを、記録し始めた時刻からまとめて取り消す（`/login` の書き込み順に依存しないため。`ObservationLog.retract(of:from:through:)`）、(3) まだ誰にも割り当てていないトークン（更新されてハッシュが変わったものなど）は、週次枠（fixed）の次のリセット時刻が自分の見込み（過ぎていれば周期を足す）と分単位で違い、同じプロバイダの別アカウントの見込みと同じなら見送る。見送ってもハッシュは割り当てないので、食い違いが続く間は毎回見送られる。自分の観測が無い枠は判定に使わない。見送ったら UsageStore が5秒後と35秒後に取り直す。ハッシュもトークンも保存しない
- 切り替え検知：`.claude.json` は Claude Code がアトミックに書き換えるので DispatchSource ではなく2秒ごとに mtime を見て、変わったときだけ持ち主を読み直す（約480KB）
- 2026-10-01 の実例：`/login` の途中（16:38:56）に一度検知して W を取得、ログイン完了後は当時の15秒間隔＋3秒待ちが間に合わず、ユーザーが「更新」を押した（16:40:19）。これを受けて2秒間隔・1秒待ち・パネルを開いたときの確認・`activity.log` を追加
- 2026-10-11 の実例（#13）：P のトークンが期限切れ→更新（ハッシュが変わる）の後、`/login` で `.claude.json` だけが W を指し、Keychain は P のトークンのまま約36時間続いた。(2) は既知のハッシュにしか効かず、P の観測が W として記録され続けた。これを受けて (3) と、まとめて取り消す (2) の拡張を追加
- 周期の要約（`cycles.jsonl`）：Analytics 用に、周期1つにつき1行（`account` / `key` / `title` / `cadence` / `resetsAt` / `firstObservedAt` / `lastObservedAt` / `finalPercent` / `peakPercent` / `observations`）を残し、間引かない。同じアカウント・枠の観測を resetsAt 順に並べ、隣どうしが `sameCycle`（1分以内）なら同じ周期とする。後ろに別の周期の観測があるか、`now` が resetsAt + 60秒を過ぎたら閉じたとみなし、まだ要約に無ければ追記する。これを `load`（35日の間引きの前の全行で）・`record` の後（上書き前の latest も含めて）・`UsageEngine.refresh` の後に呼ぶので、新しい周期の観測・時間経過・初回の backfill が同じコードになる。resetsAt が無い枠（未使用の session）は要約しない。一度も観測できなかった周期は行が無い（0% ではない）。下限かどうかは保存せず、読む側が `resetsAt - lastObservedAt` で判断する。要約済みの周期に後から観測が来ても書き換えない（取り違えなどで生ログを直したら `--rebuild-cycles`。生ログで作り直せない古い周期の行は残す）。`observations` は保存された観測時刻の数で、取得回数ではない
- 複数プロバイダ：保存キーは `provider:account`、枠の周期は観測ごとに `Cadence` として持つ。プロバイダを足すときは `UsageProvider` を実装して `Providers.all` に入れる

## Codex の確認状況（2026-10-02, codex-cli 0.147.0）
- `~/.codex/auth.json` のキー: `OPENAI_API_KEY`, `auth_mode`, `last_refresh`, `tokens{access_token, account_id, id_token, refresh_token}`
- セッションログ `token_count` イベントの `rate_limits`: `{limit_id:"codex", primary:{used_percent, window_minutes:10080, resets_at(epoch)}, secondary:null, credits:{has_credits, unlimited, balance}, plan_type:"pro", ...}`。このアカウント（pro）では週次枠だけで、5h 枠は出ていない
- `--once` で `Codex ~/.codex → <メール>`、Weekly limit 3%（10/1 18:26 の記録）を確認
- ログの履歴（約300ファイル）: 2025/10/16〜10/30 は primary 299 / secondary 10079、〜2026/07/04 は primary 300 / secondary 10080、2026/07/14 以降は primary 10080 / secondary null（週次のみ）。1分ずれた旧値は 300 / 10080 に寄せている（`CodexRolloutReader.normalize`）
- 未確認：`credits.balance` の単位（表示していない）、`limit_id` が `codex` 以外になるケース

## API・認証の確認状況（2026-10-01）
`--once` で既定の Keychain エントリから取得が成功し、以下は**確認済み**：
- エンドポイント `GET https://api.anthropic.com/api/oauth/usage`、ヘッダー `anthropic-beta: oauth-2025-04-20`
- Keychain service 名 `Claude Code-credentials`、中身 `{"claudeAiOauth": {"accessToken", "expiresAt"(ms), ...}}`
- レスポンスの `limits` 配列が `/usage` の表示項目そのもの。`{kind, group, percent, severity, resets_at, scope, is_active}`
  - `kind`: `session` / `weekly_all` / `weekly_scoped`（`scope.model.display_name` にモデル名、例 "Fable"）
  - `group`: `session` / `weekly` → メニューバーのピーク値対象
  - トップレベルの `five_hour` / `seven_day` も残っているが、モデル別の週次枠（`seven_day_opus` 等）は `null` で、Fable 枠は `limits` にしか出ない
- Usage credits は `spend`（`used` / `limit` が `{amount_minor, currency, exponent}`）。`extra_usage.utilization` は `null`
- パーサーは `limits` だけを読み、無い・`null`・オブジェクトの配列でないレスポンスは `UsageError.parse` で失敗させる（パネルにエラー、前回の観測は残す）。`spend.limit` が 0 なら credits 行は出さない
- `resets_at` は取得のたびに秒未満〜1秒前後する（`01:59:59.59` / `02:00:00.19`）。パース時に最も近い分に丸めている
- 最初の頃に「P の値」として見ていたレスポンス（`spend.limit` = 0）は実は W のもの。P は `spend.limit` = $200.00（20000 minor）で、パネルに「$0.00 / $200.00」と出ることを確認済み（2026-10-01）。当初メモの「$57.97 / $200.00」は P の以前の状態と思われる。W は Usage credits なし（limit 0 → 行を出さない）
- P のセッション枠は未使用だと `resets_at: null`（使い始めてから決まる = rolling の裏付け）

### アカウントと置き場所
- このマシンの Keychain にある Claude Code のエントリは `Claude Code-credentials` **1つだけ**（`Claude Safe Storage` はデスクトップアプリの暗号化キーで無関係）。
  → 2アカウントは `/login` で1つのログインを切り替えて使っている可能性が高い。その場合、同時に取れるのはログイン中の1アカウントのみ
- そのため「置き場所の持ち主は実行時に `.claude.json` の `oauthAccount.emailAddress` で判定」「アカウントごとの最後の観測を保存して表示」という設計にした。設定のラベルは信用しない
- 最初の `--once` で `[P]` と表示していた値は、ラベルを信じていたため。実際の持ち主は仕事用（W）だった（下記で確認）
- **確認済み（2026-10-01 15:50）**: `--once` で `Keychain 'Claude Code-credentials' → <W のメール>`。`~/.claude.json` の `oauthAccount.emailAddress` で持ち主が取れること、既定エントリが W のものであることを確認。`latest.json` への記録も確認

未確認：
- `CLAUDE_CONFIG_DIR` 別の Keychain エントリ名（`Claude Code-credentials-<hash>` と思われるが未確認。必要なら `sources` で明示）
- 週次枠が本当に 7 日周期でずれずに続くか（projected の前提）。セッション枠を rolling とみなしている点も挙動からの推測
- `/login` で `.claude.json` と Keychain のどちらが先に書かれるか（どちらでも動くようにはしてある）。2026-10-11 には `.claude.json` だけが切り替わった状態が約36時間続いた（原因は不明）

## 既知の小さな問題
- ログイン中のアカウントで、リセット時刻を過ぎてから次の取得までの間は「ログイン中」なのに「リセット済み」と出る
- `--once` の記録は、起動中のアプリが自分の保存で上書きすることがある
- 実レスポンスは `~/.config/quotaback/last-response-<email>.json` に保存される。形式が変わったらこれを見て `UsageClient.parse` を直す

## 設計上の決定（変えるならユーザーに確認）
- **トークンのリフレッシュをしない。** refresh token がローテーションされると Claude Code 側のログインが壊れる恐れがあるため、読み取り専用。期限切れはエラー表示し、ユーザーがそのアカウントで `claude` を起動して更新する
- Keychain は `SecItemCopyMatching` ではなく `/usr/bin/security` 経由で読む（他アプリのアイテムの ACL を扱いやすいため）
- 取得失敗時・未ログイン時は最後の観測を残す。未ログインのアカウントはメニューバーで `≥`（下限）
- メニューバーには各アカウントの上限枠（`limits` の group が session / weekly のもの）の最大値のみを出す。Usage credits は詳細パネルにだけ出す

## 今後のアイデア（未着手）
- WidgetKit のデスクトップウィジェット（サンドボックスのため App Group 経由のデータ受け渡しが必要）
