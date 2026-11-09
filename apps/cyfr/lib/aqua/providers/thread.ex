# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.Thread do
  @moduledoc """
  Chat on the wire: the `thread` tool, and the `turn` tool beside it.

  Exposes AQUA thread addressing, queuing, history and approvals to
  MCP clients through the thread runner.

  `turn` is the second tool this provider serves: `suspend` sets a turn
  down with every row kept, its runtime released and the thread's claim
  given up, and `recover` takes a suspended or abandoned turn back.
  `crew` is the third: `ask` and `list`, the soul's hand-off to a crew
  member from inside its turn (`Aqua.Crew`). The provider's `service/0`
  is `"aqua"` for all three, so `system.status` and the request log's
  `routed_to` read one label.

  Every turn-shaped action here **wraps `Aqua.Runner`** — there
  is no second implementation of a turn, and no path that starts one
  without the runner's gates. The rest wrap the domain verbs the console
  itself uses: `create`/`list` are `Arca.ThreadStorage` (how a
  headless client gets an id at all), and `aloud` is
  `Aqua.Aloud.post/4` with every rule decided there.

  It lives beside the runner because the assistant owns its providers,
  as every domain does. `Aqua.ToolSeamTest` keeps the other arrow
  pointing one way — the assistant dispatches through the gate only at
  `Aqua.Ops` — and the Boundary compiler keeps it from naming `Emissary`.

  ## Starting turns

  Start chat turns through the runner so the turn pins a profile and later
  approvals use that same authority. Direct execution of the agent formula
  does not establish this thread state.

  ## Two gates, on different axes

    * **Plane.** `Sanctum.Gate.call_external/4` refuses a
      `:guest` context outright, and these actions declare
      `planes: [:external]` so they never appear in-chain. A running agent
      cannot read or post into threads — including other people's in
      the same athanor.
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

  ## Streams

  Two streams a canvas reads ride beside the tools (`streams/0`), each
  with its shape and refresh:

    * `threads.changes` is one person's list of threads, on their own
      topic, so its subject is the grant holder's own id, which the gate
      binds: their athanor's own threads and the active shared threads
      they sit in (`Aqua.ThreadList`).
    * `activity.changes` is the athanor's crew at work, a job's start and
      end, and takes no subject (`Aqua.Crew.Activity`). It is declared
      here, beside the `crew` tool, as the assistant's one provider.

  ## Approvals are never skipped

  A client with no way to render a card does not get to decide for the
  person. `send` reports a turn that is waiting, and the card stays
  pending until somebody answers it through `approve` or `decline`.
  """

  @behaviour Prima.Provider

  # The most lines one `aloud` may carry: each one copies bytes into the
  # shared thread, so a call moves a slice, never a thread.
  @aloud_max 50

  alias Aqua.{Approvals, Runner, Tape}
  alias Sanctum.Context

  @impl true
  def service, do: "aqua"

  # Two tools, one service. The service label is the provider's, so
  # `system.status` and the request log's `routed_to` read one label for
  # both; a tool name and a service name are already different things
  # (`Opus.Provider` answers `"opus"`, `Emissary.External.Provider`
  # answers `"emissary"`).
  @impl true
  def tools, do: [definition(), turn_definition(), crew_definition()]

  # A day: the longest a grant on either stream lives.
  @deadline_bound 86_400

  # Fifteen minutes: how long a picture of either stream stands before it
  # is read again. Each change is announced, so a read only mends one the
  # bus lost.
  @stale_after 900

  @doc """
  The streams a canvas reads: `threads.changes` and `activity.changes`,
  each with its shape and refresh (the moduledoc's).
  """
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "threads.changes",
        topic: :threads,
        projection:
          ["kind", "id", "title", "people", "last_activity", "waits_on_you", "unread"] ++
            Prima.Provider.Stream.delivery_fields(),
        subject: ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z",
        bind: :holder,
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(threads_shape()),
        refresh: {Aqua.ThreadList, :listed},
        key: "id",
        removal: "removed",
        stale_after: @stale_after
      },
      %Prima.Provider.Stream{
        name: "activity.changes",
        topic: :crew_activity,
        projection:
          ["kind", "id", "member", "asked_by", "title", "since", "status"] ++
            Prima.Provider.Stream.delivery_fields(),
        deadline_bound: @deadline_bound,
        shape: Prima.Provider.Stream.delivered(activity_shape()),
        refresh: {Aqua.Crew.Activity, :open},
        key: "id",
        removal: "ended",
        stale_after: @stale_after
      }
    ]
  end

  # A removal carries its kind and id alone, so every other field is
  # nullable. A title is at most the 200 characters either store keeps.
  defp threads_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{"type" => "enum", "values" => ["own", "shared", "removed"]},
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string", "max" => 200, "nullable" => true},
        "people" => %{
          "type" => "list",
          "max" => 1000,
          "nullable" => true,
          "of" => %{"type" => "string", "max" => 4096}
        },
        "last_activity" => %{"type" => "time", "nullable" => true},
        "waits_on_you" => %{"type" => "boolean", "nullable" => true},
        "unread" => %{"type" => "integer", "nullable" => true}
      },
      "required" => ["kind", "id", "title", "people", "last_activity", "waits_on_you", "unread"]
    })
  end

  defp activity_shape do
    normalized(%{
      "type" => "object",
      "fields" => %{
        "kind" => %{"type" => "enum", "values" => ["started", "ended"]},
        "id" => %{"type" => "string"},
        "member" => %{"type" => "string"},
        "asked_by" => %{"type" => "string", "max" => 4096, "nullable" => true},
        "title" => %{"type" => "string", "max" => Aqua.Crew.title_max(), "nullable" => true},
        "since" => %{"type" => "time", "nullable" => true},
        "status" => %{"type" => "enum", "values" => Prima.TurnState.statuses()}
      },
      "required" => ["kind", "id", "member", "asked_by", "title", "since", "status"]
    })
  end

  # Declared in the normalized form the stream table keeps
  # (`Prima.Provider.Stream.valid?/1`).
  defp normalized(shape) do
    {:ok, normalized} = Prima.Canvas.Shape.validate(shape)
    normalized
  end

  @doc false
  def definition do
    alias Prima.{Arg, Operation}
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
          sources: [:pinned, :filed, :files_by_grant, :vault_disclosed, :outside],
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
          sources: [:pinned, :filed, :files_by_grant, :vault_disclosed, :outside],
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
                 Arg.new("shared_thread_id", :string, required: true),
                 Arg.new("title", :string)
               ]},
              description:
                "send: the shared thread the sender has open beside this thread (shared_thread_id, title); its newest lines are read under the sender's seat for this one turn, never stored"
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
                    Arg.new("data", :string, required: true, bulk: true)
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
          "discard",
          "Discard thread attachments",
          [
            Arg.new("thread", :string,
              required: true,
              description: "Thread id (all actions except create and list)"
            ),
            Arg.new("message_id", :string,
              required: true,
              description:
                "discard: the unsent message whose files this session attached, which go"
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
          sources: [:pinned, :filed, :files_by_grant, :vault_disclosed, :outside],
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
            Arg.new("target_thread", :string,
              required: true,
              description: "aloud: the shared thread (sth_…) to say them in, which you sit in"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "thread",
          "archive",
          "Archive thread",
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
        "Talk to an agent: open or list threads, send a message, follow the reply, stop a turn, decide the approval cards a turn raises, archive a crew member's thread, and say one of your own private lines aloud into a shared thread you sit in. A send in your own thread starts a turn of the athanor's assistant, or with @<name> asks that crew member, who works in a thread of its own under yours and replies here; a send in a crew member's thread speaks to that member. A send may carry a pre-minted id with files attached under it, a model, an agent, the sender's own client id, and the shared thread open beside it. Wraps the same runner and the same verbs the console drives, with the same gates — this is not a second way to run an agent.",
      title: "Threads"
    )
  end

  @doc false
  def turn_definition do
    alias Prima.{Arg, Operation}
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
        "Move a turn between servers: suspend sets it down with every row it has written kept, its runtime capacity released and the thread's claim given up, so any server may pick it up; recover takes a suspended or abandoned turn and carries it on, under a new fence, with the consent head and the capability identity read again. Suspending is not stopping — a stopped turn ends, a suspended one waits. A turn a live server is running is refused rather than taken, and a turn recovered too many times ends uncertain.",
      title: "Turns"
    )
  end

  @doc false
  def crew_definition do
    alias Prima.{Arg, Operation}
    # In a chain only: the soul's turn hands a job to a crew member, and a
    # person's own ask is an `@name` in `thread.send`. The answer is the
    # request's id and the roster the athanor's own files hold, so
    # neither carries outside material.
    Operation.tool(
      [
        Operation.new(
          "crew",
          "ask",
          "Ask crew",
          [
            Arg.new("member", :string,
              required: true,
              description: "ask: the crew member to hand the job to (crew.list names them)"
            ),
            Arg.new("task", :string,
              required: true,
              description:
                "ask: the job, with everything the member needs to do it (at most 32 KiB)",
              max: 32768
            ),
            Arg.new("title", :string,
              description:
                "ask: a short title for the job, plain text on one line of at most #{Aqua.Crew.title_max()} characters, that a desktop shows for it; omit for none",
              max: Aqua.Crew.title_max()
            ),
            Arg.new("tools", {:array, Arg.new(nil, :string)},
              description:
                "ask: narrow the member's tools for this job to these (a tool, or tool.action); omit for all it holds"
            ),
            Arg.new("options", {:map, Arg.new(nil, :json)},
              description: "ask: options for the member's brain, those it declares"
            )
          ],
          kind: :write,
          sources: [],
          planes: [:in_chain]
        ),
        Operation.new("crew", "list", "List crew", [],
          kind: :read,
          sources: [],
          planes: [:in_chain],
          recovery: :replay_safe
        )
      ],
      description:
        "Hand a job to a crew member: ask sends it, and the member works it in a thread of its own under this one and replies here when it is done, failed or stopped, or when it needs the person; nothing waits for the reply, which arrives as a message of its own. list names the members whose brain is ready, with what each is good at and what to avoid.",
      title: "Crew"
    )
  end

  @impl true
  def handle("thread", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle("turn", %Context{} = ctx, args), do: turn(ctx, args)
  def handle("crew", %Context{} = ctx, %{"action" => "ask"} = args), do: Aqua.Crew.ask(ctx, args)

  def handle("crew", %Context{} = ctx, %{"action" => "list"} = args),
    do: Aqua.Crew.list(ctx, args)

  def handle("crew", _ctx, _args),
    do: {:error, {:invalid_argument, "crew takes the action ask or list"}}

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

  # The turn vocabulary on top of the thread one: a turn a live member is
  # running is a conflict, not a refusal; a turn that is not the caller's
  # athanor's is absent, which `translate/2` already answers.
  defp turn_refusal(:held_elsewhere, _id),
    do: {:conflict, "That turn is running on another server. Try again once it is down."}

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

    actor = Sanctum.Context.actor(ctx)

    with {:ok, thread} <- Arca.ThreadStorage.create(actor, attrs) do
      Aqua.ThreadList.changed(actor, thread.id)
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
  # the shared thread open beside it — read server-side under the
  # sender's seat into the text the turn reads beside the task
  # (`Aqua.Loop.Turn`), never stored.
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
            _ -> Prima.UUID7.generate_id("msg")
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

  # The files a message carries are written under its id before the
  # send names them, so the bytes are the sender's own write.
  defp act("attach", ctx, id, %{"message_id" => message_id, "files" => files})
       when is_binary(message_id) and is_list(files) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         {:ok, decoded} <- decode_files(files),
         {:ok, refs} <- Aqua.Attachments.store(ctx, id, message_id, decoded) do
      {:ok, %{message_id: message_id, attachments: refs}}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "thread", id}}

      {:error, {:invalid_argument, _} = reason} ->
        {:error, reason}

      {:error, reason} when reason in [:message_sent, :attachment_exists, :database_error] ->
        {:error, attachment_refusal(reason)}

      {:error, reason} ->
        {:error, {:invalid_argument, "attach refused: " <> Sanctum.Refusals.render(reason)}}
    end
  end

  # A send refused after its files were stored, or a held one given up:
  # the files this caller's own session stored under the message go, and
  # nothing anyone else stored (`Aqua.Attachments.discard_unsent/3`).
  defp act("discard", ctx, id, %{"message_id" => message_id}) when is_binary(message_id) do
    with {:ok, _thread} <- Arca.ThreadStorage.get(Sanctum.Context.actor(ctx), id),
         {:ok, names} <- Aqua.Attachments.discard_unsent(ctx, id, message_id) do
      {:ok, %{message_id: message_id, discarded: names}}
    else
      {:error, :not_found} -> {:error, {:not_found, "thread", id}}
      {:error, reason} -> {:error, attachment_refusal(reason)}
    end
  end

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

  defp act("restart_for_consent", ctx, id, args) do
    result = %{profile_id: args["profile_id"], revision: args["revision"]}

    case Runner.restart_for_consent(ctx, id, result) do
      :ok -> {:ok, %{restart_prompted: true}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # A thread is deleted whole — its rows and its blobs, and a room's crew
  # threads with it, their open turns cancelled and the runtime still
  # holding them stopped after — and never under a running turn, nor while
  # a crew thread of the room waits on a card.
  defp act("delete", ctx, id, _args) do
    cond do
      Runner.turn_running?(ctx, id) ->
        {:error, {:conflict, "a turn is running in this thread — stop it first"}}

      true ->
        case Tape.delete_thread(ctx, id) do
          # The rows are gone either way; a runner that cannot stop its
          # work retires with it.
          {:ok, %{cancelled: cancelled}} ->
            _ = Runner.stop_cancelled(cancelled)
            {:ok, %{deleted: true, thread: id}}

          {:error, :not_found} ->
            {:error, {:not_found, "thread", id}}

          {:error, reason} ->
            {:error, refusal(reason, id)}
        end
    end
  end

  # A crew member's thread is retired: it admits nothing more, its open
  # turns end cancelled with their replies in the archive's own
  # transaction, the runtime still holding them is stopped after, and the
  # next request to the member opens a new one.
  defp act("archive", ctx, id, _args) do
    with {:ok, %{thread: archived, cancelled: cancelled}} <- Tape.archive(ctx, id),
         :ok <- Runner.stop_cancelled(cancelled) do
      {:ok, Map.put(render_thread(archived), :archived, true)}
    else
      {:error, :not_crew} ->
        {:error,
         {:conflict, "only a crew member's thread is archived; delete a thread of your own"}}

      {:error, reason} ->
        {:error, refusal(reason, id)}
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

  # The durable truth of a thread is `messages.seq`, so replay is a
  # cursor over rows. Deliberately NOT `Opus.events_since/3`:
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

  # Saying your own lines aloud into a shared thread you sit in. Everything
  # that matters is decided in `Aqua.Aloud.post/4` — the source athanor's
  # owner, the target's seat, author-only, byte-copied attachments —
  # this wraps it exactly as every other action wraps the runner.
  defp act("aloud", ctx, id, %{"message_ids" => ids, "target_thread" => target_thread})
       when is_list(ids) and is_binary(target_thread) do
    # Keep the direct domain entry bounded too: every selected message
    # copies bytes into the shared thread.
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, {:invalid_argument, "aloud takes a list of message ids"}}

      length(ids) > @aloud_max ->
        {:error, {:invalid_argument, "aloud takes at most #{@aloud_max} messages at a time"}}

      true ->
        say_aloud(ctx, id, ids, target_thread)
    end
  end

  defp say_aloud(ctx, id, ids, target_thread) do
    case Aqua.Aloud.post(ctx, id, ids, target_thread) do
      {:ok, rows} ->
        {:ok, %{said_aloud: length(rows), target_thread: target_thread}}

      {:error, :not_a_member} ->
        {:error, {:invalid_argument, "aloud reads only threads of your own athanor"}}

      {:error, :not_the_author} ->
        {:error,
         {:invalid_argument,
          "only your own lines can be said aloud — or your own assistant's, from your own athanor"}}

      {:error, :same_thread} ->
        {:error, {:invalid_argument, "that line is already in this thread"}}

      {:error, :nothing_to_say} ->
        {:error, {:invalid_argument, "aloud requires at least one message id"}}

      {:error, :not_found} ->
        {:error, {:invalid_argument, "the selected messages could not be found"}}

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

  defp attachment_refusal(:message_sent),
    do: {:conflict, "That message was sent; its attachments stay as they are"}

  defp attachment_refusal(:attachment_exists),
    do:
      {:conflict,
       "A file of that name is already under that message; discard the message's files " <>
         "(thread.discard) first to replace it"}

  defp attachment_refusal(:database_error), do: {:unavailable, "Storage"}

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
  # the thread store, not the storage-unit outcome `Prima.Refusal` maps.
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
      kind: thread.kind,
      parent_id: thread.parent_id,
      agent: if(thread.kind == "crew", do: thread.agent),
      archived_at: thread.archived_at,
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
