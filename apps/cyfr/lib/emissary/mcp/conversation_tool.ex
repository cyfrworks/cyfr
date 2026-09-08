# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ConversationTool do
  @moduledoc """
  Chat on the wire: the `conversation` tool.

  AQUA is the agent runtime, and Prism is a client of it — the first one,
  not the boundary. Until this existed there were twelve MCP tools and none
  of them was chat, so a headless caller could start an *execution* but
  could not talk to an agent: no addressing, no queue, no history window,
  no approvals. The harness owned all of that and only a LiveView could
  reach it.

  Every turn-shaped action here **wraps `Aqua.ConversationRunner`** — there
  is no second implementation of a turn, and no path that starts one
  without the runner's gates. The rest wrap the domain verbs the console
  itself uses: `create`/`list` are `Arca.ConversationStorage` (how a
  headless client gets an id at all), `follow`/`unfollow` are
  `Arca.TopicSubscriptionStorage` for the caller alone, and `aloud` is
  `Aqua.Aloud.post/5` with every rule decided there.

  It lives in Emissary rather than beside the runner for the same reason
  `Emissary.MCP.Tools.RecordsProvider` does: the tool surface is the
  transport's, and it calls *into* a domain. `Aqua.ToolSeamTest` keeps the
  arrow pointing this way — the assistant reaches MCP only through
  `Aqua.MCPHelpers`, never by owning a provider.

  ## Why this is not `execution.run_stream`

  A client must not start a turn by running the agent formula directly.
  That path re-roots the target's own consented authority, which is right
  for launching an app and wrong for a chat turn: the turn's profile is
  pinned once, at its start, and an approval later in the turn roots that
  same pin. Going around the runner would produce a turn nothing had
  pinned. (The harness still uses `run_stream` internally — that path is
  not being removed, it is just not a client's door.)

  ## Two gates, on different axes

    * **Plane.** `Emissary.MCP.ToolRegistry.call_external/4` refuses a
      `:guest` context outright, and these actions declare
      `planes: [:external]` so they never appear in-chain. A running agent
      cannot read or post into conversations — including other people's in
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

  @behaviour Emissary.MCP.ToolProvider

  # The most lines one `aloud` may carry: each one copies bytes into the
  # target estate, so a call moves a slice, never a thread.
  @aloud_max 50

  alias Aqua.ConversationRunner
  alias Sanctum.Context

  @impl true
  def service, do: "conversation"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    %{
      name: "conversation",
      title: "Conversations",
      description:
        "Talk to an agent: open or list threads, send a message, follow the reply, " <>
          "stop a turn, decide the approval cards a turn raises, follow or unfollow a " <>
          "topic, and say one of your own private lines aloud into an estate you " <>
          "belong to. Addressing: in an estate with one person every send starts a " <>
          "turn; with more than one, a send starts a turn only when it names one — " <>
          "@aqua for the estate's assistant, or @<role> for one of its roles. An " <>
          "unaddressed send is people talking: it " <>
          "persists and starts nothing (the result says running: false). The wire " <>
          "send takes text only — no attachments, no model or agent argument; address " <>
          "by mention — and threads are deleted from the console, not from here. " <>
          "Wraps the same runner and the same verbs the console drives, with the " <>
          "same gates — this is not a second way to run an agent.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: false,
        actions: %{
          # `:external` on every action: a running agent must not be able to
          # read or post into conversations, its own included. And
          # `:interactive` on every action: only a person's own session may
          # speak, decide, or read as them — never a standing credential.
          "create" => %{kind: :write, planes: [:external], consent: :interactive},
          "list" => %{kind: :read, planes: [:external], consent: :interactive},
          "send" => %{kind: :write, planes: [:external], consent: :interactive},
          "stop" => %{kind: :write, planes: [:external], consent: :interactive},
          "approve" => %{kind: :write, planes: [:external], consent: :interactive},
          "decline" => %{kind: :write, planes: [:external], consent: :interactive},
          "events" => %{kind: :read, planes: [:external], consent: :interactive},
          "follow" => %{kind: :write, planes: [:external], consent: :interactive},
          "unfollow" => %{kind: :write, planes: [:external], consent: :interactive},
          "aloud" => %{kind: :write, planes: [:external], consent: :interactive}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "create",
              "list",
              "send",
              "stop",
              "approve",
              "decline",
              "events",
              "follow",
              "unfollow",
              "aloud"
            ]
          },
          "conversation" => %{
            "type" => "string",
            "description" => "Conversation id (all actions except create and list)"
          },
          "title" => %{"type" => "string", "description" => "create: the thread's title"},
          "message" => %{
            "type" => "string",
            # Advisory: maxLength counts graphemes; the governing bound is
            # the runner's 32 KiB byte check, which every sender passes
            # through (the console included).
            "maxLength" => 32_768,
            "description" => "send: the text to say (at most 32 KiB of text)"
          },
          "message_id" => %{
            "type" => "string",
            "description" => "approve/decline: the approval card"
          },
          "message_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "aloud: your own messages to copy, in any order — or your assistant's replies to you in your own athanor"
          },
          "target_athanor" => %{
            "type" => "string",
            "description" => "aloud: the estate to post into (you must be a member)"
          },
          "target_conversation" => %{
            "type" => "string",
            "description" => "aloud: the topic in that estate to post onto"
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["once", "conversation", "always", "never"],
            "description" =>
              "approve: once | conversation | always. decline: once | never. " <>
                "Standing scopes are refused for destructive and external actions."
          },
          "reason" => %{"type" => "string", "description" => "decline: why"},
          "after_seq" => %{
            "type" => "integer",
            "description" =>
              "events: replay messages after this seq. Omit to start from the beginning."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "events: rows per page (default and ceiling 500). Page by passing " <>
                "the returned cursor as after_seq."
          }
        },
        "required" => ["action"]
      }
    }
  end

  @impl true
  def handle("conversation", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  # The interactive-surface gate is NOT here: it is the `consent:
  # :interactive` declaration on every action, enforced by the registry
  # before the handler runs.

  # `create` and `list` name no conversation — they are how a headless
  # client gets an id in the first place, which is what makes this the
  # same surface the console has rather than one that assumes it.
  defp dispatch(ctx, %{"action" => "create"} = args) do
    attrs =
      case args["title"] do
        title when is_binary(title) and title != "" -> %{title: title}
        _ -> %{}
      end

    with {:ok, conv} <- Arca.ConversationStorage.create(ctx, attrs) do
      {:ok, render_conversation(conv)}
    end
  end

  defp dispatch(ctx, %{"action" => "list"}) do
    case Arca.ConversationStorage.list(ctx) do
      rows when is_list(rows) ->
        {:ok, %{conversations: Enum.map(rows, &render_conversation/1), count: length(rows)}}

      {:error, _} ->
        {:error, {:unavailable, "Storage"}}
    end
  end

  defp dispatch(ctx, %{"action" => action, "conversation" => id} = args)
       when is_binary(id) and id != "" do
    act(action, ctx, id, args)
  end

  defp dispatch(_ctx, _args),
    do: {:error, {:invalid_argument, "conversation requires an 'action' and a 'conversation'"}}

  defp act("send", ctx, id, args) do
    case args["message"] do
      text when is_binary(text) and text != "" ->
        case ConversationRunner.send_message(ctx, id, text) do
          :ok -> {:ok, waiting(ctx, id)}
          {:error, reason} -> {:error, refusal(reason, id)}
        end

      _ ->
        {:error, {:invalid_argument, "send requires a non-empty 'message'"}}
    end
  end

  defp act("stop", ctx, id, _args) do
    case ConversationRunner.stop_turn(ctx, id) do
      :ok -> {:ok, %{stopped: true}}
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("approve", ctx, id, %{"message_id" => message_id} = args) when is_binary(message_id) do
    with {:ok, scope} <- approve_scope(args["scope"]),
         :ok <- ConversationRunner.approve(ctx, id, message_id, scope) do
      {:ok, %{decided: "approved", message_id: message_id, scope: scope}}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("approve", _ctx, _id, _args),
    do: {:error, {:invalid_argument, "approve requires 'message_id'"}}

  defp act("decline", ctx, id, %{"message_id" => message_id} = args) when is_binary(message_id) do
    with {:ok, scope} <- decline_scope(args["scope"]),
         :ok <- ConversationRunner.decline(ctx, id, message_id, args["reason"] || "", scope) do
      {:ok, %{decided: "declined", message_id: message_id, scope: scope}}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("decline", _ctx, _id, _args),
    do: {:error, {:invalid_argument, "decline requires 'message_id'"}}

  # The durable truth of a conversation is `messages.seq`, so replay is a
  # cursor over rows. Deliberately NOT `Cyfr.Execution.events_since/3`:
  # that is keyed by execution id and carries a turn's in-flight tool
  # deltas, which are the runner's business. A client that reconnects wants
  # what was SAID, and the final rows are enough.
  defp act("events", ctx, id, args) do
    with {:ok, _conv} <- Arca.ConversationStorage.get(ctx, id) do
      case Arca.ConversationStorage.messages(ctx, id, message_opts(args)) do
        rows when is_list(rows) ->
          rows = Enum.map(rows, &render/1)
          {:ok, %{conversation: id, messages: rows, cursor: cursor(rows)}}

        {:error, _} ->
          {:error, {:unavailable, "Storage"}}
      end
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  # Following is a person's sidebar and notify roster, never an ACL — and
  # never someone else's: the row is always the CALLER's, no `user_id`
  # argument exists on the wire. The tenant-scoped `get` proves the topic
  # is the focused estate's before the row is written.
  defp act("follow", ctx, id, _args) do
    with {:ok, _conv} <- Arca.ConversationStorage.get(ctx, id),
         :ok <- Arca.TopicSubscriptionStorage.follow(ctx, id, ctx.user_id) do
      {:ok, %{following: true, conversation: id}}
    else
      {:error, reason} -> {:error, refusal(reason, id)}
    end
  end

  defp act("unfollow", ctx, id, _args) do
    with {:ok, _conv} <- Arca.ConversationStorage.get(ctx, id),
         :ok <- Arca.TopicSubscriptionStorage.unfollow(ctx, id, ctx.user_id) do
      {:ok, %{following: false, conversation: id}}
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
         "target_conversation" => target_conversation
       })
       when is_list(ids) and is_binary(target_athanor) and is_binary(target_conversation) do
    # The validator does not look inside arrays, so the ids' shape and the
    # list's length are checked here: every element copies bytes into the
    # target estate, and a bound is what keeps one call from moving a
    # whole thread.
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, {:invalid_argument, "aloud takes a list of message ids"}}

      length(ids) > @aloud_max ->
        {:error, {:invalid_argument, "aloud takes at most #{@aloud_max} messages at a time"}}

      true ->
        say_aloud(ctx, id, ids, target_athanor, target_conversation)
    end
  end

  defp act("aloud", _ctx, _id, _args),
    do:
      {:error,
       {:invalid_argument,
        "aloud requires 'message_ids', 'target_athanor' and 'target_conversation'"}}

  defp act(action, _ctx, _id, _args), do: {:error, {:unknown_action, "conversation.#{action}"}}

  defp say_aloud(ctx, id, ids, target_athanor, target_conversation) do
    case Aqua.Aloud.post(ctx, id, ids, target_athanor, target_conversation) do
      {:ok, rows} ->
        {:ok, %{said_aloud: length(rows), target_conversation: target_conversation}}

      {:error, :not_a_member} ->
        {:error, {:invalid_argument, "aloud reaches only estates you are a member of"}}

      {:error, :not_the_author} ->
        {:error,
         {:invalid_argument,
          "only your own lines can be said aloud — or your own assistant's, from your own athanor"}}

      {:error, :same_conversation} ->
        {:error, {:invalid_argument, "that line is already in this conversation"}}

      {:error, :nothing_to_say} ->
        {:error, {:invalid_argument, "aloud requires at least one message id"}}

      {:error, :not_found} ->
        {:error,
         {:invalid_argument,
          "the selected messages or the target conversation could not be found"}}

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

  # What a client is told after speaking. A pending card is REPORTED, never
  # decided: a caller that cannot render one has not thereby been given
  # permission to answer it. The message is already accepted by the time
  # this runs, so a faulty status read degrades to "not running, nothing
  # pending" rather than turning the accepted send into an error — both
  # reads can return error tuples, and either would crash the handler.
  defp waiting(ctx, id) do
    live =
      case ConversationRunner.state(id, ctx.athanor_id) do
        %{} = state -> state
        _ -> %{}
      end

    pending =
      case Arca.ConversationStorage.pending_approvals(ctx, id) do
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
  # collapses to a generic "the tool call failed". A reason already in the
  # vocabulary passes through untouched.
  defp refusal(reason, id) do
    if Emissary.MCP.ToolError.reason?(reason), do: reason, else: translate(reason, id)
  end

  defp translate(:not_found, id), do: {:not_found, "conversation", id}

  defp translate(:archived, _id),
    do: {:invalid_argument, "this conversation's estate is archived — nothing runs in it"}

  defp translate(:not_member, _id),
    do: {:invalid_argument, "only a member of the estate can act in its conversations"}

  defp translate(:busy, _id),
    do: {:invalid_argument, "the turn queue is full — send again after the current turn"}

  defp translate(:no_orchestrator, _id),
    do: {:invalid_argument, "this estate has no assistant to address — reset its AQUA tree"}

  defp translate(:empty, _id), do: {:invalid_argument, "send requires a non-empty 'message'"}

  defp translate(:message_too_long, _id),
    do: {:invalid_argument, "the message is longer than the 32 KiB bound"}

  defp translate(:unavailable, _id), do: {:unavailable, "Conversations"}
  defp translate(:database_error, _id), do: {:unavailable, "Storage"}

  # One sentence per reason, and the runner's — the same words the chat
  # shows, so a client and a person are told the same thing.
  defp translate({:scope_not_permitted, _reason} = refusal, _id),
    do: {:invalid_argument, Aqua.ToolGrants.refusal_message(refusal)}

  # An unmapped reason stays as it is — the router logs it and answers
  # generically, which is the visible cue that a new refusal needs a row
  # above.
  defp translate(other, _id), do: other

  defp render_conversation(conv) do
    %{
      id: conv.id,
      title: conv.title,
      created_by: conv.created_by,
      running: is_binary(conv.execution_id),
      last_message_at: conv.last_message_at,
      at: conv.inserted_at
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
    |> Map.put(:intent, Arca.ConversationStorage.payload(msg)["intent"])
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
                    [:once, :conversation, :always],
                    &{Aqua.ApprovalScope.to_string(&1), &1}
                  )
  @decline_scopes Map.new([:once, :never], &{Aqua.ApprovalScope.to_string(&1), &1})

  defp approve_scope(nil), do: {:ok, :once}

  defp approve_scope(value) do
    case Map.fetch(@approve_scopes, value) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        {:error, {:invalid_argument, "approve scope must be once, conversation or always"}}
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
