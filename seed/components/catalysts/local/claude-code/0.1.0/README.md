# Claude Code Catalyst

Claude Code as a brain of the `model/chat@1` contract. The harness runs as itself, with its own tools, its own prompt and the person's own sign-in, in the folder a login entry keeps for the program `claude`; this catalyst drives it over the program's pipe (`cyfr:process/pipe`) and gives it CYFR's tools through `cyfr-stub`, so every action of CYFR's still passes CYFR's gate. The catalyst holds no credential, no route and nothing between runs; CYFR ships nothing of Anthropic's.

## The program

The manifest declares one need, `claude`, of type `login` for the program `claude`, and no other. Its `install` block suggests the row: command `npx -y @anthropic-ai/claude-code@2.1.318`, sign-in `npx -y @anthropic-ai/claude-code@2.1.318 auth login`. The person installs it from the setup plan or the crew entry on the AQUA page, which defines the row, makes the login entry and opens the sign-in terminal; or places a binary and writes the row by hand. The version is the one this catalyst was tested against: the control requests below and the result bound were read from Claude Code 2.1.318.

## How a turn runs

`chat` opens the session the request names: `--resume <id>` when the request carries a `session`, else a new `--session-id <id>`, which the response names as its `session`. Every session starts with

```
-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
--strict-mcp-config --permission-prompt-tool stdio
```

and the request's options as `--model`, `--effort`, `--permission-mode` and `--tools`. A new process is sent an `initialize` control request carrying the request's `system` as `appendSystemPrompt`, so the harness keeps its own prompt. Each turn then sets CYFR's tools with an `mcp_set_servers` control request naming one stdio server, `cyfr`, run as `cyfr-stub` with one tool per argument (a pipe argument is at most 4096 bytes, so the tool list cannot ride on `--mcp-config`). The harness names those tools `mcp__cyfr__<name>`.

The catalyst sends the newest user message and streams the reply's text as `text.delta`. It answers on the first of:

- an ask (`control_request` `can_use_tool`) to run one of CYFR's tools: a `tool_call` named as AQUA names the tool, with `provider_data: {request_id}`, and `stop_reason: tool_call`. The ask stays pending in the harness while CYFR runs the call through its gate. The next `chat`, carrying the `tool_result`, answers the ask with an allow whose `updatedInput` holds CYFR's answer as `result` (or `error` for a refusal), and `cyfr-stub` returns it as the tool's content;
- the turn's `result`: `end_turn` with its usage;
- an error, typed by the contract's refusals.

The harness's asks for its own tools are answered allow inside its box and shown as a `tool_call.start` and `tool_call.end` pair, by name only. If the program that held an ask has ended when the answer comes, the resumed session receives CYFR's answer as a message instead.

A result past 50,000 characters is cut, with a note naming what was left out: Claude Code takes at most that much from one tool call through `updatedInput` (measured on 2.1.318 for plain and dense text alike: 50,000 characters arrive whole, 50,625 are replaced by its own note that the output was saved to a file).

What the pipe answers maps to the contract's refusals: `denied` and `setup_required` (no login entry granted, or the entry, its row or its grant no longer serves, or the folder is past its cap) to `secret_denied`; `busy` and `unavailable` to `overloaded`; a session that ended to `incomplete_stream`; `lost` to `provider_error`; `invalid_request` and `too_large` to `invalid_request`. An error the harness types an assistant message with maps by its type (`authentication_failed` and the account's other refusals to `authentication`, `rate_limit` to `rate_limited`, and so on). No line of the harness's, nothing of its stderr, its folder or its sign-in, reaches the answer.

## What Claude Code answers, and the fallback

`describe` and `models` start the harness in a session of their own, send `initialize`, read its answer and close the session. Claude Code 2.1.318 answers `initialize` with `models`, each `{value, resolvedModel?, displayName, description, supportsEffort?, supportedEffortLevels?, ...}`; with a Claude subscription it listed `default`, `opus`, `fable`, `sonnet`, `haiku` and the full ids of older models, the levels `low`, `medium`, `high`, `xhigh` and `max` on the models that take an effort. From it:

- **model**: an enum of the listed `value`s; `models` answers the same listing as `{id: value, name: displayName}`.
- **effort**: an enum of the levels any listed model takes, in the harness's order.

What the harness does not list ships here:

- **permission_mode**: `default`, `acceptEdits` and `plan`, the modes under which the harness still asks before it runs one of CYFR's tools (`bypassPermissions`, `dontAsk` and `auto` would run or refuse those calls without the ask).
- **tools**: a string, the harness's own tools as `--tools` takes them (comma-separated, empty for none).
- **context_window**: 200,000 for any model, on `describe` with a `model`; the harness lists no window and manages its own context.

When the harness cannot be asked (no login entry granted yet), `describe` answers with the two options it does not need the listing for, and `models` answers the pipe's refusal.

## Building

`scripts/build-seed-guest.sh seed/components/catalysts/local/claude-code/0.1.0` builds `catalyst.wasm` and writes `src/build.stamp`; `cargo test` in `src/` runs the contract and protocol tests on the host target, against a scripted pipe and the shared vectors `tests/fixtures/model_chat.json`. `tests/locus-backends-image/claude_code.py` drives the built catalyst against a fake harness in the backends image.
