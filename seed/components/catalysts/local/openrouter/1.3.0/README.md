# OpenRouter Catalyst

Unified access to 400+ AI models through a single API key. Supports chat completions (with streaming), embeddings, model listing, and account info.

## `model/chat@1`

The catalyst declares the model contract (`"contracts": ["model/chat@1"]` in its manifest) and answers its three operations on the same `run` export: `chat` (a contract request in; the answer streams as the contract's events on the execution's event stream through `cyfr:emit/events`, and the whole contract response is answered), `describe` (capabilities, answered without a key; with a `model` param, that model's `context_window` and `max_output_tokens`, from the model listing's, which takes the key, or an `unknown_model` refusal) and `models` (the bound key's reachable models, normalized). The shapes are documented once, in `component-guide.md` under "Model catalysts"; the mapping onto this provider's API lives in `src/src/chat.rs` and the stream reading in `src/src/stream.rs`, with host-target tests (`cargo test` in `src/`).

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.openrouter`. The binary reads `OPENROUTER_API_KEY` through `cyfr:vault/read`; it never learns the vault entry's name.
