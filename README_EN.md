<div align="center">

# ClaudeBridger

<img src="docs/images/app-icon.png" alt="ClaudeBridger" width="128">

**Point Claude Code at any Anthropic-compatible model service — without hand-editing config files.**

Fill in an endpoint, a credential and the models, click Activate, and the configuration is written. Switching backends needs no memorised field names and no risk of breaking Claude Code's settings.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)

[Features](#features) · [Screenshots](#screenshots) · [Install](#install) · [Quick start](#quick-start) · [How it works](#how-it-works) · [Configuration](#configuration) · [Safety design](#safety-design) · [FAQ](#faq) · [Known limitations](#known-limitations) · [License](#license)

[简体中文](./README.md) · **English**

</div>

---

## Table of contents

- [The problem it solves](#the-problem-it-solves)
- [Features](#features)
- [Screenshots](#screenshots)
- [What it applies to](#what-it-applies-to)
- [The two files it writes](#the-two-files-it-writes)
- [Install](#install)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Safety design](#safety-design)
- [Supported backends](#supported-backends)
- [FAQ](#faq)
- [Build from source](#build-from-source)
- [Known limitations](#known-limitations)
- [License](#license)

---

## What 1.0.1 fixes

Three fixes, each with a regression test:

- **A blank detail pane after reopening the app.** A saved configuration was restored, the sidebar showed a row as selected, and the right-hand pane drew the empty state; clicking that row did nothing. The cause: launch restored the selected id but never loaded the corresponding draft, and the pane renders from the draft. Clicking the already-selected row could not recover either, because SwiftUI does not call a selection setter when the value it is given is unchanged.
- **Deletion had no confirmation.** Deleting now raises a confirmation that says the action cannot be undone, and distinguishes two cases: deleting the backend **in use** tells you that deleting it does **not** revert Claude Code's configuration (that is what "restore official configuration" is for), while deleting an unused one tells you the config file is untouched.
- **Model display names.** You can now set a display label for the Opus / Sonnet / Haiku / Fable tiers (`ANTHROPIC_DEFAULT_*_MODEL_NAME`). It changes only the text shown in the `/model` picker, not which model is requested. Switching backends clears the previous labels, so the picker can no longer advertise one model while the requests go to another.

> Those four variables exist for a reason: Claude Code defines no `ANTHROPIC_MODEL_NAME` and no subagent display-name variable, so the main-conversation and subagent tiers show no such field. Writing a key Claude Code ignores would be worse than writing nothing, because it looks like it works.

---

## The problem it solves

Claude Code speaks one protocol: the Anthropic Messages API. Any service that speaks it can be its backend, and switching means writing environment variables such as `ANTHROPIC_BASE_URL` into a config file. That sounds simple. Done by hand, every step has a trap:

| Trap | What happens |
| --- | --- |
| One missing comma in the JSON | The whole `settings.json` stops loading, taking your permissions and hooks with it |
| Not knowing which variables matter | You set only the main model, and background summarisation and subagents fail silently |
| A leftover `ANTHROPIC_API_KEY` when switching | It conflicts with `ANTHROPIC_AUTH_TOKEN` and you get 401s |
| A `base_url` ending in `/v1` | Requests go to `/v1/v1/messages`, failing in a way that looks like a server problem |
| Being asked to sign in on first use | The flag that skips that lives in a **different file** |
| Assuming the desktop app works the same way | The desktop app does not read `settings.json`'s `env` at all |

ClaudeBridger turns that chain into one click, with a backup before the write and a read-back check after it.

## Features

**It rewrites only the twelve env keys that do the wiring; everything else survives byte for byte.**
The `env` block is a general-purpose environment for Claude Code and every subprocess it starts, so a user may well keep a proxy setting, a timeout or their own variables there. The built-in JSON editor records the byte span of each value and replaces only the spans it was asked to — changing a value touches one line, adding a key inserts one line. A test asserts that a value replacement differs from the original in exactly one line. Hand-written comments, trailing commas and indentation style all survive.

**Every write is backed up first, including switches between two backends this app manages.**
The one destructive action always has a way back. Backup filenames carry the backend and a timestamp, and a second backup within the same minute gets a numeric suffix rather than overwriting the first.

**It reads the file back after writing.**
"The write call returned" and "the file says this" are different claims. After writing, it re-reads from disk and compares the `base_url`, every model tier and the credential variable — and only reports success when they match.

**It stops rather than "repairs".**
When `settings.json` cannot be parsed, or `env` exists but is not an object, it **refuses to write and reports the error**. The worst thing a buggy tool can do is "fix" a config it did not understand, because that amounts to discarding the user's data. An unparseable `~/.claude.json` — which holds the sign-in session and every MCP server — is skipped with a warning.

**It fills every model tier in one go.**
Claude Code picks a different model per situation, and configuring only the main conversation makes the background tiers fail silently. DeepSeek's and Kimi's own integration guides both call this out as the most common misconfiguration. So each tier is its own field, presets fill them all, and the form offers a "fill the remaining tiers" button.

## Screenshots

<p align="center">
  <img src="docs/images/app-main.png" alt="ClaudeBridger main window: the backend list on the left (the one in use carries a green checkmark), the endpoint, credential header and per-tier models on the right, and the address Claude Code currently points at shown along the top" width="900">
</p>

<p align="center">
  <img src="docs/images/app-form.png" alt="The backend form: a Base URL section with name, address, credential header and credential; a Models section with one field per tier; and an Advanced section with context window, effort level and a switch for non-essential traffic" width="620">
</p>

The interface is bilingual and follows the system language.

## What it applies to

**Only the terminal Claude Code CLI.**

If you are trying to configure the Claude desktop app (the one with Chat / Cowork / Code tabs), this app cannot help. The official documentation is explicit: the desktop app takes its routing from its own third-party inference configuration (`inferenceProvider: gateway`, a macOS `.mobileconfig` profile, or Windows registry policy), and **it does not read `ANTHROPIC_BASE_URL` or the `env` block of `settings.json`**. That is a different mechanism.

On top of that, since desktop version 1.6259.1 the app only accepts model IDs that look like Anthropic models (beginning with `claude-` or `anthropic`), so pointing it at a Chinese vendor additionally requires a model-name mapping layer. The CLI has no such restriction.

## The two files it writes

| File | Location | Purpose |
| --- | --- | --- |
| `settings.json` | `~/.claude/settings.json` | The endpoint, credential and per-tier models in the `env` block |
| `.claude.json` | `~/.claude.json` | Exactly one key: `hasCompletedOnboarding: true` |

The second file exists only to skip the first-run sign-in check. Without it, launching the CLI against a third-party endpoint makes it try to validate a session with Anthropic first. Note it is **not** `~/.claude/settings.json` — it is a sibling of that directory, which is the trap most people hit the first time they configure this.

Setting `CLAUDE_CONFIG_DIR` moves the first file, and ClaudeBridger follows that variable. It is also the mechanism the tests use to run against a throwaway directory.

> **One unverified point**: the official docs say `CLAUDE_CONFIG_DIR` decides where "every `~/.claude` path" lives, but do not say whether the sibling `~/.claude.json` travels with it. ClaudeBridger currently treats it as staying in the home directory, reading the documentation literally. If your environment behaves differently, `ClaudePaths.claudeJSONOverride` is the hook left for that.

## Install

### Download

Download `ClaudeBridger-1.0.0.dmg` from [Releases](https://github.com/panando/ClaudeBridger/releases), open it, and drag ClaudeBridger into your Applications folder.

### macOS will block the first launch (the app is not developer-signed)

The app uses an **ad-hoc signature**. It is not signed with an Apple Developer certificate and not notarised, so Gatekeeper may show one of two warnings:

> "ClaudeBridger" is damaged and can't be opened. You should move it to the Trash.

> "ClaudeBridger" cannot be opened because the developer cannot be verified.

**This usually does not mean the app is actually damaged.** It means macOS has flagged an app that was downloaded from the internet and not notarised — the quarantine flag.

#### Option 1: allow it in System Settings (no command line)

1. Double-click ClaudeBridger once (it will be blocked).
2. Open **System Settings → Privacy & Security**.
3. Under **Security**, you will see the message about ClaudeBridger.
4. Click **Open Anyway**.
5. Confirm in the dialog.

#### Option 2: clear the quarantine flag in Terminal

If **Open Anyway** does not appear, or macOS still says the app is damaged, move `ClaudeBridger.app` into your Applications folder first, then open Terminal and run:

```bash
sudo xattr -dr com.apple.quarantine /Applications/ClaudeBridger.app
```

Enter your Mac password and press Return (**nothing is displayed as you type, which is normal**), then open ClaudeBridger.

### Requirements

macOS 14.0 or later. The current build is Apple Silicon (arm64) only.

## Quick start

1. Open ClaudeBridger, click **+ New backend** at the lower left, and pick a vendor (DeepSeek, for example).
2. Paste the **API credential** from that vendor's platform.
3. Click **Activate**.

Claude Code now points at that backend. Verify it from a terminal:

```bash
claude "hello"
```

To see exactly what was written, run `/status` inside Claude Code and check the `Anthropic base URL` line.

## How it works

- **Multiple backends**: the sidebar groups them as "Chinese models" and "Custom", and marks the one in use with a green checkmark.
- **One-click creation**: six built-in presets — DeepSeek, Zhipu GLM, Kimi (both the open platform and the membership plan), Alibaba Cloud DashScope Qwen, and a blank custom entry — each citing where its endpoint was confirmed, and each filling every model tier.
- **Live status**: the address Claude Code currently points at is shown at all times. It is read **from the file**, not from this app's own record, so a `settings.json` you edited elsewhere is reported as it actually is.
- **Switch protection**: when the current address is one this app does not manage (a configuration you wrote by hand, say), activating a new backend asks for confirmation first and tells you the original will be backed up.
- **Delete protection**: deleting a backend always confirms first and states the consequences. When the backend is the one in use, it says plainly that deleting it does **not** revert Claude Code's configuration.
- **Restore official configuration**: clears every key ClaudeBridger wrote from `settings.json`, returning Claude Code to its defaults. Also takes a backup first.
- **Address validation**: the form warns on the spot about the three address shapes that break things — a trailing `/v1`, a loopback host, and plain `http` carrying your credential in the clear.
- **Save and Activate are separate**: `Save` writes only ClaudeBridger's own record file and touches nothing Claude Code reads; `Activate` is what writes and backs up. When you have unsaved edits, the Activate button is disabled and says why.

## Configuration

### The environment variables it writes

ClaudeBridger writes only the keys below. Nothing else in the `env` block is touched.

| Variable | Comes from |
| --- | --- |
| `ANTHROPIC_BASE_URL` | The Base URL field |
| `ANTHROPIC_AUTH_TOKEN` | The credential, when Bearer Token is selected |
| `ANTHROPIC_API_KEY` | The credential, when API Key is selected |
| `ANTHROPIC_MODEL` | Main conversation |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Opus tier |
| `ANTHROPIC_DEFAULT_OPUS_MODEL_NAME` | Opus tier display label (affects only the `/model` picker) |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Sonnet tier |
| `ANTHROPIC_DEFAULT_SONNET_MODEL_NAME` | Sonnet tier display label (affects only the `/model` picker) |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Haiku tier (background tasks) |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME` | Haiku tier display label (affects only the `/model` picker) |
| `ANTHROPIC_DEFAULT_FABLE_MODEL` | Fable tier (automatic fallback) |
| `ANTHROPIC_DEFAULT_FABLE_MODEL_NAME` | Fable tier display label (affects only the `/model` picker) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Subagents |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Context window |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Context window |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | The "disable non-essential traffic" switch |
| `CLAUDE_CODE_EFFORT_LEVEL` | Effort level |

`ANTHROPIC_API_KEY` is special: it can only ever be **removed**, never written. Having it alongside `ANTHROPIC_AUTH_TOKEN` causes 401s, so switching to Bearer Token always clears any leftover.

### Do not put `/v1` in the Base URL

Claude Code appends `/v1/messages` itself. Giving it `https://api.example.com/v1` produces a request to `/v1/v1/messages` — the hardest failure to debug here, because it looks like a server problem. The form warns about this as you type.

### About the `[1m]` suffix

Vendor guides recommend names like `deepseek-v4-pro[1m]`. This was verified by experiment: **the suffix is a client-side hint and Claude Code strips it before sending the request.** Captured against the real Claude Code v2.1.299: the configuration said `deepseek-v4-pro[1m]` and the request body arriving at a local mock server contained `"model": "deepseek-v4-pro"`. So the vendor sees a clean name; the suffix only tells Claude Code how large the context window is.

### The context window field

This maps to `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and `CLAUDE_CODE_MAX_CONTEXT_TOKENS`. **Getting it wrong causes premature context compaction or an over-limit error.** If you are unsure, leave it empty and let the model's own default apply.

## Safety design

This is the one section worth reading closely, because everything the app does replaces configuration you are currently using.

### It touches only the keys that do the wiring

See the variable table above. Everything else — `HTTPS_PROXY`, `API_TIMEOUT_MS`, `permissions`, `hooks`, `statusLine`, your own variables — survives byte for byte. That is verified rather than asserted: a test checks that replacing one value differs from the original text in exactly one line.

### It refuses rather than "repairs"

A parse failure stops the write. The reasoning is in [Features](#features).

### Every write is backed up, with no exception

Before writing, both `settings.json` and `~/.claude.json` are copied to:

```
~/.claude/claudebridger/backup/settings-<backend>-yyyy-MM-dd-HHmm-bak.json
~/.claude/claudebridger/backup/claude-json-<backend>-yyyy-MM-dd-HHmm-bak.json
```

The directory is deliberately **not** `~/.claude/backups/`, which is where Claude Code keeps its own rotating `.claude.json.backup.*` files. Two writers in one directory is how one of them ends up deleting the other's files.

### Where credentials live

Credentials go in `~/.claude/claudebridger/credentials.json` with mode `0600`.

**The Keychain is deliberately not used.** This app is ad-hoc signed and not notarised; an unsigned binary reading a Keychain item triggers a prompt, and the "Always Allow" grant is keyed to a code signature that changes on every rebuild — so the user would re-approve on every update, which is more annoying than the problem it solves.

This file is **not** a strong secret store and the code does not pretend it is. Its purpose is that your credential is not sitting in a repository you commit, in a team-shared project settings file, or on the screen that a settings app inevitably gets screenshotted on.

To be clear: **`ANTHROPIC_AUTH_TOKEN` still ends up as plaintext in `settings.json`, because that is the file Claude Code reads.** The official documentation warns about exactly this. ClaudeBridger cannot make that file secret; what it can do is refrain from keeping a second copy somewhere less expected.

## Supported backends

A preset only ships when its endpoint's Anthropic compatibility could be confirmed against the vendor's own documentation, and each one cites its source. **Model names move fast — check the vendor's docs for the currently valid name before filling it in.**

| Backend | Base URL |
| --- | --- |
| DeepSeek | `https://api.deepseek.com/anthropic` |
| Zhipu GLM | `https://open.bigmodel.cn/api/anthropic` |
| Kimi / Moonshot open platform | `https://api.moonshot.cn/anthropic` |
| Kimi Code (membership) | `https://api.kimi.com/coding/` |
| Alibaba Cloud DashScope · Qwen | `https://dashscope.aliyuncs.com/apps/anthropic` |
| Custom / relay service | Any service implementing the Anthropic Messages API |

Both DashScope and Kimi offer several billing plans, and **each plan's base URL must be paired with that plan's own key** — mixing them causes authentication failures. The form says so.

DeepSeek adds a convenience: it maps `claude-opus*` to its own pro model and `claude-sonnet*` / `claude-haiku*` to its flash model, so it works even if the model names are not an exact match.

## FAQ

**401 after activating?**
Check the credential header. If the server expects `x-api-key`, switch "Credential header" from Bearer Token to API Key, or vice versa. Also confirm the key and the base URL belong to the same billing plan — DashScope and Kimi give each plan its own endpoint, and mixing them always fails.

**"Model not found" after activating?**
The model name is wrong. Check the vendor's docs for the current name. The `[1m]` suffix does not affect this (it gets stripped), but the model name itself must be exact.

**Background tasks fail (generating conversation titles, for instance)?**
The Haiku tier is unset. It maps to `ANTHROPIC_DEFAULT_HAIKU_MODEL` and is what background work uses.

**I edited `settings.json` by hand and the address at the top is now stale.**
Click the refresh button on that row, or press `⌘R`, to re-read from disk.

**Why is the Activate button greyed out?**
Hover it and it explains. The two common reasons: you have unsaved edits; or this backend is already in use and the file already holds exactly this configuration, in which case there is nothing to write and the button settles.

**Can I configure two backends and switch between them?**
Yes — click between them in the sidebar. When both are managed by this app, it does not ask for confirmation.

**Does it work with the desktop app?**
No. See [What it applies to](#what-it-applies-to).

## Build from source

Requires the Xcode command line tools (Swift 5.9+).

```bash
swift build            # build
swift test             # 129 tests
swift run ClaudeBridger
```

No external dependencies: JSON, file IO and SwiftUI all come from the system.

Packaging:

```bash
./scripts/build-app.sh     # produces build/ClaudeBridger.app
./scripts/build-dmg.sh     # produces build/ClaudeBridger-1.0.0.dmg
```

`build-dmg.sh` mounts the image back after building and checks that the executable is present, the `/Applications` symlink exists, and the version matches `VERSION`.

### Tests

Every test runs in a temporary directory (using `CLAUDE_CONFIG_DIR` to point at a throwaway home), so **your real `~/.claude` is never touched**.

```bash
swift test
```

These groups are worth running on their own, because they guard the reason this app exists:

```bash
swift test --filter JSONDocumentTests          # the editor touches only the bytes it should
swift test --filter ClaudeSettingsWriterTests  # your configuration survives a switch
swift test --filter ManagedEnvironmentTests    # the safety boundary has not quietly widened
swift test --filter AppModelTests              # which action writes which file
```

## Known limitations

- **CLI only.** The desktop app uses a different mechanism; see [What it applies to](#what-it-applies-to).
- **Some Claude Code features stop working behind a third-party endpoint.** This is Claude Code's own behaviour: once `ANTHROPIC_BASE_URL` points at a non-official host, MCP tool search is off by default, Remote Control is unavailable, and pricing display is wrong.
- **Anthropic neither forbids nor supports third-party gateways.** The official documentation says it does not endorse, maintain or audit third-party gateway products, and does not support routing Claude Code to non-Claude models through any gateway. The trend has been toward tightening: the desktop app gained a model-name allowlist, and the CLI changed gateway model discovery from on-by-default to manual opt-in. Relying on this path means accepting it may get harder.
- **Model names in the presets will go stale.** Endpoints are relatively stable; model names are not.
- **Not notarised.** The first launch needs a manual allow; see [Install](#install).
- **Whether `CLAUDE_CONFIG_DIR` also moves `~/.claude.json` is unverified**; see [The two files it writes](#the-two-files-it-writes).
- **No reverse import.** You can only create backends from a preset; it cannot read an existing `settings.json` and recognise it as a backend.

## What was verified by experiment

These are not transcribed from documentation — they were run:

- The real Claude Code CLI **v2.1.299** was launched against a configuration this app generated, and its requests did go to the configured address.
- Captured traffic confirmed the request path is `/v1/messages?beta=true` and the authentication header is `Authorization: Bearer <token>`.
- The `[1m]` suffix in `deepseek-v4-pro[1m]` was confirmed to be stripped by the CLI before the request, with the vendor receiving `deepseek-v4-pro`.
- After a write, `$schema`, `permissions` and user-defined `env` variables were confirmed to survive byte for byte.

## License

[MIT](LICENSE)

Copyright (c) 2026 panando
