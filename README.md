# Quotaback

Yet another usage status bar.

## Install

```sh
git clone git@github.com:otiai10/quotaback.git
cd quotaback
make install
```

## Configure

`~/.config/quotaback/config.json`

```json
{
  "language": "en",
  "refreshSeconds": 300,
  "accounts": [
    { "email": "personal@example.com", "emoji": "🏈", "label": "Personal" },
    { "email": "work@example.com", "emoji": "💼", "label": "Work" }
  ]
}
```

`emoji` marks the account in the menu bar (`🏈 13% · 💼 ≥43%`). In the panel the account is shown as `emoji` + `label`; without `label`, the part of the email before `@` is shown instead (or the full address if two accounts share it). Without `emoji`, the menu bar uses `label`, or the first letter of the email. Accounts Quotaback observes are added here with just their email.

`language` is `en` (default) or `ja`.

## Development

```sh
swift run
```

## How it works

Quotaback shows, for each account, the fullest usage limit in the menu bar (`P 13% · W ≥43%`). Click it for per-limit details, reset times and a projection of when you'll hit 100%.

- **Claude Code**: reads the OAuth token Claude Code keeps in the Keychain (`Claude Code-credentials`) and calls the same usage endpoint `/usage` uses. The token is never refreshed or stored; if it has expired, run `claude` with that account once.
- **Codex CLI**: no API calls. Reads the latest `rate_limits` from Codex session logs under `~/.codex/sessions`.
- **Who owns the token**: decided at runtime from `~/.claude.json` (`oauthAccount.emailAddress`) or Codex's `auth.json`, not from the labels in your config. Accounts it observes are added to `config.json` automatically.
- **Multiple accounts**: only the account you're currently logged in to can be fetched. When you switch with `/login`, Quotaback notices within a couple of seconds. Other accounts keep their last observed value, shown with `≥` because they may have been used elsewhere since.
- **Data**: observations are kept in `~/.config/quotaback/`. Estimates (lower bounds, projected resets, time to 100%) are recomputed from them each time.

> [!WARNING]
> The Claude usage endpoint (`api.anthropic.com/api/oauth/usage`) is undocumented and may change without notice.
