# AI Cost Estimator

**What is your AI plan really worth?** An open-source AI usage tracker from [AI Cost Estimator](https://ai-cost-estimator.com).

[Website](https://ai-cost-estimator.com/companion) · [Install](INSTALL.md) · [Contribute](CONTRIBUTING.md) · [MIT license](LICENSE)

Keep a compact native window beside your coding agent. See this month's API-equivalent cost, then expand into model breakdowns, input/output/cache token shares and recent individual requests. The menu bar shows the amount without an extra product abbreviation. The original website's estimator, pricing catalog and tokenizer remain separate and available.

## Preview release · v0.3.0

- Native Liquid Glass on macOS 26; 188 × 40 pt floating window, draggable and position-restoring.
- Monthly or inclusive custom-date ranges, agent, exact-model and recorded-speed filters; input, cache read/write and output accounting. Agent choices come only from recorded sources in the selected month; a single source is shown without a redundant dropdown.
- Daily line charts for API value, cumulative API value, requests and disjoint input/output/cache tokens. Model tables, charts and daily CSV exports share the selected date, agent, model and tier filters. Days without collected requests are not evidence of no usage; unpriced amounts stay blank.
- Standard / Fast breakdowns show request shares, unchanged token counts and API values. Fast uses its verified official rate; absent a verified Fast rate, the same model’s Standard price is visibly labeled as a reference.
- Opt-in local Codex history sync, filesystem notifications plus a five-second fallback; the UI refreshes every second. Records appear after the client writes request usage, not as a per-token stream.
- Recent usage can be grouped by conversation or viewed request by request. Optional local Codex titles are matched by the existing conversation hash in both views. Missing identities remain unassociated; missing titles use stable markers rather than changing row numbers.
- Unknown prices or required fields remain unpriced; zero is never used as a substitute for unknown.
- English / 中文, switchable in Settings or the window menu; your choice is remembered.
- Pause and resume, amount/token display choices, and Control–Option–L hide/show.
- Collection is off by default. Demo data is only shown when explicitly selected.

| Source | Actual status |
|---|---|
| Codex local history | Verified on an Apple silicon Mac, with the installed Codex 0.166.0-alpha.5.1 data format. Active and archived records containing per-response usage are supported. Other versions need validation. |
| Codex PostModelRequest | Optional receiver and setup fragment implemented; real desktop delivery has not been validated. No existing hook config is overwritten. |
| Claude Code | Experimental local OTel receiver and opt-in new-session flow. Real sessions have not been validated; it is not complete support. |
| Pi, OpenCode, Hermes, Copilot | Planned; no working adapter is claimed. |

## Install

Read [INSTALL.md](INSTALL.md). This release is built locally from source and is not a notarized downloadable binary. Requirements: Apple silicon, macOS 26+, Apple Swift SDK 26+ and Python 3.14+. The installer never installs dependencies or changes security settings. The native app supports English and Chinese. A Windows source preview is available; Linux and terminal displays are not released yet. Windows real-session collection has not been manually validated. The shared ledger and pricing engine are open source, and platform contributions are welcome.

```bash
bash scripts/install.sh --check
bash scripts/install.sh
```

The second command builds and installs in `~/Applications/AI Cost Estimator.app` and opens it. Connect Codex explicitly in the app to start collection. Installing does not enable collection. A custom destination and `--no-open` are supported. Existing apps are never overwritten.

## Privacy and coverage

The ledger stays on this computer. It retains usage timestamps, model/provider fields, disjoint token buckets, hashed request/conversation identifiers and accounting completeness state. It does not save prompts, responses, credentials or account identity, and does not upload usage. Codex transcript lines are streamed locally and discarded, retaining only the required metadata.

Conversation titles are separately opt-in. The official local Codex app-server `thread/list` reads explicit thread names with state-only metadata queries, including archived chats. Only the requested hash-to-name mappings stay in memory; titles and raw thread IDs are not written into the usage ledger, exported CSVs or app files. Prompt previews are discarded and never used as fallback titles. Names refresh at most once per minute unless you request a refresh or a newly recorded conversation needs a title. Settings can turn this off. The installed Codex 0.167.0-alpha.3.2 title protocol was verified locally; unsupported versions keep titles unavailable. See the [official app-server documentation](https://learn.chatgpt.com/docs/app-server#list-threads-with-pagination--filters).

New installations store data in `~/Library/Application Support/AI Cost Estimator`. Existing AI Cost Companion Application Support data or a legacy ledger beside the app is reused in place if present, preserving existing opt-in preferences. No login item is created. Quit or pause to stop collection; reopening resumes only a previously authorized connection.

Records from other devices, unsynced cloud sessions, deleted history, unsupported old formats and collection gaps are not included. Forked/inherited requests and retries require stable identities to avoid double counting. Parent totals must not be added again to child requests.

## Pricing is an estimate

Pricing review starts with each agent's official billing documentation, then the exact model provider for missing token-rate details. [Source policy and verified decisions](PRICING.md) distinguish credits, subscription charges and API-equivalent references.

This is an **API-equivalent estimate, not an invoice, subscription charge or guaranteed saving**. Prices are the explicit, dated first-party reference snapshot in [pricing.json](LMCost/pricing.json), with source URLs and exact model IDs. Historical usage is evaluated using that snapshot, not reconstructed historical rates. Configured model/tier metadata cannot prove there was no provider-side routing fallback. Tools, tax and region surcharges are not included.

Input/cache relationships and write TTL requirements are model-specific. Reasoning already included in output is not added again. Only complete, supported events are priced. Missing subscription metadata is left unknown; optional plan recognition requires separate consent and is a reference, not actual payment history.

## Develop

```bash
python3 -B -m unittest discover -s tests -v
bash scripts/test-window-placement.sh
bash build.sh
```

85 synthetic ledger and metadata tests cover pricing, partial data, deduplication, restart, month boundaries, history append/rotation, privacy filtering, title matching and notification-driven refresh. Nine native geometry tests cover expanded dragging, compact placement, repeated resize cycles and screen boundaries. Native UI changes also require real-window checks. Never use private histories as test fixtures. Current source retains the internal `LMCost/` directory name for continuity; the public product is AI Cost Estimator.

The macOS UI is in `LMCost/App.swift`; the shared Python ledger and pricing engine are in `engine.py`; adapters are in `history_import.py`, `history_sync.py`, `codex_hook.py` and `subscriptions.py`. A richer cross-agent adapter API and native CLI footers are future work, not included features.

## Windows source preview

See [Windows setup](windows/README.md). A compact always-on-top Tk window uses the same ledger and exact-model pricing engine, with monthly/model/tier filters, token shares and request-tier details. Collection requires explicit consent. Windows validation uses synthetic records; real Windows Codex sessions, WSL and Claude Code remain unverified.

The macOS expanded window starts with a monthly value overview. Detailed model/token tables are one click away. The overview shows recorded tokens, request counts and active days below the subscription comparison. Remaining subscription allowance and historical reset counts are not available and are not inferred from token usage. Both window sizes use native Liquid Glass on macOS 26.

Drag the expanded window by its title. After moving it, collapsing anchors the compact window at that new top-left position, and reopening the app restores it. Automatic screen-edge fitting during expansion does not move the saved compact position unless you drag the expanded window.

The Connections screen lists only sources already connected or represented in the local ledger; other adapters are available through Add connection. A successful explicit plan lookup caches only the projected plan metadata locally, so the last identified plan survives restart. Refresh the lookup after changing accounts or plans; the broad Pro label does not identify an exact monthly price tier.
