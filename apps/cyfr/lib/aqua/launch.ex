# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Launch do
  @moduledoc """
  The one dispatcher of an approved launch. A `launch` step — an
  `execution.run` of something that is neither a hand nor an agent,
  approved by a member — becomes an external-plane `execution.run` as
  that member: the application roots its own consent, and the turn's
  pinned authority is never widened into it.

  The input is the durable step alone. The approver's context is rebuilt
  from the approval's `decided_by` (`Sanctum.Tenancy.continuation/3`), so
  a launch consumed after a restart runs as the person who decided it, or
  not at all: a person no longer seated refuses it. It carries the origin
  stored on the approved turn's row, never one inferred from the person
  approving: a programmatic turn's launch stays `programmatic`, and a
  turn whose row stores no origin launches nothing
  (`{:approver_unavailable, :no_origin}`). The loop marks the step
  dispatched before calling here, which is what makes a launch happen
  once.

  A launch naming an account (`connection`) runs under the account its
  card showed, or not at all. The card's proposal binds the account as
  its binding stored the name, and the entry it resolved to when the card
  was drawn (`vault_entry`); before anything runs the name is resolved
  again, as the approver, from the app's stored head
  (`Sanctum.Consent.Accounts.resolve/4`, the one read the assistant's
  policy resolves it by), and a different entry, a name the head no
  longer binds or now stores otherwise, or an account the card did not
  show is refused as a stale approval, a conflict that says to ask again.
  The run is asked for under the stored name, and itself picks the named
  binding as its root's vault (`Crucible.run_root/5`); a head that moves
  between this check and the run's own admission is resolved there
  again, by name.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @launch_actions ~w(run run_stream)

  @doc """
  Run the launch the step was approved for, as its approver. Answers the
  execution the application started (`execution_id` is nil when the
  answer names none) with the tool's whole result, or the refusal.
  """
  @spec dispatch(Context.t(), Tape.step()) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}} | {:error, term()}
  def dispatch(%Context{} = ctx, %{approval_id: approval_id}) when is_binary(approval_id) do
    with {:ok, approval} <- Tape.approval(ctx, approval_id),
         :ok <- approved_launch(approval),
         {:ok, card} <- Tape.message(ctx, approval.message_id),
         :ok <- card_approved(approval, card),
         {:ok, args} <- launch_args(card),
         {:ok, approver} <- approver(ctx, approval),
         :ok <- account_holds(approver, card, args) do
      case Aqua.Ops.call_tool("execution", approver, args) do
        {:ok, result} -> {:ok, %{execution_id: execution_id(result), result: result}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def dispatch(_ctx, _step), do: {:error, :not_approved}

  defp approved_launch(%{status: "approved", resolution_kind: "launch"}), do: :ok
  defp approved_launch(_approval), do: {:error, :not_approved}

  # The launch runs what the approval was opened for, or nothing.
  defp card_approved(approval, card) do
    proposal = get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal"])

    if Aqua.Approvals.proposal?(approval, proposal),
      do: :ok,
      else: {:error, {:invalid_argument, "the card no longer matches its approval"}}
  end

  # The proposal the card carried, as the model wrote it and the person
  # saw it. The assistant itself is never launched, and a wrapped
  # catalyst is a hand, not a launch — both are decided again at this
  # last door, whatever the card said.
  defp launch_args(card) do
    case get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal"]) do
      %{"tool" => "execution", "action" => action, "args" => args}
      when action in @launch_actions and is_map(args) ->
        reference = args["reference"]

        cond do
          not is_binary(reference) ->
            {:error, {:invalid_argument, "execution.#{action} needs a reference"}}

          Prima.AgentRef.agent_ref?(reference) ->
            {:error, {:invalid_argument, "an agent is not a tool to run"}}

          Aqua.Hands.hand_catalyst?(reference) ->
            {:error, {:invalid_argument, "#{reference} is a hand, not a launch"}}

          true ->
            {:ok,
             args
             |> Map.put("action", action)
             |> Map.drop(["parent_execution_id", "root_execution_id", "thread_id"])}
        end

      _ ->
        {:error, {:invalid_argument, "the card carries no launch"}}
    end
  end

  # The account the card showed is the account the launch runs under: the
  # stored name its arguments carry still resolves, as the approver, to the
  # entry its proposal bound, under that name as the binding stores it. A
  # launch naming none runs under the default, and its card bound no entry.
  defp account_holds(approver, card, args) do
    shown = get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal", "vault_entry"])
    stored = args["connection"]

    case {shown, launch_account(approver, args)} do
      {nil, {:ok, nil}} -> :ok
      {entry_id, {:ok, %{entry_id: entry_id, name: ^stored}}} when is_binary(entry_id) -> :ok
      {_shown, {:error, reason}} when reason != :connection_not_granted -> {:error, reason}
      _another_account_or_none -> stale(stored)
    end
  end

  # The entry the account an `execution.run` names resolves to on the
  # app's own profile, by the one read of it; none for a launch naming no
  # account, and for a stream, which declares none and is refused naming
  # one by the gate.
  defp launch_account(approver, %{"action" => "run", "connection" => name} = args)
       when is_binary(name) do
    Sanctum.Consent.Accounts.resolve(
      approver,
      Prima.Authority.RootSelect.decode(args["profile"]),
      args["reference"],
      name
    )
  end

  defp launch_account(_approver, _args), do: {:ok, nil}

  defp stale(name) do
    account = if is_binary(name), do: "The account #{inspect(name)}", else: "The default account"

    {:error,
     {:conflict,
      account <>
        " is not the one this launch was approved for, so nothing ran: ask again to " <>
        "approve the account as it stands now"}}
  end

  # The approver continues the turn the approval was opened in, under the
  # origin that turn's row stores.
  defp approver(%Context{} = ctx, %{decided_by: user_id, turn_id: turn_id})
       when is_binary(user_id) and is_binary(turn_id) do
    with {:ok, turn} <- Tape.turn(ctx, turn_id) do
      case Sanctum.Tenancy.continuation(user_id, Context.athanor!(ctx), turn.origin) do
        {:ok, approver} -> {:ok, approver}
        {:error, reason} -> {:error, {:approver_unavailable, reason}}
      end
    end
  end

  defp approver(_ctx, _approval), do: {:error, {:approver_unavailable, :denied}}

  defp execution_id(%{execution_id: id}) when is_binary(id), do: id
  defp execution_id(%{"execution_id" => id}) when is_binary(id), do: id
  defp execution_id(_result), do: nil
end
