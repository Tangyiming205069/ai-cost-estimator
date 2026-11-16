# Contributing

AI Cost Estimator is maintained by Eric Bush and shares its product home with AI Cost Estimator.

## Agent adapters

We welcome Pi, OpenCode and Hermes adapters. Open an issue identifying the client version, operating system and documented source of request usage. Separate collection from presentation: a footer reads the common ledger rather than maintaining its own monthly total.

Every adapter needs synthetic fixtures and tests for input/cache inclusion, write TTL if applicable, missing fields, exact model ID, source/tier, retries, restart, duplicate delivery, parent/child sessions and month boundaries. Never upload conversations, credentials, database files, original session IDs or private screenshots. Synthetic fixtures must use invented identifiers and content.

Mark coverage as experimental until a real user validates a named client version. Report which calls are missing, including auxiliary calls, compression or remote sessions. Test-only evidence is not real-session evidence. An API key is never required to run the synthetic test suite.

## Boundaries

Follow [the pricing source order](PRICING.md): agent official billing rules first, then exact upstream model prices for missing details. Keep credits, contract charges and API-equivalent estimates separate; document source, date, applicability and unknown fields.

Use supported public hooks, APIs or explicitly authorized local sources. No private UI injection, credential scraping, security changes or global window monitoring. Unknown fields stay unknown; do not copy a similarly named model's price. Price changes need an exact official source, check date, model ID and bucket semantics.

Run `python3 -B -m unittest discover -s tests -v`. UI changes also need a native macOS build and actual window verification. Keep user histories and build products out of Git. Contributions are under the MIT license.
