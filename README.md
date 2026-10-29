# Usage Notifier

<p align="center">
  <img src="docs/images/usage-light.png" width="49%" alt="Usage Notifier showing Codex and Claude capacity in light mode" />
  <img src="docs/images/usage-dark.png" width="49%" alt="Usage Notifier showing Codex and Claude capacity in dark mode" />
</p>

A small native macOS floating card showing your **remaining Codex and Claude capacity**, with reset countdowns and local reset times. Inspired by `caffeinate-gui`, with the usage integrations adapted from `ai-usage`.

## Build and run

Requires macOS 13+ and Apple Command Line Tools to build. Log in with the Codex and Claude CLIs first.

```sh
./scripts/build.sh
open "build/Usage Notifier.app"
```

You can move the built app into Applications. The app is written entirely in Swift, with native provider queries running asynchronously alongside the UI. The installed Codex CLI is required at runtime; Claude credentials come from your existing Claude Code login.

## Behavior

- Floats at the top right across Spaces, like Caffeinate. Drag its background to reposition it.
- Shows only the limits actually returned by each provider. A missing 5-hour or weekly window is not assumed to be unlimited.
- Bars show **remaining** capacity. Orange means 25% or less remains; red means 10% or less remains.
- Refreshes Codex every minute and Claude every five minutes. Refresh button / Command-R rechecks eligible providers without bypassing cooldowns.
- Keeps the last successful reading on failures, labels the error and last successful update, and shows the retry countdown.
- Honors Claude's `Retry-After` response (15-minute fallback). Backoff and usage cache are held in memory for the app's lifetime.
- Close button / Command-Q quits. Pressing Q while the app is focused also quits. No notification permissions required.

## Data sources

Codex uses the local CLI's [`account/rateLimits/read` app-server method](https://learn.chatgpt.com/docs/app-server). The CLI owns authentication. The app reads subscription usage, not API billing or local token estimates.

Claude uses `https://api.anthropic.com/api/oauth/usage` with Claude Code's OAuth credentials from the macOS Keychain (`Claude Code-credentials`), falling back to `$CLAUDE_CONFIG_DIR/.credentials.json` or `~/.claude/.credentials.json`. Supports the legacy window response and newer scoped model limits used by `ai-usage`. This endpoint may change independently of the app.

Claude tokens stay in memory and are sent only to Anthropic's usage endpoint. They are never included in app output or saved to disk by Usage Notifier. If silent Keychain access and the credentials file are unavailable, a small login-session helper allows **one authorization attempt per macOS login**. After you approve, it keeps the credentials in memory across closing and reopening the card. Normal refreshes try to pick up credentials renewed by Claude Code silently, falling back to the in-memory credentials. Cancelling authorization does not trigger repeated prompts; the card shows an access error until the next macOS login.

The app registers `~/Library/LaunchAgents/local.usage-notifier.credentials.plist` on demand. The helper starts only when needed and exits at logout, clearing its memory cache. It communicates over a local XPC connection restricted to the same user and the app's signing identifier. A nonsecret login-session marker in `~/Library/Application Support/UsageNotifier/credential-prompt-session` prevents repeated prompts even if the helper crashes or restarts. If the helper restarts and cannot read Keychain silently, its lost memory cache cannot be recovered until the next login. To remove the helper, run `launchctl bootout gui/$(id -u)/local.usage-notifier.credentials` and delete its LaunchAgent plist.

Finder's minimal PATH is supplemented with Homebrew, `~/.local/bin`, and common Nix locations to find Codex.

## Verify

```sh
./scripts/test.sh
```

For a live diagnostic, the app prints usage-only JSON (no tokens) without opening a window:

```sh
"build/Usage Notifier.app/Contents/MacOS/UsageNotifier" --once
```
