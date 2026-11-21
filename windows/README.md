# Windows source preview

Requirements: Windows 10/11 and Python 3.14 from [python.org](https://www.python.org/downloads/windows/), including Tcl/Tk and the Python launcher. No API key or extra Python packages are required. This is source code, not a signed standalone EXE.

Double-click `windows/Launch.cmd` in a checkout to launch immediately. For a per-user installation, inspect and run `windows/Install.ps1` in PowerShell. It copies the tool under `%LOCALAPPDATA%\Programs\AI Cost Estimator` and creates a Start-menu shortcut. If script execution is blocked, use `Launch.cmd`; do not change execution policy or security settings. The installer does not overwrite an existing destination or create a login item.

Click the amount to expand. The title bar supports dragging and minimizing to the taskbar; restore from the taskbar. The window stays on top and remembers position and language. Monthly/model/tier filters show collected records and input/output/cache shares. Select a model to inspect recorded tiers and effective unit rates. Values are API equivalents, not invoices; unpriced records remain explicit.

Click **Connect Codex** to opt in to reading local `%USERPROFILE%\.codex\sessions` and `archived_sessions` every five seconds while open. Only usage metadata is retained. The choice persists; pause or quit to stop. Data stays in `%LOCALAPPDATA%\AI Cost Estimator`. No prompt/reply content is saved or uploaded. No Codex settings are changed.

Current coverage is the same supported local Codex file format as the macOS adapter. Real Windows Codex collection has not yet been manually validated. WSL, custom Codex-home locations, other devices and Claude Code are not connected by this preview. Do not claim otherwise based on passing CI. Windows CI opens the Tk window with synthetic data and tests filters, details, language and shutdown.

Uninstall by quitting and removing the installed tool folder and Start-menu shortcut. Keep the separate data directory unless you explicitly want to delete the ledger.
