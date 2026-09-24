# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ControlPlane do
  @moduledoc """
  Whether this member of the cell holds its slot, and under which
  generation — the `cell_leases` row it claims, and the cached copy every
  gate reads.

  Every gate in the product asks `held?/0` on the way in: the operation
  catalog before dispatch, the ownership plug on every request, the runner
  before it starts a thread, each background job on every tick. So that
  question is a term read and an integer comparison, never a query. The
  row is the authority; the cache is what the authority leaves behind, and
  this module writes both so they cannot drift apart. `Cyfr.Cell`, the
  claimant, keeps no second copy: what it wrote through `take/3` is what
  it reads back through `held/0`.

  ## The row

  One row per member SLOT, keyed by the node's distribution name and not
  by a boot. A restarted member takes its own row over rather than opening
  a second one beside it, and the row survives a release, so a returning
  member's generation carries on from its predecessor's instead of
  starting again at one — a member that came back must never reissue a
  generation a worker has already retired.

  `generation` and `fence` do different jobs. `generation` is the outward
  stamp on what the member issues — worker assignments, host-call
  bindings, bridge grants — and rises only when THIS slot is taken over
  past its lease. `fence` is the row's write token, raised by every write,
  so a renew is itself a compare-and-set and two writers cannot
  interleave. A holder compares generations per issuing member and never
  across members: `(node, generation)` is the fence and `boot` is the
  identity.

  ## The two clocks

  Which member holds a slot is decided on DATABASE time
  (`Arca.ServerMetaStorage.now!/0`), inside the statement that writes the
  row: a take compares the lease it is replacing against the database's
  clock, so members whose own clocks have drifted still agree.

  How long a member goes on believing its own answer is decided on that
  member's MONOTONIC clock. `record/1` is handed a duration — the time
  left of the lease just won — not a deadline, and `held?/0` counts it
  down locally. A duration cannot carry the skew between a member's clock
  and the database's, and a monotonic countdown cannot be moved by a clock
  step, a leap second or an operator's hand. `take/3` and `renew/1` read
  the monotonic clock BEFORE they issue their write and derive the
  remainder from that instant, less `margin_ms/0` for the two clocks'
  rate difference, so what this module believes always runs out before the
  row it stands for becomes takeable, never after.

  ## The generation

  `generation/0` is the member's, not the cell's. It rises when this
  member's slot is taken over by a successor and at no other time, so a
  peer joining or leaving the cell invalidates nothing this member issued.

    * `{:ok, n}` — this member holds `n`.
    * `:none` — no member claims a slot in this deployment, so there is no
      generation to stamp and nothing to fence.
    * `{:error, :unavailable}` — a slot is claimed here but this member
      holds no generation: before its claim is won, or after it lost the
      row. Never `:none`: the generation is not known, so nothing may be
      issued or checked under one.

  ## Who writes it

  The cell's claimant, and nothing else. This module keeps no timer and no
  process: `take/3`, `renew/1` and `release/0` are called from the
  claimant's own process and leave the cached standing behind them.
  `verify_held/1` writes nothing a reader could see: it is how a security
  transaction proves, under a row lock, that the slot it runs for is
  still this member's.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.CellLease

  @standing_key {__MODULE__, :standing}
  @generation_key {__MODULE__, :generation}
  @slot_key {__MODULE__, :slot}

  # How much of a won lease a member gives up before it believes it holds
  # one, covering the rate difference between its monotonic clock and the
  # database's wall clock over a single lease.
  @margin_ms 1_000

  # A take that loses its compare-and-set re-reads the row; past this many
  # rounds whoever keeps winning holds it.
  @rounds 3

  @typedoc """
  What this member holds: its slot for a further `ms` milliseconds on the
  local monotonic clock, its slot indefinitely (no claimant runs, so
  nothing can take it), nothing after a lapse, or nothing recorded yet.
  """
  @type standing :: {:held, non_neg_integer() | :indefinitely} | :lost | :unclaimed

  @typedoc """
  The slot this member won: the row's key, the boot holding it, the
  generation it stamps outward and the fence its next write names.
  """
  @type slot :: %{
          node: String.t(),
          owner: String.t(),
          generation: pos_integer(),
          fence: pos_integer(),
          lease_until: DateTime.t()
        }

  @doc """
  Whether this member holds its slot right now. No query, no process, no
  wall clock.
  """
  @spec held?() :: boolean()
  def held? do
    case :persistent_term.get(@standing_key, :unclaimed) do
      {:held, :indefinitely} -> true
      {:held, deadline} -> System.monotonic_time(:millisecond) < deadline
      :lost -> false
      :unclaimed -> not claimed_here?()
    end
  end

  @doc "The generation this member holds. See the module doc."
  @spec generation() :: {:ok, pos_integer()} | :none | {:error, :unavailable}
  def generation do
    case :persistent_term.get(@generation_key, nil) do
      generation when is_integer(generation) -> {:ok, generation}
      :none -> :none
      nil -> if claimed_here?(), do: {:error, :unavailable}, else: :none
    end
  end

  @doc """
  The slot this member last won, as it was written. `:none` before a take
  and after a release or a loss. A term read, like `held?/0`.
  """
  @spec held() :: {:ok, slot()} | :none
  def held do
    case :persistent_term.get(@slot_key, nil) do
      nil -> :none
      slot -> {:ok, slot}
    end
  end

  @doc "The slice of a won lease a member does not count as its own."
  @spec margin_ms() :: pos_integer()
  def margin_ms, do: @margin_ms

  # ---- the writes ------------------------------------------------------------

  @doc """
  Take `node`'s slot for the boot `owner`, for `lease_ms` of database
  time, and record what was won.

    * A slot nobody has ever held is inserted at generation 1, fence 1.
    * A slot this same boot already holds is renewed in place: its fence
      rises and its generation does NOT, because a member is not its own
      successor and must not fence out work it is still running.
    * A slot whose lease has run out is taken over: owner replaced,
      generation and fence both raised by one, so the predecessor's
      outward artifacts are refused by the holders that compare them and
      its own renew writes nothing.
    * A slot a live peer holds answers `{:busy, row}` and writes nothing.

  The takeover names the fence it read, so a peer racing this take loses
  its compare-and-set rather than both replacing the same row.
  """
  @spec take(String.t(), String.t(), pos_integer()) ::
          {:ok, slot()} | {:busy, map()} | {:error, :database_error}
  def take(node, owner, lease_ms)
      when is_binary(node) and node != "" and is_binary(owner) and owner != "" and
             is_integer(lease_ms) and lease_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ControlPlane.take", fn ->
      started = System.monotonic_time(:millisecond)

      case do_take(node, owner, lease_ms, @rounds) do
        {:ok, row} -> {:ok, won(row, lease_ms, started)}
        other -> other
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Push the slot this member holds `lease_ms` further out, and record the
  time won.

  The statement names the owner and the fence this member last wrote, so
  it is itself a compare-and-set. Zero rows means a successor took the
  slot — its generation is above this one's, and everything this member
  issued is now older than everything the successor issues. The loss is
  recorded BEFORE this function returns, so nothing is admitted between
  the discovery and the next gate.

  A lease that merely ran out is still renewed while the row reads this
  member: nobody has taken it, so it is still this member's. What the
  member believed had already lapsed on its own countdown, so it admitted
  nothing in the gap.

  `{:error, :database_error}` records nothing: a member that cannot reach
  the row does not know it lost it, and its countdown runs out on its own.
  """
  @spec renew(pos_integer()) :: {:ok, slot()} | :taken | :unclaimed | {:error, :database_error}
  def renew(lease_ms) when is_integer(lease_ms) and lease_ms > 0 do
    case held() do
      :none ->
        :unclaimed

      {:ok, slot} ->
        Arca.Repo.Errors.with_db_rescue("Arca.ControlPlane.renew", fn ->
          started = System.monotonic_time(:millisecond)
          now = Arca.ServerMetaStorage.now!()

          slot
          |> mine()
          |> Arca.Repo.update_all(
            set: [
              lease_until: lease_end(now, lease_ms),
              fence: slot.fence + 1,
              updated_at: now
            ]
          )
          |> case do
            {1, _} ->
              # What the statement set, not what a later read would see:
              # the renew keeps this member's own generation, and a
              # successor's must never be mistaken for it.
              renewed = %{
                slot
                | fence: slot.fence + 1,
                  lease_until: lease_end(now, lease_ms)
              }

              {:ok, won(renewed, lease_ms, started)}

            {0, _} ->
              lost()
              :taken
          end
        end)
    end
  end

  @doc """
  Give this member's slot up: the row is left with its lease already run
  out, so a successor takes it at once and the generation still rises on
  that take. The row is never deleted, and its owner and generation are
  kept.

  `:taken` when the row is no longer this member's at this fence, and then
  nothing is written. Either way this member holds nothing afterwards.
  """
  @spec release() :: :ok | :taken | :unclaimed | {:error, :database_error}
  def release do
    case held() do
      :none ->
        :unclaimed

      {:ok, slot} ->
        result =
          Arca.Repo.Errors.with_db_rescue("Arca.ControlPlane.release", fn ->
            now = Arca.ServerMetaStorage.now!()

            slot
            |> mine()
            |> Arca.Repo.update_all(
              set: [lease_until: now, fence: slot.fence + 1, updated_at: now]
            )
            |> case do
              {1, _} -> :ok
              {0, _} -> :taken
            end
          end)

        lost()
        result
    end
  end

  @doc """
  Inside a caller's `Arca.Repo.locking_transaction/2`: whether `slot` —
  node, owner and generation as `take/3` won them — still names the row,
  under a lease that stands on the database's clock.

  The statement is a conditional update that changes nothing
  (`fence` raised by zero), so it takes the row's lock without moving the
  fence the claimant's renew names: the claimant keeps renewing, and a
  successor's take waits until the caller commits. The lease is read back
  and compared with the database's clock read AFTER that lock was won, so
  a wait behind a release or a takeover cannot pass on an instant taken
  before it. Never touches the cached standing: `renew/1` writes that,
  and it is not called here.

  Raises outside a transaction and on a store that cannot answer, so the
  caller's transaction rolls back.
  """
  @spec verify_held(slot()) :: :ok | :lost
  # arca:db-raise-ok a step inside the caller's locking transaction; a raise rolls it back.
  def verify_held(%{node: node, owner: owner, generation: generation})
      when is_binary(node) and is_binary(owner) and is_integer(generation) do
    unless Arca.Repo.in_transaction?() do
      raise ArgumentError, "Arca.ControlPlane.verify_held/1 runs inside a locking transaction"
    end

    locked =
      from(l in CellLease,
        where: l.node == ^node and l.owner == ^owner and l.generation == ^generation,
        select: l.lease_until
      )

    case Arca.Repo.update_all(locked, inc: [fence: 0]) do
      {1, [lease_until]} ->
        if DateTime.compare(lease_until, Arca.ServerMetaStorage.now!()) == :gt,
          do: :ok,
          else: :lost

      {0, _} ->
        :lost
    end
  end

  # ---- the roster ------------------------------------------------------------

  @doc """
  The cell's live members: every `cell_leases` row whose lease still
  stands on the cell's clock, newest slot first.

  A member refreshes its copy on its own renew tick, so a roster is at
  most one tick stale, and staleness only ever affects a PROPOSAL — where
  a singleton should run. What actually runs it is a claim row.
  """
  @spec roster() :: {:ok, [map()]} | {:error, :database_error}
  def roster do
    Arca.Repo.Errors.with_db_rescue("Arca.ControlPlane.roster", fn ->
      now = Arca.ServerMetaStorage.now!()

      {:ok,
       Arca.Repo.all(
         from(l in CellLease,
           where: l.lease_until > ^now,
           order_by: [asc: l.node]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  @doc """
  Whether `boot` is a live member's boot: the one question behind every
  "is the claimant still alive?" in the cell — a turn's holder, an
  occurrence's claimant, an attempt's runner.

  Because `Prima.Boot.id/0` embeds the node, a claim left by an OLDER boot
  of the same node is not live, which is exactly right: that boot is gone
  even though its node came back.

  A store that cannot answer reads as not live, which refuses a takeover
  rather than admitting one.
  """
  @spec live_member?(String.t()) :: boolean()
  def live_member?(boot) when is_binary(boot) and boot != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ControlPlane.live_member?", false, fn ->
      now = Arca.ServerMetaStorage.now!()
      Arca.Repo.exists?(from(l in CellLease, where: l.owner == ^boot and l.lease_until > ^now))
    end)
  end

  def live_member?(_boot), do: false

  @doc "The slot row for `node` as it reads now, for diagnostics and tests."
  @spec slot(String.t()) :: {:ok, map()} | {:error, :not_found | :database_error}
  def slot(node) when is_binary(node) do
    Arca.Repo.Errors.with_db_rescue("Arca.ControlPlane.slot", fn ->
      case read(node) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  # ---- the cache -------------------------------------------------------------

  @doc """
  Record what this member holds. The claimant's writes call it; a test
  that needs a member in a given state calls it too.

  `{:held, ms}` is a DURATION, counted down from now on the local
  monotonic clock — see the module doc for why it is not a deadline.
  """
  @spec record(standing()) :: :ok
  def record({:held, :indefinitely} = standing),
    do: :persistent_term.put(@standing_key, standing)

  def record({:held, ms}) when is_integer(ms) and ms >= 0,
    do: :persistent_term.put(@standing_key, {:held, System.monotonic_time(:millisecond) + ms})

  def record(standing) when standing in [:lost, :unclaimed],
    do: :persistent_term.put(@standing_key, standing)

  @doc """
  Record the generation this member won, or `:none` where no member claims
  a slot. `forget_generation/0` for a member that holds none: its
  generation is unknown, which is not the same as there being none.
  """
  @spec record_generation(pos_integer() | :none) :: :ok
  def record_generation(:none), do: :persistent_term.put(@generation_key, :none)

  def record_generation(generation) when is_integer(generation) and generation > 0,
    do: :persistent_term.put(@generation_key, generation)

  @doc "Unrecord the generation: this member holds none and none is known."
  @spec forget_generation() :: :ok
  def forget_generation do
    _ = :persistent_term.erase(@generation_key)
    :ok
  end

  @doc """
  Record the slot this member holds, so `renew/1` and `release/0` know
  which row to write against. `take/3` calls it with what it won; a test
  putting a member back in a state it held calls it too.
  """
  @spec record_slot(slot()) :: :ok
  def record_slot(%{node: node, owner: owner, generation: generation, fence: fence} = slot)
      when is_binary(node) and is_binary(owner) and is_integer(generation) and is_integer(fence),
      do: :persistent_term.put(@slot_key, slot)

  @doc "Unrecord the slot: this member holds none, so its next act is a take."
  @spec forget() :: :ok
  def forget do
    _ = :persistent_term.erase(@slot_key)
    :ok
  end

  # ---- internal --------------------------------------------------------------

  # Everything a won lease leaves behind, in one place so the row and the
  # cache cannot drift: the slot the next write names, the generation
  # stamped outward, and the time left counted from the instant BEFORE the
  # write went out.
  defp won(row, lease_ms, started) do
    slot = %{
      node: row.node,
      owner: row.owner,
      generation: row.generation,
      fence: row.fence,
      lease_until: row.lease_until
    }

    elapsed = System.monotonic_time(:millisecond) - started
    record_slot(slot)
    record_generation(row.generation)
    record({:held, max(lease_ms - elapsed - @margin_ms, 0)})
    slot
  end

  defp lost do
    record(:lost)
    forget_generation()
    forget()
  end

  defp do_take(node, _owner, _lease_ms, 0) do
    case read(node) do
      nil -> {:error, :database_error}
      row -> {:busy, row}
    end
  end

  # What a write that landed is answered with is built from what the
  # statement SET, never re-read. A read after the write could see a
  # successor's row and hand this member a generation that is not its
  # own — the quietest way there is to believe a fence that fences
  # nothing.
  defp do_take(node, owner, lease_ms, rounds) do
    now = Arca.ServerMetaStorage.now!()

    case read(node) do
      nil ->
        if insert(node, owner, lease_ms, now),
          do: {:ok, opened(node, owner, lease_ms, now)},
          else: do_take(node, owner, lease_ms, rounds - 1)

      %CellLease{} = row ->
        cond do
          live?(row, now) and row.owner == owner ->
            # This boot's own slot, still standing: pushed out under the
            # same generation. A member is not its own successor.
            if push(row, lease_ms, now),
              do: {:ok, pushed(row, lease_ms, now)},
              else: do_take(node, owner, lease_ms, rounds - 1)

          live?(row, now) ->
            {:busy, row}

          take_over(row, owner, lease_ms, now) ->
            {:ok, taken(row, owner, lease_ms, now)}

          true ->
            do_take(node, owner, lease_ms, rounds - 1)
        end
    end
  end

  defp opened(node, owner, lease_ms, now) do
    %CellLease{
      node: node,
      owner: owner,
      generation: 1,
      fence: 1,
      lease_until: lease_end(now, lease_ms),
      taken_at: now
    }
  end

  defp taken(%CellLease{} = row, owner, lease_ms, now) do
    %CellLease{
      pushed(row, lease_ms, now)
      | owner: owner,
        generation: row.generation + 1,
        taken_at: now
    }
  end

  defp pushed(%CellLease{} = row, lease_ms, now) do
    %CellLease{row | fence: row.fence + 1, lease_until: lease_end(now, lease_ms)}
  end

  # The primary key on `node` decides a race between two first takes: the
  # loser inserts nothing and goes round again, where it finds the
  # winner's row.
  defp insert(node, owner, lease_ms, now) do
    row = %{
      node: node,
      owner: owner,
      generation: 1,
      fence: 1,
      lease_until: lease_end(now, lease_ms),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }

    match?({1, _}, Arca.Repo.insert_all(CellLease, [row], on_conflict: :nothing))
  end

  # The row is taken only as it was read — same fence — and only while it
  # is still takeable. Both conditions carry weight: the holder renewing
  # between the read and this write raises the fence, so the take finds a
  # number it did not read and the live claim is kept; and a second taker
  # racing this one loses for the same reason.
  defp take_over(%CellLease{} = row, owner, lease_ms, now) do
    query =
      from(l in CellLease,
        where: l.node == ^row.node and l.fence == ^row.fence,
        where: l.lease_until <= ^now
      )

    match?(
      {1, _},
      Arca.Repo.update_all(query,
        set: [
          owner: owner,
          generation: row.generation + 1,
          fence: row.fence + 1,
          lease_until: lease_end(now, lease_ms),
          taken_at: now,
          updated_at: now
        ]
      )
    )
  end

  defp push(%CellLease{} = row, lease_ms, now) do
    match?(
      {1, _},
      row
      |> mine()
      |> Arca.Repo.update_all(
        set: [lease_until: lease_end(now, lease_ms), fence: row.fence + 1, updated_at: now]
      )
    )
  end

  # The row while it is still this member's, at the fence it last wrote.
  defp mine(%{node: node, owner: owner, fence: fence}) do
    from(l in CellLease, where: l.node == ^node and l.owner == ^owner and l.fence == ^fence)
  end

  defp live?(%CellLease{lease_until: until}, now), do: DateTime.compare(until, now) == :gt

  defp read(node), do: Arca.Repo.one(from(l in CellLease, where: l.node == ^node))

  defp lease_end(now, lease_ms), do: DateTime.add(now, lease_ms, :millisecond)

  # Whether a claimant runs in this deployment at all. With one, a member
  # that has recorded nothing holds nothing — the fail-closed direction,
  # and the state of every member between its start and its first claim.
  # Without one there is no slot to take, so every boot holds.
  defp claimed_here?, do: Application.get_env(:arca, :control_plane_claim_enabled, true)
end
