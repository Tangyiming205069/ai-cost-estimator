# Pricing evidence and source order

Agent billing rules reviewed on **2026-11-16**. The API rate snapshot has its own date in `LMCost/pricing.json`; reviewing an agent's billing policy does not renew every model's verification date.

1. Start with the agent's official pricing and billing documentation. Determine units and conditions: subscription, credits, API tokens, organization contract, speed, context and provider route.
2. Prefer applicable token prices published there. For missing details, follow its official references to the actual model/provider. Match exact model IDs; an unofficial aggregator or similarly named model is insufficient.
3. Keep agent charges, credits and the separate API-equivalent comparison distinct. A known but inapplicable or incomplete agent price cannot be replaced with a model price and labeled an actual bill. Unknown pricing stays unpriced.
4. Record source links, dates, selected basis and missing fields. Test cache inclusion, TTLs only where they affect price, thresholds and speed modifiers with synthetic requests. Never add reasoning twice when it is included in output.

| Agent | Official starting point | Verified decision for this release |
| --- | --- | --- |
| Codex | [Official pricing and token rates](https://learn.chatgpt.com/docs/pricing#token-rates) | Credit billing has no separate cache-write fee. API-key billing follows [OpenAI API prices](https://developers.openai.com/api/docs/pricing). The current dollar display is an API-equivalent reference, not credits consumed or subscription charges. Included usage and contract terms cannot be reconstructed from token counts alone. |
| Claude Code | [Costs and organization rates](https://code.claude.com/docs/en/costs), [Fast mode rates](https://code.claude.com/docs/en/fast-mode#understand-the-cost-tradeoff) | The agent publishes Fast input/output rates and can report costs using organization `modelPricing`. Its session estimate is not a subscription invoice. Standard and cache details are verified against [Anthropic's rate card](https://platform.claude.com/docs/en/about-claude/pricing). This release uses first-party global API list rates; it does not retrieve private contracts. |

The supported model table and cache accounting remain explicit in [pricing.json](LMCost/pricing.json). Rates are not fetched live by the app. Historical months use this dated reference snapshot, not reconstructed historical prices. Promotions must be rechecked at expiry. Local model/tier metadata does not prove which backend tier actually served a request.

Pi, OpenCode, Hermes and other adapters are not implemented. Before adding one, repeat this source review for the actual agent and provider route. Installation by an agent does not imply its usage collection is supported. No confidence percentage is invented: evidence is stated as official rate verified, usage fields complete or incomplete, and coverage validated or experimental.
