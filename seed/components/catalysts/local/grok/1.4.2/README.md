# Grok Catalyst

xAI Grok API — chat, vision, image generation, and embeddings.

## `model/chat@1`

The catalyst declares the model contract (`"contracts": ["model/chat@1"]` in its manifest) and answers its three operations on the same `run` export: `chat` (a contract request in; the answer streams as the contract's events on the execution's event stream through `cyfr:emit/events`, and the whole contract response is answered), `describe` (capabilities, answered without a key; with a `model` param that names a model by its id or an id xAI serves it under, that model's `context_window`, from a table in `src/src/chat.rs` (the Models API reports none, and xAI documents no output ceiling), or an `unknown_model` refusal) and `models` (the bound key's reachable models, normalized). The shapes are documented once, in `component-guide.md` under "Model catalysts"; the mapping onto this provider's API lives in `src/src/chat.rs` and the stream reading in `src/src/stream.rs`, with host-target tests (`cargo test` in `src/`).

## Credentials

The catalyst declares one need, `api_key`, served from a vault entry the operator binds at consent: on the console's Vault page, or with `cyfr profile grant catalyst:local.grok`. Every request the binary makes names that need as its `connection`. CYFR attaches the bound key as the need's attach rule places it (`Authorization: Bearer {value}`), and only to a request the binding's destination admits; the binary never holds the key or learns the vault entry's name.
