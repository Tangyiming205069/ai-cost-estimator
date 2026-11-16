# Install AI Cost Companion

This preview is a local source build. There is no notarized one-click binary yet. You can give this page to your coding agent; no special agent plugin or API key is required for installation.

## Requirements

- Apple silicon Mac running macOS 26 or newer.
- Apple Command Line Tools or Xcode with a macOS SDK 26+.
- Python 3.14+ with `compression.zstd` (Homebrew's Python is detected). If needed set `COMPANION_PYTHON` to its absolute executable path.
- Git to obtain the source.

The installer stops if these requirements are missing. It does not install dependencies, accept licenses, change developer tools, remove quarantine attributes or weaken Gatekeeper. Have the user choose how to install any missing prerequisite.

## Reproducible source installation

1. Choose the newest published source preview on [official releases](https://github.com/Tangyiming205069/ai-cost-estimator-companion/releases). Clone `https://github.com/Tangyiming205069/ai-cost-estimator-companion.git` into a new directory, check out that exact release tag and record its commit SHA before building. Do not install from an unreviewed third-party fork.
2. Read `build.sh` and `scripts/install.sh` before running them.
3. Run `bash scripts/install.sh --check`.
4. Run `bash scripts/install.sh`. It builds, checks the local ad-hoc signature, installs in the user's `~/Applications`, and opens the app. It never writes to system `/Applications`.
5. Choose English or 中文 in Settings → Language (also available in the window’s More menu). The choice persists after restart.
6. Choose whether to connect Codex in the app. Installation is not collection consent. Do not use a model request to test a connection without the user's authorization.

To build and install somewhere else without opening it:

```bash
bash scripts/install.sh --destination "$HOME/Downloads/AI Cost Companion.app" --no-open
```

The destination must not exist. Updates use a new destination; no existing app or data is removed automatically. The Python executable is recorded locally in the built bundle; do not distribute that local build as a portable binary.

## For the installing agent

Do not read private session records for installation. Do not change Codex or Claude settings, hooks, telemetry, login items or system security. Do not enable collection on the user's behalf merely because they asked to install. Do not install an unsupported client to make a support badge look complete. Show the installed path and explain actual source coverage.

## Remove

Quit the app and move its `.app` to Trash. The local ledger remains in the Application Support directory documented in README. Remove ledger data only when the user explicitly requests it. No uninstall command deletes it automatically.
