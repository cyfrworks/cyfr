# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionAttempts do
  @moduledoc """
  The `execution_attempts` rows: the fence every attempt-scoped write
  names.

  An execution is owned by exactly one attempt at a time, the one its
  `current_attempt` names. Renewal, pause, resume, closing and cancel all
  match the attempt AND the pointer, so an attempt that lost the row —
  its lease lapsed and the sweeper retired it, or a successor took it —
  cannot write over the owner. A successor is opened only by
  `takeover/3`, in the same transaction that retires its predecessor and
  moves the pointer, so two attempts are never both running.

  Running time is accounted per interval: `running_since` is set when an
  attempt starts or resumes and cleared when it pauses, ends or lapses;
  each of those answers the milliseconds the interval ran, and a caller
  that keeps a total adds each interval once.

  Functions ending in `!` run inside a caller's transaction and raise on
  a store error so the caller's transaction rolls back; the others are
  entry points and answer `{:error, :database_error}` when the store
  cannot answer.

  ## A guest's mutable storage write

  A put, an append and a delete are the mutable storage operations a guest
  reaches, and each runs through `while_held/5` in three steps. No
  transaction is open while the store is touched, and the store is never
  touched on a check alone: the check and the record of what is about to
  happen commit together.

    1. **Intent.** One short transaction takes the attempt row's lock by
       writing it, requires the hold — the attempt owns its execution, is
       `running` at the caller's fence, is claimed by the caller's runner
       and its lease has not run out — and inserts a `pending`
       `Arca.Schemas.StorageWriteIntent` naming the attempt, fence, runner,
       operation and path under a fresh id. Without the hold nothing is
       recorded and the store is not touched.
    2. **Store.** The adapter call runs outside any transaction.
    3. **Settle.** A second short transaction takes the row's lock again,
       requires the same hold and moves the intent out of `pending` by
       compare-and-set.

  Every write that ends an attempt's hold (`pause!/2`, `close!/4`,
  `lapse/2`, `takeover!/3`) settles the attempt's `pending` intents as
  `uncertain`, in its own transaction and after it wrote the attempt row,
  with the reason `paused`, the terminal state, `lapsed` or `taken_over`.
  So an intent is `pending` only while its attempt still holds, a cancel is
  never made to wait for a store, and the evidence that a write may land
  commits with the write that ended the hold.

  ### The commit point of each operation

  | Operation | The store's commit point | `confirmed` means |
  |---|---|---|
  | put | the adapter's replacement of the object (Local: the rename over the path; S3: the `PUT` the store acknowledged) | the object holds the bytes, and the attempt held its row before and after |
  | append | the adapter's extension of the object (Local: the `O_APPEND` write; S3: the conditional `PUT` under the ETag it read) | the bytes were appended once, whole, and the attempt held its row before and after |
  | delete | the adapter's removal of the object | the object is gone, and the attempt held its row before and after |

  The write is the guest's once step 3 commits `confirmed`; until then it
  is answered to nobody as written.

  ### Against a cancel, a lapse and a takeover

  For a write the store answered `:ok`:

  | The hold ends | The store | The intent | `while_held/5` answers |
  |---|---|---|---|
  | before step 1 commits | not touched | none | `{:error, :lost}` |
  | between steps 1 and 2 | may be written after the hold ended | `uncertain`, settled by the write that ended the hold | `{:ok, {:uncertain, :hold_lost}}` |
  | between steps 2 and 3 | written while the hold stood | `uncertain`, settled by the write that ended the hold | `{:ok, {:uncertain, :hold_lost}}` |
  | after step 3 commits | written while the hold stood | `confirmed` | `{:ok, {:confirmed, :ok}}` |

  Steps 1 and 3 and the write that ends a hold all write the attempt row
  first, so each pair runs in one order. A write whose store call overlaps
  the end of its attempt's hold cannot be told from one that landed after
  it, so it is never confirmed and never answered as refused: it is
  `uncertain`. A process killed between the steps settles nothing itself;
  its intent is settled by the cancel, lapse or takeover that ends its
  attempt, which is also what a recovering owner's takeover does with the
  `pending` intents it finds.

  ### What the store answered

  | The store | The intent | `while_held/5` answers |
  |---|---|---|
  | `:ok` | as the table above | as the table above |
  | `{:error, :unknown}`: it may have applied the write | `uncertain`, `unknown_outcome` | `{:ok, {:uncertain, :unknown_outcome}}` |
  | it raised, exited or answered no storage result | `uncertain`, `io_crashed` | `{:ok, {:uncertain, :io_crashed}}` |
  | any other `{:error, reason}`: it wrote nothing | `failed`, with the reason's name | `{:ok, {:failed, {:error, reason}}}` |

  The last three rows are answered whoever holds the row by then. An intent
  the end of a hold already settled keeps that settlement: an attempt that
  lost its row overwrites nothing, its own evidence included.

  An append that lost to concurrent writers until the adapter's bound ran
  out is `{:error, :precondition_failed}`: a definite conflict, nothing
  appended, the intent `failed`, and appending again is safe. An append the
  store may have applied is `:unknown` and is never sent twice. Two writes
  of one attempt to one path are two intents; the adapter orders them (per
  path on Local, by conditional write on S3), a put is last-writer-wins and
  appends all land. When the store applied a write and step 3 cannot reach
  the database, the answer is `{:ok, {:uncertain, :unconfirmed}}` and the
  intent stays `pending` until the attempt's hold ends.

  Intents are evidence: no path here deletes one, and a row goes only with
  its execution's row.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Arca.Schemas.{ExecutionAttempt, StorageWriteIntent}

  @open_states ["running", "paused"]
  @terminal_states ["completed", "failed", "cancelled", "lapsed"]
  @outcomes ["ok", "error", "result_lost", "cancelled", "uncertain"]

  @doc "The states an attempt that still owns work can be in."
  def open_states, do: @open_states

  @doc "The states of an attempt that no longer owns work."
  def terminal_states, do: @terminal_states

  @doc "A fresh attempt id."
  @spec generate_id() :: String.t()
  def generate_id, do: Cyfr.UUID7.generate_id("att")

  @doc """
  Open the first attempt of `execution_id` inside the caller's admission
  transaction: fence 1, `running`, and the execution's `current_attempt`
  pointed at it. `opts`: `:attempt` (the id, minted when absent),
  `:service_id` (the worker service it is dispatched to; nil when the
  control plane holds it), `:boot_id` (the boot holding it), `:lease_until`,
  `:started_at`.
  """
  @spec open!(String.t(), String.t(), keyword()) :: ExecutionAttempt.t()
  # arca:db-raise-ok inside the caller's transaction
  def open!(athanor_id, execution_id, opts) when is_binary(athanor_id) do
    now = Keyword.get(opts, :started_at, DateTime.utc_now())

    attempt =
      Arca.Repo.insert!(%ExecutionAttempt{
        attempt: Keyword.get(opts, :attempt) || generate_id(),
        athanor_id: athanor_id,
        execution_id: execution_id,
        fence: 1,
        service_id: Keyword.get(opts, :service_id),
        boot_id: Keyword.fetch!(opts, :boot_id),
        lease_until: Keyword.fetch!(opts, :lease_until),
        state: "running",
        started_at: now,
        running_since: now
      })

    point!(athanor_id, execution_id, attempt.attempt)
    attempt
  end

  @doc """
  Renew the lease `attempt` holds. `{:ok, until}` when the attempt still
  owns its running execution; `:lost` when the store answered and it does
  not (it ended, paused, lapsed, or a successor took the row);
  `:unavailable` when the store could not answer.
  """
  @spec renew(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | :lost | :unavailable
  def renew(attempt, %DateTime{} = until) when is_binary(attempt) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.renew", :unavailable, fn ->
      # arca:unscoped-ok the runner renews the attempt it holds; the id
      # comes from trusted runtime state, never from a request.
      {count, _} =
        from(a in ExecutionAttempt,
          where: a.attempt == ^attempt and a.state == "running",
          where: a.attempt in subquery(owner(attempt))
        )
        |> Arca.Repo.update_all(set: [lease_until: until])

      if count == 1, do: {:ok, until}, else: :lost
    end)
  end

  @doc """
  Claim a running attempt for the runner that attached to it: `claimed_by`
  is set on the attempt at `fence` that owns its execution, is `running`
  and is unclaimed.

  Answers `:ok` when the attempt is now claimed by `runner`, including
  when `runner` had already claimed it; `{:error, :replayed}` when another
  runner holds the claim; `{:error, :lost}` when the attempt is not the
  running owner at that fence; `{:error, :database_error}` when the store
  cannot answer.
  """
  @spec claim(String.t(), String.t(), pos_integer(), String.t()) ::
          :ok | {:error, :replayed | :lost | :database_error}
  def claim(athanor_id, attempt, fence, runner)
      when is_binary(athanor_id) and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.claim", fn ->
      Arca.Repo.transaction(fn ->
        {count, _} =
          from(a in running_owner(athanor_id, attempt, fence),
            where: is_nil(a.claimed_by) or a.claimed_by == ^runner
          )
          |> Arca.Repo.update_all(set: [claimed_by: runner])

        cond do
          count == 1 ->
            :ok

          Arca.Repo.exists?(running_owner(athanor_id, attempt, fence)) ->
            Arca.Repo.rollback(:replayed)

          true ->
            Arca.Repo.rollback(:lost)
        end
      end)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renew the lease of `attempt` while `holder` holds it: one update,
  predicated on the row owning its execution, being `running`, dispatched
  to the holder's `service_id` on its `boot_id` and claimed by its
  `runner`. `{:ok, until}` when it did; `:lost` when no such row holds;
  `{:error, :database_error}` when the store cannot answer. A header's own
  attempt and the children its runner runs renew alike.
  """
  @spec renew_held(String.t(), String.t(), %{
          service_id: String.t() | nil,
          boot_id: String.t(),
          runner: String.t()
        }) ::
          {:ok, DateTime.t()} | :lost | {:error, :database_error}
  def renew_held(athanor_id, attempt, %{boot_id: boot_id, runner: runner} = holder)
      when is_binary(athanor_id) and is_binary(attempt) and is_binary(boot_id) and
             is_binary(runner) do
    until = lease_until()

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.renew_held", fn ->
      held =
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
          where: a.state == "running" and a.claimed_by == ^runner and a.boot_id == ^boot_id,
          where: a.attempt in subquery(owner(attempt))
        )

      held =
        case holder.service_id do
          nil -> from(a in held, where: is_nil(a.service_id))
          service_id -> from(a in held, where: a.service_id == ^service_id)
        end

      {count, _} = Arca.Repo.update_all(held, set: [lease_until: until])
      if count == 1, do: {:ok, until}, else: :lost
    end)
  end

  @doc """
  Whether `runner` holds the attempt: it owns its execution, is `running`,
  is at `fence` and is claimed by `runner`. One read. Answers
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec held?(String.t(), String.t(), pos_integer(), String.t()) ::
          boolean() | {:error, :database_error}
  def held?(athanor_id, attempt, fence, runner)
      when is_binary(athanor_id) and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.held?", fn ->
      Arca.Repo.exists?(
        from(a in running_owner(athanor_id, attempt, fence), where: a.claimed_by == ^runner)
      )
    end)
  end

  @typedoc """
  A mutable storage write: the operation, the athanor-relative path it
  names, the bytes a put or append carries, and the store call itself,
  which answers `:ok` or `{:error, reason}` as `Arca.Storage` does.
  """
  @type write :: %{
          required(:op) => :put | :append | :delete,
          required(:path) => [String.t()],
          required(:io) => (-> :ok | {:error, term()}),
          optional(:bytes) => non_neg_integer() | nil
        }

  @typedoc "What became of a write whose intent was recorded (the moduledoc's tables)."
  @type written ::
          {:confirmed, :ok}
          | {:failed, {:error, term()}}
          | {:uncertain, :hold_lost | :unknown_outcome | :io_crashed | :unconfirmed}

  @doc """
  Run the storage `write` for the attempt `runner` holds at `fence`: its
  intent is recorded while the attempt holds its row, the store call runs
  outside any transaction, and the intent is settled against the same hold
  (the moduledoc's "A guest's mutable storage write").

  Answers `{:ok, written}` once an intent was recorded; `{:error, :lost}`
  when the attempt is not held, and `{:error, :database_error}` when the
  database cannot answer. In both the store call did not run and nothing
  was recorded.
  """
  @spec while_held(String.t(), String.t(), pos_integer(), String.t(), write()) ::
          {:ok, written()} | {:error, :lost | :database_error}
  def while_held(athanor_id, attempt, fence, runner, %{op: op, path: path, io: io} = write)
      when is_binary(athanor_id) and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) and op in [:put, :append, :delete] and is_list(path) and
             is_function(io, 0) do
    holder = %{athanor_id: athanor_id, attempt: attempt, fence: fence, runner: runner}

    with {:ok, intent} <- record_intent(holder, write) do
      {:ok, settle(holder, intent, effect(io, intent))}
    end
  end

  @doc "The write intents of `attempt`, oldest first."
  @spec write_intents(String.t(), String.t()) ::
          [StorageWriteIntent.t()] | {:error, :database_error}
  def write_intents(athanor_id, attempt) when is_binary(athanor_id) and is_binary(attempt) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.write_intents", fn ->
      Arca.Repo.all(
        from(i in StorageWriteIntent,
          where: i.athanor_id == ^athanor_id and i.attempt == ^attempt,
          order_by: [asc: i.inserted_at, asc: i.id]
        )
      )
    end)
  end

  @doc """
  Whether `runner` holds the attempt (`held?/4`) and it is live: its
  execution is `running` and still points at it. A cancel is a terminal
  write, so a cancelled execution is no longer live. One read. Answers
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec live?(String.t(), String.t(), pos_integer(), String.t()) ::
          boolean() | {:error, :database_error}
  def live?(athanor_id, attempt, fence, runner)
      when is_binary(athanor_id) and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.live?", fn ->
      Arca.Repo.exists?(
        from(a in ExecutionAttempt,
          join: e in Arca.Execution,
          on: e.id == a.execution_id and e.athanor_id == a.athanor_id,
          where: a.athanor_id == ^athanor_id and a.attempt == ^attempt and a.fence == ^fence,
          where: a.state == "running" and a.claimed_by == ^runner,
          where: e.status == "running" and e.current_attempt == a.attempt
        )
      )
    end)
  end

  @doc """
  Hold the attempt a child is admitted under, inside the caller's admission
  transaction: `attempt` must own `execution_id` and be `running`, and the
  execution must be `running`. Answers 1 when it is, 0 when it is not (the
  caller rolls back). The write takes the attempt row's lock, so a close,
  cancel or lapse of the attempt either commits first, and the child is
  refused, or waits for the admission to commit, and finds the child to
  fail.
  """
  @spec hold_for_child!(String.t(), String.t(), String.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def hold_for_child!(athanor_id, execution_id, attempt)
      when is_binary(athanor_id) and is_binary(execution_id) and is_binary(attempt) do
    running_execution =
      from(e in Arca.Execution,
        where: e.id == ^execution_id and e.athanor_id == ^athanor_id and e.status == "running",
        select: e.current_attempt
      )

    {count, _} =
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
        where: a.attempt == ^attempt and a.state == "running",
        where: a.attempt in subquery(running_execution)
      )
      |> Arca.Repo.update_all(inc: [fence: 0])

    count
  end

  @doc """
  Pause a running attempt inside the caller's transaction: `running →
  paused`, the running interval closed. Answers the milliseconds it ran,
  or `nil` when the attempt was not the running owner (the caller rolls
  back).
  """
  @spec pause!(String.t(), String.t()) :: non_neg_integer() | nil
  # arca:db-raise-ok inside the caller's transaction
  def pause!(athanor_id, attempt) when is_binary(athanor_id) do
    close_interval!(athanor_id, attempt, "running", "paused", nil, nil)
  end

  @doc """
  Resume a paused attempt inside the caller's transaction with a fresh
  lease: `paused → running`, a new running interval opened. Answers the
  rows moved (1, or 0 when the attempt was not the paused owner).
  """
  @spec resume!(String.t(), String.t(), DateTime.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def resume!(athanor_id, attempt, %DateTime{} = until) when is_binary(athanor_id) do
    {count, _} =
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.attempt == ^attempt and a.state == "paused",
        where: a.attempt in subquery(owner(attempt))
      )
      |> Arca.Repo.update_all(
        set: [state: "running", lease_until: until, running_since: DateTime.utc_now()]
      )

    count
  end

  @doc """
  Close an open attempt inside the caller's transaction as
  `completed | failed | cancelled` with its `outcome`. Answers the
  milliseconds its last running interval ran (0 when it was paused), or
  `nil` when the attempt was not the open owner.
  """
  @spec close!(String.t(), String.t(), String.t(), String.t()) :: non_neg_integer() | nil
  # arca:db-raise-ok inside the caller's transaction
  def close!(athanor_id, attempt, state, outcome)
      when is_binary(athanor_id) and state in ["completed", "failed", "cancelled"] and
             outcome in @outcomes do
    close_interval!(athanor_id, attempt, @open_states, state, outcome, DateTime.utc_now())
  end

  @doc "Entry-point form of `close!/4`: `{:ok, ran_ms}` or `{:error, :not_owner}`."
  @spec close(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_owner | :database_error}
  def close(athanor_id, attempt, state, outcome) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.close", fn ->
      Arca.Repo.transaction(fn ->
        case close!(athanor_id, attempt, state, outcome) do
          nil -> Arca.Repo.rollback(:not_owner)
          ran -> ran
        end
      end)
    end)
  end

  @doc """
  Retire a running attempt whose lease the sweeper observed lapsed:
  `running → lapsed`, fenced on that exact lease so a renewal that landed
  between the scan and this write matches nothing. Answers `{:ok, ran_ms}`
  when the attempt was retired, `{:ok, nil}` when it was not.
  """
  @spec lapse(String.t(), DateTime.t()) :: {:ok, non_neg_integer() | nil} | {:error, term()}
  def lapse(attempt, %DateTime{} = seen) when is_binary(attempt) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.lapse", fn ->
      # arca:unscoped-ok the sweeper retires lapsed attempts across all
      # tenants; the id comes from its own scan, never from a request.
      Arca.Repo.transaction(fn ->
        row =
          Arca.Repo.one(
            from(a in ExecutionAttempt,
              where: a.attempt == ^attempt and a.state == "running" and a.lease_until == ^seen
            )
          )

        case row do
          nil ->
            nil

          %ExecutionAttempt{} = a ->
            upto = DateTime.add(seen, -lease_seconds(), :second)
            ran = interval_ms(a.running_since, upto)

            {1, _} =
              from(x in ExecutionAttempt,
                where: x.attempt == ^attempt and x.state == "running" and x.lease_until == ^seen
              )
              |> Arca.Repo.update_all(
                set: [
                  state: "lapsed",
                  outcome: "uncertain",
                  running_since: nil,
                  ended_at: DateTime.utc_now()
                ]
              )

            settle_pending!(a.athanor_id, attempt, "lapsed")
            ran
        end
      end)
    end)
  end

  @doc """
  Open the successor of an execution's current attempt inside the
  caller's transaction: the predecessor is retired as `lapsed` unless it
  is already terminal, the successor is inserted `running` with the next
  fence and a fresh lease, and the pointer moves — one transaction, so
  two attempts never both own the row. Answers
  `%{previous: t | nil, attempt: t, ran_ms: n}` where `ran_ms` is the
  predecessor's unaccounted running interval (0 when it had none).
  """
  @spec takeover!(String.t(), String.t(), keyword()) :: %{
          previous: ExecutionAttempt.t() | nil,
          attempt: ExecutionAttempt.t(),
          ran_ms: non_neg_integer()
        }
  # arca:db-raise-ok inside the caller's transaction
  def takeover!(athanor_id, execution_id, opts) when is_binary(athanor_id) do
    now = DateTime.utc_now()

    previous =
      Arca.Repo.one(
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
          where: a.attempt in subquery(current_of(execution_id))
        )
      )

    ran =
      case previous do
        %ExecutionAttempt{state: state, running_since: since} when state in @open_states ->
          upto =
            if state == "running",
              do: DateTime.add(previous.lease_until, -lease_seconds(), :second),
              else: nil

          ms = interval_ms(since, upto)

          {1, _} =
            from(a in ExecutionAttempt,
              where: a.athanor_id == ^athanor_id and a.attempt == ^previous.attempt
            )
            |> Arca.Repo.update_all(
              set: [state: "lapsed", outcome: "uncertain", running_since: nil, ended_at: now]
            )

          settle_pending!(athanor_id, previous.attempt, "taken_over")
          ms

        _ ->
          0
      end

    fence =
      Arca.Repo.one(
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
          select: coalesce(max(a.fence), 0)
        )
      ) + 1

    attempt =
      Arca.Repo.insert!(%ExecutionAttempt{
        attempt: Keyword.get(opts, :attempt) || generate_id(),
        athanor_id: athanor_id,
        execution_id: execution_id,
        fence: fence,
        service_id: Keyword.get(opts, :service_id),
        boot_id: Keyword.fetch!(opts, :boot_id),
        lease_until: Keyword.fetch!(opts, :lease_until),
        state: "running",
        started_at: now,
        running_since: now
      })

    point!(athanor_id, execution_id, attempt.attempt)
    %{previous: previous, attempt: attempt, ran_ms: ran}
  end

  @doc "Entry-point form of `takeover!/3`."
  @spec takeover(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def takeover(athanor_id, execution_id, opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.takeover", fn ->
      Arca.Repo.transaction(fn -> takeover!(athanor_id, execution_id, opts) end)
    end)
  end

  @doc "The attempt that owns `execution_id`, or nil."
  @spec current(String.t(), String.t()) :: ExecutionAttempt.t() | nil | {:error, term()}
  def current(athanor_id, execution_id) when is_binary(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.current", fn ->
      Arca.Repo.one(
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
          where: a.attempt in subquery(current_of(execution_id))
        )
      )
    end)
  end

  @doc "One attempt by id, within the athanor."
  @spec get(String.t(), String.t()) :: ExecutionAttempt.t() | nil | {:error, term()}
  def get(athanor_id, attempt) when is_binary(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.get", fn ->
      Arca.Repo.one(
        from(a in ExecutionAttempt, where: a.athanor_id == ^athanor_id and a.attempt == ^attempt)
      )
    end)
  end

  @doc """
  Running attempts whose lease lapsed before `now` (the sweep). Spans
  every tenant: the sweeper reaps what a crashed runner left when no
  tenant context can be reconstructed. System-internal only.
  """
  @spec list_stale(DateTime.t(), pos_integer()) :: [ExecutionAttempt.t()]
  def list_stale(%DateTime{} = now, limit \\ 50) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.list_stale", [], fn ->
      # arca:unscoped-ok the sweeper reaps lapsed attempts across all
      # tenants when no tenant context can be reconstructed.
      Arca.Repo.all(
        from(a in ExecutionAttempt,
          where: a.state == "running" and a.lease_until < ^now,
          order_by: [asc: a.lease_until],
          limit: ^limit
        )
      )
    end)
  end

  @doc "How long one lease is good for, in seconds."
  def lease_seconds, do: 180

  @doc "A fresh lease expiry from now."
  def lease_until, do: DateTime.add(DateTime.utc_now(), lease_seconds(), :second)

  # Close the running interval of the owner attempt in `from_states`,
  # moving it to `to` with `outcome` (nil keeps the column) and
  # `ended_at`. Answers the interval's milliseconds, or nil when no row
  # moved.
  # arca:db-raise-ok inside the caller's transaction
  defp close_interval!(athanor_id, attempt, from_states, to, outcome, ended_at) do
    from_states = List.wrap(from_states)

    row =
      Arca.Repo.one(
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
          where: a.state in ^from_states,
          where: a.attempt in subquery(owner(attempt))
        )
      )

    case row do
      nil ->
        nil

      %ExecutionAttempt{} = a ->
        ran = interval_ms(a.running_since, nil)

        sets =
          [state: to, running_since: nil, ended_at: ended_at] ++
            if(outcome, do: [outcome: outcome], else: [])

        {1, _} =
          from(x in ExecutionAttempt,
            where: x.athanor_id == ^athanor_id and x.attempt == ^attempt and x.state == ^a.state
          )
          |> Arca.Repo.update_all(set: sets)

        settle_pending!(athanor_id, attempt, to)
        ran
    end
  end

  # The attempt's hold just ended in this transaction: a write whose intent
  # is still pending may land after it, so it is settled uncertain with
  # what ended the hold. Runs after the attempt row was written, so it sees
  # every intent whose transaction held that row's lock before this one.
  # arca:db-raise-ok inside the caller's transaction
  defp settle_pending!(athanor_id, attempt, reason) do
    from(i in StorageWriteIntent,
      where: i.athanor_id == ^athanor_id and i.attempt == ^attempt and i.state == "pending"
    )
    |> Arca.Repo.update_all(
      set: [state: "uncertain", reason: reason, settled_at: DateTime.utc_now()]
    )

    :ok
  end

  # Step 1: the hold and the intent commit together, or neither does.
  defp record_intent(holder, write) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.record_intent", fn ->
      Arca.Repo.transaction(fn ->
        if not lock_held!(holder), do: Arca.Repo.rollback(:lost)

        execution_id =
          Arca.Repo.one!(
            from(a in ExecutionAttempt,
              where: a.athanor_id == ^holder.athanor_id and a.attempt == ^holder.attempt,
              select: a.execution_id
            )
          )

        intent =
          Arca.Repo.insert!(%StorageWriteIntent{
            id: Cyfr.UUID7.generate_id("swi"),
            athanor_id: holder.athanor_id,
            execution_id: execution_id,
            attempt: holder.attempt,
            fence: holder.fence,
            runner: holder.runner,
            op: Atom.to_string(write.op),
            path: Enum.join(write.path, "/"),
            bytes: Map.get(write, :bytes),
            state: "pending",
            inserted_at: DateTime.utc_now()
          })

        intent.id
      end)
    end)
  end

  # Step 2: the store call, outside any transaction. A call that did not
  # answer a storage result leaves what the store did unknown.
  defp effect(io, intent) do
    case io.() do
      :ok -> :applied
      {:error, :unknown} -> {:unknown, :unknown_outcome}
      {:error, _reason} = refused -> {:refused, refused}
      other -> crashed(intent, "answered #{inspect(other, limit: 5, printable_limit: 64)}")
    end
  rescue
    exception -> crashed(intent, Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, _payload -> crashed(intent, "ended with a #{kind}")
  end

  defp crashed(intent, how) do
    Logger.error("[Arca.ExecutionAttempts] the store call of write intent #{intent} #{how}")
    {:unknown, :io_crashed}
  end

  # Step 3: the intent leaves `pending` by compare-and-set, under the
  # attempt row's lock. A write the store applied is confirmed only while
  # the hold still stands and the intent is still pending; a refusal and
  # an unknown outcome are what they are whoever holds the row.
  defp settle(holder, intent, effect) do
    settled =
      Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.settle", fn ->
        Arca.Repo.transaction(fn ->
          held? = lock_held!(holder)
          {state, reason} = settlement(effect, held?)

          {count, _} =
            from(i in StorageWriteIntent,
              where: i.athanor_id == ^holder.athanor_id and i.id == ^intent,
              where: i.state == "pending"
            )
            |> Arca.Repo.update_all(
              set: [state: state, reason: reason, settled_at: DateTime.utc_now()]
            )

          held? and count == 1
        end)
      end)

    case {effect, settled} do
      {:applied, {:ok, true}} -> {:confirmed, :ok}
      {:applied, {:ok, false}} -> {:uncertain, :hold_lost}
      {:applied, {:error, _reason}} -> {:uncertain, :unconfirmed}
      {{:refused, refused}, _settled} -> {:failed, refused}
      {{:unknown, reason}, _settled} -> {:uncertain, reason}
    end
  end

  defp settlement(:applied, true), do: {"confirmed", nil}
  defp settlement(:applied, false), do: {"uncertain", "hold_lost"}
  defp settlement({:refused, {:error, reason}}, _held?), do: {"failed", failure(reason)}
  defp settlement({:unknown, reason}, _held?), do: {"uncertain", Atom.to_string(reason)}

  # The name of a store's refusal, never its detail: a reason can carry a
  # backend's words.
  defp failure(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: failure(elem(reason, 0))

  defp failure(_reason), do: "error"

  # Whether the holder holds the attempt for a write, decided by a write
  # of the attempt row, so the decision takes the row's lock and stands
  # until the caller's transaction ends.
  # arca:db-raise-ok inside the caller's transaction
  defp lock_held!(%{athanor_id: athanor_id, attempt: attempt, fence: fence, runner: runner}) do
    now = DateTime.utc_now()

    {count, _} =
      from(a in running_owner(athanor_id, attempt, fence),
        where: a.claimed_by == ^runner and a.lease_until > ^now
      )
      |> Arca.Repo.update_all(inc: [fence: 0])

    count == 1
  end

  # arca:db-raise-ok inside the caller's transaction
  defp point!(athanor_id, execution_id, attempt) do
    {1, _} =
      from(e in Arca.Execution, where: e.id == ^execution_id and e.athanor_id == ^athanor_id)
      |> Arca.Repo.update_all(set: [current_attempt: attempt])

    :ok
  end

  # The pointer of the execution `attempt` belongs to, as a subquery a
  # write can require its own id to be in.
  defp owner(attempt) do
    from(e in Arca.Execution,
      join: a in ExecutionAttempt,
      on: a.execution_id == e.id,
      where: a.attempt == ^attempt,
      select: e.current_attempt
    )
  end

  # The attempt at `fence` that owns its execution and is running.
  defp running_owner(athanor_id, attempt, fence) do
    from(a in ExecutionAttempt,
      where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
      where: a.fence == ^fence and a.state == "running",
      where: a.attempt in subquery(owner(attempt))
    )
  end

  defp current_of(execution_id) do
    from(e in Arca.Execution, where: e.id == ^execution_id, select: e.current_attempt)
  end

  # The milliseconds from `since` to `upto` (now when nil), never negative;
  # 0 when the interval never opened.
  defp interval_ms(nil, _upto), do: 0

  defp interval_ms(%DateTime{} = since, upto) do
    upto = upto || DateTime.utc_now()
    max(DateTime.diff(upto, since, :millisecond), 0)
  end
end
