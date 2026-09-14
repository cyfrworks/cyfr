# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Clone do
  @moduledoc """
  A role the soul clones into: its own turn under the parent's root,
  attempt and deadline, run by the parent's exclusive worker as a loop
  of its own — its own steps through workers of its own, its own policy,
  catalyst and prompt, its own rows. A clone never pauses: what asks is
  refused, and a launch is not its to make. Its last reply is the
  parent's tool result.

  The clone runs under the soul's authority stepped along the soul → role
  consent edge (`authority/4`): the soul's profile, consent and budget,
  the role's cursor, edges and key selections. The role's file is
  snapshotted at clone start; its release digest must equal the one the
  soul's consent names for the role, and the snapshot's revision and
  capability digests are pinned on the clone's row before its spec is
  built, so the clone runs the bytes that were checked.
  """

  alias Aqua.Loop.Binding.Call
  alias Aqua.Loop.Turn
  alias Aqua.Tape
  alias Arca.Schemas.Message
  alias Compendium.AgentSource
  alias Cyfr.Authority
  alias Cyfr.Authority.Transition

  @type refusal ::
          {:no_role_edge, String.t()}
          | {:role_shape_moved, String.t()}
          | {:clone_denied, term()}

  @spec run(Aqua.Loop.State.t(), Tape.step(), Call.t()) ::
          {:ok, String.t()} | {:error, String.t()} | {:uncertain, String.t()}
  def run(%Aqua.Loop.State{} = parent, step, %Call{kind: :clone, target: role, args: args}) do
    task = if is_binary(args["task"]), do: args["task"], else: ""
    guest = parent.spec.guest
    ctx = parent.spec.ctx

    with {:ok, definition} <- Turn.role(parent.spec, role),
         :ok <- intact(ctx, parent.spec.authority),
         {:ok, snapshot} <- Compendium.AgentIndex.snapshot(ctx, role),
         {:ok, child} <- authority(parent.spec.authority, role, snapshot, roster(parent.spec)),
         {:ok, %{turn: clone}} <-
           Tape.open_clone_turn(guest, parent.turn, %{
             role: role,
             task: task,
             model: definition["model"],
             step_id: step.id,
             profile_id: child.profile_id,
             consent_id: child.consent_id,
             agent_revision_digest: snapshot.revision_digest,
             agent_capability_digest: snapshot.capability_digest
           }),
         {:ok, spec} <- build(guest, ctx, clone, child, parent) do
      state = %Aqua.Loop.State{
        spec: spec,
        claim: nil,
        turn: spec.turn,
        parent: parent,
        clone?: true,
        since: parent.since,
        active_ms: parent.active_ms
      }

      {result, ended} = Aqua.Loop.loop(state)
      {status, error} = terminal(result)
      _ = Tape.close_clone_turn(guest, ended.turn, status, %{error: error})

      case result do
        :completed -> {:ok, last_reply(guest, ended.turn)}
        {:uncertain, _} -> {:uncertain, "the #{role} role stopped: #{error}"}
        _ -> {:error, "the #{role} role did not finish: #{error}"}
      end
    else
      {:error, :no_such_role} ->
        {:error, "no role named #{role}"}

      {:error, :consent_moved} ->
        {:error, "the soul's consent is no longer in force"}

      {:error, {:no_role_edge, _}} ->
        {:error, "the soul's consent names no edge to #{role}"}

      {:error, {:role_shape_moved, _}} ->
        {:error, "the soul must re-consent to the changed #{role} role"}

      {:error, {:clone_denied, reason}} ->
        {:error, "cloning into #{role} was refused: #{describe(reason)}"}

      {:error, reason} ->
        {:error, Aqua.Ops.render_refusal(reason)}
    end
  end

  @doc """
  The authority a clone of `role` runs under, from the soul's `parent`
  authority: the release digest the soul's consent names for the role
  (`activation[role_ref]`) must equal the one `snapshot` projects under
  `roster` (the estate's enabled agent names), then the soul → role edge
  is stepped as a synchronous call — the soul's profile, consent and
  budget with the role's cursor and edge resources. `{:error, refusal}`
  when the soul names no edge to the role, the role's shape moved since
  the soul consented, or the transition refuses.
  """
  @spec authority(Authority.t(), String.t(), map(), MapSet.t(String.t())) ::
          {:ok, Authority.t()} | {:error, refusal()}
  def authority(%Authority{} = parent, role, %{agent: agent} = _snapshot, %MapSet{} = roster)
      when is_binary(role) do
    ref = AgentSource.ref(role)

    with {:ok, consented} <- consented_release(parent, ref, role),
         :ok <- check_release(consented, agent, roster, role) do
      step_edge(parent, ref, role)
    end
  end

  defp consented_release(%Authority{activation: activation}, ref, role) do
    case Map.fetch(activation || %{}, ref) do
      {:ok, digest} when is_binary(digest) -> {:ok, digest}
      _ -> {:error, {:no_role_edge, role}}
    end
  end

  defp check_release(consented, agent, roster, role) do
    if AgentSource.row(agent, roster).release_digest == consented,
      do: :ok,
      else: {:error, {:role_shape_moved, role}}
  end

  # The transition walks the edge and selects the key; it does no consent
  # check of its own (`activation_digest` only detects self-invocation),
  # so nothing is passed there.
  defp step_edge(parent, ref, role) do
    target = {:invoke, %{reference: ref, need: nil, activation_digest: nil, declared_needs: []}}

    case Transition.step(parent, :call, target) do
      {:child, %Authority{cursor: {:bound, _}} = child} -> {:ok, child}
      {:child, _unbound} -> {:error, {:no_role_edge, role}}
      {:child_zero, _} -> {:error, {:no_role_edge, role}}
      {:deny, reason} -> {:error, {:clone_denied, reason}}
      {:invalid, reason} -> {:error, {:clone_denied, reason}}
      other -> {:error, {:clone_denied, other}}
    end
  end

  defp roster(%Turn{roster: roster}), do: MapSet.new(roster, & &1["name"])

  # A revocation mid-turn lets the in-flight call finish and refuses the
  # next transition; a clone is one. The pinned profile is loaded again
  # through the port: its head must still be the pinned consent.
  defp intact(ctx, %Authority{profile_id: profile_id, consent_id: consent_id, source_ref: ref}) do
    case Cyfr.Execution.authority_for(ctx, {:id, profile_id}, ref) do
      {:ok, %Authority{consent_id: ^consent_id}} -> :ok
      _ -> {:error, :consent_moved}
    end
  end

  # The spec is built from the pinned row and the release it resolves is
  # pinned on the clone's row; a row that cannot carry a spec is closed
  # before the refusal is answered.
  defp build(guest, ctx, clone, child, parent) do
    with {:ok, spec} <-
           Turn.build(ctx, clone,
             authority: child,
             catalyst: parent.spec.catalyst,
             model: parent.spec.model,
             excerpt?: false
           ),
         {:ok, pinned} <- Tape.pin_catalyst(guest, clone, spec.catalyst) do
      {:ok, Turn.with_turn(spec, pinned)}
    else
      {:error, reason} ->
        _ = Tape.close_clone_turn(guest, clone, "failed", %{error: describe(reason)})
        {:error, reason}
    end
  end

  defp terminal(:completed), do: {"completed", nil}
  defp terminal(:cancelled), do: {"cancelled", "stopped"}
  defp terminal({:paused, _}), do: {"failed", "a role cannot pause"}
  defp terminal({:failed, reason}), do: {"failed", describe(reason)}
  defp terminal({:uncertain, reason}), do: {"uncertain", describe(reason)}

  defp last_reply(guest, clone) do
    agent = Message.agent_author()

    case Tape.projection(guest, clone) do
      {:ok, rows} ->
        rows
        |> Enum.filter(fn row ->
          row.kind == "text" and row.author == agent and
            Tape.payload(row)["as"] != "task"
        end)
        |> List.last()
        |> case do
          %{content: content} when is_binary(content) and content != "" -> content
          _ -> "(the role answered nothing)"
        end

      _ ->
        "(the role's reply could not be read)"
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: Aqua.Ops.render_refusal(reason)
end
