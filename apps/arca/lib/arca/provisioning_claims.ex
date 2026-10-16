# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProvisioningClaims do
  @moduledoc """
  Who is filling an athanor: the one `provisioning_claims` row an athanor
  has (`Arca.Schemas.ProvisioningClaim`), taken, renewed and settled by
  compare-and-set. Rows only — no process holds a claim, so a claim
  outlives nothing but its lease.

  Every function takes the actor first and works on the actor's athanor;
  an actor without one is refused (`{:error, :no_athanor}`) before any
  query.

    * `claim/5` takes the row for `owner`: a fresh row at fence 1, or a
      takeover — fence raised by one, a new attempt — of a row whose lease
      ran out or whose outcome is settled. A live claim of another owner
      answers `{:busy, claim}`; a live claim of the same owner answers
      itself, attempt and fence unchanged. The take runs in one
      transaction under the claiming member's slot, verified live first
      (`Arca.ControlPlane.verify_held/1`): a member that lost its slot
      takes no athanor, `{:error, :not_owner}`.
    * `renew/5` moves the lease forward, `settle/6` writes the outcome and
      `release/3` settles `released`. Each lands only while the row still
      reads the caller's `owner` and `fence` and carries no outcome;
      otherwise it answers `:stale` and writes nothing. `renew/5` and
      `settle/6` also name the slot the claim was taken under and verify
      it live in their own transaction, as `claim/5` does: a member that
      lost its slot keeps no lease and settles no verdict,
      `{:error, :not_owner}`. `release/3` names none — giving an athanor
      back is safe whoever still holds the claim's owner and fence.
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
  `entry_kind`, for `lease_ms`, under the claiming member's `slot`
  (`Arca.ControlPlane.member_slot/0`).

  The slot is verified live in the take's own transaction before the row
  is read (`Arca.ControlPlane.verify_held/1`, which holds the lease row
  until commit), so a takeover of the member's slot either lands first —
  and this answers `{:error, :not_owner}` with nothing taken — or waits
  until the claim has committed. This is the member's check, beside the
  athanor's own fence (the claim row's owner and fence), not a second one.
  """
  @spec claim(
          Prima.Actor.t(),
          String.t(),
          String.t(),
          pos_integer(),
          Arca.ControlPlane.slot() | :none
        ) ::
          {:ok, map()} | {:busy, map()} | {:error, :not_owner} | refusal()
  def claim(%Prima.Actor{athanor_id: athanor_id}, owner, entry_kind, lease_ms, slot)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and
             is_binary(entry_kind) and
             is_integer(lease_ms) and lease_ms > 0 do
    if entry_kind not in ProvisioningClaim.entry_kinds(),
      do:
        raise(
          ArgumentError,
          "unknown provisioning entry kind #{Prima.LoggerContext.shape(entry_kind)}"
        )

    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.claim", fn ->
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> take(athanor_id, owner, entry_kind, lease_ms, @rounds)
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
      |> case do
        {:ok, answer} -> answer
        {:error, :not_owner} -> {:error, :not_owner}
      end
    end)
    |> Arca.Data.project()
  end

  def claim(%Prima.Actor{}, _owner, _entry_kind, _lease_ms, _slot), do: {:error, :no_athanor}

  @doc """
  Move the lease `lease_ms` past now, while `owner` still holds `fence`
  under the member's `slot` — the one the claim was taken under, never one
  read again since.

  The slot is verified live in the renewal's own transaction before the
  row is written (`Arca.ControlPlane.verify_held/1`), as `claim/5` verifies
  it: a member that lost its slot keeps no lease, `{:error, :not_owner}`
  with nothing written, so the claim of an attempt that can no longer
  publish runs out and a successor takes it. A member that won its slot
  back holds a new generation, which is not the slot named here.
  """
  @spec renew(
          Prima.Actor.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          Arca.ControlPlane.slot() | :none
        ) ::
          :ok | :stale | {:error, :not_owner} | refusal()
  def renew(%Prima.Actor{athanor_id: athanor_id}, owner, fence, lease_ms, slot)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) and
             is_integer(lease_ms) and lease_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.renew", fn ->
      under_slot(slot, fn ->
        now = now()

        athanor_id
        |> held(owner, fence)
        |> Arca.Repo.update_all(set: [lease_until: lease_end(now, lease_ms), updated_at: now])
        |> landed()
      end)
    end)
  end

  def renew(%Prima.Actor{}, _owner, _fence, _lease_ms, _slot), do: {:error, :no_athanor}

  @doc """
  Write the attempt's verdict, `outcome` (`ready` or `failed`), and its
  `detail`, while `owner` still holds `fence` under the member's `slot`,
  and with it `stamps`, the athanor row's own record of that verdict
  (`Arca.Athanors.set/2` on the actor's athanor: readiness, or the failure
  a person reads).

  One transaction: the slot is verified live first, as `renew/5` verifies
  it, then the verdict is written by compare-and-set, then the stamps —
  only once the verdict landed. A claim that was taken over, or already
  settled, answers `:stale` and writes neither; a slot that is no longer
  the member's answers `{:error, :not_owner}` and writes neither; stamps
  the row refuses roll the verdict back and answer the refusal. So an
  athanor is never marked ready, nor a failure recorded over its
  successor's, by an attempt that no longer holds both.
  """
  @spec settle(
          Prima.Actor.t(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t() | nil,
          Arca.ControlPlane.slot() | :none,
          keyword()
        ) ::
          :ok | :stale | {:error, :not_owner | :not_found | {:invalid, map()}} | refusal()
  def settle(actor, owner, fence, outcome, detail, slot, stamps \\ [])

  def settle(
        %Prima.Actor{athanor_id: athanor_id} = actor,
        owner,
        fence,
        outcome,
        detail,
        slot,
        stamps
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) and
             is_binary(outcome) and (is_binary(detail) or is_nil(detail)) and is_list(stamps) do
    if outcome not in ProvisioningClaim.outcomes(),
      do:
        raise(ArgumentError, "unknown provisioning outcome #{Prima.LoggerContext.shape(outcome)}")

    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.settle", fn ->
      under_slot(slot, fn ->
        with :ok <- write_outcome(athanor_id, owner, fence, outcome, detail) do
          stamp(actor, stamps)
        end
      end)
    end)
  end

  def settle(%Prima.Actor{}, _owner, _fence, _outcome, _detail, _slot, _stamps),
    do: {:error, :no_athanor}

  @doc """
  Give the claim up with no verdict on readiness: the outcome `released`,
  while `owner` still holds `fence`, and `:stale` otherwise.

  It names no slot. A release is given only once the attempt and the work
  it started beside itself have stopped, and it hands the athanor to the
  next attempt sooner than the lease would; a member that lost its slot
  publishes nothing by giving the claim back.
  """
  @spec release(Prima.Actor.t(), String.t(), pos_integer()) :: :ok | :stale | refusal()
  def release(%Prima.Actor{athanor_id: athanor_id}, owner, fence)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.release", fn ->
      write_outcome(athanor_id, owner, fence, "released", nil)
    end)
  end

  def release(%Prima.Actor{}, _owner, _fence), do: {:error, :no_athanor}

  @doc "The athanor's claim row as it reads now."
  @spec current(Prima.Actor.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def current(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProvisioningClaims.current", fn ->
      case read(athanor_id) do
        nil -> {:error, :not_found}
        claim -> {:ok, claim}
      end
    end)
    |> Arca.Data.project()
  end

  def current(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  Hold the athanor's claim for the rest of the caller's transaction, as a
  write that publishes for the attempt: `true` while the member still
  holds `slot` — the one the claim was taken under, never one read again
  since — and the row still reads `owner` at `fence` with no outcome;
  `false` otherwise. In either case nothing about the claim changes but
  the instant it was last touched.

  The slot is verified first (`Arca.ControlPlane.verify_held/1`, whose
  shared hold on the slot's lease row lasts until the caller commits), in
  the order `claim/5` takes them. The claim is then held by a conditional
  WRITE and not a read, on purpose: a read inside a transaction is a
  check-then-act, and a takeover landing between it and the work it guards
  leaves the work written under a claim its owner has lost. A write takes
  the claim row for the length of the transaction. So a takeover of either
  the slot or the claim lands first — and this answers `false` — or waits
  behind the commit, which is the ordering the guard needs.

  Called from inside `Arca.Repo.locking_transaction/2`, which is where its
  guarantee lives and which `verify_held/1` requires; it raises like
  anything else there, and the caller's
  `Arca.Repo.Errors.with_db_rescue/2` reports it.
  """
  @spec hold?(Prima.Actor.t(), String.t(), pos_integer(), Arca.ControlPlane.slot() | :none) ::
          boolean()
  # arca:db-raise-ok inside the caller's locking transaction
  def hold?(%Prima.Actor{athanor_id: athanor_id}, owner, fence, slot)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(owner) and is_integer(fence) do
    Arca.ControlPlane.verify_held(slot) == :ok and
      athanor_id
      |> held(owner, fence)
      |> Arca.Repo.update_all(set: [updated_at: now()])
      |> landed()
      |> Kernel.==(:ok)
  end

  def hold?(%Prima.Actor{}, _owner, _fence, _slot),
    do: Arca.QueryHelpers.no_athanor!("Arca.ProvisioningClaims.hold?/4")

  @doc """
  Whether `claim`, as `claim/5` or `current/1` answered it, still stands on
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
      id: Prima.UUID7.generate_id("pc"),
      athanor_id: athanor_id,
      owner: owner,
      attempt: Prima.UUID7.generate_id("att"),
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
          attempt: Prima.UUID7.generate_id("att"),
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

  # The verdict, written only as the row still reads `owner` at `fence`.
  defp write_outcome(athanor_id, owner, fence, outcome, detail) do
    athanor_id
    |> held(owner, fence)
    |> Arca.Repo.update_all(set: [outcome: outcome, outcome_detail: detail, updated_at: now()])
    |> landed()
  end

  # The verdict's stamps on the athanor row, inside the verdict's
  # transaction: a refusal rolls the verdict back with it.
  defp stamp(_actor, []), do: :ok

  defp stamp(actor, stamps) do
    case Arca.Athanors.set(actor, stamps) do
      :ok -> :ok
      {:error, reason} -> Arca.Repo.rollback(reason)
    end
  end

  # `write` in one locking transaction that first verifies `slot` live, as
  # `claim/5` does: a slot that is not the member's rolls back as
  # `{:error, :not_owner}` with nothing written. The public entry that
  # calls it holds the `with_db_rescue`, as the row-plane convention has it
  # (`Arca.DbRescueCoverageTest` reads each public entry's own body).
  defp under_slot(slot, write) do
    Arca.Repo.locking_transaction(fn ->
      case Arca.ControlPlane.verify_held(slot) do
        :ok -> write.()
        :lost -> Arca.Repo.rollback(:not_owner)
      end
    end)
    |> case do
      {:ok, answer} -> answer
      {:error, _} = refused -> refused
    end
  end

  defp landed({1, _}), do: :ok
  defp landed({0, _}), do: :stale

  defp lease_end(now, lease_ms), do: DateTime.add(now, lease_ms, :millisecond)

  # The cell's lease clock, shared with every other row a member holds.
  # It raises when the store cannot answer, which each entry point's
  # `with_db_rescue` turns into this module's own refusal.
  defp now, do: Arca.ServerMetaStorage.now!()
end
