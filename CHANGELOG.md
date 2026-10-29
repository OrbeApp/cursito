# Changelog

All notable changes to Cursito are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-29

First release.

### Added

- macOS menu bar app (macOS 14+) that syncs a Cursor setup between Macs through
  iCloud Drive or any shared folder.
- **Export This Mac** writes the setup to a single `cursor-sync.tar.gz`, created
  with `600` permissions and replaced atomically.
- **Review…** shows what an import would change; **Import…** quits Cursor, backs
  up the current setup, imports and reopens Cursor.
- **Restore Backup** rolls back any of the last five imports, kept in
  `~/.cursito/backups/`.
- Menu bar icon fills in when there's an export this Mac hasn't imported, and a
  warning before overwriting an export the other Mac hasn't imported yet.
- Syncs MCP servers, hooks, agent/CLI settings (without the login session),
  editor settings, keybindings, snippets, plugins, skills, subagents, commands,
  rules and extensions.
- **Cursor Usage**: spend in the current billing cycle against the on-demand
  limit, with a Details window by model, by day and per team member. Reads
  Cursor's Admin API (Enterprise teams) with an admin key kept in the login
  keychain; refreshes at most once an hour because Cursor aggregates usage
  hourly.
- **Show spend in the menu bar** option, and a menu bar warning with the
  percentage once spend reaches a configurable share (80% by default) of
  your Cursor on-demand limit or, without one, of a monthly budget set in
  Cursito, with an optional macOS notification once per threshold and
  billing cycle.
- **Git Repos**: **Pull All** fetches every repo in a folder and fast-forwards
  the ones that are behind; **Fetch Only** just updates remote branches. Repos
  with uncommitted changes or diverged branches are listed and can be opened in
  Finder, Terminal or Cursor.
- Configurable sync folder (default `iCloud Drive/Cursito`) and **Open at Login**.
- **About** in the menu footer, with the version, a link to the repository
  and the note that Cursito isn't affiliated with Cursor.
- `scripts/sync-cursor.sh` command line with `export`, `info`, `diff` and
  `import`.
- `scripts/update-repos.sh` command line for fetching and fast-forwarding repos.
- `scripts/build-app.sh` to build, install and optionally sign and zip the app.
- Unit tests plus end-to-end test scripts for sync and repo updates, and a CI
  workflow.

[Unreleased]: https://github.com/OrbeApp/cursito/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/OrbeApp/cursito/releases/tag/v1.0.0
