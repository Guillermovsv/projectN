# ProjectN

A native macOS app for running **Claude Code**, **Codex** and plain **terminals** inside your local project folders, organised into workspaces.

## Install

**You need:** a Mac with **macOS 26** or newer, and [Claude Code](https://docs.claude.com/en/docs/claude-code) and/or [Codex](https://github.com/openai/codex) installed and logged in.

### Option A — download the app (easiest)

1. Go to the **Releases** page of this repo and download `ProjectN.zip`.
2. Double-click the zip, then drag **ProjectN** into your **Applications** folder.
3. Open Terminal and paste this once (the app isn't signed by Apple, so macOS blocks it otherwise):
   ```bash
   xattr -dr com.apple.quarantine /Applications/ProjectN.app
   ```
4. Open ProjectN from Applications. Done.

### Option B — build it yourself

```bash
xcode-select --install            # only if you don't have Xcode / Command Line Tools
git clone https://github.com/Guillermovsv/projectN.git projectN
cd projectN
./build.sh --install              # builds and copies ProjectN to /Applications
open /Applications/ProjectN.app
```

### First launch

- Add a project folder (⌘O or drop a folder on the sidebar), then press **+** to open a Claude, Codex or Terminal pane.
- For voice dictation, allow **Microphone**, **Input Monitoring** and **Accessibility** when macOS asks.

## Concepts

| Thing | What it is |
|---|---|
| **Project** | A folder you've declared (sidebar → Projects, ⌘O, or drop folders on it). |
| **Workspace** | A named group of projects. Shown as a parent in the sidebar. |
| **Space** | A screen inside a workspace holding **1–8 panes**, tiled automatically: a single pane fills the space, 2–3 sit side by side, 4 → 2×2, 5–6 → 3×2, 7–8 → 4×2. |
| **Pane** | Claude, Codex or a Terminal running in one of the workspace's projects. Each new pane gets a random name (Ada, Grace, Linus…) so you can tell agents apart; the ⤢ button in its header expands it to fill the space (click again to go back to the split view). |

The sidebar always shows the Workspaces → Spaces tree (plus Projects). Each workspace has a **⋮** menu: *Add Space*, *Projects…*, *Rename…*, *Remove from App* (removes the workspace from ProjectN only — your folders and files are never deleted). Click a space to open it, click **Overview** (⌘0) to step out. Panes keep running in the background while you're elsewhere.

## Chat box, attachments & agent-to-agent messages

Every Claude/Codex pane has a chat box under its terminal (hide it from the pane's ⋮ menu; you can always type in the terminal directly).

- **Send** with ⏎ (⇧⏎ or ⌥⏎ for a new line; the box is 4 lines tall and scrolls). The message is pasted into the agent's input and submitted. ⇧⏎ also inserts a new line when typing directly in a Claude/Codex terminal.
- **Latest prompt** is pinned above each Claude/Codex terminal (click it to read it in full). It's read from the agent's own transcript, so prompts typed directly into the terminal show up too (within ~5 s).
- **Attach** with 📎 or by **dropping files/images on the pane** — their paths are added to the message (Claude and Codex pick up image paths as images). 📎 → *Attach This Pane's Recent Output* saves a handoff file in `~/.projectn/handoffs/` and attaches it.
- **Tag other agents** with **@** (or type `@`), or **drag a pane's title onto another pane**. When agents are tagged, Send delivers the message to *them* (prefixed with `[Message from <pane> (<space>), via ProjectN]`) instead of this pane — combine with a handoff file for a drop-off. Agents in other spaces/workspaces can be tagged too; a stopped pane is started and resumed first.
- Dropping files on a **terminal** pane pastes their quoted paths.
- The bottom row has **Model**, **Effort** and **Permissions** menus:

| | Claude | Codex |
|---|---|---|
| Model | Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5 (+ previous versions) (`--model <id>`) | models from Codex's own cache (`-m`) |
| Effort | low … max (`--effort`) | levels the chosen model supports (`model_reasoning_effort`) |
| Permissions | Ask, Accept edits, Plan, Auto mode, Don't ask, ⚠︎ Bypass all (`--permission-mode`) | Read only, Workspace, Workspace no prompts, ⚠︎ Full access (`-s` / `-a`) |

  Values are always explicit — there is no "Default": a new pane starts with your saved defaults, and anything never chosen is filled in from what the CLI itself is configured to use (`~/.claude/settings.json`, `~/.codex/config.toml`). **Claude: model and effort change live** — the app types `/model <id>` / `/effort <level>` into the running session (no restart, no redraw of the conversation), then puts your global Claude defaults back (Claude would otherwise save them as your default everywhere). Changing Claude's **permissions**, or any Codex setting, restarts the pane and resumes the same conversation (you're asked first if the agent is busy). Permissions menu → *Use Current Settings as Default* for new panes. The ⚡ button toggles Auto · Complete.

## Usage meters

The top bar shows the usage of the **focused pane's agent** (Claude or Codex, with its icon; it switches as you change focus, and keeps the last one for terminals/Overview): the **higher** of the 5-hour and weekly windows, as a bar + percentage. White below 70%, orange from 70%, red from 90%. Click for both windows and reset times. Refreshes every minute.
- Claude: the same usage data as Claude Code's `/usage`, using the login Claude Code keeps in your Keychain (only sent to api.anthropic.com).
- Codex: read locally from the rate-limit info Codex records in `~/.codex/sessions`.

## Auto mode

Auto mode is not AI: it's local pattern matching on the pane's screen (no model, no network, no cost).

## Right panel

The icon rail on the right edge opens **Files**, **Activity** or **Browser** (click the active icon again to close). ⌥⌘0 toggles, ⌥⌘1/2/3 pick a tab. Drag the panel's edge to resize.

- **Files**: tree of the focused pane's project (or pick another). Double-click opens a file; right-click to reveal in Finder, copy (relative) path, insert the path into the focused pane, open a terminal pane in a folder, or open HTML/images in the Browser tab.
- **Activity**: every Claude/Codex pane across all workspaces, grouped as *Needs your input*, *Working*, *Idle*, *Not running*. Panes waiting on a prompt are highlighted **yellow** (also on the pane, its space in the sidebar, and the panel button). Click a row to jump to it.
- **Browser**: preview `localhost` dev servers or any URL (`3000` → `http://localhost:3000`). Viewport presets: Fit (panel width), Mobile 390, Tablet 820, Desktop 1440. The page really gets that CSS width and is scaled to fit, so media queries behave like the device.

New panes are added from the **+** in the top bar (or ⌘T / ⌘Y / ⌘U).

## Restoring after quitting

Quitting saves everything. On the next launch each pane restarts when its space is opened:
- **Claude** panes resume their *own* conversation (each pane gets a `--session-id`, reopened with `--resume`).
- **Codex** panes resume their own session (`codex resume <id>`, found in `~/.codex/sessions`).
- **Terminal** panes show their previous output (dimmed) above a fresh shell in the project folder.
- Layout, spaces, focused pane, selected space and Auto settings are restored.

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘Y / ⌘U | Add a Claude / Codex / Terminal pane to the current space |
| ⌘1…⌘8 | Focus pane N |
| ⇧⌘W | Close focused pane |
| ⇧⌘N | New space |
| ⇧⌘] / ⇧⌘[ | Next / previous space |
| ⌘0 | Overview |
| ⌥⌘0 | Show / hide right panel |
| ⌥⌘1 / 2 / 3 | Files / Activity / Browser |

Each pane's **⋮** menu has Auto → Complete, restart & resume, restart fresh, rename. Double-click a pane title or space name to rename it.

## Auto mode

Each Claude/Codex pane header has a **⋮** menu → **Auto → Complete**. While it's on (⚡ AUTO badge), the session answers prompts for you:

- Numbered choice prompts (permission prompts, plan approval, "trust this folder", questions): picks the option marked **Recommended**, otherwise the first **Yes** option.
- Inline `(y/n)`, `[y/N]`, `(yes/no)` prompts: types `y`.
- Anything else (no Yes and no Recommended option, multi-select checkboxes, free text) is left for you.

Each prompt is answered once, after it has been on screen and unchanged for about 0.3 s. The header briefly shows what it answered. The setting is saved per pane.

## Settings

Open from **Settings** at the bottom of the sidebar (or ⌘,) — it opens inside the window: the sidebar lists the sections under a **‹ Back** button and the panels area shows the section. **Back** (Esc / ⌘[) returns you to the same workspace, space, focused pane and right-panel tab you were on. The palette menu beside Settings switches the theme directly.

- **Appearance** — themes: Midnight, Daylight, Nord, Dracula, Solarized Dark. Each sets light/dark, accent, surfaces and the terminal palette (applies instantly to running terminals). Terminal font size.
- **Accounts** — sign-in status for Claude Code (`claude auth status`), Codex (`codex login status`), GitHub CLI (`gh auth status`) and Gemini CLI. *Sign In / Switch Account / Sign Out* run the CLI's own flow in a small built-in terminal.
- **API keys & tokens** — e.g. `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GITHUB_TOKEN`: stored in the macOS Keychain and added to every pane's environment. (Note: an `ANTHROPIC_API_KEY` makes Claude Code bill that key instead of your subscription.)
- **Voice (NVoice)** — the NVoice dictation app, built in (see below).
- **MCP Servers** and **Tools** as before.

## Voice dictation (built-in NVoice)

While ProjectN is open, **hold fn anywhere, talk, release** — the text is pasted at your cursor in any app (⇧ + fn enhances that one dictation with Claude/Codex, Esc cancels). It is NVoice's own code (`Sources/ProjectN/NVoice/`), so you no longer need NVoice.app running.

- Settings › **Voice (NVoice)**: on/off switch, menu bar icon on/off, and NVoice's pages — General, AI, People & Words, History, Metrics.
- Shares NVoice's data and preferences (`~/Library/Application Support/NVoice/`, defaults domain `com.4vmarketing.nvoice`): people, dictionary, corrections, history and settings carry over both ways.
- Only one of them listens to fn at a time (same lock file). If NVoice.app is running, Settings › Voice offers *Quit NVoice App & Use ProjectN*; launching NVoice.app while ProjectN has dictation on just opens ProjectN's Voice settings.
- First run: allow **Microphone**, **Input Monitoring** and **Accessibility** for ProjectN. `build.sh` signs with a stable local identity (`NVoice Local Signing` if present, or `SIGN_IDENTITY=…`) so these grants survive rebuilds.
- Requires macOS 26+ (Apple's on-device `DictationTranscriber`).

## The app's own directory: `~/.projectn`

```
~/.projectn/
  state.json     projects, workspaces, spaces, panes (+ their Claude/Codex session ids)
  scrollback/    saved terminal output, restored on relaunch
  settings.json  app settings
  mcp.json       MCP servers for every Claude & Codex session started here
  mcp/           npm prefix for installed MCP server packages (node_modules/.bin is on PATH)
  bin/           your own scripts, on PATH in every session
  claude/        CLAUDE_CONFIG_DIR, only if "Isolate Claude config" is on
  codex/         CODEX_HOME, only if "Isolate Codex home" is on
```

Override the location with `PROJECTN_HOME=/some/path`.

**MCP servers.** Manage them from the puzzle-piece button on the home screen, or edit `mcp.json` directly (same format as Claude's `.mcp.json`).
- Claude gets them through `--mcp-config ~/.projectn/mcp.json`. They're added on top of your normal Claude MCP setup.
- Codex gets them as per-launch `-c mcp_servers.<name>.*=…` overrides, so your `~/.codex/config.toml` is never modified.
- "Install" runs `npm install --prefix ~/.projectn/mcp <package>`. Then add a server whose command is the package's bin name.

Every session also gets `PROJECTN_HOME`, `PROJECTN_WORKSPACE`, `PROJECTN_PROJECT` and `PROJECTN_MCP_CONFIG` in its environment.
