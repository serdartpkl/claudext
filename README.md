<p align="center">
  <img src="https://res.cloudinary.com/dljhkznwj/image/upload/v1790759010/claudext-logo_bp9p8h.png" alt="ClaudExt" width="180">
</p>

<h1 align="center">ClaudExt</h1>

<p align="center">
  <b>Back up everything Claude Code keeps on your machine, and bring it back on a new one —<br>
  even when your username, drive letters or project folders have changed.</b>
</p>

<p align="center">
  <img alt="PowerShell 7+" src="https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-verified-0078D6?logo=windows&logoColor=white">
  <img alt="Zero dependencies" src="https://img.shields.io/badge/dependencies-none-2ea44f">
  <img alt="Works offline" src="https://img.shields.io/badge/works-offline-lightgrey">
</p>

---

Chats on claude.ai live on Anthropic's servers. **Local Claude Code sessions do
not.** Every conversation, each project's auto memory, your prompt history,
skills, agents, hooks, MCP servers and trust decisions exist only as files under
`~/.claude` and `~/.claude.json`. Reinstall Windows, and they are gone.

Copying that folder is not enough either. Claude Code files each project under a
folder named after its path (`C:\Users\ada\Desktop\app` becomes
`C--Users-ada-Desktop-app`) and writes absolute paths into every session record.
On a new machine where you are `bob` instead of `ada`, or your projects moved
from `D:` to `E:`, Claude Code simply cannot find your history.

ClaudExt makes one zip of all of it, checks it, and on the new machine puts it
back **with every path translated** — folders renamed, records rewritten, and
nothing you already have on that machine lost.

## Highlights

- **Complete.** Sessions and auto memory, prompt history, settings, skills,
  agents, commands, rules, output styles, plans, project records and MCP
  servers — and whatever a later Claude Code adds to its folder.
- **Moves with you.** Paths are remapped when the username, the drive or a
  project's location changed. Paths under the old home move automatically;
  anything else is shown to you to decide.
- **Nothing is lost.** A file the restore would replace is moved aside first,
  and JSON settings are merged key by key, never overwritten.
- **No secrets in the archive.** Credentials, `.env` files, SSH keys and your
  account details are never collected.
- **Verified.** The archive is checked entry by entry, and a restore that put
  back 6,797 of 6,798 files is reported as incomplete, never as success.
- **Nothing to install.** Plain PowerShell 7 — no Node, no Python, no modules.
  A copy of ClaudExt travels beside every backup, so the restore works on a
  freshly installed machine.
- **A browser interface or the command line** — both run the same code.

## Quick start

### 1. Get PowerShell 7

```bash
winget install Microsoft.PowerShell
```

(ClaudExt does not install it for you: a PowerShell script cannot run before
PowerShell exists. `ClaudExt.cmd` tells you when it is missing.)

### 2. Back up

Download or clone this repository, then double-click **`ClaudExt.cmd`**. Your
browser opens on ClaudExt:

1. **Back Up** tab — ClaudExt finds your Claude folder by itself.
2. Every source is listed with its live size; untick what you do not need.
3. Choose a destination on **another drive** (an external disk, a second SSD).
   The page warns you if it is on the same drive as your home — the drive you
   are about to wipe.
4. **Create Backup.**

You get `claude-backup-<PC>-<date>-<time>.zip` and, beside it, a
`claudext-tool` folder: ClaudExt itself, checked file by file, so the backup can
be restored on a machine that has nothing yet.

### 3. Restore on the new machine

1. Install PowerShell 7, then double-click `claudext-tool\ClaudExt.cmd` on the
   backup drive.
2. **Restore** tab — pick the archive and press **Inspect**.
3. If your home folder changed, ClaudExt shows how every path will move.
   Paths under the old home are translated for you; for a project that lived
   elsewhere (another drive, a network share) type its new location or keep
   the old one.
4. Choose **This Machine**, or **A Folder** to try the restore somewhere safe
   first — a folder stands in for your home, and nothing outside it is touched.
5. **Restore Backup.** Then start Claude Code, run `/login`, and your projects,
   sessions and memory are where you left them.

Close Claude Code and the Claude app before restoring into this machine: a
running Claude writes `~/.claude.json` back from memory when it exits. ClaudExt
checks for one and asks twice before going ahead.

## Command line

Everything the browser interface does is also a script:

```bash
pwsh -File extract.ps1 -Destination E:\claude-backup
```

```bash
pwsh -ExecutionPolicy Bypass -File claudext-tool\import.ps1 -Archive claude-backup-PC-2026-08-11-1430.zip
```

`-ExecutionPolicy Bypass` matters when ClaudExt was downloaded with a browser:
Windows marks every downloaded file, and its default policy refuses to run
marked scripts. `ClaudExt.cmd` passes the flag for you, and the `claudext-tool`
copy is cleared of the mark on every backup.

Useful options:

| | |
|---|---|
| `import.ps1 -DryRun` | Inspect the archive and show the path mapping, write nothing |
| `import.ps1 -TargetRoot E:\restore-test` | Restore into a folder that stands in for your home |
| `import.ps1 -Yes` | Unattended: accept the automatic mapping, keep other paths as they were |
| `extract.ps1 -ClaudeDir F:\Users\ada\.claude` | Back up a Claude folder from an old disk |
| `import.ps1 -ClaudeDir D:\claude-config` | Restore into a Claude folder that is not the default one |
| `gui.ps1 -NoBrowser` | Start the browser interface and print its address instead of opening it |

## What is backed up

| | Where | |
|---|---|---|
| Sessions & memory | `~/.claude/projects` | Every session, and each project's auto memory |
| Skills | `~/.claude/skills` | |
| Tasks | `~/.claude/tasks` | |
| Prompt history | `~/.claude/history.jsonl` | Up-arrow recall, filed by project |
| Settings | `~/.claude/settings.json` | Hooks, status line, enabled plugins |
| Everything else | the rest of `~/.claude` | `CLAUDE.md`, `agents/`, `commands/`, `rules/`, `output-styles/`, `themes/`, `workflows/`, `plans/`, `keybindings.json`, the paste cache, `/usage` totals — and anything a later Claude Code adds |
| Project records | `~/.claude.json` | Trust decisions, allowed tools, per-project and user MCP servers, the `/config` choices stored there. Only these keys are archived, and they are merged into the new file key by key |
| Desktop app config | `%APPDATA%\Claude` | MCP servers and preferences, merged the same way |
| Custom memory folder | wherever `autoMemoryDirectory` points | When your `settings.json` moves auto memory out of the Claude folder |

Folders linked in with a junction or a symbolic link are backed up like
ordinary folders.

## What is deliberately left out

- **Credentials** (`.credentials.json`) — the archive is not encrypted. Run
  `/login` after restoring; it takes ten seconds.
- **Files that hold a secret by their nature**, anywhere: `.env`, `.env.*`,
  `.ssh/`, SSH keys, `*.pem`, `*.key`, `*.pfx`, `*.p12`, `.netrc`, `.npmrc`,
  `.pypirc`. A skill that reads a key from a `.env` beside it needs that file
  put back by hand.
- **Your account** from `~/.claude.json` — the signed-in account, the user id,
  an API key. Only the portable keys go into the archive.
- **Plugins** (`~/.claude/plugins`) — over a gigabyte that Claude Code
  reinstalls by itself. `INVENTORY.md` in the archive lists every enabled
  plugin with its marketplace.
- **Caches and live state** — sessions in flight, shell snapshots, file-history
  checkpoints, logs, telemetry, image cache, Claude Code's own backups of
  `~/.claude.json`, and the claude-mem plugin's internal sessions.

**What does travel:** values you put in an MCP server's `env` or in
`settings.json`'s `env` are part of your configuration, so they are in the
archive. Keep the archive where you would keep those keys.

## How path remapping works

When the home folder differs between the backup and the new machine, ClaudExt:

1. Translates every path under the old home to the new one.
2. Asks you about paths that lived elsewhere — they cannot be guessed.
3. Shows the complete mapping before writing anything.
4. Renames each project folder after its new path, and rewrites the paths
   inside every text file: sessions, memory, prompt history, settings, skills,
   `CLAUDE.md`, and the keys and values of `~/.claude.json`.

The details that make this safe:

- **Folders are matched to their real paths.** The folder name is a one-way
  encoding (`Çözümcül` becomes `--z-mc-l`), and sessions started in a git
  worktree or a subfolder are filed under the repository's folder. So the
  backup records which real path each folder was named after, and the restore
  renames from that.
- **Every spelling of a path.** Raw (`C:\Users\ada`), JSON-escaped
  (`C:\\Users\\ada`) and forward-slash (`C:/Users/ada`), in one pass, longest
  match first, and only on a boundary: `C:\Users\ada` never touches
  `C:\Users\adam`.
- **Byte-exact everywhere else.** Line endings, untouched lines and file
  timestamps (Claude Code sorts past sessions by them) are kept exactly. Binary
  files are never modified; scripts saved in a legacy code page or as UTF-16
  are rewritten in their own encoding.
- **Drive roots are handled.** A project that lived at `D:\` and now lives at
  `F:\work`, or the other way round, comes out with valid paths and correctly
  named folders.

## Safety

- **Nothing already there is lost.** A file the restore would replace is first
  moved into `~/.claude/claudext-replaced/<time>/`, keeping its place. Every
  JSON file that receives merged keys is copied there beforehand too.
- **A restore writes only where you agreed.** An archive cannot choose where
  its files go: only the places ClaudExt defines are written, and a custom
  memory folder named in an archive is always shown to you and never written
  into your home itself, the Claude folder, start-up folders, `~/.ssh` or
  system folders. Still, settings, hooks and skills run code by design —
  **restore only archives you made yourself.**
- **The browser interface is local and locked.** It listens on `127.0.0.1`
  only, and every request needs a random token generated at startup, so no
  other website or device can drive it.
- **Your data never leaves your machine.** Backups go only where you point
  them. The only network traffic is the browser page loading its fonts from
  Google Fonts (it works fine offline) and whatever the package managers do
  when `INVENTORY.md` asks them for their lists.

## Old disks and custom locations

ClaudExt finds the Claude folder the way Claude Code does: `CLAUDE_CONFIG_DIR`
if it is set, `~/.claude` otherwise. You can point it anywhere else — including
an old disk mounted on the new machine (`F:\Users\ada\.claude`, or
`C:\Windows.old\Users\ada\.claude` after a reinstall). ClaudExt recognises a
folder that is not this machine's, records the home its files were written
under, and reads that home's desktop app config instead of this machine's.

## Requirements and platforms

PowerShell 7 or newer — nothing else.

| Platform | Status |
|---|---|
| Windows | **Verified** against real installations |
| macOS | Supported in the code, **untested** |
| Linux | Supported in the code, **untested** |

On macOS and Linux, start with `import.ps1 -DryRun` or a restore into a folder.

## Known limitations

- A project folder name longer than 200 characters is shortened by Claude Code
  with a hash that cannot be recomputed; such a folder keeps its old name, and
  the restore tells you.
- A path followed by a space is ambiguous: when `proj` moves, a sibling folder
  named `proj (copy)` that is not a recorded project moves with it in the text.
- Only `autoMemoryDirectory` in your user `settings.json` is followed, not one
  set in managed settings or with `--settings`.
- Terminal output such as Git Bash `/c/Users/...` or WSL `/mnt/c/...` paths is
  history, and is left as it was written.

## FAQ

**Why not just copy `~/.claude`?** That works only if the new machine has the
same username and every project sits at the same path. Otherwise Claude Code
looks for `C--Users-bob-...` folders while your history is filed under
`C--Users-ada-...`, and every record inside still points at the old paths.

**Does Claude Code have an export?** `/export` saves the current conversation as
text. There is no built-in way to move your sessions, memory and configuration
to another machine.

**How big is a backup?** Sessions compress well: 5 GB of sessions made a
1.6 GB archive in testing.

---

ClaudExt is an independent project. It is not affiliated with, or endorsed by,
Anthropic. Claude and Claude Code are trademarks of Anthropic.
