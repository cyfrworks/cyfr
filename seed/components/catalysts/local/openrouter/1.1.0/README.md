# OpenRouter Catalyst

Unified access to 400+ AI models through a single API key. Supports chat completions (with streaming), embeddings, model listing, and account info.

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.openrouter`. The binary reads `OPENROUTER_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
