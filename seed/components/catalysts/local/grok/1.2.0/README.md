# Grok Catalyst

xAI Grok API — chat, vision, image generation, and embeddings.

## `model/chat@1`

The catalyst declares the model contract (`"contracts": ["model/chat@1"]` in its manifest) and answers its three operations on the same `run` export: `chat` (a contract request in, a contract response out), `describe` (capabilities, answered without a key) and `models` (the bound key's reachable models, normalized). The shapes are documented once, in `component-guide.md` under "Model catalysts"; the mapping onto this provider's API lives in `src/src/chat.rs`, with host-target tests (`cargo test` in `src/`).

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.grok`. The binary reads `GROK_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
