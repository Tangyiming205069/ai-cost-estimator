# Repository instructions

Product: **AI Cost Companion**, the open-source desktop companion to AI Cost Estimator. Public credit: Eric Bush. Keep the original website estimator usable; companion work must not replace its existing functionality.

## Pricing verification

Read [PRICING.md](PRICING.md) before changing pricing or adding an agent adapter.

- Start at the agent's official pricing/billing documentation. Prefer its applicable token rates. Only then use the exact model provider's official price for missing details.
- Establish currency/credits/subscription/contract units, provider route, model ID, speed, context tier and cache accounting. Do not silently substitute a provider API estimate for actual agent charges.
- Keep sources, verification dates and applicability decisions in `LMCost/pricing.json` and `PRICING.md`. Unknown or incomplete prices remain unpriced. Never fabricate a confidence percentage.
- Require cache-write TTL buckets only when that model's selected rate depends on them. Avoid double-counting cached input, write totals and reasoning tokens.
- Test with synthetic data: official worked examples, threshold boundaries, duplicate delivery, restart, missing fields and model/tier mismatch. A unit test is not evidence of a real agent connection.

## Product interface

Verification workflow, contributor instructions and technical audit notes belong in this repository, not on the product landing page or in the app's normal user flow. Display plain amounts in the compact window and menu bar; do not prefix amounts or token totals with inequality symbols. Keep partial-coverage and unpriced details in the expanded ledger. Show users the amount, monthly/model/token breakdowns, connection status, clickable price sources, and concise estimate/coverage limitations. Do not present the development process as a product feature.

## Privacy and coverage

Only collect after explicit user opt-in. Keep usage metadata on the local device; never persist or publish prompts, responses, secrets, account identifiers or private sessions as fixtures. Preserve existing opt-in settings when updating. No host injection, security changes, login items or global window monitoring.

Codex local history is validated on the development Mac. Claude Code is experimental until a real controlled CLI session is verified. Pi, OpenCode, Hermes and CLI footers are planned. An agent being able to install the app does not imply its usage adapter exists.

Run `python3 -B -m unittest discover -s tests -v`. Native UI changes require a macOS build and real window verification. Keep generated applications, ledgers and private evidence out of Git. Do not claim a build is an installed, connected or notarized release.
