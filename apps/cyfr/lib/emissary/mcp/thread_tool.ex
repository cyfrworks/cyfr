# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ThreadTool do
  @moduledoc """
  Chat on the wire: the `thread` tool, and the `turn` tool beside it.

  Exposes AQUA thread addressing, queuing, history and approvals to
  MCP clients through the thread runner.

  `turn` is the second tool this provider serves: `suspend` sets a turn
  down with every row kept, its runtime released and the thread's claim
  given up, and `recover` takes a suspended or abandoned turn back. The
  provider's `service/0` stays `"thread"` for both, so `system.status`
  and the request log's `routed_to` read one label.

  Every turn-shaped action here **wraps `Aqua.Runner`** — there
  is no second implementation of a turn, and no path that starts one
  without the runner's gates. The rest wrap the domain verbs the console
  itself uses: `create`/`list` are `Arca.ThreadStorage` (how a
  headless client gets an id at all), `follow`/`unfollow` are
  `Arca.ThreadSubscriptionStorage` for the caller alone, and `aloud` is
  `Aqua.Aloud.post/5` with every rule decided there.

  It lives in Emissary rather than beside the runner because the tool
  surface is the transport's, and it calls *into* a domain. `Aqua.ToolSeamTest` keeps the
  arrow pointing this way — the assistant reaches MCP only through
  `Aqua.Ops`, never by owning a provider.

  ## Starting turns

  Start chat turns through the runner so the turn pins a profile and later
  approvals use that same authority. Direct execution of the agent formula
  does not establish this thread state.

  ## Two gates, on different axes

    * **Plane.** `Cyfr.Ops.Catalog.call_external/4` refuses a
      `:guest` context outright, and these actions declare
      `planes: [:external]` so they never appear in-chain. A running agent
      cannot read or post into threads — including other people's in
      the same estate.
    * **Surface.** Every action declares `consent: :interactive`, which the
      registry's dispatch gate holds to
      `Sanctum.Consent.Authz.authorize_interactive/1` — `:oidc` and nothing
      else, so **no API key can drive somebody's chat, a `*` key included**.
      A standing credential is exactly the thing that should not be able to
      speak as a person; the plane gate says nothing about this axis.
      Declared on the annotation rather than checked in the handler so the
      three surfaces that read it cannot drift: dispatch refuses,
      `tools/list` hides the tool from a caller who would be refused, and
      the refusal renders as the typed `consent_class_required` code
      instead of a generic tool error.

  ## Approvals are never skipped

  A client with no way to render a card does not get to decide for the
  person. `send` reports a turn that is waiting, and the card stays
  pending until somebody answers it through `approve` or `decline`.
  """

  @behaviour Cyfr.Ops.Provider

  # The most lines one `aloud` may carry: each one copies bytes into the
  # target estate, so a call moves a slice, never a thread.
  @aloud_max 50

  alias Aqua.{Approvals, Runner, Tape}
  alias Sanctum.Context

  @impl true
  def service, do: "thread"

  # Two tools, one service. The service label is the provider's, so
  # `system.status` and the request log's `routed_to` read one label for
  # both; a tool name and a service name are already different things
  # (`Cyfr.Execution.MCP` answers `"opus"`, `Emissary.MCP.McpServersTool`
  # answers `"emissary"`).
  @impl true
  def tools, do: [definition(), turn_definition()]

  @doc false
  def definition do
    alias Cyfr.Ops.{Arg, Operation}
    # `:external` on every action: a running agent must not be able to
    # read or post into threads, its own included. And
    # `:interactive` on every action: only a person's own session may
    # speak, decide, or read as them — never a standing credential.
    # Advisory: maxLength counts graphemes; the governing bound is
    # the runner's 32 KiB byte check, which every sender passes
    # through (the console included).
    Operation.tool(
      [
        Operation.new(
          "thread",
          "create",
          "Create thread",
          [Arg.new("title", :string, description: "create: the thread's title")],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new("thread", "list", "List thread", [],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "get",
          "Get thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "messages",
          "Messages thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("after_seq", :integer,
              description:
                "events: replay messages after this seq. Omit to start from the beginning."
            ),
            Arg.new("limit", :integer,
              description:
                "events: rows per page (default and ceiling 500). Page by passing the returned cursor as after_seq."
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "send",
          "Send thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("message", :string,
              required: true,
              description: "send: the text to say (at most 32 KiB of text)",
              max: 32768
            ),
            Arg.new("agent", :string,
              description: "send: the agent to address when the text names none"
            ),
            Arg.new(
              "attachments",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("filename", :string, required: true),
                    Arg.new("stored_name", :string, required: true),
                    Arg.new("media_type", :string, required: true),
                    Arg.new("size", :integer, required: true)
                  ]}
               )},
              description: "send: the refs `attach` answered for this message id"
            ),
            Arg.new("client_id", :string,
              description:
                "send: the sender's own id for this send, so a retry answers the same message"
            ),
            Arg.new("id", :string,
              description:
                "send: a pre-minted message id (mint one, attach the files under it, then send)"
            ),
            Arg.new("model", :string, description: "send: a model override for this turn"),
            Arg.new(
              "room",
              {:record,
               [
                 Arg.new("athanor_id", :string, required: true),
                 Arg.new("thread_id", :string, required: true),
                 Arg.new("title", :string),
                 Arg.new("estate", :string)
               ]},
              description:
                "send: the room the sender has open beside this thread (athanor_id, thread_id, title, estate); its newest lines are read for this one turn, never stored"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "attach",
          "Attach thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("message_id", :string,
              required: true,
              description:
                "approve/decline: the approval card; attach: the message the files belong to"
            ),
            Arg.new(
              "files",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("filename", :string, required: true),
                    Arg.new("media_type", :string, required: true),
                    Arg.new("data", :string, required: true)
                  ]}
               )},
              required: true,
              description: "attach: the files as {filename, media_type, data} with base64 data"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "stop",
          "Stop thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "approve",
          "Approve thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("message_id", :string,
              required: true,
              description:
                "approve/decline: the approval card; attach: the message the files belong to"
            ),
            Arg.new("scope", :string,
              description:
                "approve: once | thread | always. decline: once | never. Standing scopes are refused for destructive and external actions.",
              enum: ["once", "thread", "always"]
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "decline",
          "Decline thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("message_id", :string,
              required: true,
              description:
                "approve/decline: the approval card; attach: the message the files belong to"
            ),
            Arg.new("scope", :string,
              description:
                "approve: once | thread | always. decline: once | never. Standing scopes are refused for destructive and external actions.",
              enum: ["once", "never"]
            ),
            Arg.new("reason", :string, description: "decline: why")
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "revoke_grant",
          "Revoke grant thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("agent_name", :string,
              required: true,
              description: "revoke_grant: the agent the standing answer was given for"
            ),
            Arg.new("tool", :string, required: true, description: "revoke_grant: the tool"),
            Arg.new("tool_action", :string,
              required: true,
              description: "revoke_grant: the action"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "restart_for_consent",
          "Restart for consent thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("profile_id", :string,
              nullable: true,
              description: "restart_for_consent: the profile the consent was granted on"
            ),
            Arg.new("revision", :integer,
              nullable: true,
              description: "restart_for_consent: the consent revision granted"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "events",
          "Events thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("after_seq", :integer,
              description:
                "events: replay messages after this seq. Omit to start from the beginning."
            ),
            Arg.new("limit", :integer,
              description:
                "events: rows per page (default and ceiling 500). Page by passing the returned cursor as after_seq."
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "follow",
          "Follow thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "unfollow",
          "Unfollow thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "aloud",
          "Aloud thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("message_ids", {:array, Arg.new(nil, :string)},
              required: true,
              description:
                "aloud: your own messages to copy, in any order — or your assistant's replies to you in your own athanor"
            ),
            Arg.new("target_athanor", :string,
              required: true,
              description: "aloud: the estate to post into (you must be a member)"
            ),
            Arg.new("target_thread", :string,
              required: true,
              description: "aloud: the thread in that estate to post onto"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "delete",
          "Delete thread",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Talk to an agent: open or list threads, send a message, follow the reply, stop a turn, decide the approval cards a turn raises, follow or unfollow a thread, and say one of your own private lines aloud into an estate you belong to. Addressing: in an estate with one person every send starts a turn; with more than one, a send starts a turn only when it names one — @aqua for the estate's assistant, or @<role> for one of its roles. An unaddressed send is people talking: it persists and starts nothing (the result says running: false). A send may carry a pre-minted id with files attached under it, a model, an agent, the sender's own client id, and the room open beside the thread. Wraps the same runner and the same verbs the console drives, with the same gates — this is not a second way to run an agent.",
      title: "Threads"
    )
  end

  @doc false
  def turn_definition do
    alias Cyfr.Ops.{Arg, Operation}
    # `:external` for the reason every `thread` action is: a running agent
    # must not be able to set a turn down or pick one up, its own
    # included. `:interactive` because only a person's own session may
    # move their work, never a standing credential. `standing: false`
    # because neither is something a person pre-answers: every call is a
    # click. And `recover` is deliberately NOT `recovery: :replay_safe` —
    # recovery is never itself replay-safe.
    Operation.tool(
      [
        Operation.new(
          "turn",
          "suspend",
          "Suspend turn",
          [
            Arg.new("thread", :string,
              required: true,
              description: "The thread whose turn to suspend."
            ),
            Arg.new("turn", :string,
              description:
                "suspend: the turn id. A caller that read one suspends exactly that turn, never its successor."
            ),
            Arg.new("reason", :string,
              description: "suspend: recorded on the turn and shown in the transcript.",
              max: 200
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive,
          standing: false
        ),
        Operation.new(
          "turn",
          "recover",
          "Recover turn",
          [
            Arg.new("thread", :string, required: true, description: "The thread."),
            Arg.new("turn", :string,
              required: true,
              description:
                "recover: the turn to resume. Recovery names its turn; there is no \"whatever is there now\"."
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive,
          standing: false
        )
      ],
      description:
        "Move a turn between members: suspend sets it down with every row it has written kept, its runtime capacity released and the thread's claim given up, so any member may pick it up; recover takes a suspended or abandoned turn and carries it on, under a new fence, with the consent head and the capability identity read again. Suspending is not stopping — a stopped turn ends, a suspended one waits. A turn a live member is running is refused rather than taken, and a turn recovered too many times ends uncertain.",
      title: "Turns"
    )
  end

  @impl true
  def handle("thread", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle("turn", %Context{} = ctx, args), do: turn(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  # ---------------------------------------------------------------------------
  # `turn`
  # ---------------------------------------------------------------------------

  defp turn(ctx, %{"action" => "suspend", "thread" => id} = args)
       when is_binary(id) and id != "" do
    opts =
      []
      |> put_opt(:turn, args["turn"])
      |> put_opt(:reason, String.slice(args["reason"] || "", 0, 200))

    case Runner.suspend_turn(ctx, id, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, turn_refusal(reason, id)}
    end
  end

  defp turn(ctx, %{"action" => "recover", "thread" => id, "turn" => turn_id})
       when is_binary(id) and id != "" and is_binary(turn_id) and turn_id != "" do
    case Runner.recover_turn(ctx, id, turn_id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, turn_refusal(reason, id)}
    end
  end

  defp turn(_ctx, %{"action" => "suspend"}),
    do: {:error, {:invalid_argument, "turn.suspend requires a 'thread'"}}

  defp turn(_ctx, %{"action" => "recover"}),
    do: {:error, {:invalid_argument, "turn.recover requires a 'thread' and a 'turn'"}}

  defp turn(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "turn.#{action}"}}
  defp turn(_ctx, _args), do: {:error, {:invalid_argument, "turn requires an 'action'"}}

  # The turn vocabulary on top of the thread one: a turn a live member is
  # running is a conflict, not a refusal; a turn that is not the caller's
  # athanor's is absent, which `translate/2` already answers.
  defp turn_refusal(:busy, _id),
    do: {:conflict, "That turn is running on another member. Try again once it is down."}

  defp turn_refusal(:not_running, _id),
    do: {:conflict, "No turn is running in this thread."}

  defp turn_refusal(:not_suspended, _id),
    do: {:conflict, "That turn is running. Stop or suspend it before recovering it."}

  defp turn_refusal(:recovery_exhausted, _id),
    do:
      {:conflict, "That turn has been recovered too many times and has been ended as uncertain."}

  defp turn_refusal({:superseded, why}, _id), do: {:conflict, why}
  defp turn_refusal(reason, id), do: translate(reason, id)

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  # The interactive-surface gate is NOT here: it is the `consent:
  # :interactive` declaration on every action, enforced by the registry
  # before the handler runs.

  # `create` and `list` name no thread — they are how a headless
  # client gets an id in the first place, which is what makes this the
  # same surface the console has rather than one that assumes it.
  defp dispatch(ctx, %{"action" => "create"} = args) do
    attrs =
      case args["title"] do
        title when is_binary(title) and title != "" -> %{title: title}
        _ -> %{}
      end

    with {:ok, thread} <- Arca.ThreadStorage.create(Sanctum.Context.actor(ctx), attrs) do
      {:ok, render_thread(thread)}
    end
  end

  defp dispatch(ctx, %{"action" => "list"}) do
    case Arca.ThreadStorage.list(Sanctum.Context.actor(ctx)) do
      rows when is_list(rows) ->
        {:ok, %{threads: Enum.map(rows, &render_thread/1), count: length(rows)}}

      {:error, _} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  defp dispatch(ctx, %{"action" => action, "thread" => id} = args)
       when is_binary(id) and id != "" do
    act(action, ctx, id, args)
  end

  defp dispatch(_ctx, _args),
    do: {:error, {:invalid_argument, "thread requires an 'action' and a 'thread'"}}

  # The whole send envelope: the text, a pre-minted id and the refs
  # attached under it, the agent and model, the sender's client id, and
  # the room beside the thread — read here, server-side, into the text
  # the turn reads beside the task and never stored.
  defp act("send", ctx, id, args) do
    text = args["message"]
    attachments = args["attachments"] || []

    cond do
      not is_binary(text) or (String.trim(text) == "" and attachments == []) ->
        {:error, {:invalid_argument, "send requires a non-empty 'message'"}}

      not is_list(attachments) or not Enum.all?(attachments, &is_map/1) ->
        {:error, {:invalid_argument, "send takes 'attachments' as the refs attach answered"}}

      not (is_nil(args["room"]) or is_map(args["room"])) ->
        {:error, {:invalid_argument, "send takes 'room' as an object"}}

      true ->
        message_id =
          case args["id"] do
            mid when is_binary(mid) and mid != "" -> mid
            _ -> Cyfr.UUID7.generate_id("msg")
          end

        opts =
          [id: message_id, attachments: attachments]
          |> put_opt(:client_id, args["client_id"])
          |> put_opt(:model, args["model"])
          |> put_opt(:agent, args["agent"])
          |> put_opt(:room, args["room"])

        case Runner.send_message(ctx, id, text, opts) do
          {:ok, accepted} -> {:ok, Map.merge(accepted, waiting(ctx, id))}
          {:error, reason} -> {:error, refusal(reason, id)}
        end
    end
  end

  defp act("get", ctx, id, _args) do
    with {:ok, thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id) do
      {:ok, Map.merge(render_thread(thread), waiting(ctx, id))}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("messages", ctx, id, args), do: act("events", ctx, id, args)

  # The files a message carries are written under its id before the
  # send names them, so the bytes are the sender's own write.
  defp act("attach", ctx, id, %{"message_id" => message_id, "files" => files})
       when is_binary(message_id) and is_list(files) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         {:ok, decoded} <- decode_files(files),
         {:ok, refs} <- Aqua.Attachments.store(ctx, id, message_id, decoded) do
      {:ok, %{message_id: message_id, attachments: refs}}
    else
      {:error, :not_found} -> {:error, {:not_found, "thread", id}}
      {:error, {:invalid_argument, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:invalid_argument, "attach refused: #{inspect(reason)}"}}
    end
  end

  defp act("attach", _ctx, _id, _args),
    do: {:error, {:invalid_argument, "attach requires 'message_id' and 'files'"}}

  defp act("revoke_grant", ctx, id, %{
         "agent_name" => agent,
         "tool" => tool,
         "tool_action" => action
       })
       when is_binary(agent) and is_binary(tool) and is_binary(action) do
    case Runner.revoke_grant(ctx, id, agent, tool, action) do
      :ok -> {:ok, %{revoked: true, agent: agent, tool: tool, action: action}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("revoke_grant", _ctx, _id, _args),
    do:
      {:error,
       {:invalid_argument, "revoke_grant requires 'agent_name', 'tool' and 'tool_action'"}}

  defp act("restart_for_consent", ctx, id, args) do
    result = %{profile_id: args["profile_id"], revision: args["revision"]}

    case Runner.restart_for_consent(ctx, id, result) do
      :ok -> {:ok, %{restart_prompted: true}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # A thread is deleted whole — its rows, its blobs, what followed it —
  # and never under a running turn.
  defp act("delete", ctx, id, _args) do
    cond do
      Runner.turn_running?(ctx, id) ->
        {:error, {:conflict, "a turn is running in this thread — stop it first"}}

      true ->
        case Arca.ThreadStorage.delete(Sanctum.Context.actor(ctx), id) do
          :ok -> {:ok, %{deleted: true, thread: id}}
          {:error, :not_found} -> {:error, {:not_found, "thread", id}}
          {:error, reason} -> {:error, refusal(reason, id)}
        end
    end
  end

  defp act("stop", ctx, id, _args) do
    case Runner.stop_turn(ctx, id) do
      :ok -> {:ok, %{stopped: true}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # A card is decided by the message it was shown as; the decision is
  # `Aqua.Approvals`' — the same door the `approval` tool opens.
  defp act("approve", ctx, id, %{"message_id" => message_id} = args) when is_binary(message_id) do
    with {:ok, scope} <- approve_scope(args["scope"]),
         {:ok, approval} <- card_approval(ctx, id, message_id),
         {:ok, outcome} <-
           Approvals.resolve(ctx, approval.id, %{decision: :approved, scope: scope}) do
      {:ok,
       Map.merge(outcome, %{decided: outcome.decision, message_id: message_id, scope: scope})}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("approve", _ctx, _id, _args),
    do: {:error, {:invalid_argument, "approve requires 'message_id'"}}

  defp act("decline", ctx, id, %{"message_id" => message_id} = args) when is_binary(message_id) do
    with {:ok, scope} <- decline_scope(args["scope"]),
         {:ok, approval} <- card_approval(ctx, id, message_id),
         {:ok, outcome} <-
           Approvals.resolve(ctx, approval.id, %{
             decision: :declined,
             scope: scope,
             reason: String.slice(args["reason"] || "", 0, 80)
           }) do
      {:ok,
       Map.merge(outcome, %{decided: outcome.decision, message_id: message_id, scope: scope})}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("decline", _ctx, _id, _args),
    do: {:error, {:invalid_argument, "decline requires 'message_id'"}}

  # The durable truth of a thread is `messages.seq`, so replay is a
  # cursor over rows. Deliberately NOT `Cyfr.Execution.events_since/3`:
  # that is keyed by execution id and carries a turn's in-flight tool
  # deltas, which are the runner's business. A client that reconnects wants
  # what was SAID, and the final rows are enough.
  defp act("events", ctx, id, args) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id) do
      case Arca.ThreadStorage.messages(Sanctum.Context.actor(ctx), id, message_opts(args)) do
        rows when is_list(rows) ->
          rows = Enum.map(rows, &render/1)
          {:ok, %{thread: id, messages: rows, cursor: cursor(rows)}}

        {:error, _} ->
          {:error, {:unavailable, "Storage"}}
      end
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # Following is a person's sidebar and notify roster, never an ACL — and
  # never someone else's: the row is always the CALLER's, no `user_id`
  # argument exists on the wire. The tenant-scoped `get` proves the thread
  # is the focused estate's before the row is written.
  defp act("follow", ctx, id, _args) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         :ok <- Arca.ThreadSubscriptionStorage.follow(Sanctum.Context.actor(ctx), id, ctx.user_id) do
      {:ok, %{following: true, thread: id}}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("unfollow", ctx, id, _args) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         :ok <-
           Arca.ThreadSubscriptionStorage.unfollow(Sanctum.Context.actor(ctx), id, ctx.user_id) do
      {:ok, %{following: false, thread: id}}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # Saying your own lines aloud into an estate you belong to. Everything
  # that matters is decided in `Aqua.Aloud.post/5` — membership on both
  # sides, author-only, byte-copied attachments — this wraps it exactly as
  # every other action wraps the runner.
  defp act("aloud", ctx, id, %{
         "message_ids" => ids,
         "target_athanor" => target_athanor,
         "target_thread" => target_thread
       })
       when is_list(ids) and is_binary(target_athanor) and is_binary(target_thread) do
    # Keep the direct domain entry bounded too: every selected message
    # copies bytes into the target estate.
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, {:invalid_argument, "aloud takes a list of message ids"}}

      length(ids) > @aloud_max ->
        {:error, {:invalid_argument, "aloud takes at most #{@aloud_max} messages at a time"}}

      true ->
        say_aloud(ctx, id, ids, target_athanor, target_thread)
    end
  end

  defp act("aloud", _ctx, _id, _args),
    do:
      {:error,
       {:invalid_argument, "aloud requires 'message_ids', 'target_athanor' and 'target_thread'"}}

  defp act(action, _ctx, _id, _args), do: {:error, {:unknown_action, "thread.#{action}"}}

  defp say_aloud(ctx, id, ids, target_athanor, target_thread) do
    case Aqua.Aloud.post(ctx, id, ids, target_athanor, target_thread) do
      {:ok, rows} ->
        {:ok, %{said_aloud: length(rows), target_thread: target_thread}}

      {:error, :not_a_member} ->
        {:error, {:invalid_argument, "aloud reaches only estates you are a member of"}}

      {:error, :not_the_author} ->
        {:error,
         {:invalid_argument,
          "only your own lines can be said aloud — or your own assistant's, from your own athanor"}}

      {:error, :same_thread} ->
        {:error, {:invalid_argument, "that line is already in this thread"}}

      {:error, :nothing_to_say} ->
        {:error, {:invalid_argument, "aloud requires at least one message id"}}

      {:error, :not_found} ->
        {:error,
         {:invalid_argument, "the selected messages or the target thread could not be found"}}

      {:error, :attachment_missing} ->
        {:error,
         {:invalid_argument,
          "an attachment on the selected lines is missing — nothing was said aloud"}}

      {:error, reason} ->
        {:error, refusal(reason, id)}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # The card's approval, pinned to this thread: a member cannot
  # drive one thread's door to settle another thread's card.
  defp card_approval(ctx, thread_id, message_id) do
    case Tape.approval_by_message(ctx, message_id) do
      {:ok, %{thread_id: ^thread_id} = approval} -> {:ok, approval}
      {:ok, _elsewhere} -> {:error, {:not_found, "approval", message_id}}
      {:error, :not_found} -> {:error, {:not_found, "approval", message_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp decode_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"filename" => name, "media_type" => media, "data" => data}, {:ok, acc}
      when is_binary(name) and is_binary(media) and is_binary(data) ->
        case Base.decode64(data) do
          {:ok, bytes} ->
            {:cont,
             {:ok, acc ++ [%{"filename" => name, "media_type" => media, "bytes" => bytes}]}}

          :error ->
            {:halt, {:error, {:invalid_argument, "attach: '#{name}' is not base64"}}}
        end

      _, _ ->
        {:halt,
         {:error, {:invalid_argument, "attach: each file needs filename, media_type and data"}}}
    end)
  end

  # What a client is told after speaking. A pending card is REPORTED, never
  # decided: a caller that cannot render one has not thereby been given
  # permission to answer it. The message is already accepted by the time
  # this runs, so a faulty status read degrades to "not running, nothing
  # pending" rather than turning the accepted send into an error — both
  # reads can return error tuples, and either would crash the handler.
  defp waiting(ctx, id) do
    live =
      case Runner.state(id, ctx.athanor_id) do
        %{} = state -> state
        _ -> %{}
      end

    pending =
      case Arca.ThreadStorage.pending_approvals(Sanctum.Context.actor(ctx), id) do
        rows when is_list(rows) -> Enum.map(rows, &render/1)
        _ -> []
      end

    %{
      sent: true,
      running: live[:running] || false,
      queued: live[:queued] || 0,
      pending_approvals: pending
    }
  end

  @events_page_max 500

  defp message_opts(args) do
    opts =
      case args["after_seq"] do
        seq when is_integer(seq) -> [after_seq: seq]
        _ -> []
      end

    # Bounded like the console's read: an un-cursored `events` on a
    # long-lived thread must not load every row. The cursor pages.
    case args["limit"] do
      n when is_integer(n) and n > 0 -> [{:limit, min(n, @events_page_max)} | opts]
      _ -> [{:limit, @events_page_max} | opts]
    end
  end

  # Runner and storage refusals, translated to the typed vocabulary at the
  # boundary: an atom is the runner's business, and rendered raw it
  # collapses to a generic "the tool call failed". `translate/2`'s
  # catch-all passes anything it does not name through untouched, a
  # reason already in the vocabulary included; what it does name is this
  # domain's spelling and wins over a shared one — `:unavailable` here is
  # the thread store, not the storage-unit outcome `Cyfr.Refusal` maps.
  defp refusal(reason, id), do: translate(reason, id)

  defp translate(:not_found, id), do: {:not_found, "thread", id}

  defp translate(:empty, _id), do: {:invalid_argument, "send requires a non-empty 'message'"}

  defp translate(:unavailable, _id), do: {:unavailable, "Threads"}
  defp translate(:database_error, _id), do: {:unavailable, "Storage"}

  defp translate(:superseded, _id),
    do: {:conflict, "The turn's owner changed. Retry the operation."}

  defp translate(:not_open, _id),
    do: {:conflict, "The turn changed while this request was running. Retry the operation."}

  defp translate(:workers_not_stopped, _id),
    do: {:timeout, "Some workers have not stopped yet. Retry Stop."}

  defp translate(:workers_unavailable, _id), do: {:unavailable, "Worker coordination"}

  # One sentence per reason, and the runner's — the same words the chat
  # shows, so a client and a person are told the same thing.
  defp translate({:scope_not_permitted, _reason} = refusal, _id),
    do: {:invalid_argument, Aqua.ToolGrants.refusal_message(refusal)}

  # An unmapped reason stays as it is — the router logs it and answers
  # generically, which is the visible cue that a new refusal needs a row
  # above.
  defp translate(other, _id), do: other

  defp render_thread(thread) do
    %{
      id: thread.id,
      title: thread.title,
      created_by: thread.created_by,
      last_message_at: thread.last_message_at,
      at: thread.inserted_at
    }
  end

  defp cursor([]), do: nil
  defp cursor(rows), do: rows |> List.last() |> Map.get(:seq)

  # An approval row carries its intent — the tool, action and arguments
  # the card asks about — so a client without a card to render still sees
  # what it is deciding before it answers `approve`, standing scopes
  # included. A client that hides this from its person is the client's
  # failing; withholding it here would make the blind answer the only one.
  defp render(%{kind: "approval"} = msg) do
    msg
    |> render_row()
    |> Map.put(:intent, Arca.ThreadStorage.payload(msg)["intent"])
  end

  defp render(msg), do: render_row(msg)

  defp render_row(msg) do
    %{
      id: msg.id,
      seq: msg.seq,
      author: msg.author,
      kind: msg.kind,
      content: msg.content,
      status: msg.status,
      at: msg.inserted_at
    }
  end

  # The codec is `Aqua.ApprovalScope`; what each verb accepts is the verb's.
  @approve_scopes Map.new(
                    [:once, :thread, :always],
                    &{Aqua.ApprovalScope.to_string(&1), &1}
                  )
  @decline_scopes Map.new([:once, :never], &{Aqua.ApprovalScope.to_string(&1), &1})

  defp approve_scope(nil), do: {:ok, :once}

  defp approve_scope(value) do
    case Map.fetch(@approve_scopes, value) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        {:error, {:invalid_argument, "approve scope must be once, thread or always"}}
    end
  end

  defp decline_scope(nil), do: {:ok, :once}

  defp decline_scope(value) do
    case Map.fetch(@decline_scopes, value) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, {:invalid_argument, "decline scope must be once or never"}}
    end
  end
end
