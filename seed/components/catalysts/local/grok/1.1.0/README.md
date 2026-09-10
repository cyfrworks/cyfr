# Grok Catalyst

xAI Grok API — chat, vision, image generation, and embeddings.

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.grok`. The binary reads `GROK_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
