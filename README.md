# Cursito

Cursor has no built-in settings sync. Cursito is a small macOS menu bar app that
copies your Cursor setup from one Mac to another through iCloud Drive (or any
folder both Macs can see).

- **Export This Mac** on your main Mac writes the setup to a single
  `cursor-sync.tar.gz`.
- On the other Mac, the menu bar icon fills in when there's an export it hasn't
  imported. **Review…** shows what would change and **Import…** applies it: it
  quits Cursor, backs up the current setup, imports and reopens Cursor.
- **Restore Backup** rolls back any of the last five imports.

Sync goes one way: the Mac that exports last is the source of truth. Cursito
warns you before overwriting an export the other Mac hasn't imported yet.

**Cursor Usage** shows what you've spent in the current billing cycle and how
close you are to your on-demand limit. **Details** breaks it down by model and
by day, and lists every team member's spend. It reads Cursor's
[Admin API](https://cursor.com/docs/account/teams/admin-api), so it needs an
Enterprise team and an admin key (see [Cursor Usage](#cursor-usage)).

As an extra, **Git Repos** keeps the code itself in step: point it at the
folder that holds your repos and **Pull All** fetches every repo and
fast-forwards the ones that are behind. It never merges or rebases; repos with
uncommitted changes or diverged branches are listed for you to sort out
(right-click one to open it in Finder, Terminal or Cursor). **Fetch Only**
just updates the remote branches.

## What gets synced

| Synced | Where it lives |
|---|---|
| MCP servers | `~/.cursor/mcp.json` |
| Hooks | `~/.cursor/hooks.json` |
| Agent/CLI settings (permissions, models…) | `~/.cursor/cli-config.json`, minus the login session |
| Editor settings, keybindings, snippets | `~/Library/Application Support/Cursor/User/` |
| Plugins | `~/.cursor/plugins` plus the installed plugin list in Cursor's `state.vscdb` |
| Skills and subagents | `~/.cursor/{skills,agents,commands,rules}`, `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills` |
| Extensions | Installs missing ones with the `cursor` CLI; never uninstalls |

Not synced:

- **Chats, login and MCP OAuth tokens.** They're encrypted with each Mac's
  keychain, so OAuth MCP servers ask you to log in again after an import.
- **User Rules.** Cursor already syncs them with your account.

An import mirrors the export: skills or plugins that exist only on the importing
Mac are removed. The previous state stays in `~/.cursito/backups/`.

## Install

Requires macOS 14 or later and Xcode (or the Command Line Tools with Swift 6).
Build from source on each Mac:

```bash
git clone https://github.com/OrbeApp/cursito.git
cd cursito
scripts/build-app.sh --install    # builds and copies Cursito.app to /Applications
```

Open Cursito from `/Applications`. The first time it touches iCloud Drive,
macOS asks for permission. Turn on **Open at Login** in the menu so it's always
there.

Cursito checks [GitHub releases](https://github.com/OrbeApp/cursito/releases)
at launch and once a day. When there's a newer one, **Update to X.Y.Z**
appears next to the title and opens the release page. To update a build from
source, `git pull` and run `scripts/build-app.sh --install` again.

The default sync folder is `iCloud Drive/Cursito`. Use **Change…** in the menu
to pick another one; both Macs need to point at the same folder.

## Cursor Usage

1. In the [Cursor dashboard](https://cursor.com/dashboard), a team admin opens
   **API Keys** and creates a key (`crsr_…`).
2. In Cursito, **Connect Admin API Key…**, paste it and check the email. It
   defaults to the account Cursor is signed in with on this Mac.

Cursito checks the key against the API before saving it in your login
keychain, never in its preferences or on disk. It only calls
`/teams/spend` and `/teams/filtered-usage-events`, but the key itself has
admin rights over the team, so treat it like a password. **Settings… →
Disconnect** in the Details window removes it.

**Show spend in the menu bar** puts this cycle's spend next to the icon.

The warning measures spend against your per-user on-demand limit in Cursor
or, if you have none, against a **monthly budget** you set in Cursito (it
counts everything spent in the cycle, included usage too). Once spend
reaches 80% of it, the icon turns into a gauge with the percentage, and into
a warning sign past 100%, whether or not the spend is shown. The menu next to
the checkbox sets the budget, changes the threshold (50–100%, or never) and
can send a macOS notification: once when you cross the threshold and once
more past 100%, per billing cycle. Notifications need the built app; they're
off under `swift run`.

Cursor aggregates usage hourly, so Cursito refreshes at most once an hour in
the background; the refresh button forces it. Costs are what Cursor
counts towards spend (`chargedCents`), included usage and on-demand alike.

The Admin API is Cursor's only documented way to read usage. Apps that read
the session of the Cursor app itself stopped working when Cursor started
encrypting it with the keychain, and Cursito doesn't try to get around that.

## Command line

The app is a thin UI over [`scripts/sync-cursor.sh`](scripts/sync-cursor.sh),
which also works on its own:

```bash
SYNC=~/Library/Mobile\ Documents/com~apple~CloudDocs/Cursito/cursor-sync.tar.gz

scripts/sync-cursor.sh export -d "$SYNC"   # main Mac
scripts/sync-cursor.sh info   -d "$SYNC"   # who exported, and whether this Mac imported it
scripts/sync-cursor.sh diff   -d "$SYNC"   # what an import would change
scripts/sync-cursor.sh import -d "$SYNC"   # other Mac, with Cursor closed
scripts/sync-cursor.sh import -d ~/.cursito/backups/20261029-105854   # restore a backup
```

Run `scripts/sync-cursor.sh -h` for every option. A `-d` path ending in
`.tar.gz` is used as a single archive; any other path as a plain folder.

Git Repos runs [`scripts/update-repos.sh`](scripts/update-repos.sh):

```bash
scripts/update-repos.sh -C ~/code        # fetch + fast-forward every repo in ~/code
scripts/update-repos.sh -C ~/code -f     # fetch only
scripts/update-repos.sh -C ~/code api    # only ~/code/api
```

It runs git without a terminal, so remotes need credentials git can use on its
own: an SSH agent or keychain, or a credential helper for HTTPS. A repo that
would ask for a password shows up as `fetch failed`.

## Security

The export contains `mcp.json`, which often holds API tokens in plain text. The
archive is created with `600` permissions, but anything in iCloud Drive is only
end-to-end encrypted if you turn on
[Advanced Data Protection](https://support.apple.com/en-us/102651). Don't put
the sync folder in a git repository or a shared folder.

## How it works

- Export copies the files above into a staging folder, strips the login session
  from `cli-config.json`, reads the installed plugin list from `state.vscdb`,
  records the Mac's hardware UUID and the time, and replaces the archive in one
  move, so the other Mac never sees a half-written export.
- Import refuses to run while Cursor is open, because Cursor rewrites its
  settings and state when it quits. The app quits Cursor for you and reopens it
  afterwards.
- Import keeps the importing Mac's login session in `cli-config.json`, only
  touches the `cursor.plugins.installedIds.*` keys in `state.vscdb`, and records
  the import in `~/.cursito/last-import`.

Cursito relies on how Cursor stores its setup today, which isn't a public API.
If a Cursor update moves things around, an import may miss something; the
backup lets you roll back.

## Development

```bash
swift run Cursito          # run the app from the checkout (uses scripts/sync-cursor.sh)
swift test                 # parsing, import-state rules and the usage client
scripts/test-sync.sh       # end-to-end export/import between two fake home folders
scripts/test-update-repos.sh   # update-repos.sh against throwaway git repos
```

`scripts/test-sync.sh` stubs `ps` and `cursor`, so it never touches your real
Cursor setup.

### Releases

The update check compares `CFBundleShortVersionString` in
`Resources/Info.plist` with the tag of the latest published GitHub release
(drafts and prereleases don't count). To release, bump the version in
`Info.plist` and `CHANGELOG.md`, tag `vX.Y.Z`, and publish a GitHub release
for that tag with `build/Cursito.zip` from `scripts/build-app.sh --zip`.

### Signed releases

`scripts/build-app.sh` signs ad hoc by default, which is enough for Macs you
build on yourself. To publish a download that opens without Gatekeeper
warnings, sign with a Developer ID and notarize:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh --zip
xcrun notarytool submit build/Cursito.zip --keychain-profile <profile> --wait
xcrun stapler staple build/Cursito.app
```

## License

[MIT](LICENSE). Cursito isn't affiliated with Anysphere or Cursor.
