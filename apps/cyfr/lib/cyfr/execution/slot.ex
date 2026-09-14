# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Slot do
  @moduledoc """
  One execution slot for the calling process: the semaphore's slot and
  the registry entry that lets a cancel find the process, taken and
  released together. The WASM path takes one around a component call; a
  host loop takes a `:root` slot around a turn without entering the
  WASM path. Both are keyed on `self()`: the process that acquires is
  the process that releases, and the semaphore's monitor releases for a
  process that dies.
  """

  @type token :: %{registered: boolean(), execution_id: String.t() | nil}

  @doc """
  Take a slot of `class` for `tenant`, waiting at most `timeout` ms, and
  register `execution_id` (when given) as this process's. Answers the
  token `release/1` takes back, or the refusal sentence the semaphore's
  answer means.
  """
  @spec acquire(Cyfr.Execution.Semaphore.class(), String.t() | nil, timeout(), String.t() | nil) ::
          {:ok, token()} | {:error, String.t()}
  def acquire(class, tenant, timeout, execution_id) do
    case Cyfr.Execution.Semaphore.acquire(timeout, class, tenant) do
      :ok ->
        {:ok, %{registered: register(execution_id), execution_id: execution_id}}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  @doc "Give the slot back and drop the registration, from the acquiring process."
  @spec release(token()) :: :ok
  def release(%{registered: registered?, execution_id: execution_id}) do
    Cyfr.Execution.Semaphore.release()
    if registered?, do: Registry.unregister(Cyfr.Execution.Registry, execution_id)
    :ok
  end

  @doc "The sentence a semaphore refusal means to the caller."
  @spec refusal(:queue_full | :tenant_limit | :tenant_unreaped_limit) :: String.t()
  def refusal(:queue_full), do: "Server at maximum concurrent executions. Retry later."
  def refusal(:tenant_limit), do: "Athanor at maximum concurrent executions. Retry later."

  def refusal(:tenant_unreaped_limit),
    do:
      "Athanor has too many recently timed-out executions whose CPU could not be " <>
        "reclaimed. Wait a few minutes, and check for components that never yield."

  # Register the execution's driving process for cancellation. An existing
  # registration by the same process is a no-op.
  defp register(nil), do: false

  defp register(execution_id) do
    case Registry.register(Cyfr.Execution.Registry, execution_id, :running) do
      {:ok, _} -> true
      {:error, {:already_registered, _}} -> false
    end
  end
end
