# CLAUDE.md — Quotaback 引き継ぎメモ

## 名前
**Quotaback** = quota + quarterback。2アカウントの残量を見て「どっちで走らせるか」を判断する司令塔、というコンセプト。
（候補だったもの: Quota Relay, Cost Relay, Swell, Hopper など）
将来的には表示だけでなく「上限が近いアカウントから別アカウントへの切り替えを促す」方向に広げる可能性がある。
アイコン・ロゴはアメフト（ボール／QB）モチーフで「quota back（返金）」と誤読されないようにしたい。

## 最初のタスク（この順で）
1. ~~`swift build` を通す~~ ✅ 済（Apple Swift 6.4 / macOS 27 で無修正でビルド成功。zip の `Quotaback/` をリポジトリ直下に展開済み）
2. `swift run Quotaback --once` して Keychain から両アカウントのトークンが読めるか確認。仕事用アカウントの Keychain service 名を調べて `~/.config/quotaback/config.json` に設定
3. 実レスポンス（`~/.config/quotaback/last-response-*.json`）を見てパーサーと表示ラベルを合わせる
4. ~~`.app` バンドル化とログイン時自動起動~~ ✅ 実装済み（`scripts/bundle.sh`、パネルの「ログイン時に起動」トグル）。実機での SMAppService 登録は未確認

## 目的
Claude Code の `/usage` に出る「利用上限の消費率」を、**2つのサブスクリプションアカウント分**、macOS のメニューバーに常時表示する。

- P: personal@example.com（個人）
- W: work@example.com（仕事）

スコープは `/usage` の上限表示のみ（Current session / Current week (all models) / Current week (<model>) / Usage credits）。トークン量やコスト集計は対象外。

## 構成
- SwiftPM の executableTarget、macOS 13+、SwiftUI `MenuBarExtra`（`.window` スタイル）
- `NSApp.setActivationPolicy(.accessory)` で Dock 非表示
- `Models.swift` 設定（`~/.config/quotaback/config.json`）と表示用モデル
- `UsageClient.swift` 認証情報の読み取りと usage API 呼び出し、レスポンス解析
- `UsageStore.swift` 定期更新（既定 300 秒、最短 60 秒）とメニューバー文字列
- `App.swift` UI（ログイン時起動トグル含む）
- `Main.swift` エントリポイント。`--once` で UI なしの1回取得（動作確認用）
- `Tests/QuotabackTests` パーサー・表示ラベルのテスト（サンプルは推測形式。実レスポンスで差し替えること）
- `scripts/bundle.sh` release ビルド → `dist/Quotaback.app`（LSUIElement、ad-hoc 署名）

## 未検証事項（最初にやること）
ビルドは通るが、**まだ一度も実行していない**（Keychain とトークンの読み取りはユーザー側で実行する必要がある）。

データ取得部分はすべて推測ベース：
- エンドポイント `GET https://api.anthropic.com/api/oauth/usage`、ヘッダー `anthropic-beta: oauth-2025-04-20` — Claude Code 内部の非公開 API。記憶ベースで未確認
- Keychain service 名 `Claude Code-credentials`、中身は `{"claudeAiOauth": {"accessToken", "expiresAt"(ms), ...}}` を想定
- 仕事用アカウントの Keychain エントリ名は未調査（`security dump-keychain | grep '"svce"' | grep -i claude` で確認）
- レスポンスは `{ "five_hour": {"utilization": 12.0, "resets_at": "..."}, "seven_day": {...}, ... }` のような形を想定。パーサーは `utilization` を持つオブジェクトを全部拾う緩い実装
- 実レスポンスは `~/.config/quotaback/last-response-<label>.json` に保存されるので、それを見てパーサーとラベル（`UsageWindow.title`）を合わせること

参考：ユーザーの `/usage` 表示には「Current session」「Current week (all models)」「Current week (Fable)」「Usage credits ($57.97 / $200.00)」が出ている（個人アカウント）。仕事用は Usage credits なし。

## 設計上の決定（変えるならユーザーに確認）
- **トークンのリフレッシュをしない。** refresh token がローテーションされると Claude Code 側のログインが壊れる恐れがあるため、読み取り専用。期限切れはエラー表示し、ユーザーがそのアカウントで `claude` を起動して更新する
- Keychain は `SecItemCopyMatching` ではなく `/usr/bin/security` 経由で読む（他アプリのアイテムの ACL を扱いやすいため）
- 取得失敗時は前回値を残す
- メニューバーには各アカウントの上限枠（five_hour / seven_day*）の最大値のみを出す。`extra_usage` 等は詳細パネルにだけ出す

## 今後のアイデア（未着手）
- WidgetKit のデスクトップウィジェット（サンドボックスのため App Group 経由のデータ受け渡しが必要）
