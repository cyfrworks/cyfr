# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.JobClaims do
  @moduledoc """
  Who is running one of the cell's singleton jobs: the one `job_claims`
  row a `(kind, key)` has (`Arca.Schemas.JobClaim`), taken, renewed and
  given up by compare-and-set against the cell's clock. Rows only — no
  process holds a claim, so a claim outlives nothing but its lease.

  A claim is a mutual-exclusion token and authorizes **nothing**. Its
  holder reads and writes through the same tenant-scoped facades under the
  same actor as any other caller, so a `key` naming an athanor's
  credential is a name and not a reach. That is also why the table carries
  no `athanor_id`: several kinds have no estate at all.

  Where a job *should* run is not decided here. The cell proposes an owner
  — rendezvous over the live member roster, so the common case is
  uncontended — and this row disposes: `claim/4` takes an owner as an
  argument and knows nothing about rosters. Two members that disagree
  about the proposal cost one wasted conditional update, never a second
  holder.

    * `claim/4` takes the row for `owner`: a fresh row at fence 1, or a
      takeover — fence raised by one — of a row whose lease ran out. A
      live claim of another owner answers `{:busy, claim}`; a live claim
      of the same owner answers itself unchanged, so a member may ask on
      every tick. A takeover leaves `detail` exactly as it found it.
    * `renew/3` moves the lease forward, `record/2` writes `detail`
      without moving it, and `release/1` gives the row up by leaving its
      lease already run out. Each answers the row it wrote.
    * `hold/1` and `renew_held/3` are the same checks as steps of a
      caller's locking transaction: the row is held at its owner and
      fence until the caller commits, and the lease is judged on the
      clock read after the lock was won.

  ## The fence

  `fence` rises on **every** write, so a renew is itself a
  compare-and-set and two writers cannot interleave. Each function is
  given the claim it is writing against (`t:held/0`) and answers the row
  it wrote, so a holder carries its own fence forward; a holder that has
  lost track of one reads the row again (`read/2`). Of the claim a caller
  hands back only `kind`, `key`, `owner` and `fence` are read — the row's
  identity and the compare-and-set expectation — and every other column
  is read from the row as it stands. Every row a function here answers is
  a plain map (`Arca.Data`).

  ## The two ways to lose, which a caller must tell apart

    * `:taken` — the row is no longer this owner's at this fence. A peer
      holds it. **Stop.** Nothing issued under the old claim may land, and
      asking again would be taking it from a live holder.
    * `:lapsed` — the row still reads this owner and this fence, and the
      lease ran out before the write. Nobody has taken it yet. Stop
      acting, then ask for it again with `claim/4`, which wins it back if
      no peer got there first.

  ## Authority and evidence

  Renewing is an act of authority, so it lands only while the authority
  still stands: a lease that has run out is not extended, it is asked for
  again. Recording is an act of evidence, so it lands while the identity
  that would record it is still the row's, lease or no lease.

  `detail` is that evidence, and it is what a successor inherits: the
  worker watch's consecutive misses and the worker boot it last heard, a
  sweep's cursor. It is written in the same conditional statement as the
  rest, never in a second one, so a takeover racing it either loses or
  finds it whole. The worker watch is why `record/2` does not renew: a
  miss must raise its count without extending the lease, or a member that
  cannot reach a worker keeps the watch through its own misses.

  The bytes of `detail` are the job's own business. This module carries
  them and compares nothing in them.

  ## The lease clock

  Every comparison is `Arca.ServerMetaStorage.now!/0`, the cell's clock,
  so members whose own clocks have drifted still agree which lease stands.
  """

  import Ecto.Query

  alias Arca.Schemas.JobClaim

  # A takeover that loses its compare-and-set re-reads the row; past this
  # many rounds whoever keeps winning holds it.
  @rounds 3

  @typedoc """
  Why a write did not land. `:taken` is a peer holding the row; `:lapsed`
  is this holder's own lease having run out first.
  """
  @type lost :: :taken | :lapsed

  @typedoc """
  A claim as its holder carries it: the row's identity (`kind`, `key`)
  and the compare-and-set expectation (`owner`, `fence`). Any other key
  is ignored.
  """
  @type held :: %{
          required(:kind) => String.t(),
          required(:key) => String.t(),
          required(:owner) => String.t(),
          required(:fence) => pos_integer(),
          optional(atom()) => term()
        }

  @doc """
  The `key` of a job the cell has exactly one of — retention, the boot
  reconciliation, the seed release. The kinds that name a thing of their
  own (a worker service, a credential) carry that thing's id instead.
  """
  @spec cell_key() :: String.t()
  def cell_key, do: "cell"

  @doc """
  Take the claim for `(kind, key)` on behalf of `owner`, for `lease_ms`.

  Raises on a kind the claim roster does not name: an
  undeclared singleton is a caller's bug, and answering `{:busy, …}` for
  one would leave its subject silently unclaimed.
  """
  @spec claim(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:busy, map()} | {:error, :database_error}
  def claim(kind, key, owner, lease_ms)
      when is_binary(kind) and is_binary(key) and key != "" and is_binary(owner) and owner != "" and
             is_integer(lease_ms) and lease_ms > 0 do
    known!(kind)

    Arca.Repo.Errors.with_db_rescue("Arca.JobClaims.claim", fn ->
      take(kind, key, owner, lease_ms, @rounds)
    end)
    |> Arca.Data.project()
  end

  @doc """
  Move `held`'s lease `lease_ms` past now, while it is still the row's
  owner and fence **and** its lease still stands.

  `:detail` in `opts` writes the claim's evidence in the same statement;
  omitted, whatever the row carries is kept.
  """
  @spec renew(held(), pos_integer(), keyword()) ::
          {:ok, map()} | lost() | {:error, :database_error}
  def renew(held, lease_ms, opts \\ [])

  def renew(%{} = held, lease_ms, opts)
      when is_integer(lease_ms) and lease_ms > 0 and is_list(opts) do
    held = identity!(held)

    Arca.Repo.Errors.with_db_rescue("Arca.JobClaims.renew", fn ->
      checked_renew(held, lease_ms, Keyword.get(opts, :detail, :keep))
    end)
    |> Arca.Data.project()
  end

  @doc """
  Inside a caller's `Arca.Repo.locking_transaction/2`: lock `held`'s row
  at its owner and fence, then decide on the database's clock read after
  that lock was won whether its lease still stands.

  `{:ok, claim}` is the row as locked, which nothing else can change
  before the caller commits. `:taken` and `:lapsed` mean what they mean
  for `renew/3`. A decision is never taken on an instant read before a
  wait for the lock: a holder that waited behind a release or a takeover
  finds the row gone from under its fence, and one that waited past its
  own lease finds it lapsed.

  Raises outside a transaction and on a store that cannot answer, so the
  caller's transaction rolls back.
  """
  @spec hold(held()) :: {:ok, map()} | lost()
  # arca:db-raise-ok a step inside the caller's locking transaction; a raise rolls it back.
  def hold(%{} = held) do
    held = identity!(held)
    in_transaction!("hold/1")

    case held |> mine() |> Arca.QueryHelpers.for_update() |> Arca.Repo.one() do
      nil ->
        :taken

      %JobClaim{} = claim ->
        if live?(claim, Arca.ServerMetaStorage.now!()),
          do: {:ok, Arca.Data.project(claim)},
          else: :lapsed
    end
  end

  @doc """
  `renew/3` as a step of a caller's `Arca.Repo.locking_transaction/2`: the
  final checked renewal that records the job's evidence and answers the
  newest claim, which is the one the caller releases after committing.

  Raises outside a transaction and on a store that cannot answer, so the
  caller's transaction rolls back rather than committing work whose claim
  it could not renew.
  """
  @spec renew_held(held(), pos_integer(), keyword()) :: {:ok, map()} | lost()
  # arca:db-raise-ok a step inside the caller's locking transaction; a raise rolls it back.
  def renew_held(held, lease_ms, opts \\ [])

  def renew_held(%{} = held, lease_ms, opts)
      when is_integer(lease_ms) and lease_ms > 0 and is_list(opts) do
    held = identity!(held)
    in_transaction!("renew_held/3")

    held
    |> checked_renew(lease_ms, Keyword.get(opts, :detail, :keep))
    |> Arca.Data.project()
  end

  @doc """
  Write `held`'s evidence, leaving its lease where it is.

  Lands while the row still reads this owner and fence, run out or not:
  what a successor inherits is worth keeping either way, and this extends
  nothing and takes nothing. `:taken` once a peer holds the row.
  """
  @spec record(held(), String.t() | nil) ::
          {:ok, map()} | :taken | {:error, :database_error}
  def record(%{} = held, detail) when is_binary(detail) or is_nil(detail) do
    held = identity!(held)

    Arca.Repo.Errors.with_db_rescue("Arca.JobClaims.record", fn ->
      now = Arca.ServerMetaStorage.now!()

      case Arca.Repo.update_all(mine(held),
             set: [detail: detail, fence: held.fence + 1, updated_at: now]
           ) do
        {1, _} -> {:ok, reread(held)}
        {0, _} -> :taken
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Give `held` up: the row is left with its lease already run out, so the
  next member takes it at once, and with its `detail` intact, so the next
  member inherits what this one learned. `:taken` when the row is no
  longer this owner's at this fence, and then nothing is written.
  """
  @spec release(held()) :: :ok | :taken | {:error, :database_error}
  def release(%{} = held) do
    held = identity!(held)

    Arca.Repo.Errors.with_db_rescue("Arca.JobClaims.release", fn ->
      now = Arca.ServerMetaStorage.now!()

      case Arca.Repo.update_all(mine(held),
             set: [lease_until: now, fence: held.fence + 1, updated_at: now]
           ) do
        {1, _} -> :ok
        {0, _} -> :taken
      end
    end)
  end

  @doc "The claim row for `(kind, key)` as it reads now."
  @spec read(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def read(kind, key) when is_binary(kind) and is_binary(key) do
    known!(kind)

    Arca.Repo.Errors.with_db_rescue("Arca.JobClaims.read", fn ->
      case row(kind, key) do
        nil -> {:error, :not_found}
        claim -> {:ok, claim}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Whether the lease of the claim `held` names still stands on the cell's
  clock, read from the row as it stands: false once the row has left this
  owner and fence.
  """
  @spec live?(held()) :: boolean()
  def live?(%{} = held) do
    held = identity!(held)

    Arca.Repo.Errors.with_db_rescue("Arca.JobClaims.live?", false, fn ->
      case Arca.Repo.one(mine(held)) do
        nil -> false
        claim -> live?(claim, Arca.ServerMetaStorage.now!())
      end
    end)
  end

  # ---- internal --------------------------------------------------------------

  defp live?(%JobClaim{lease_until: until}, now), do: DateTime.compare(until, now) == :gt

  # The clock is read here, after any lock the caller already holds, so the
  # lease comparison is never older than the write it decides.
  defp checked_renew(held, lease_ms, detail) do
    now = Arca.ServerMetaStorage.now!()

    sets =
      [lease_until: lease_end(now, lease_ms), fence: held.fence + 1, updated_at: now]
      |> with_detail(detail)

    held
    |> mine()
    |> where([c], c.lease_until > ^now)
    |> Arca.Repo.update_all(set: sets)
    |> landed(held)
  end

  defp in_transaction!(fun) do
    unless Arca.Repo.in_transaction?() do
      raise ArgumentError, "Arca.JobClaims.#{fun} runs inside a locking transaction"
    end
  end

  defp take(kind, key, _owner, _lease_ms, 0) do
    case row(kind, key) do
      nil -> {:error, :database_error}
      claim -> {:busy, claim}
    end
  end

  defp take(kind, key, owner, lease_ms, rounds) do
    now = Arca.ServerMetaStorage.now!()

    case row(kind, key) do
      nil ->
        if insert(kind, key, owner, lease_ms, now),
          do: {:ok, row(kind, key)},
          else: take(kind, key, owner, lease_ms, rounds - 1)

      %JobClaim{} = claim ->
        cond do
          live?(claim, now) and claim.owner == owner ->
            {:ok, claim}

          live?(claim, now) ->
            {:busy, claim}

          take_over(claim, owner, lease_ms, now) ->
            {:ok, row(kind, key)}

          true ->
            take(kind, key, owner, lease_ms, rounds - 1)
        end
    end
  end

  # The unique index on `(kind, key)` decides a race between two first
  # claims: the loser inserts nothing and reads the winner's row.
  defp insert(kind, key, owner, lease_ms, now) do
    row = %{
      id: Cyfr.UUID7.generate_id("jcl"),
      kind: kind,
      key: key,
      owner: owner,
      lease_until: lease_end(now, lease_ms),
      fence: 1,
      inserted_at: now,
      updated_at: now
    }

    match?({1, _}, Arca.Repo.insert_all(JobClaim, [row], on_conflict: :nothing))
  end

  # The row is taken only as it was read — same fence — and only while it
  # is still takeable. Both conditions carry weight: the holder renewing
  # between the read and this write raises the fence, so the take finds a
  # number it did not read and the live claim is kept; and a second taker
  # racing this one loses for the same reason. `detail` is untouched,
  # which is how a successor inherits what its predecessor learned.
  defp take_over(%JobClaim{} = claim, owner, lease_ms, now) do
    query =
      from(c in JobClaim,
        where: c.kind == ^claim.kind and c.key == ^claim.key and c.fence == ^claim.fence,
        where: c.lease_until <= ^now
      )

    match?(
      {1, _},
      Arca.Repo.update_all(query,
        set: [
          owner: owner,
          lease_until: lease_end(now, lease_ms),
          fence: claim.fence + 1,
          updated_at: now
        ]
      )
    )
  end

  # Of a claim a caller hands back, only the row's identity and the
  # compare-and-set expectation are kept: nothing else it carries can
  # reach a write.
  defp identity!(%{kind: kind, key: key, owner: owner, fence: fence})
       when is_binary(kind) and is_binary(key) and is_binary(owner) and is_integer(fence),
       do: %{kind: kind, key: key, owner: owner, fence: fence}

  defp identity!(held),
    do: raise(ArgumentError, "not a held job claim: #{inspect(Map.keys(held))}")

  # The row while it is still this holder's, at the fence it read.
  defp mine(%{kind: kind, key: key, owner: owner, fence: fence}) do
    from(c in JobClaim,
      where: c.kind == ^kind and c.key == ^key and c.owner == ^owner and c.fence == ^fence
    )
  end

  defp landed({1, _}, held), do: {:ok, reread(held)}

  # Nothing landed, and which of the two it is decides whether the caller
  # stops or asks again. The row still reading this holder's own owner and
  # fence means nobody has taken it and the lease alone ran out.
  defp landed({0, _}, %{owner: owner, fence: fence} = held) do
    case row(held.kind, held.key) do
      %JobClaim{owner: ^owner, fence: ^fence} -> :lapsed
      _taken_or_gone -> :taken
    end
  end

  defp with_detail(sets, :keep), do: sets
  defp with_detail(sets, detail), do: Keyword.put(sets, :detail, detail)

  defp row(kind, key),
    do: Arca.Repo.one(from(c in JobClaim, where: c.kind == ^kind and c.key == ^key))

  defp reread(%{kind: kind, key: key}), do: row(kind, key)

  defp lease_end(now, lease_ms), do: DateTime.add(now, lease_ms, :millisecond)

  defp known!(kind) do
    if kind not in JobClaim.kinds(),
      do: raise(ArgumentError, "unknown job claim kind #{inspect(kind)}")
  end
end
