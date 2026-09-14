# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Approvals do
  @moduledoc """
  A card is decided: authorised again from its own rows, its standing
  answer recorded with the decision, and the turn told.

  `resolve/3` is the one door for a person's decision, from the console
  and the wire alike. It decides before it writes: a decision already
  made is answered again without a second effect (the same identity, as
  a replay); a card whose proposal no longer matches its approval's
  digest, or whose pins moved, resolves `error`; a card past its expiry
  resolves `expired`. An approval is a decision about the turn's pinned
  authority: the turn's profile at its pinned consent, and the agent as
  it was when the turn started, must still be what they were — else the
  approval resolves `error`, the turn fails, and the sender starts again.

  The decision, the step's fate, the card's status and the standing
  grant rows land in one transaction (`Aqua.Tape.resolve_approval/5`).
  A launch is not run here: the approved step is consumed by the loop
  through `Aqua.Launch`.
  """

  require Logger

  alias Aqua.Orchestrator
  alias Aqua.Standing
  alias Aqua.Tape
  alias Sanctum.Context

  @type choice :: %{
          required(:decision) => :approved | :declined,
          optional(:scope) => Standing.scope(),
          optional(:reason) => String.t() | nil
        }

  @type outcome :: %{
          approval_id: String.t(),
          turn_id: String.t(),
          step_id: String.t(),
          thread_id: String.t(),
          decision: String.t(),
          resolution_kind: String.t() | nil,
          replayed: boolean(),
          pending: non_neg_integer()
        }

  @doc """
  Decide a pending approval as the calling person. `choice`: `:decision`
  (`:approved` | `:declined`), `:scope` (`:once` by default; `:thread`
  or `:always` with an approval, `:never` with a decline), `:reason`.

  Answers the outcome, with `pending` the turn's approvals still open
  after this one. `{:error, :not_found}` for no such approval;
  `{:error, {:scope_not_permitted, _}}` when the scope may not stand for
  the action; `{:error, :turn_superseded}` when the turn's pins moved and
  the turn was failed.
  """
  @spec resolve(Context.t(), String.t(), choice()) :: {:ok, outcome()} | {:error, term()}
  def resolve(%Context{} = ctx, approval_id, %{decision: decision} = choice)
      when decision in [:approved, :declined] do
    scope = Map.get(choice, :scope) || :once

    with {:ok, approval} <- fetch_approval(ctx, approval_id),
         {:ok, turn} <- Tape.turn(ctx, approval.turn_id),
         {:ok, step} <- Tape.step(ctx, approval.step_id),
         {:ok, card} <- Tape.message(ctx, approval.message_id) do
      intent = Arca.ThreadStorage.payload(card)["intent"] || %{}

      cond do
        approval.status != "pending" ->
          {:ok, outcome(ctx, approval, step, true)}

        not digest_matches?(approval, intent) ->
          settle(ctx, turn, approval, "error", %{
            resolution_kind: "denied",
            reason: "the card no longer matches its approval",
            denied_result: denied_result(intent, "the card no longer matches its approval")
          })

        expired?(approval) ->
          settle(ctx, turn, approval, "expired", %{
            resolution_kind: "expired",
            reason: "expired",
            denied_result: denied_result(intent, "the card expired before it was decided")
          })

        decision == :declined ->
          decline(ctx, turn, approval, intent, scope, Map.get(choice, :reason))

        true ->
          approve(ctx, turn, approval, step, intent, scope)
      end
    end
  end

  @doc """
  How long a card stays open, in seconds: the estate's
  `settings["approvals"]["expiry_hours"]` (a positive integer, read
  defensively — member-writable settings are not trusted to have a
  shape), else `config :cyfr, Aqua.Approvals, expiry_hours:`.
  """
  @spec ttl_seconds(Context.t()) :: pos_integer()
  def ttl_seconds(%Context{} = ctx) do
    configured =
      with {:ok, athanor} <- Sanctum.Tenancy.Athanors.get(Context.athanor!(ctx)),
           %{"approvals" => %{"expiry_hours" => hours}} <-
             Sanctum.Tenancy.Athanors.settings(athanor),
           hours when is_integer(hours) and hours > 0 <- hours do
        hours
      else
        _ -> nil
      end

    default =
      case Keyword.get(Application.get_env(:cyfr, __MODULE__, []), :expiry_hours, 24) do
        hours when is_integer(hours) and hours > 0 -> hours
        _ -> 24
      end

    (configured || default) * 3600
  end

  @doc """
  Resolve every pending approval of the estate past its expiry as
  `expired`. Answers how many were settled.
  """
  @spec expire_due(Context.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expire_due(%Context{} = ctx) do
    with {:ok, approvals} <- Tape.expired_approvals(ctx) do
      settled =
        Enum.count(approvals, fn approval ->
          with {:ok, turn} <- Tape.turn(ctx, approval.turn_id),
               {:ok, card} <- Tape.message(ctx, approval.message_id) do
            intent = Arca.ThreadStorage.payload(card)["intent"] || %{}

            match?(
              {:ok, _},
              settle(ctx, turn, approval, "expired", %{
                resolution_kind: "expired",
                reason: "expired",
                denied_result: denied_result(intent, "the card expired before it was decided")
              })
            )
          else
            _ -> false
          end
        end)

      {:ok, settled}
    end
  end

  # ---------------------------------------------------------------------------
  # Decisions
  # ---------------------------------------------------------------------------

  defp approve(ctx, turn, approval, step, intent, scope) do
    proposal = intent["proposal"] || %{}

    with :ok <- Standing.check(intent, scope),
         :ok <- authorize_card(ctx, turn, proposal),
         :ok <- pins_hold(ctx, turn, approval, intent),
         {:ok, grants} <- Standing.rows(ctx, turn, proposal, scope) do
      kind = if step.kind == "launch", do: "launch", else: "continue"

      settle(ctx, turn, approval, "approved", %{
        scope: Atom.to_string(scope),
        resolution_kind: kind,
        resolution: %{"summary" => "approved", "scope" => Atom.to_string(scope)},
        grants: grants
      })
    else
      {:error, {:scope_not_permitted, _}} = refusal ->
        refusal

      {:error, {:stale_card, why}} ->
        settle(ctx, turn, approval, "error", %{
          resolution_kind: "denied",
          reason: why,
          denied_result: denied_result(intent, why)
        })

      {:error, {:superseded, why}} ->
        settle(ctx, turn, approval, "error", %{
          resolution_kind: "denied",
          reason: why,
          denied_result: denied_result(intent, why),
          superseded: true
        })

      {:error, _} = error ->
        error
    end
  end

  defp decline(ctx, turn, approval, intent, scope, reason) do
    proposal = intent["proposal"] || %{}
    reason = if is_binary(reason) and reason != "", do: reason, else: nil
    why = if reason, do: "declined: #{reason}", else: "declined"

    with {:ok, grants} <- Standing.rows(ctx, turn, proposal, scope) do
      settle(ctx, turn, approval, "declined", %{
        scope: Atom.to_string(scope),
        resolution_kind: "denied",
        reason: reason,
        resolution: %{"summary" => why, "reason" => reason, "scope" => Atom.to_string(scope)},
        denied_result: denied_result(intent, why),
        grants: grants
      })
    end
  end

  # The one transaction, then the turn's fate and the telemetry. A card
  # whose pins moved ends the turn: the sender starts again under the
  # consent as it stands now.
  defp settle(ctx, turn, approval, decision, attrs) do
    attrs = Map.put_new(attrs, :decided_by, ctx.user_id)

    case Tape.resolve_approval(ctx, turn, approval.id, decision, attrs) do
      {:ok, %{approval: resolved, step: step}} ->
        telemetry(ctx, turn, resolved, step, attrs)

        if attrs[:superseded] do
          _ = Tape.finish(ctx, turn, "failed", %{error: attrs[:reason]})
          {:error, :turn_superseded}
        else
          {:ok, outcome(ctx, resolved, step, false)}
        end

      {:error, {:already_resolved, resolved}} ->
        with {:ok, step} <- Tape.step(ctx, resolved.step_id),
             do: {:ok, outcome(ctx, resolved, step, true)}

      {:error, _} = error ->
        error
    end
  end

  defp outcome(ctx, approval, step, replayed?) do
    pending =
      case Tape.turn(ctx, approval.turn_id) do
        {:ok, turn} ->
          case Tape.pending_approvals(ctx, turn) do
            {:ok, rows} -> length(rows)
            _ -> 0
          end

        _ ->
          0
      end

    %{
      approval_id: approval.id,
      turn_id: approval.turn_id,
      step_id: step.id,
      thread_id: approval.thread_id,
      decision: approval.status,
      resolution_kind: approval.resolution_kind,
      replayed: replayed?,
      pending: pending
    }
  end

  # ---------------------------------------------------------------------------
  # Checks
  # ---------------------------------------------------------------------------

  defp fetch_approval(ctx, approval_id) when is_binary(approval_id) do
    case Tape.approval(ctx, approval_id) do
      {:ok, approval} -> {:ok, approval}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp fetch_approval(_ctx, _id), do: {:error, :not_found}

  # A card is consumed by the digest of the proposal it showed.
  defp digest_matches?(%{proposal_digest: ""}, _intent), do: true
  defp digest_matches?(%{proposal_digest: nil}, _intent), do: true

  defp digest_matches?(%{proposal_digest: digest}, %{"proposal" => proposal})
       when is_map(proposal),
       do: Aqua.Loop.Policy.proposal_digest(proposal) == digest

  defp digest_matches?(_approval, _intent), do: false

  defp expired?(%{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :lt

  defp expired?(_approval), do: false

  # The card's pair against the CURRENT policy of the turn's agent: the
  # definition as the tree holds it now, composed with the standing rows
  # as they stand now. A "never" since the card was raised wins; an agent
  # gone from the roster or a pair it no longer holds makes the card
  # stale. A confirmation card with no proposal has nothing to check.
  defp authorize_card(_ctx, _turn, proposal) when map_size(proposal) == 0, do: :ok

  defp authorize_card(ctx, turn, %{"tool" => tool, "action" => action})
       when is_binary(tool) and is_binary(action) do
    name = turn.orchestrator

    with {:ok, orchestrator} <- Orchestrator.resolve(ctx, Orchestrator.by_name(name)),
         {:ok, rows} <- Aqua.ToolGrants.for_thread(ctx, turn.thread_id, name) do
      policy = orchestrator |> Orchestrator.with_grants(rows) |> Orchestrator.tool_policy()

      case Map.get(policy, "#{tool}.#{action}") do
        mode when mode in ["ask", "auto"] ->
          :ok

        "deny" ->
          {:error,
           {:stale_card, "#{tool}.#{action} was declined for good since this card was raised"}}

        _ ->
          {:error, {:stale_card, "#{name} no longer holds #{tool}.#{action} — the card is stale"}}
      end
    else
      {:error, :no_orchestrator} -> {:error, {:stale_card, "#{name} is no longer on the roster"}}
      {:error, {:unavailable, what}} -> {:error, {:unavailable, what}}
    end
  end

  defp authorize_card(_ctx, _turn, _proposal),
    do: {:error, {:stale_card, "the card names no call"}}

  # Pin equality: the profile the turn pinned, loaded again at its head,
  # must still be at the pinned consent, and the agent as the tree holds
  # it now must still have the capability digest the turn started under.
  # A turn that pinned no profile cannot be resumed under any authority.
  # The lender pins the executor re-verifies on every run are not
  # decided here.
  defp pins_hold(_ctx, %{profile_id: nil}, _approval, _intent),
    do: {:error, {:superseded, "the turn pinned no profile — send the message again"}}

  defp pins_hold(ctx, turn, _approval, _intent) do
    with :ok <- consent_holds(ctx, turn),
         :ok <- capability_holds(ctx, turn) do
      :ok
    else
      {:error, why} -> {:error, {:superseded, why}}
    end
  end

  defp consent_holds(ctx, turn) do
    case Cyfr.Execution.authority_for(
           ctx,
           {:id, turn.profile_id},
           Compendium.AgentSource.soul_ref()
         ) do
      {:ok, %{consent_id: consent_id}} when consent_id == turn.consent_id ->
        :ok

      {:ok, _moved} ->
        {:error, "the consent the turn ran under has moved"}

      {:error, reason} ->
        {:error, "the turn's consent could not be loaded: #{Aqua.Ops.render_refusal(reason)}"}
    end
  end

  defp capability_holds(_ctx, %{agent_capability_digest: nil}), do: :ok

  defp capability_holds(ctx, %{orchestrator: name, agent_capability_digest: pinned}) do
    with {:ok, agent} <- Compendium.AquaAgent.get(ctx, name),
         {:ok, ^pinned} <- Compendium.AquaAgent.capability_digest(agent) do
      :ok
    else
      {:ok, _other} -> {:error, "#{name} changed since the turn started"}
      {:error, _} -> {:error, "#{name} is no longer on the roster"}
    end
  end

  # ---------------------------------------------------------------------------
  # Rows and telemetry
  # ---------------------------------------------------------------------------

  # What a refused step leaves for the model: its tool result, an error.
  defp denied_result(intent, why) do
    proposal = intent["proposal"] || %{}

    %{
      content: why,
      payload: %{
        "tool_call_id" => intent["tool_call_id"],
        "name" => proposal["tool"] && "#{proposal["tool"]}.#{proposal["action"]}",
        "is_error" => true
      }
    }
  end

  defp telemetry(ctx, turn, approval, _step, attrs) do
    :telemetry.execute([:cyfr, :aqua, :approval], %{count: 1}, %{
      id: approval.id,
      decision: approval.status,
      scope: Aqua.ApprovalScope.parse(approval.scope),
      resolution_kind: approval.resolution_kind,
      thread_id: turn.thread_id,
      turn_id: turn.id,
      user_id: ctx.user_id,
      athanor_id: Context.athanor!(ctx),
      orchestrator: turn.orchestrator,
      reason: attrs[:reason]
    })
  rescue
    # An approval decision's telemetry is compliance-relevant: dropping it
    # leaves a trace, and never fails the decision.
    e ->
      Logger.warning("[Aqua.Approvals] approval telemetry dropped: " <> Exception.message(e))
      :ok
  end
end
