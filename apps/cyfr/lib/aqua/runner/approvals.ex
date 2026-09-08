# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.Approvals do
  @moduledoc """
  A card is decided: authorised again from its own row, run under its own turn's profile, and its standing answer recorded.

  Part of `Aqua.ConversationRunner`: every function here takes the
  runner's state and answers the state, and is called from the runner's
  callbacks alone — the public face stays `Aqua.ConversationRunner`.
  """

  require Logger
  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.Orchestrator
  alias Aqua.Turn, as: AquaTurn

  # The runner's voice, as the schema spells it.
  @system_author Arca.Schemas.Message.system_author()

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  # `msg` is already marked "running" by the caller's compare-and-set.
  #
  # Decided BEFORE anything is written: the card's own agent, as it is
  # defined now and with the standing answers as they stand now, must
  # still hold the pair at ask (or auto) — a deny or a page edit since the
  # card was raised refuses it — and only then is the standing scope
  # recorded and the call run. Written first, a naive re-check would
  # reject the approval's own newly recorded allow.
  @doc false
  def run_approval(state, ctx, msg, scope) do
    intent = approval_intent(msg)
    proposal = intent |> proposal_of() |> with_provenance(state, msg)

    case authorize_card(state, ctx, msg, proposal) do
      :ok ->
        state = apply_scope(state, ctx, msg, proposal, scope)
        state = Aqua.Runner.Shared.broadcast(state, {:message_updated, msg})

        case proposal do
          nil ->
            # A pure-confirmation card — nothing to execute; the
            # acknowledgement is the outcome.
            complete_approval(state, ctx, msg.id, :approved, %{result: %{status: "ok"}})

          %{} ->
            run_proposal(state, ctx, msg, proposal, approval_profile(state, ctx, msg))
        end

      {:error, why} ->
        state
        |> Aqua.Runner.Shared.broadcast({:message_updated, msg})
        |> complete_approval(ctx, msg.id, :error, %{reason: why})
    end
  end

  # The card's pair against the CURRENT policy of the card's own agent:
  # the definition as the tree holds it now (an agent disabled since is
  # gone), composed with the rows as they stand now (a "never" since
  # wins). `state.tool_policy` is not consulted — it may be a later
  # turn's, or another agent's. A confirmation card with no proposal has
  # nothing to check.
  @doc false
  def authorize_card(_state, _ctx, _msg, nil), do: :ok

  def authorize_card(state, ctx, msg, %{tool: tool, action: action}) do
    case approval_orchestrator(msg) do
      name when is_binary(name) -> authorize_card(state, ctx, name, tool, action)
      _ -> {:error, "the card names no agent"}
    end
  end

  def authorize_card(state, ctx, name, tool, action) do
    with {:ok, orchestrator} <- Orchestrator.resolve(ctx, Orchestrator.by_name(name)),
         {:ok, rows} <- Aqua.ToolGrants.for_conversation(ctx, state.id, name) do
      policy = Orchestrator.with_grants(orchestrator, rows) |> Orchestrator.tool_policy()

      case Map.get(policy, "#{tool}.#{action}") do
        mode when mode in ["ask", "auto"] ->
          :ok

        "deny" ->
          {:error, "#{tool}.#{action} was declined for good since this card was raised"}

        _ ->
          {:error, "#{name} no longer holds #{tool}.#{action} — the card is stale"}
      end
    else
      {:error, :no_orchestrator} -> {:error, "#{name} is no longer on the roster"}
      {:error, {:unavailable, what}} -> {:error, "#{what} could not be read — approve again"}
    end
  end

  # The profile the card's OWN turn pinned. A card can outlive the turn
  # that raised it — a person decides it after the next send — and by then
  # the runner's pin is the next turn's, so the row's execution is the one
  # source: every card this runner appends is stamped with it. A row that
  # names no execution takes the runner's pin.
  @doc false
  def approval_profile(_state, ctx, %{execution_id: execution_id}) when is_binary(execution_id),
    do: Aqua.Runner.Recovery.pinned_profile(ctx, execution_id)

  def approval_profile(state, _ctx, _msg), do: state.profile_id

  @doc false
  def run_proposal(state, ctx, msg, _proposal, profile_id) when not is_binary(profile_id) do
    # No pin means the turn's authority is unknown — an execution written
    # before the column, or a row the read could not reach. Refuse:
    # rooting a freshly-selected profile here is exactly the substitution
    # the pin exists to prevent.
    complete_approval(state, ctx, msg.id, :error, %{
      reason: "the turn's profile is unknown — send the message again"
    })
  end

  def run_proposal(state, ctx, msg, proposal, profile_id) do
    runner = self()
    id = msg.id
    turn = state.turn

    # The turn's own profile, not a fresh selection: a human decision
    # unblocks a call, it never chooses the authority the call runs
    # under.
    spawned =
      Aqua.Runner.Addressing.start_task(fn ->
        result =
          try do
            turn.run_approved(proposal, ctx, profile_id)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            # The approved run reaches GenServers and MCP; an exit
            # uncaught here died silently and the card read "running"
            # forever.
            kind, reason ->
              Logger.warning("[Aqua.ConversationRunner] approval run #{kind}: #{inspect(reason)}")

              {:error, "the engine did not respond"}
          end

        case result do
          {:ok, value} ->
            send(runner, {:approval_result, id, ctx, :approved, %{result: value}})

          {:error, reason} ->
            send(runner, {:approval_result, id, ctx, :error, %{reason: reason}})
        end
      end)

    case spawned do
      :ok ->
        state

      :error ->
        # The card was already marked "running" by the caller's
        # compare-and-set; without this it stayed there forever.
        complete_approval(state, ctx, id, :error, %{
          reason: "The action could not run — the server is busy. Approve again to retry."
        })
    end
  end

  # `:conversation` and `:always` are both STANDING grants — they answer
  # for calls nobody has seen yet — so both are refused for
  # destructive/external actions; only `:once` may approve those. Past the
  # kind, the action's own standing rule — minted onto the intent from the
  # same annotation `Aqua.ToolGrants` reads at the write — has the last
  # word: `false` takes no standing answer at all, `"conversation"` takes
  # none at agent scope. The card hides these buttons, but the card is a
  # client; the rule is decided here, on what the intent already carries.
  @doc false
  def scope_permitted(msg, scope) when scope in [:conversation, :always] do
    intent = approval_intent(msg)

    cond do
      intent["action_kind"] in ["destructive", "external"] ->
        {:error, {:scope_not_permitted, intent["action_kind"]}}

      Aqua.ApprovalScope.standing(intent["standing"]) == false ->
        {:error, {:scope_not_permitted, :never_standing}}

      Aqua.ApprovalScope.standing(intent["standing"]) == :conversation and scope == :always ->
        {:error, {:scope_not_permitted, :conversation_only}}

      true ->
        :ok
    end
  end

  def scope_permitted(_msg, _scope), do: :ok

  # Where an approved call came from: the card's OWN execution — the row
  # is stamped with it when the card is raised, and the runner's current
  # execution may by now be a later turn's or none — and this
  # conversation. It rides the proposal as `lineage`, which the registry
  # stamps onto the call as host-only keys (`Emissary.MCP.ToolRegistry`);
  # a tool reads provenance from those and nothing the model wrote.
  @doc false
  def with_provenance(nil, _state, _msg), do: nil

  def with_provenance(%{} = proposal, state, msg) do
    Map.put(proposal, :lineage, %{execution_id: msg.execution_id, conversation_id: state.id})
  end

  # What an approved card kept lands on the tape as a visible line, in the
  # runner's voice: the agent proposed, a person clicked, and the room sees
  # what was kept. The system author like every other runner line — never
  # the agent's, which the tape reads as its own speech. The sentence is
  # `Aqua.Notes.describe/1`'s, one per outcome the domain mints.
  @doc false
  def note_kept(state, :approved, intent, %{result: result}) do
    case {proposal_of(intent), Aqua.Notes.describe(result)} do
      {%{tool: "notes"}, line} when is_binary(line) ->
        Aqua.Runner.Recovery.append_and_broadcast(state, %{
          author: @system_author,
          kind: "system",
          content: line
        })

      _ ->
        state
    end
  end

  def note_kept(state, _outcome, _intent, _payload), do: state

  # A standing approval is a row now, not a `MapSet` that a restart
  # discards and not an edit to the agent's authored markdown.
  # `:conversation` reaches this thread, `:always` every thread the agent
  # runs in — and `Aqua.ToolGrants` refuses the latter for an agent this
  # estate does not own.
  @doc false
  def apply_scope(state, ctx, msg, %{tool: tool, action: action}, scope)
      when scope in [:conversation, :always] do
    write_grant(state, ctx, msg, {tool, action}, grant_scope(scope), "allow")
  end

  def apply_scope(state, _ctx, _msg, _proposal, _scope), do: state

  # Decline "never": a standing DENY, which the resolver drops from the
  # policy outright. It used to delete the key from the agent's markdown —
  # the same file the AQUA page edits, so a decline in a chat quietly
  # rewrote the agent's definition for everyone.
  @doc false
  def deny_standing(state, ctx, msg) do
    case proposal_of(approval_intent(msg)) do
      %{tool: tool, action: action} ->
        write_grant(state, ctx, msg, {tool, action}, "agent", "deny")

      _ ->
        state
    end
  end

  @doc false
  def grant_scope(:conversation), do: "conversation"
  def grant_scope(:always), do: "agent"

  # One write path for both effects: record the row for the agent the card
  # names, then re-read the conversation's standing grants so the runner's
  # fast path and the chat's display come from the store rather than a
  # separately-maintained set.
  @doc false
  def write_grant(state, ctx, msg, {tool, action}, scope, effect) do
    case approval_orchestrator(msg) do
      name when is_binary(name) ->
        attrs = %{
          scope: scope,
          effect: effect,
          conversation_id: state.id,
          agent_name: name,
          tool: tool,
          action: action
        }

        case Aqua.ToolGrants.put(ctx, attrs) do
          {:ok, _row} ->
            refresh_grants(state, ctx, name)

          # The click still ran (or declined) this one call; what did NOT
          # happen is the standing answer, and the person who clicked
          # "always" must hear so from the tape, not from a log line.
          {:error, reason} ->
            Logger.warning(
              "[Aqua.ConversationRunner] could not record #{effect} for #{tool}.#{action}: " <>
                inspect(reason)
            )

            Aqua.Runner.Recovery.append_and_broadcast(state, %{
              author: @system_author,
              kind: "system",
              content: not_recorded_note(scope, effect, {tool, action}, reason)
            })
        end

      _ ->
        state
    end
  end

  # Why a standing answer was not recorded, in the words a person can act
  # on: the grant vocabulary's own sentence for a refused scope, the shared
  # renderer for anything else (a storage fault).
  @doc false
  def not_recorded_note(scope, effect, {tool, action}, reason) do
    why =
      case reason do
        {:scope_not_permitted, _} -> Aqua.ToolGrants.refusal_message(reason)
        other -> Aqua.MCPHelpers.render_refusal(other)
      end

    "#{standing_answer(scope, effect)} was not recorded for #{tool}.#{action} — #{why}"
  end

  @doc false
  def standing_answer(_scope, "deny"), do: "\"Never\""
  def standing_answer("agent", "allow"), do: "\"Always\""
  def standing_answer(_conversation, "allow"), do: "\"Always for this conversation\""

  # The conversation's standing allows, re-read whole and keyed by the
  # agent they were answered for — the fast path and the chat's display
  # come from the store, never from a set this process maintains. A store
  # that cannot be read leaves the set as it was: an unreadable answer
  # widens nothing.
  @doc false
  def refresh_grants(state, ctx, _agent_name) do
    case Aqua.ToolGrants.allowed_by_agent(ctx, state.id) do
      {:ok, grants} ->
        %{state | grants: grants} |> Aqua.Runner.Shared.broadcast({:grants, grants})

      {:error, reason} ->
        Logger.warning(
          "[Aqua.ConversationRunner] standing grants not re-read: #{inspect(reason)}"
        )

        state
    end
  end

  @doc false
  def complete_approval(state, ctx, message_id, outcome, payload) do
    case Conversations.get_message(ctx, message_id) do
      {:ok, msg} ->
        intent = approval_intent(msg)
        scope = Conversations.resolution(msg)["scope"]

        {summary, system_text} =
          AquaTurn.outcome_summary(outcome, payload, intent["title"] || "")

        status = if outcome == :approved, do: "approved", else: "error"

        case Conversations.resolve_approval(ctx, message_id, "running", status, %{
               resolution: %{
                 "summary" => summary,
                 # Sanitize before inspect: an arbitrary tool failure term
                 # lands on a row every member reads.
                 "reason" =>
                   payload[:reason] && inspect(Sanctum.Sanitizer.sanitize(payload[:reason])),
                 "scope" => scope
               }
             }) do
          {:ok, updated} ->
            approval_telemetry(state, ctx, updated, outcome, scope, payload[:reason])
            notify_resolved(state, updated)

            state
            |> note_kept(outcome, intent, payload)
            |> append_history(system_text)
            |> Aqua.Runner.Shared.broadcast({:message_updated, updated})
            |> Aqua.Runner.Shared.touch()

          {:error, _} ->
            state
        end

      {:error, _} ->
        state
    end
  end

  # A synthetic turn the agent should see next time. While a turn runs the
  # formula will hand back its own snapshot of the history at the end, so
  # the note is also kept aside and merged into that snapshot.
  @doc false
  def append_history(state, system_text) do
    note = %{"role" => "user", "content" => system_text}
    history = state.history ++ [note]
    Conversations.update(state.system_ctx, state.id, %{history: history})

    notes = if state.running, do: state.notes_in_flight ++ [note], else: state.notes_in_flight
    %{state | history: history, notes_in_flight: notes}
  end

  # The tray: a card someone else was looking at is settled.
  @doc false
  def notify_resolved(state, msg) do
    Sanctum.Notify.broadcast(state.athanor_id, :approval_resolved, %{
      conversation_id: state.id,
      message_id: msg.id,
      status: msg.status,
      resolved_by: msg.resolved_by
    })
  end

  @doc false
  def approval_telemetry(state, ctx, msg, outcome, scope, reason) do
    proposal = proposal_of(approval_intent(msg)) || %{tool: nil, action: nil}
    intent = approval_intent(msg)

    :telemetry.execute([:cyfr, :aqua, :approval], %{count: 1}, %{
      id: msg.id,
      decision: outcome,
      scope: scope_atom(scope),
      tool: proposal[:tool],
      action: proposal[:action],
      kind: intent["action_kind"],
      conversation_id: state.id,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      orchestrator: approval_orchestrator(msg),
      reason: reason
    })
  rescue
    # An approval decision's telemetry is compliance-relevant — dropping
    # it must leave a trace, even though it must not fail the decision.
    e ->
      Logger.warning(
        "[Aqua.ConversationRunner] approval telemetry dropped: " <> Exception.message(e)
      )

      :ok
  end

  @doc false
  def scope_atom(scope), do: Aqua.ApprovalScope.parse(scope)

  # The intent as stored on the row (string keys after the JSON round trip).
  @doc false
  def approval_intent(msg), do: Conversations.payload(msg)["intent"] || %{}
  @doc false
  def approval_orchestrator(msg), do: Conversations.payload(msg)["orchestrator"]

  @doc false
  def proposal_of(%{"proposal" => %{"tool" => tool, "action" => action} = p})
      when is_binary(tool) and is_binary(action),
      do: %{tool: tool, action: action, args: p["args"] || %{}}

  def proposal_of(_), do: nil

  @doc false
  def atomize_intent(intent), do: %{proposal: proposal_of(intent)}
end
