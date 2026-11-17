# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.Inputs do
  @moduledoc """
  The host calls a runner makes for its invocation's further inputs
  (`cyfr:model/inputs`): `input_next` and `input_sent` (`Prima.HostAPI`),
  each answered by the supplier the invocation was started with
  (`Opus.Inputs`).

  `Opus.Host` verifies each call and reads its args before it reaches
  here. The attempt must be held by the calling runner and live, as for a
  pipe call: `Opus.Attempt.call/3` with `:inputs` answers the supplier and
  the invocation's trusted identity only then, and the call is `lost` or
  `unavailable` otherwise, with nobody asked. The supplier is asked in
  the host call's own process, so a supplier slow to answer holds up none
  of the attempt's other calls.

  ## Next

  A supplier's input is held to `Prima.Model.check_input/1`; one that
  breaks it is the guest error `invalid_request` naming the member. The
  attempt is then checked again, under a nonce of this step's own derived
  from the header's, before the input is answered: an invocation stopped
  while its supplier answered is `lost` and is handed nothing. Bytes
  answered past that check cannot be recalled (`Opus.Inputs`).

  The read is `nil` only with no supplier or one that answers it has
  none. A supplier that is gone, does not answer within
  `Opus.Inputs.answer_ms/0` or answers what is no answer of the port's is
  `unavailable`, so a runner tells a supplier that failed from one with
  nothing to hand.

  ## Sent

  The report reaches the supplier only past the attempt's check, and is
  `:ok` only once the supplier answered that it recorded it; no supplier,
  one that is gone or one that does not answer is `unavailable`, and the
  runner may report again.

  Nothing an input carries is logged: a refusal is logged by the member
  that broke it alone.
  """

  require Logger

  alias Opus.Attempt

  @doc "The caller's invocation's next input, or nil."
  @spec next(Attempt.caller()) :: {:ok, Prima.Model.input() | nil} | {:error, term()}
  def next(caller) do
    with {:ok, supplier, invocation} <- Attempt.call(caller.execution_id, caller, :inputs) do
      case supplier && Opus.Inputs.next(supplier, invocation) do
        nil -> {:ok, nil}
        {:ok, {:ok, input}} -> release(caller, input)
        {:ok, :none} -> {:ok, nil}
        _gone_silent_or_no_answer -> {:error, :unavailable}
      end
    end
  end

  @doc "Report to the caller's invocation's supplier that the input `id` was handed on."
  @spec sent(Attempt.caller(), String.t()) :: :ok | {:error, term()}
  def sent(caller, id) do
    with {:ok, supplier, invocation} <- Attempt.call(caller.execution_id, caller, :inputs) do
      case supplier && Opus.Inputs.sent(supplier, invocation, id) do
        {:ok, :ok} -> :ok
        _unrecorded -> {:error, :unavailable}
      end
    end
  end

  # Checked whole, then the attempt again: an input reaches the runner only
  # while its invocation still holds its attempt.
  defp release(caller, input) do
    case Prima.Model.check_input(input) do
      :ok ->
        case Attempt.call(caller.execution_id, step(caller), :inputs) do
          {:ok, _supplier, _invocation} -> {:ok, input}
          {:error, _lost_or_unavailable} = refused -> refused
        end

      {:error, {:invalid, member}} ->
        refused(member)
    end
  end

  defp step(caller), do: %{caller | nonce: caller.nonce <> "/input"}

  defp refused(member) do
    Logger.warning(
      "[Opus.Host.Inputs] a supplier answered an input that does not read: #{member}"
    )

    {:error,
     {:guest_error, "invalid_request", "The input the run was handed does not read (#{member})."}}
  end
end
