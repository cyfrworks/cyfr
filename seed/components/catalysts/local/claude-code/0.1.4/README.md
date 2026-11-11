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

and the request's options as `--model`, `--effort`, `--permission-mode` and `--tools`. A running process keeps the flags it started with, and the box attaches to it without applying new ones, so the `session` a response answers records them: `<id>.<fingerprint of the flags>`. A request whose options differ from the ones its session records closes the running process and starts it again with `--resume <id>` and the new flags; the transcript in the kept folder carries the session across. A new process is sent an `initialize` control request carrying the request's `system` as `appendSystemPrompt`, so the harness keeps its own prompt. Each new turn then sets CYFR's tools with an `mcp_set_servers` control request (the answer to a pending ask continues a turn whose tools are set) naming one stdio server, `cyfr`, run as `cyfr-stub` with one tool per argument (a pipe argument is at most 4096 bytes, so the tool list cannot ride on `--mcp-config`). The harness names those tools `mcp__cyfr__<name>`.

This replaces the `--mcp-config <json>` argument the plan first named, as ruled for S3: a pipe argument is at most 4096 bytes (`Prima.LocusBackends`), and the soul's tool list alone is about 20 KB. Two bounds remain. One tool's JSON, as one argument of `cyfr-stub`, is at most 131,071 bytes, the kernel's bound on one argument (`MAX_ARG_STRLEN`, with its NUL). The whole list, as the one `mcp_set_servers` line, is at most 1 MiB, the pipe's bound on a line. A request whose tools pass either bound is refused `invalid_request`, naming the tool or the list's size, before any session is opened. The list is never cut.

The catalyst sends the newest user message and streams the reply's text as `text.delta`. It answers on the first of:

- an ask (`control_request` `can_use_tool`) to run one of CYFR's tools: a `tool_call` named as AQUA names the tool, with `provider_data: {request_id, after}` (`after` is the number of the ask's line in the session's output), and `stop_reason: tool_call`. The ask stays pending in the harness while CYFR runs the call through its gate. The next `chat`, carrying the `tool_result`, answers the ask with an allow whose `updatedInput` holds CYFR's answer as `result` (or `error` for a refusal), and `cyfr-stub` returns it as the tool's content. It reads the turn on from the ask's line, so what the harness wrote after the ask, another ask in the same batch among it, is handled as the turn's;
- the turn's `result`: `end_turn` with its usage;
- an error, typed by the contract's refusals.

The harness's asks for its own tools are answered allow inside its box and shown as a `tool_call.start` and `tool_call.end` pair, by name only. If the program that held an ask has ended when the answer comes, the resumed session receives CYFR's answer as a message instead.

A result past 50,000 characters is cut, with a note naming what was left out: Claude Code takes at most that much from one tool call through `updatedInput` (measured on 2.1.318 for plain and dense text alike: 50,000 characters arrive whole, 50,625 are replaced by its own note that the output was saved to a file).

A run that attaches to a running session, other than one answering an ask, first reads past what the session holds unread, which earlier runs, each answered, left behind, and only then sends. Once a run has sent anything, a failure of the pipe interrupts the session. This covers a read or a send the box could not answer, a line lost past the session's 8 MiB buffer while unread, the program ending mid-turn, and the run's time running out. What reached the harness is then unknown, and sending it again could make the harness act twice, so nothing is sent again and the session is closed. The turn answers `provider_error`, which the loop does not retry, saying the session was interrupted. The next message starts the program again with `--resume`, and the transcript its folder keeps carries what happened, a held ask included: the harness holds an error result for it and asks again.

Every refusal of a `chat` carries a `session`, which the host keeps as it keeps a response's (`Prima.Model`), once one exists: the session the run would have answered once the harness has shown the run's turn (its start, its text, an ask or its end), else the one the request named. A first chat interrupted at its budget is therefore resumed by the next message. A new session the harness never showed a turn of carries none, since it may hold no transcript to resume. A turn is bounded by the 30 minutes the manifest consents the catalyst (`caps.limits.timeout`), which is how long the assistant's loop waits for a model call: the catalyst stops at 29, closes a turn still running as interrupted, and its partial work stays in the folder and the transcript. A run's first read cannot tell lines lost from the ones an earlier run read past, so it counts no loss and carries its place past them. The answer to an ask can: it reads on from the ask's line, so lines lost past it interrupt the session as any later read's do.

A session the harness holds no transcript of is refused `unknown_session`, and that refusal carries no session. Claude Code 2.1.318, started with `--resume` of a session its folder does not hold, writes a `result` of no turn (`num_turns: 0`) whose `errors` say `No conversation found with session ID: <id>`, and exits before it reads a line. The catalyst reads that while it waits for the answer to `initialize`, before it sets a tool or sends the message, so nothing of the request ran. It reads it as well when the harness was gone before `initialize` reached it. The session on the pipe is closed. The host forgets the session and asks the same request again without one (`Prima.Model`), which opens a new session; that session holds nothing of the earlier conversation. A harness that ends at its start without those words is an interrupted session, as above.

Before a run sends anything, what the pipe answers maps to the contract's refusals: `denied` and `setup_required` (no login entry granted, or the entry, its row or its grant no longer serves, or the folder is past its cap) to `secret_denied`; `busy` and `unavailable` to `overloaded`, which the loop retries safely since nothing was sent; `lost` to `provider_error`; `invalid_request` and `too_large` to `invalid_request`. An error the harness types an assistant message with maps by its type (`authentication_failed` and the account's other refusals to `authentication`, `invalid_request` and `model_not_found` to theirs). It ends a turn this run already sent to, so no answer of it is a type the loop retries. A rate limit or an overload is `provider_error` naming the reason and asking for the message again later. The harness's turn ended on its side, nothing is closed, and the next message goes on in the session. No line of the harness's, nothing of its stderr, its folder or its sign-in, reaches the answer.

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

`scripts/build-seed-guest.sh seed/components/catalysts/local/claude-code/0.1.4` builds `catalyst.wasm` and writes `src/build.stamp`; `cargo test` in `src/` runs the contract and protocol tests on the host target, against a scripted pipe and the shared vectors `tests/fixtures/model_chat.json`. `tests/locus-backends-image/claude_code.py` drives the built catalyst against a fake harness in the backends image.
