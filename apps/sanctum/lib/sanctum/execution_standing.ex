# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ExecutionStanding do
  @moduledoc """
  Whether admitted work still stands: the decision over an execution's
  grant (`Prima.ExecutionGrant`).

  A root is admitted under a grant `capture/1` reads from its estate's
  current active standing, and every attempt stores it. An archive raises
  the estate's generation and a reopen raises it again, so the grant of
  work admitted before an archive never stands again: `verify/1` refuses
  it for good, whether or not anyone heard of the archive. A reopened
  estate admits fresh roots under a fresh grant; an old one is never
  rebuilt from the standing it has now.

  `verify/1` is asked inside the execution write's own transaction
  (`Arca.ExecutionStanding`), which it passes to the storage APIs as their
  `verify:` check. It holds the estate's row shared: execution writes and
  host effects never wait for one another on it, while an archive waits
  for each of them and each waits for an archive — a write that commits
  first is retired by the archive, and one that waits reads the archive's
  result.

  `stamp_only/1` is the check a retirement runs instead — a failure, a
  cancel, a lease lapse and the sweep's cancellation of retired work
  (`Cyfr.Boundaries.system_responsibilities/0`). It asks nothing of the
  estate: the storage write still requires the attempt to carry the
  grant's stamp, and a retirement can end work but never report its
  success.

  `retired_attempts/3` lists, for the sweep, the open attempts whose stamp
  no longer stands.
  """

  alias Sanctum.Context

  @doc """
  The grant a root admitted in `ctx` runs under: its focused estate, at
  the generation it stands at now. `{:error, :not_standing}` for a context
  focused on no estate, or on one that is not active;
  `{:error, :unavailable}` when the store cannot answer.
  """
  @spec capture(Context.t()) ::
          {:ok, Prima.ExecutionGrant.t()} | {:error, :not_standing | :unavailable}
  def capture(%Context{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "" do
    case Arca.ExecutionStanding.current(Prima.Actor.in_athanor(athanor_id), athanor_id) do
      {:ok, row} -> grant_of(row)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def capture(%Context{}), do: {:error, :not_standing}

  @doc """
  Whether `grant` stands: its estate exists, is active and is at exactly
  the grant's generation, read under the estate row's shared lock. Only
  inside an execution write's transaction; raises outside one. `:ok`,
  `{:error, :not_standing}`, or `{:error, :unavailable}` when the store
  cannot answer.
  """
  @spec verify(Prima.ExecutionGrant.t()) :: :ok | {:error, :not_standing | :unavailable}
  def verify(%Prima.ExecutionGrant{athanor_id: athanor_id, generation: generation}) do
    case Arca.ExecutionStanding.locked(Prima.Actor.in_athanor(athanor_id), athanor_id) do
      {:ok, %{status: "active", security_generation: ^generation}} -> :ok
      {:ok, _retired} -> {:error, :not_standing}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc """
  The check a retirement write runs in place of `verify/1`: nothing of
  the estate is asked, and the storage write matches the attempt's stored
  stamp alone. Only a failure, a cancel, a lease lapse and the sweep's
  cancellation pass this; a completion, new output and a renewal pass
  `verify/1`.
  """
  @spec stamp_only(Prima.ExecutionGrant.t()) :: :ok
  def stamp_only(%Prima.ExecutionGrant{}), do: :ok

  @doc """
  Up to `limit` open attempts, after `cursor` in attempt-id order, whose
  stored grant no longer stands, as `{execution_id, attempt, athanor_id,
  stored_generation}`. The server's own actor only; `{:error,
  :unavailable}` when the store cannot answer.
  """
  @spec retired_attempts(Prima.Actor.t(), String.t() | nil, pos_integer()) ::
          {:ok, [Arca.ExecutionStanding.retired()]} | {:error, :unavailable | :cross_tenant}
  def retired_attempts(%Prima.Actor{} = actor, cursor, limit) do
    case Arca.ExecutionStanding.retired_attempts(actor, cursor, limit) do
      {:ok, retired} -> {:ok, retired}
      {:error, :cross_tenant} -> {:error, :cross_tenant}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp grant_of(%{id: athanor_id, status: "active", security_generation: generation}) do
    case Prima.ExecutionGrant.new(athanor_id, generation) do
      {:ok, grant} -> {:ok, grant}
      {:error, :invalid_grant} -> {:error, :not_standing}
    end
  end

  defp grant_of(_row), do: {:error, :not_standing}
end
