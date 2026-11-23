# AI Cost Estimator

**What is your AI plan really worth?** An open-source AI usage tracker from [AI Cost Estimator](https://ai-cost-estimator.com).

[Website](https://ai-cost-estimator.com/companion) · [Install](INSTALL.md) · [Contribute](CONTRIBUTING.md) · [MIT license](LICENSE)

Keep a compact native window beside your coding agent. See this month's API-equivalent cost, then expand into model breakdowns, input/output/cache token shares and recent individual requests. The menu bar shows the amount without an extra product abbreviation. The original website's estimator, pricing catalog and tokenizer remain separate and available.

Where do the numbers come from? See [Usage sources and accuracy](#usage-sources-and-accuracy) for the exact inputs, calculations and verification limits.

## Preview release · v0.3.2

- Native Liquid Glass on macOS 26; 188 × 40 pt floating window, draggable and position-restoring.
- Select and highlight an inclusive date range in one calendar, with Last 7 days, Last 30 days, This month, Last month and All shortcuts; agent, exact-model and recorded-speed filters; input, cache read/write and output accounting. Agent choices come only from recorded sources in the selected period; a single source is shown without a redundant dropdown.
- Select API value, tokens, requests and cumulative value as distinct colored lines in one daily chart, or turn every line off. Multiple selected metrics use a relative scale (each metric’s period peak is 100); hover shows original values, and a single metric uses its original unit. Chart amounts display two decimals while calculations and CSV retain precision. Optional token components show disjoint input/output/cache usage. Model tables, charts and daily CSV exports share the selected date, agent, model and tier filters. Days without collected requests are not evidence of no usage; unpriced amounts stay blank.
- Daily aggregates are built once per local process and updated only for newly appended records. Period switches combine those aggregates without repricing history. Selection requests are coalesced while commands remain ordered; the displayed period stays labeled during updates.
- Standard / Fast breakdowns show request shares, unchanged token counts and API values. Fast uses its verified official rate; absent a verified Fast rate, the same model’s Standard price is visibly labeled as a reference.
- Opt-in local Codex history sync, filesystem notifications plus a five-second fallback; the UI refreshes every second. Records appear after the client writes request usage, not as a per-token stream.
- Recent usage can be grouped by conversation or viewed request by request. Optional local Codex titles are matched by the existing conversation hash in both views. Missing identities remain unassociated; missing titles use stable markers rather than changing row numbers.
- Unknown prices or required fields remain unpriced; zero is never used as a substitute for unknown.
- English / 中文, switchable in the native header; your choice is remembered.
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

## Usage sources and accuracy

**Token counts are read from recorded request usage, not estimated from conversation length. Dollar amounts are a separate API-equivalent calculation.** Accurate copying of a local record does not establish complete account coverage or agreement with a provider's invoice.

### What the Codex history adapter actually reads

After opt-in, [history_sync.py](LMCost/history_sync.py) scans the default local directories `~/.codex/sessions` and `~/.codex/archived_sessions`, including supported `.jsonl` and `.jsonl.zst` files. The current UI does not automatically follow a custom `CODEX_HOME`. OpenAI documents Codex's [local state location](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations); the exact collection paths and parser used by this tool are visible in its source.

[history_import.py](LMCost/history_import.py) selects per-response `token_usage_record` entries and their `payload.usage`. It does **not** add thread/turn cumulative totals or legacy `event_msg/token_count` snapshots to request totals. This is a version-specific local file adapter, not a promised stable public API. The source-status table above states which formats and connections have been locally validated.

The local Codex record has flat fields; the [Responses API usage schema](https://developers.openai.com/api/reference/resources/responses/methods/retrieve) has nested detail fields. The official documentation explains the token categories; it is not evidence that this app queries that API or retrieves an account-wide usage export.

| Local record field | How this tool uses it |
| --- | --- |
| `usage.input_tokens` | Total input for the request, including its cached portions. The displayed ordinary-input bucket subtracts cached reads and, when independently accounted for, cache writes. |
| `usage.cached_input_tokens` | Recorded cache-read tokens. They are a subset of total input, not extra input to add on top. |
| `usage.cache_write_input_tokens` | Recorded cache-write count when supplied. Models with separate write pricing require the applicable write buckets; models without a separate write premium retain writes inside ordinary input. |
| `usage.output_tokens` | Recorded output, including reasoning tokens. It is not just the visible answer or the number of tokens written to files. |
| `usage.reasoning_output_tokens` | Checked against output when supplied as a valid count; never added to output again. |
| `usage.total_tokens` | Checked against input plus output when supplied as a valid count. The displayed known-token total sums disjoint buckets and is flagged incomplete if required counts are missing. |

The inclusion of cached tokens in input, and reasoning tokens in output, matches [OpenAI's usage explanation](https://developers.openai.com/api/docs/guides/agents-api/observability#understand-token-usage). Input can include instructions, history and tool results on every request, so summed usage can greatly exceed the text a person typed. Repeated processing of shared context is still request usage.

For example, a **synthetic** request with 12,000 input, 4,000 cached input, zero cache writes and 2,000 output (including 1,500 reasoning) gives 8,000 ordinary input + 4,000 cache read + 0 cache write + 2,000 output = **14,000 tokens**. Neither cached input nor reasoning is counted twice. This example is covered by [test_history.py](tests/test_history.py).

### What does cache-write zero mean?

There are different cases, and they should not be confused:

- An explicit zero in the source record is the client's reported zero. It does not independently prove that the provider performed no physical cache writes.
- For a model with no separate write premium, the current displayed write bucket is zero by design; those tokens remain in ordinary input. It is not a measurement of the provider's cache infrastructure.
- If an independently required write field is absent, the history adapter keeps it unknown and leaves affected requests unpriced. An aggregate sums known portions; check its incomplete-token state or the daily CSV's `incomplete_tokens`, rather than treating a zero known subtotal as proof of complete zero usage.

Cache reads and writes concern model prompt caching, not this Mac's disk I/O. Caching behavior and charges vary by model; see [OpenAI's prompt-caching documentation](https://developers.openai.com/api/docs/guides/prompt-caching). The actual conversion and completeness rules are in [engine.py](LMCost/engine.py), particularly `codex_event` and `token_mix`.

### What is checked, and what remains uncertain?

The collector hashes stable response IDs and uses an SQLite primary key to prevent the same recorded response being imported twice. It skips inherited records belonging to another thread. Missing reliable identity, missing usage or unusable timestamps are skipped and counted in import/sync diagnostics. Missing model, tier or required pricing information leaves affected requests unpriced; available token counts can still be shown.

Required token buckets are validated as nonnegative integers. The converter checks that cached input does not exceed total input and that independently accounted read/write buckets fit within input. Usable optional totals and reasoning counts are checked for consistency. Records failing these checks are not presented as fully priced requests; absent optional counters cannot provide an independent cross-check.

Model and tier metadata come from the matching local turn context and recorded settings. They describe client configuration, not independent confirmation of the model/tier ultimately served after routing. Other devices, unwritten or deleted records, unsupported formats and collection gaps are outside coverage. The current tool does not reconcile against a provider bill.

To inspect or reproduce the checks:

- [History tests](tests/test_history.py) cover field projection, plain/compressed files, inherited records, missing fields and duplicate imports. [Sync tests](tests/test_history_sync.py) cover appends, rotation and restart. [Analytics tests](tests/test_analytics.py) check daily/model/conversation totals against request-level values; [billing tests](tests/test_bill.py) cover pricing and tier partitions. Run `python3 -B -m unittest discover -s tests -v`.
- For a local spot-check, compare one original per-response `usage` object with its sanitized ledger buckets using the mapping above. Compare the same request or the same date range, timezone and filters; a context-window counter or cumulative thread snapshot is a different quantity. Keep private session files local and use synthetic fixtures for public bug reports.
- Passing tests establishes the behavior of this adapter and its arithmetic. It does not certify the provider's upstream accounting, guarantee every installation's coverage, or justify a statistical confidence percentage. Codex history has been exercised locally; the experimental Claude Code receiver and optional Codex hook do not have the same real-session validation.

Source descriptions reviewed on **2026-11-23**. This does not refresh the dated pricing verification in [PRICING.md](PRICING.md) or [pricing.json](LMCost/pricing.json).

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
bash scripts/test-date-range.sh
bash scripts/test-trend-scale.sh
bash build.sh
```

87 synthetic ledger and metadata tests cover pricing, partial data, deduplication, restart, month boundaries, history append/rotation, privacy filtering, title matching and notification-driven refresh. Seven chart tests cover empty selections, mixed-unit scales, missing values and precision. Eight calendar tests cover two-click selection, cross-month/year ranges, reversed endpoints, leap dates and timezone transitions. Nine native geometry tests cover expanded dragging, compact placement, repeated resize cycles and screen boundaries. Native UI changes also require real-window checks. Never use private histories as test fixtures. Current source retains the internal `LMCost/` directory name for continuity; the public product is AI Cost Estimator.

The macOS UI is in `LMCost/App.swift`; the shared Python ledger and pricing engine are in `engine.py`; adapters are in `history_import.py`, `history_sync.py`, `codex_hook.py` and `subscriptions.py`. A richer cross-agent adapter API and native CLI footers are future work, not included features.

## Windows source preview

See [Windows setup](windows/README.md). A compact always-on-top Tk window uses the same ledger and exact-model pricing engine, with monthly/model/tier filters, token shares and request-tier details. Collection requires explicit consent. Windows validation uses synthetic records; real Windows Codex sessions, WSL and Claude Code remain unverified.

The macOS expanded window starts with a monthly value overview. Detailed model/token tables are one click away. The overview shows recorded tokens, request counts and active days below the subscription comparison. Remaining subscription allowance and historical reset counts are not available and are not inferred from token usage. Both window sizes use native Liquid Glass on macOS 26.

Drag the expanded window by its title. After moving it, collapsing anchors the compact window at that new top-left position, and reopening the app restores it. Automatic screen-edge fitting during expansion does not move the saved compact position unless you drag the expanded window.

The Connections screen lists only sources already connected or represented in the local ledger; other adapters are available through Add connection. A successful explicit plan lookup caches only the projected plan metadata locally, so the last identified plan survives restart. Refresh the lookup after changing accounts or plans; the broad Pro label does not identify an exact monthly price tier.
