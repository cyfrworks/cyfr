# Claude Code Catalyst

Claude Code as a brain of the `model/chat@1` contract. The harness runs as itself, with its own tools, its own prompt and the person's own sign-in, in the folder a login entry keeps for the program `claude`; this catalyst drives it over the program's pipe (`cyfr:process/pipe`) and gives it CYFR's tools through `cyfr-stub`, so every action of CYFR's still passes CYFR's gate. The catalyst holds no credential, no route and nothing between runs; CYFR ships nothing of Anthropic's.

## The program

The manifest declares one need, `claude`, of type `login` for the program `claude`, and no other. Its `install` block suggests the row: command `npx -y @anthropic-ai/claude-code@2.1.318`, sign-in `npx -y @anthropic-ai/claude-code@2.1.318 auth login`. The person installs it from the setup plan or the crew entry on the AQUA page, which defines the row, makes the login entry and opens the sign-in terminal; or places a binary and writes the row by hand. The version is the one this catalyst was tested against: the control requests below and the result bound were read from Claude Code 2.1.318.

## How a turn runs

`chat` opens the session the request names: `--resume <id>` when the request carries a `session`, else a new `--session-id <id>`, which the response names as its `session`. Every session starts with

```
-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
--replay-user-messages --strict-mcp-config --permission-prompt-tool stdio
```

and the request's options as `--model`, `--effort`, `--permission-mode` and `--tools`. A running process keeps the flags it started with, and the box attaches to it without applying new ones, so the `session` a response answers records them: `<id>.<fingerprint of the flags>`. A request whose options differ from the ones its session records closes the running process and starts it again with `--resume <id>` and the new flags; the transcript in the kept folder carries the session across. A new process is sent an `initialize` control request carrying the request's `system` as `appendSystemPrompt`, so the harness keeps its own prompt. Each new turn then sets CYFR's tools with an `mcp_set_servers` control request (the answer to a pending ask continues a turn whose tools are set) naming one stdio server, `cyfr`, run as `cyfr-stub` with one tool per argument (a pipe argument is at most 4096 bytes, so the tool list cannot ride on `--mcp-config`). The harness names those tools `mcp__cyfr__<name>`.

This replaces the `--mcp-config <json>` argument the plan first named, as ruled for S3: a pipe argument is at most 4096 bytes (`Prima.LocusBackends`), and the soul's tool list alone is about 20 KB. Two bounds remain. One tool's JSON, as one argument of `cyfr-stub`, is at most 131,071 bytes, the kernel's bound on one argument (`MAX_ARG_STRLEN`, with its NUL). The whole list, as the one `mcp_set_servers` line, is at most 1 MiB, the pipe's bound on a line. A request whose tools pass either bound is refused `invalid_request`, naming the tool or the list's size, before any session is opened. The list is never cut.

The catalyst sends the newest user message and streams the reply's text as `text.delta`. It answers on the first of:

- an ask (`control_request` `can_use_tool`) to run one of CYFR's tools: a `tool_call` named as AQUA names the tool, with `provider_data: {request_id}`, and `stop_reason: tool_call`. The ask stays pending in the harness while CYFR runs the call through its gate. The next `chat`, carrying the `tool_result`, answers the ask with an allow whose `updatedInput` holds CYFR's answer as `result` (or `error` for a refusal), and `cyfr-stub` returns it as the tool's content;
- the turn's `result`: `end_turn` with its usage;
- an error, typed by the contract's refusals.

A run whose answer was lost (a read the box could not answer is `overloaded`, which the loop retries) may have sent its message or its allow already, so every run that attaches to a running session first reads what the session holds unread. Each user message goes under a `uuid` derived from its request, and the harness echoes it back (`--replay-user-messages`). An ask's allow shows in what the harness did after it: it ran the call (a `tool_result` for the call's `tool_use` id), or wrote anything past the ask. When the held lines show the message or the allow arrived, the turn is answered from them and on, and nothing is sent twice: a `control_response` goes for each ask at most once.

The harness's asks for its own tools are answered allow inside its box and shown as a `tool_call.start` and `tool_call.end` pair, by name only. If the program that held an ask has ended when the answer comes, the resumed session receives CYFR's answer as a message instead.

A result past 50,000 characters is cut, with a note naming what was left out: Claude Code takes at most that much from one tool call through `updatedInput` (measured on 2.1.318 for plain and dense text alike: 50,000 characters arrive whole, 50,625 are replaced by its own note that the output was saved to a file).

Lines the session's buffer dropped while unread (past its 8 MiB) may have held an ask or the turn's result, so a read that reports them is a typed `incomplete_stream` naming the loss. The catalyst then closes the session, and the next chat starts the program again resuming from the transcript its folder keeps. A run's first read cannot tell those lines from the ones an earlier run read past, so it counts no loss.

What the pipe answers maps to the contract's refusals: `denied` and `setup_required` (no login entry granted, or the entry, its row or its grant no longer serves, or the folder is past its cap) to `secret_denied`; `busy` and `unavailable` to `overloaded`; a session that ended to `incomplete_stream`; `lost` to `provider_error`; `invalid_request` and `too_large` to `invalid_request`. An error the harness types an assistant message with maps by its type (`authentication_failed` and the account's other refusals to `authentication`, `rate_limit` to `rate_limited`, and so on). No line of the harness's, nothing of its stderr, its folder or its sign-in, reaches the answer.

## What Claude Code answers, and the fallback

`describe` and `models` start the harness in a session of their own, send `initialize`, read its answer and close the session. Claude Code 2.1.318 answers `initialize` with `models`, each `{value, resolvedModel?, displayName, description, supportsEffort?, supportedEffortLevels?, ...}`; with a Claude subscription it listed `default`, `opus`, `fable`, `sonnet`, `haiku` and the full ids of older models, the levels `low`, `medium`, `high`, `xhigh` and `max` on the models that take an effort. From it:

- **model**: an enum of the listed `value`s; `models` answers the same listing as `{id: value, name: displayName}`.
- **effort**: an enum of the levels any listed model takes, in the harness's order.

What the harness does not list ships here:

- **permission_mode**: `default`, `acceptEdits` and `plan`, the modes under which the harness still asks before it runs one of CYFR's tools (`bypassPermissions`, `dontAsk` and `auto` would run or refuse those calls without the ask).
- **tools**: a string, the harness's own tools as `--tools` takes them (comma-separated, empty for none).
- **context_window**: 200,000 for any model, on `describe` with a `model`; the harness lists no window and manages its own context.

With no login entry granted yet (the pipe answers `denied`), `describe` answers deliberately with the two options it does not need the listing for. Any other failure to list, such as an open whose answer was lost or a program that ends before it answers `initialize`, keeps its contract error, and `models` answers the pipe's refusal.

## Building

`scripts/build-seed-guest.sh seed/components/catalysts/local/claude-code/0.1.0` builds `catalyst.wasm` and writes `src/build.stamp`; `cargo test` in `src/` runs the contract and protocol tests on the host target, against a scripted pipe and the shared vectors `tests/fixtures/model_chat.json`. `tests/locus-backends-image/claude_code.py` drives the built catalyst against a fake harness in the backends image.
