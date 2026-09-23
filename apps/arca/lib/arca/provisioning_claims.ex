# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProvisioningClaims do
  @moduledoc """
  Who is filling an estate: the one `provisioning_claims` row an athanor
  has (`Arca.Schemas.ProvisioningClaim`), taken, renewed and settled by
  compare-and-set. Rows only — no process holds a claim, so a claim
  outlives nothing but its lease.

  Every function takes the actor first and works on the actor's athanor;
  an actor without one is refused (`{:error, :no_athanor}`) before any
  query.

    * `claim/4` takes the row for `owner`: a fresh row at fence 1, or a
      takeover — fence raised by one, a new attempt — of a row whose lease
      ran out or whose outcome is settled. A live claim of another owner
      answers `{:busy, claim}`; a live claim of the same owner answers
      itself, attempt and fence unchanged.
    * `renew/4` moves the lease forward, `settle/5` writes the outcome and
      `release/3` settles `released`. Each lands only while the row still
      reads the caller's `owner` and `fence` and carries no outcome;
      otherwise it answers `:stale` and writes nothing.
    * `current/1` reads the row once.

  ## The lease clock

  A lease is compared against the cell's one clock,
  `Arca.ServerMetaStorage.now!/0`: Postgres answers its own
  `clock_timestamp()` — the wall clock, where `now()` stands still for the
  length of a transaction — so every member sharing the database reads the
  same instant however its own clock has drifted; SQLite has no server and
  one writer, so the BEAM's clock is the database's. It is the same
  function every other lease in the cell is decided on, and this module
  keeps no copy of it.
  """

  import Ecto.Query

  alias Arca.Schemas.ProvisioningClaim

  # A takeover that loses its compare-and-set re-reads the row; past this
  # many rounds whoever keeps winning holds it.
  @rounds 3

  @type refusal :: {:error, :no_athanor | :database_error}

  @doc """
  Take the actor's athanor's claim for `owner`, entering through
  `entry_kind`, for `lease_ms`.
  """
  @spec claim(Cyfr.Actor.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:busy, map()} | refusal()
  def claim(%Cyfr.Actor{athanor_id: athanor_id}, owner, entry_kind, lease_ms)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and
             is_binary(entry_kind) and
             is_integer(lease_ms) and lease_ms > 0 do
    if entry_kind not in ProvisioningClaim.entry_kinds(),
      do: raise(ArgumentError, "unknown provisioning entry kind #{inspect(entry_kind)}")

    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.claim", fn ->
      take(athanor_id, owner, entry_kind, lease_ms, @rounds)
    end)
    |> Arca.Data.project()
  end

  def claim(%Cyfr.Actor{}, _owner, _entry_kind, _lease_ms), do: {:error, :no_athanor}

  @doc "Move the lease `lease_ms` past now, while `owner` still holds `fence`."
  @spec renew(Cyfr.Actor.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | :stale | refusal()
  def renew(%Cyfr.Actor{athanor_id: athanor_id}, owner, fence, lease_ms)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) and
             is_integer(lease_ms) and lease_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.renew", fn ->
      now = now()

      athanor_id
      |> held(owner, fence)
      |> Arca.Repo.update_all(set: [lease_until: lease_end(now, lease_ms), updated_at: now])
      |> landed()
    end)
  end

  def renew(%Cyfr.Actor{}, _owner, _fence, _lease_ms), do: {:error, :no_athanor}

  @doc """
  Write the attempt's `outcome` (`ready`, `failed` or `released`) and its
  `detail`, while `owner` still holds `fence`. A claim that was taken over,
  or already settled, answers `:stale` and keeps what it reads.
  """
  @spec settle(Cyfr.Actor.t(), String.t(), pos_integer(), String.t(), String.t() | nil) ::
          :ok | :stale | refusal()
  def settle(%Cyfr.Actor{athanor_id: athanor_id}, owner, fence, outcome, detail)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) and
             is_binary(outcome) and (is_binary(detail) or is_nil(detail)) do
    if outcome not in ProvisioningClaim.outcomes(),
      do: raise(ArgumentError, "unknown provisioning outcome #{inspect(outcome)}")

    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.settle", fn ->
      athanor_id
      |> held(owner, fence)
      |> Arca.Repo.update_all(set: [outcome: outcome, outcome_detail: detail, updated_at: now()])
      |> landed()
    end)
  end

  def settle(%Cyfr.Actor{}, _owner, _fence, _outcome, _detail), do: {:error, :no_athanor}

  @doc "Give the claim up with no verdict on readiness: `settle/5` as `released`."
  @spec release(Cyfr.Actor.t(), String.t(), pos_integer()) :: :ok | :stale | refusal()
  def release(%Cyfr.Actor{} = actor, owner, fence),
    do: settle(actor, owner, fence, "released", nil)

  @doc "The athanor's claim row as it reads now."
  @spec current(Cyfr.Actor.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def current(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.current", fn ->
      case read(athanor_id) do
        nil -> {:error, :not_found}
        claim -> {:ok, claim}
      end
    end)
    |> Arca.Data.project()
  end

  def current(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  Hold the athanor's claim for the rest of the caller's transaction:
  `true` while the row still reads `owner` at `fence` and carries no
  outcome, `false` otherwise, and in either case nothing about the claim
  changes but the instant it was last touched.

  It is a conditional WRITE and not a read on purpose. A read inside a
  transaction is a check-then-act: a takeover landing between it and the
  work it guards leaves the work written under a claim its owner has
  lost. A write takes the claim row for the length of the transaction, so
  a racing takeover either lands first — and this answers `false` — or
  waits behind the commit, which is the ordering the guard needs.

  Called from inside `Arca.Repo.transaction/1`, which is where its
  guarantee lives; it raises like anything else there, and the caller's
  `Arca.Repo.Errors.with_db_rescue/2` reports it.
  """
  @spec hold?(Cyfr.Actor.t(), String.t(), pos_integer()) :: boolean()
  # arca:db-raise-ok inside the caller's transaction
  def hold?(%Cyfr.Actor{athanor_id: athanor_id}, owner, fence)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) do
    athanor_id
    |> held(owner, fence)
    |> Arca.Repo.update_all(set: [updated_at: now()])
    |> landed()
    |> Kernel.==(:ok)
  end

  def hold?(%Cyfr.Actor{}, _owner, _fence),
    do: Arca.QueryHelpers.no_athanor!("Arca.ProvisioningClaims.hold?/3")

  @doc """
  Whether `claim`, as `claim/4` or `current/1` answered it, still stands on
  the lease clock: unsettled, its lease not run out.
  """
  @spec live?(map()) :: boolean()
  def live?(%{outcome: _, lease_until: %DateTime{}} = claim) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.live?", false, fn ->
      live?(claim, now())
    end)
  end

  @doc """
  How long ago, in milliseconds on the lease clock, `claim` was last
  written — what a backoff after a settled failure is measured on.
  """
  @spec age_ms(map()) :: integer()
  def age_ms(%{updated_at: %DateTime{} = at}) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.age_ms", 0, fn ->
      DateTime.diff(now(), at, :millisecond)
    end)
  end

  # ---- internal --------------------------------------------------------------

  defp live?(%{outcome: nil, lease_until: until}, now),
    do: DateTime.compare(until, now) == :gt

  defp live?(%{}, _now), do: false

  defp take(athanor_id, _owner, _entry_kind, _lease_ms, 0) do
    case read(athanor_id) do
      nil -> {:error, :database_error}
      claim -> {:busy, claim}
    end
  end

  defp take(athanor_id, owner, entry_kind, lease_ms, rounds) do
    now = now()

    case read(athanor_id) do
      nil ->
        if insert(athanor_id, owner, entry_kind, lease_ms, now),
          do: {:ok, read(athanor_id)},
          else: take(athanor_id, owner, entry_kind, lease_ms, rounds - 1)

      %ProvisioningClaim{} = claim ->
        cond do
          live?(claim, now) and claim.owner == owner ->
            {:ok, claim}

          live?(claim, now) ->
            {:busy, claim}

          take_over(claim, owner, entry_kind, lease_ms, now) ->
            {:ok, read(athanor_id)}

          true ->
            take(athanor_id, owner, entry_kind, lease_ms, rounds - 1)
        end
    end
  end

  defp read(athanor_id) do
    Arca.Repo.one(from(c in ProvisioningClaim, where: c.athanor_id == ^athanor_id))
  end

  # The unique index on the athanor decides a race between two first
  # claims: the loser inserts nothing and reads the winner's row.
  defp insert(athanor_id, owner, entry_kind, lease_ms, now) do
    row = %{
      id: Cyfr.UUID7.generate_id("pc"),
      athanor_id: athanor_id,
      owner: owner,
      attempt: Cyfr.UUID7.generate_id("att"),
      entry_kind: entry_kind,
      lease_until: lease_end(now, lease_ms),
      fence: 1,
      inserted_at: now,
      updated_at: now
    }

    match?({1, _}, Arca.Repo.insert_all(ProvisioningClaim, [row], on_conflict: :nothing))
  end

  # The row is taken only as it was read — same fence — and only while it
  # is still takeable: a renewal between the read and this write moves the
  # lease without raising the fence, and must keep the claim.
  defp take_over(%ProvisioningClaim{} = claim, owner, entry_kind, lease_ms, now) do
    query =
      from(c in ProvisioningClaim,
        where: c.athanor_id == ^claim.athanor_id and c.fence == ^claim.fence,
        where: not is_nil(c.outcome) or c.lease_until <= ^now
      )

    match?(
      {1, _},
      Arca.Repo.update_all(query,
        set: [
          owner: owner,
          attempt: Cyfr.UUID7.generate_id("att"),
          entry_kind: entry_kind,
          lease_until: lease_end(now, lease_ms),
          fence: claim.fence + 1,
          outcome: nil,
          outcome_detail: nil,
          updated_at: now
        ]
      )
    )
  end

  # The row while `owner` holds it at `fence`, unsettled.
  defp held(athanor_id, owner, fence) do
    from(c in ProvisioningClaim,
      where: c.athanor_id == ^athanor_id and c.owner == ^owner and c.fence == ^fence,
      where: is_nil(c.outcome)
    )
  end

  defp landed({1, _}), do: :ok
  defp landed({0, _}), do: :stale

  defp lease_end(now, lease_ms), do: DateTime.add(now, lease_ms, :millisecond)

  # The cell's lease clock, shared with every other row a member holds.
  # It raises when the store cannot answer, which each entry point's
  # `with_db_rescue` turns into this module's own refusal.
  defp now, do: Arca.ServerMetaStorage.now!()
end
