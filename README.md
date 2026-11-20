# Claude Autowake

Start your Claude Code 5-hour usage window early so it resets before you need it.

Website (a parody, but the tool is real): https://adrians5j.github.io/claude-autowake/

## How It Works

Claude Code's usage limit operates on a rolling 5-hour window. This tool sends a single small message to Haiku at scheduled times (>= 5h apart) to start each window. By 9am, you're already 3 hours into the first window — meaning it resets at 11am instead of 2pm.

Each ping is one message (`"hi"`) to the cheapest model (Haiku) — minimal token cost.

## Quick Start

You need macOS, the Xcode command line tools (`xcode-select --install`) and Claude Code installed and logged in.

```bash
# 0. Clone
git clone https://github.com/adrians5j/claude-autowake.git
cd claude-autowake

# 1. Edit config.sh to set your preferred schedule
vim config.sh

# 2. Install (sets up launchd + pmset wake schedule)
./install.sh

# 3. Test it manually
./autowake.sh

# 4. Check status
./status.sh

# 5. Optional: menu bar app with usage and token stats, starts at login
./menubar/build.sh --install
```

If you change `config.sh` later, run `./install.sh` again. The schedule is baked into the launchd plist at install time, so edits don't apply until you reinstall. The installer will ask whether to replace the existing wake schedule; say yes.

This is a fork of [1mshy/claude-autowake](https://github.com/1mshy/claude-autowake) by Luca Lapenna, with the menu bar app added.

## Configuration

Edit `config.sh` to customize:

| Setting | Default | Description |
|---------|---------|-------------|
| `PING_TIMES` | `("06:00")` | Array of ping times in HH:MM 24h format. Must be >= 5h apart. |
| `WAKE_LEAD_MINUTES` | `3` | Minutes before first ping to wake Mac from sleep |
| `WEEKDAYS_ONLY` | `false` | Skip weekends when `true` |
| `CLAUDE_MODEL` | `"haiku"` | Model to ping (haiku = cheapest) |
| `PING_PROMPT` | `"hi"` | What to send (keep it tiny) |
| `CAFFEINATE_SECONDS` | `"auto"` | `"auto"` = span of ping times + 10 min buffer. Or set a number of seconds manually. |
| `PING_WORKING_DIR` | `""` | Directory to cd into before running claude (temp dir if empty) |
| `CLAUDE_EXTRA_FLAGS` | `""` | Extra flags for the claude CLI (e.g., `"--dangerouslySkipPermissions"`) |
| `MAX_LOG_FILES` | `30` | Max log files to keep |

### Example Schedules

With pings 5 hours apart:

| `PING_TIMES` | Window resets by |
|---|---|
| `("05:00" "10:00" "15:00")` | ~10am, ~3pm, ~8pm |
| `("06:00" "11:00" "16:00")` | ~11am, ~4pm, ~9pm |
| `("06:00")` | ~11am |

## Requirements

- macOS (uses launchd, pmset, caffeinate)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Mac plugged into power (required for pmset wake from sleep)

## Logs

Stored in `~/.claude-autowake/logs/`. Auto-pruned to last 30 files.

```bash
# View latest log
ls -t ~/.claude-autowake/logs/ping_*.log | head -1 | xargs cat

# Check launchd status
launchctl list | grep autowake

# Check wake schedule
pmset -g sched
```

## Menu bar app

`menubar/` holds a small native menu bar app (AutowakeBar). The menu bar shows your current 5-hour usage and the time until it resets, for example `12% · 2h 31m`, or `idle` when no window is active. The dropdown shows:

- 5-hour and 7-day usage with a bar and reset time
- whether the ping and caffeinate agents are loaded
- the next scheduled ping and the result of the last one
- actions: token stats, ping now, open the last log, open the logs folder, refresh

"Token stats…" (⌘T) opens a window that breaks down where your tokens went, for the current 5-hour window, today, the last 24 hours or the last 7 days. It shows fresh input, cache writes, cache reads and output, a chart over time, totals per workspace and your biggest sessions by name. The numbers come from Claude Code's own transcripts in `~/.claude/projects`, so nothing leaves your machine. "Weighted" counts tokens at their price ratio to fresh input: cache reads 0.1x, cache writes 1.25x, output 5x. That makes it a better guide to what eats your limit than raw token counts, which cache reads dominate. The first scan after launch takes a few seconds; after that the window refreshes every minute.

```bash
./menubar/build.sh              # build menubar/build/AutowakeBar.app
./menubar/build.sh --install    # install to ~/Applications and start at login
./menubar/build.sh --uninstall  # remove it
```

Usage numbers come from the same endpoint Claude Code's `/usage` reads, authenticated with the Claude Code login stored in your Keychain. If the token has expired, run `claude` once to refresh it. Usage refreshes every 5 minutes and when you open the menu; local state refreshes every 30 seconds. Requires Xcode command line tools (`swiftc`).

## Uninstall

```bash
./uninstall.sh
./menubar/build.sh --uninstall   # if you installed the menu bar app
```


## Extra
#Check total usage, and see if the haiku model is sending properly.
```bash
npx ccusage@latest
```
