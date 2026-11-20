# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Claude Autowake is a macOS tool that pre-starts Claude Code's 5-hour rolling usage window by sending a minimal ping (`"hi"` to Haiku) on a schedule via launchd. This ensures the usage window resets before the user's workday begins.

## Architecture

Four shell scripts, no build system:

- **config.sh** — All user-configurable settings (ping times, model, weekday-only flag, caffeinate duration). Sourced by other scripts.
- **autowake.sh** — The ping runner. Sends one message to Claude CLI (`claude --print --model haiku -p "hi"`). Has lockfile protection, retry logic (2 attempts, 60s gap), and log pruning.
- **install.sh** — Generates two launchd plists (`com.autowake.ping` for scheduled pings, `com.autowake.caffeinate` to keep the Mac awake), loads them via `launchctl bootstrap`, and sets a `pmset repeat wakeorpoweron` schedule. Validates that ping times are >= 5h apart.
- **uninstall.sh** — Reverses install: unloads agents, removes plists, cancels pmset, optionally deletes logs.

Plus a menu bar app in `menubar/`:

- **menubar/AutowakeBar.swift**: single-file AppKit status item. Reads 5h/7d usage from `https://api.anthropic.com/api/oauth/usage` using the Claude Code OAuth token from the Keychain (`Claude Code-credentials`), and local state from launchctl, the ping plist, and the latest log. "Ping now" uses `launchctl kickstart` on `com.autowake.ping`. "Token stats…" opens a SwiftUI window that totals token usage from local transcripts (`~/.claude/projects/*/*.jsonl`, last 7 days, deduped by message id), weighted at price ratios (cache read 0.1x, cache write 1.25x, output 5x). Transcripts are read incrementally by byte offset, so only the first scan is slow (~4s).
- **menubar/build.sh**: compiles with `swiftc` into `menubar/build/AutowakeBar.app`. `--install` copies it to `~/Applications` and adds a `com.autowake.menubar` login agent; `--uninstall` removes both.

## Key Commands

```bash
./install.sh       # Install launchd agents + pmset wake (requires sudo for pmset)
./uninstall.sh     # Remove everything
./autowake.sh      # Manual test ping
./status.sh        # Check if everything is loaded and show last ping result
```

## Runtime Artifacts

- Logs: `~/.claude-autowake/logs/ping_*.log` (auto-pruned to 30 files)
- Lockfile: `/tmp/claude-autowake.lock`
- LaunchAgents: `~/Library/LaunchAgents/com.autowake.{ping,caffeinate}.plist`

## Platform

macOS only — depends on launchd, pmset, and caffeinate.
