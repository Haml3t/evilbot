# Hermes: running on a Claude Pro/Max subscription

**Audience: a Hermes agent setting up its own provider.** Follow these steps on the machine Hermes runs on. Run commands yourself where you can. Stop and ask your operator at the points marked **[Operator]**. Verified against a working setup (Hermes v0.21.5, plugin v0.3.3, Claude Code 2.1.283) on 2026-11-25. Newer versions may differ, so check the plugin README if a step fails.

## What this is

The `claude-subscription-directsdk-experimental` provider plugin (official, from Nous Research) runs the **unmodified official `claude` CLI** for each model request. The plugin has no credentials of its own: auth, entitlement and metering all belong to Claude Code and the operator's subscription. Hermes still owns its own tools, approvals, memory and compaction.

**Hard rule:** do NOT set `provider: anthropic` and point it at `~/.claude/.credentials.json`, or copy/reuse Claude OAuth tokens in any other client. That breaks Anthropic's ToS. Going through the official CLI the way this plugin does is the supported route.

## 0. Preflight

```sh
hermes --version          # needs >= 0.21.4
node --version            # Claude Code needs Node.js
```

If Hermes is older, update it first (`hermes update`).

## 1. Install Claude Code and log in

Do this as the **same OS user Hermes runs as**. A login made under another user doesn't count.

```sh
npm install -g @anthropic-ai/claude-code   # or: claude update, if already installed
claude --version                           # opus alias needs >= 2.1.280, sonnet >= 2.1.284, haiku >= 2.1.293
```

**[Operator]** Log in. You need a browser for this, so it's the operator's step.

- **Interactive desktop/laptop:** `claude auth login`. Logins expire after about 30 days, and then you log in again.
- **Headless/always-on box (gateway, systemd, server):** use `claude setup-token` instead. It gives a long-lived (~1 year) subscription token. Put it in `~/.hermes/.env` as `CLAUDE_CODE_OAUTH_TOKEN=...`. The operator pastes it in themselves. Never put it in chat.

Check:
```sh
claude auth status
claude -p 'say OK'        # should print OK
```

## 2. Clear conflicting environment variables

The plugin refuses to run if any of these are set where Hermes starts. Check the shell, `~/.hermes/.env`, and any systemd unit:

`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_FOUNDRY_API_KEY`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`

```sh
env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_USE_)' ; grep -E '^(ANTHROPIC_|CLAUDE_CODE_USE_)' ~/.hermes/.env
```

Comment out any you find (back up `.env` first) only after the operator says OK. Something else might be using them.

**Gotcha:** if `CLAUDE_CODE_OAUTH_TOKEN` is in `.env`, it **takes priority over** the `claude auth login` session. If requests fail as logged-out while `claude auth status` looks fine, the token in `.env` is stale or wrong.

## 3. Install the plugin and select the provider

```sh
hermes plugins install claude-subscription-directsdk
hermes model              # pick "Claude Subscription DirectSDK (Experimental)", then a model (e.g. opus)
```

`hermes model` checks the CLI and login, and writes nothing if something is missing. The result in config should look like this:

```yaml
model:
  default: opus
  provider: claude-subscription-directsdk-experimental
```

If you have to set it by hand, use `hermes config set model.provider claude-subscription-directsdk-experimental` and `hermes config set model.default opus`. Don't hand-edit `config.yaml`. If Claude Code isn't on Hermes' PATH (LaunchAgent, systemd), set `CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND=/full/path/to/claude` in `.env`.

Repo/docs: https://github.com/NousResearch/hermes-official-plugins/tree/main/claude-subscription-directsdk

## 4. Restart and verify

Restart the gateway if Hermes runs one, or start a new CLI session. Then:

```sh
hermes chat -q "Reply with just OK"
hermes doctor
```

Check the gateway log for `ClaudeCodeLoggedOut` or "Failed to load user provider plugin".

## 5. Recommended extras (optional, ask the operator)

**Keep cron jobs off the subscription.** Scheduled jobs burn subscription usage. One option is to send them to a cheap pay-per-token model instead (example uses Nous Portal):
```sh
hermes config set cron.model deepseek/deepseek-v4.1-flash
hermes config set cron.model_provider nous
```
Gotcha: the key is **`cron.model_provider`**. `cron.provider` is silently ignored, and cron then falls back to the main provider. With a model the subscription can't serve, that shows up as 404s. Use any provider/model the operator actually has an account with.

**Fallback providers** for when the subscription errors (expired login, rate limit, outage):
```yaml
fallback_providers:
  - provider: nous
    model: deepseek/deepseek-v4.1-flash
  - provider: nous
    model: anthropic/claude-sonnet-4.6
```
Warning: fallbacks are **pay-per-token**. If the login expires unnoticed, a paid fallback quietly runs up a real bill. If you add fallbacks, check spend now and then (`hermes insights --days 7`) and fix logins quickly.

**Extra usage / overage:** this is controlled in the operator's Claude account settings, not Hermes. To avoid overage billing, turn off extra usage there.

## Things to know

- **Usage meters like `claude -p`.** That's about 1.7x the interactive Claude Code TUI for the same work. Hermes can't see the real subscription limits. Its "cost" figures are API list-price estimates, not charges. Check real usage in Claude's own UI/CLI.
- **Login expiry is the #1 failure.** Symptoms: Telegram/CLI replies stop, or the log shows `ClaudeCodeLoggedOut`. Fix: run `claude auth login` again (or create a new `setup-token`), then restart the gateway.
- **Experimental plugin.** Keep it updated with `hermes plugins update claude-subscription-directsdk-experimental`, and run `claude update` when a newer model alias gives a "does not support this model" 400.

## Report back to the operator

When you're done, report: the Hermes version, the `claude --version` output, which auth method you used, the output of the `hermes chat -q` test, and whether cron/fallback were set up.
