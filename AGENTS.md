# Repository instructions

Product: **AI Cost Estimator**, the open-source AI usage app from ai-cost-estimator.com. Canonical public repository: `Tangyiming205069/ai-cost-estimator`. Public credit: Eric Bush. Keep the original website estimator usable; companion work must not replace its existing functionality.

## Pricing verification

Read [PRICING.md](PRICING.md) before changing pricing or adding an agent adapter.

- Start at the agent's official pricing/billing documentation. Prefer its applicable token rates. Only then use the exact model provider's official price for missing details.
- Establish currency/credits/subscription/contract units, provider route, model ID, speed, context tier and cache accounting. Do not silently substitute a provider API estimate for actual agent charges.
- Keep sources, verification dates and applicability decisions in `LMCost/pricing.json` and `PRICING.md`. Unknown or incomplete prices remain unpriced. Never fabricate a confidence percentage.
- Require cache-write TTL buckets only when that model's selected rate depends on them. Avoid double-counting cached input, write totals and reasoning tokens.
- Test with synthetic data: official worked examples, threshold boundaries, duplicate delivery, restart, missing fields and model/tier mismatch. A unit test is not evidence of a real agent connection.

## Product interface

Verification workflow, contributor instructions and technical audit notes belong in this repository, not on the product landing page or in the app's normal user flow. Display plain amounts in the compact window and menu bar; do not prefix amounts or token totals with inequality symbols. Position the product as an open-source AI usage tool; identify macOS as locally verified and Windows as a source preview, without claiming real Windows agent coverage before validation. Language switching belongs in the native app; do not infer a website localization request. English and Chinese must display the same ledger and preserve collection consent. Keep partial-coverage and unpriced details in the expanded ledger. Show users the amount, monthly/model/token breakdowns, connection status, clickable price sources, and concise estimate/coverage limitations. Do not present the development process as a product feature.

## Privacy and coverage

Only collect after explicit user opt-in. Keep usage metadata on the local device; never persist or publish prompts, responses, secrets, account identifiers or private sessions as fixtures. Preserve existing opt-in settings when updating. No host injection, security changes, login items or global window monitoring.

Codex local history is validated on the development Mac. Claude Code is experimental until a real controlled CLI session is verified. Pi, OpenCode, Hermes and CLI footers are planned. An agent being able to install the app does not imply its usage adapter exists.

Run `python3 -B -m unittest discover -s tests -v`. Native UI changes require a macOS build and real window verification. Keep generated applications, ledgers and private evidence out of Git. Do not claim a build is an installed, connected or notarized release.

Fast requests use verified exact-model Fast API prices; if none is verified, use the same model’s Standard official price with a visible Standard-reference label. Do not infer unavailable tier information or multiply tokens/amounts by subscription-limit multipliers. Keep tier filters and subtotal breakdowns consistent with the unchanged raw request counts.

Agent filters must be derived from actual recorded sources in the selected month. One source is a static label; show All only when multiple recorded sources exist. Never populate filters from a list of supported or planned adapters.

Windows source lives in `LMCost/windows_app.py`; entry and per-user installer are in `windows/`. Run the Windows CI GUI smoke with synthetic data. Do not enable collection or change execution policy during installation. WSL and Claude Code adapters are not exposed by the Windows UI.
