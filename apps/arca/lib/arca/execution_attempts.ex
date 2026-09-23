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

  ## Tenancy

  Every function that names an athanor takes the `Cyfr.Actor` first and
  matches it in its head, so the tenant comes from the caller and never
  from an argument the caller chose. An actor whose athanor is nil OR
  the empty string is refused before any query: an entry point answers
  `{:error, :no_athanor}`, a `!` function raises. The empty string is an
  identity that was never resolved, so a guard that took it would filter
  on `athanor_id == ""`, match nothing and answer an ordinary empty
  result where the refusal belongs. The sweeps — `renew/3`, `lapse/3`,
  `list_stale/2` and the two retention primitives — carry no actor and
  say why where they stand.

  ## The grant

  Every attempt carries the estate standing it was admitted under
  (`athanor_generation`, `Cyfr.ExecutionGrant`): `open!/3` stamps it from
  the admission's grant and `takeover!/3` copies it to the successor
  unchanged. Every write that renews, claims, resumes, recovers or ends an
  attempt, every hold check a host effect is admitted on, and both
  transactions of a storage write run under `Arca.ExecutionStanding`'s
  contract: `grant:` and `verify:`, the check asked first in the
  transaction, and the attempt row matched on the grant's generation once
  it is held. A write whose grant the check refuses, or whose stamp does
  not match, changes nothing.

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
  `:started_at`, and `:grant`, the `Cyfr.ExecutionGrant` of the athanor it
  is stamped with (required).
  """
  @spec open!(Cyfr.Actor.t(), String.t(), keyword()) :: ExecutionAttempt.t()
  # arca:db-raise-ok inside the caller's transaction
  def open!(%Cyfr.Actor{athanor_id: athanor_id}, execution_id, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    now = Keyword.get(opts, :started_at, DateTime.utc_now())

    %Cyfr.ExecutionGrant{athanor_id: ^athanor_id, generation: generation} =
      Keyword.fetch!(opts, :grant)

    attempt =
      Arca.Repo.insert!(%ExecutionAttempt{
        attempt: Keyword.get(opts, :attempt) || generate_id(),
        athanor_id: athanor_id,
        athanor_generation: generation,
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

  def open!(%Cyfr.Actor{}, _execution_id, _opts),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionAttempts.open!/3")

  @doc """
  Renew the lease `attempt` holds, under its grant (`grant:` and
  `verify:`, `Arca.ExecutionStanding`). `{:ok, until}` when the attempt
  still owns its running execution and its grant stands; `:lost` when the
  store answered and it does not (it ended, paused, lapsed, a successor
  took the row, or its grant was refused or missing); `:unavailable` when
  the store, or the check, could not answer.
  """
  @spec renew(String.t(), DateTime.t(), keyword()) :: {:ok, DateTime.t()} | :lost | :unavailable
  def renew(attempt, %DateTime{} = until, opts) when is_binary(attempt) and is_list(opts) do
    # Fail-open default: a store that cannot answer is `:unavailable`, which the holder tolerates only inside its lease.
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.renew", :unavailable, fn ->
      case Arca.ExecutionStanding.inputs(opts, fn ->
             Arca.ExecutionStanding.stored(:any, attempt)
           end) do
        {:ok, nil, _verify} -> :lost
        {:ok, grant, verify} -> renew_standing(attempt, until, grant, verify)
        {:error, :missing_grant} -> :lost
      end
    end)
    |> Arca.Data.project()
  end

  # arca:unscoped-ok the runner renews the attempt it holds; the id comes
  # from trusted runtime state, never from a request, and the grant names
  # its athanor.
  defp renew_standing(attempt, until, grant, verify) do
    fn ->
      Arca.ExecutionStanding.verify!(grant, verify)

      {count, _} =
        from(a in ExecutionAttempt,
          where: a.attempt == ^attempt and a.state == "running",
          where: a.athanor_id == ^grant.athanor_id and a.athanor_generation == ^grant.generation,
          where: a.attempt in subquery(owner(attempt))
        )
        |> Arca.Repo.update_all(set: [lease_until: until])

      count
    end
    |> Arca.Repo.locking_transaction()
    |> case do
      {:ok, 1} -> {:ok, until}
      {:ok, _count} -> :lost
      {:error, :unavailable} -> :unavailable
      {:error, _refused} -> :lost
    end
  end

  @doc """
  Claim a running attempt for the runner that attached to it: `claimed_by`
  is set on the attempt at `fence` that owns its execution, is `running`
  and is unclaimed.

  The claim is made under the attempt's grant (`grant:` and `verify:`,
  `Arca.ExecutionStanding`). Answers `:ok` when the attempt is now claimed
  by `runner`, including when `runner` had already claimed it;
  `{:error, :replayed}` when another runner holds the claim;
  `{:error, :lost}` when the attempt is not the running owner at that
  fence; the check's own refusal (`:not_standing`, `:unavailable`) or
  `{:error, :missing_grant}`; `{:error, :database_error}` when the store
  cannot answer.
  """
  @spec claim(Cyfr.Actor.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          :ok | {:error, atom()}
  def claim(%Cyfr.Actor{athanor_id: athanor_id}, attempt, fence, runner, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.claim", fn ->
      with {:ok, grant, verify} <- standing_inputs(athanor_id, attempt, opts) do
        fn ->
          Arca.ExecutionStanding.verify!(grant, verify)
          owner = stamped(running_owner(athanor_id, attempt, fence), grant)

          {count, _} =
            from(a in owner, where: is_nil(a.claimed_by) or a.claimed_by == ^runner)
            |> Arca.Repo.update_all(set: [claimed_by: runner])

          cond do
            count == 1 -> :ok
            Arca.Repo.exists?(owner) -> Arca.Repo.rollback(:replayed)
            true -> Arca.Repo.rollback(:lost)
          end
        end
        |> Arca.Repo.locking_transaction()
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
    |> Arca.Data.project()
  end

  def claim(%Cyfr.Actor{}, _attempt, _fence, _runner, _opts), do: {:error, :no_athanor}

  @doc """
  Renew the lease of `attempt` while `holder` holds it and its grant
  stands (`grant:` and `verify:`, `Arca.ExecutionStanding`; each attempt
  its own stamp): one update, predicated on the row owning its execution,
  being `running`, dispatched to the holder's `service_id` on its
  `boot_id`, claimed by its `runner` and stamped with the grant's
  generation. `{:ok, until}` when it did; `:lost` when no such row holds
  or its grant was refused or missing; `{:error, :unavailable}` when the
  check could not answer and `{:error, :database_error}` when the store
  cannot. A header's own attempt and the children its runner runs renew
  alike.
  """
  @spec renew_held(
          Cyfr.Actor.t(),
          String.t(),
          %{service_id: String.t() | nil, boot_id: String.t(), runner: String.t()},
          keyword()
        ) ::
          {:ok, DateTime.t()} | :lost | {:error, :no_athanor | :unavailable | :database_error}
  def renew_held(
        %Cyfr.Actor{athanor_id: athanor_id},
        attempt,
        %{boot_id: boot_id, runner: runner} = holder,
        opts
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and
             is_binary(boot_id) and
             is_binary(runner) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.renew_held", fn ->
      case standing_inputs(athanor_id, attempt, opts) do
        {:ok, grant, verify} -> renew_held(athanor_id, attempt, holder, grant, verify)
        {:error, _refused} -> :lost
      end
    end)
    |> Arca.Data.project()
  end

  def renew_held(%Cyfr.Actor{}, _attempt, _holder, _opts), do: {:error, :no_athanor}

  # arca:db-raise-ok its caller rescues around it.
  defp renew_held(
         athanor_id,
         attempt,
         %{boot_id: boot_id, runner: runner} = holder,
         grant,
         verify
       ) do
    fn ->
      Arca.ExecutionStanding.verify!(grant, verify)
      # The lease reads the cell's clock after the estate's lock was won.
      until = lease_until()

      held =
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
          where: a.state == "running" and a.claimed_by == ^runner and a.boot_id == ^boot_id,
          where: a.athanor_generation == ^grant.generation,
          where: a.attempt in subquery(owner(attempt))
        )

      held =
        case holder.service_id do
          nil -> from(a in held, where: is_nil(a.service_id))
          service_id -> from(a in held, where: a.service_id == ^service_id)
        end

      {count, _} = Arca.Repo.update_all(held, set: [lease_until: until])
      if count == 1, do: {:ok, until}, else: :lost
    end
    |> Arca.Repo.locking_transaction()
    |> case do
      {:ok, answer} -> answer
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _refused} -> :lost
    end
  end

  @doc """
  Whether `runner` holds the attempt: it owns its execution, is `running`,
  is at `fence` and is claimed by `runner`. One read. Answers
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec held?(Cyfr.Actor.t(), String.t(), pos_integer(), String.t()) ::
          boolean() | {:error, :no_athanor | :database_error}
  def held?(%Cyfr.Actor{athanor_id: athanor_id}, attempt, fence, runner)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.held?", fn ->
      Arca.Repo.exists?(
        from(a in running_owner(athanor_id, attempt, fence), where: a.claimed_by == ^runner)
      )
    end)
    |> Arca.Data.project()
  end

  def held?(%Cyfr.Actor{}, _attempt, _fence, _runner), do: {:error, :no_athanor}

  @doc """
  `held?/4` under the attempt's grant (`grant:` and `verify:`,
  `Arca.ExecutionStanding`): the check a host effect is admitted on. The
  grant is checked first, in one transaction with the read, and the row
  must carry its generation. The transaction is a locking one, except for
  an effect that writes no row (`read_only: true` — a storage read, an
  artifact fetch, an egress admission), which checks in
  `Arca.Repo.read_transaction/1`. Answers `true` or `false`, the
  check's refusal (`{:error, :not_standing}`, `{:error, :unavailable}`),
  `{:error, :missing_grant}`, or `{:error, :database_error}` when the
  store cannot answer.
  """
  @spec held?(Cyfr.Actor.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          boolean() | {:error, atom()}
  def held?(%Cyfr.Actor{athanor_id: athanor_id}, attempt, fence, runner, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) and is_list(opts) do
    standing_check(athanor_id, attempt, opts, fn grant ->
      from(a in stamped(running_owner(athanor_id, attempt, fence), grant),
        where: a.claimed_by == ^runner
      )
    end)
  end

  def held?(%Cyfr.Actor{}, _attempt, _fence, _runner, _opts), do: {:error, :no_athanor}

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
  Run the storage `write` for the attempt `runner` holds at `fence`, under
  its grant (`grant:` and `verify:`, `Arca.ExecutionStanding`): its intent
  is recorded while the attempt holds its row and its grant stands, the
  store call runs outside any transaction, and the intent is settled
  against the same hold and the same grant (the moduledoc's "A guest's
  mutable storage write"). A grant refused at settlement is a hold that
  ended: the write is `uncertain`, never confirmed.

  Answers `{:ok, written}` once an intent was recorded; `{:error, :lost}`
  when the attempt is not held, the check's refusal (`:not_standing`,
  `:unavailable`) or `{:error, :missing_grant}`, and
  `{:error, :database_error}` when the database cannot answer. In each of
  those the store call did not run and nothing was recorded.
  """
  @spec while_held(Cyfr.Actor.t(), String.t(), pos_integer(), String.t(), write(), keyword()) ::
          {:ok, written()} | {:error, atom()}
  def while_held(
        %Cyfr.Actor{athanor_id: athanor_id},
        attempt,
        fence,
        runner,
        %{op: op, path: path, io: io} = write,
        opts
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) and op in [:put, :append, :delete] and is_list(path) and
             is_function(io, 0) and is_list(opts) do
    with {:ok, grant, verify} <-
           Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.while_held", fn ->
             standing_inputs(athanor_id, attempt, opts)
           end) do
      holder = %{
        athanor_id: athanor_id,
        attempt: attempt,
        fence: fence,
        runner: runner,
        grant: grant,
        verify: verify
      }

      with {:ok, intent} <- record_intent(holder, write) do
        {:ok, settle(holder, intent, effect(io, intent))}
      end
    end
  end

  def while_held(%Cyfr.Actor{}, _attempt, _fence, _runner, _write, _opts),
    do: {:error, :no_athanor}

  @doc "The write intents of `attempt`, oldest first."
  @spec write_intents(Cyfr.Actor.t(), String.t()) ::
          [map()] | {:error, :no_athanor | :database_error}
  def write_intents(%Cyfr.Actor{athanor_id: athanor_id}, attempt)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.write_intents", fn ->
      Arca.Repo.all(
        from(i in StorageWriteIntent,
          where: i.athanor_id == ^athanor_id and i.attempt == ^attempt,
          order_by: [asc: i.inserted_at, asc: i.id]
        )
      )
    end)
    |> Arca.Data.project()
  end

  def write_intents(%Cyfr.Actor{}, _attempt), do: {:error, :no_athanor}

  @doc """
  Delete an athanor's SETTLED write intents that were recorded before
  `cutoff` — the retention kind's write (`Cyfr.Retention.WriteIntents`).

  A `pending` intent is never deleted here whatever its age. It is the
  only record that a write may be in the store and was never settled, so
  age is no reason to lose it; the cascade from its execution's row is
  what finally takes it.
  """
  @spec delete_intents_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_intents_before(%DateTime{} = cutoff, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.delete_intents_before", fn ->
      {count, _} = Arca.Repo.delete_all(settled_before(cutoff, opts))
      {:ok, count}
    end)
    |> Arca.Data.project()
  end

  @doc "How many rows `delete_intents_before/2` would remove — the dry-run count."
  @spec count_intents_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_intents_before(%DateTime{} = cutoff, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.count_intents_before", fn ->
      {:ok, Arca.Repo.aggregate(settled_before(cutoff, opts), :count)}
    end)
    |> Arca.Data.project()
  end

  defp settled_before(cutoff, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    from(i in StorageWriteIntent,
      where: i.athanor_id == ^athanor_id and i.state != "pending",
      where: i.inserted_at < ^cutoff
    )
  end

  @doc """
  Whether `runner` holds the attempt (`held?/4`) and it is live: its
  execution is `running` and still points at it. A cancel is a terminal
  write, so a cancelled execution is no longer live. One read. Answers
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec live?(Cyfr.Actor.t(), String.t(), pos_integer(), String.t()) ::
          boolean() | {:error, :no_athanor | :database_error}
  def live?(%Cyfr.Actor{athanor_id: athanor_id}, attempt, fence, runner)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.live?", fn ->
      Arca.Repo.exists?(
        from(a in ExecutionAttempt,
          join: e in Arca.Schemas.Execution,
          on: e.id == a.execution_id and e.athanor_id == a.athanor_id,
          where: a.athanor_id == ^athanor_id and a.attempt == ^attempt and a.fence == ^fence,
          where: a.state == "running" and a.claimed_by == ^runner,
          where: e.status == "running" and e.current_attempt == a.attempt
        )
      )
    end)
    |> Arca.Data.project()
  end

  def live?(%Cyfr.Actor{}, _attempt, _fence, _runner), do: {:error, :no_athanor}

  @doc """
  `live?/4` under the attempt's grant, answered as `held?/5` answers: the
  check a child, a catalog tool or a credential projection is admitted on.
  """
  @spec live?(Cyfr.Actor.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          boolean() | {:error, atom()}
  def live?(%Cyfr.Actor{athanor_id: athanor_id}, attempt, fence, runner, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) and is_list(opts) do
    standing_check(athanor_id, attempt, opts, fn grant ->
      from(a in ExecutionAttempt,
        join: e in Arca.Schemas.Execution,
        on: e.id == a.execution_id and e.athanor_id == a.athanor_id,
        where: a.athanor_id == ^athanor_id and a.attempt == ^attempt and a.fence == ^fence,
        where: a.state == "running" and a.claimed_by == ^runner,
        where: a.athanor_generation == ^grant.generation,
        where: e.status == "running" and e.current_attempt == a.attempt
      )
    end)
  end

  def live?(%Cyfr.Actor{}, _attempt, _fence, _runner, _opts), do: {:error, :no_athanor}

  @doc """
  Whether the open attempt `attempt` of `execution_id` still stands under
  its grant (`grant:` and `verify:`, `Arca.ExecutionStanding`): the attempt
  is `running` or `paused`, belongs to that execution in the actor's
  athanor, and carries the grant's generation, which the check accepts.
  The trusted lineage of an in-chain call is admitted on this. Answers as
  `held?/5` does.
  """
  @spec standing?(Cyfr.Actor.t(), String.t(), String.t(), keyword()) ::
          boolean() | {:error, atom()}
  def standing?(%Cyfr.Actor{athanor_id: athanor_id}, attempt, execution_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(attempt) and
             is_binary(execution_id) and is_list(opts) do
    standing_check(athanor_id, attempt, opts, fn grant ->
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
        where: a.execution_id == ^execution_id and a.state in ^@open_states,
        where: a.athanor_generation == ^grant.generation
      )
    end)
  end

  def standing?(%Cyfr.Actor{}, _attempt, _execution_id, _opts), do: {:error, :no_athanor}

  @doc """
  The grant the current attempt of `execution_id` carries, as it is
  stored: `{:ok, grant}`, `{:error, :not_found}` when the execution has no
  attempt in the actor's athanor, or `{:error, :database_error}`. A child
  of that execution, and a successor of its attempt, inherit it unchanged.
  """
  @spec grant(Cyfr.Actor.t(), String.t()) ::
          {:ok, Cyfr.ExecutionGrant.t()} | {:error, :no_athanor | :not_found | :database_error}
  def grant(%Cyfr.Actor{athanor_id: athanor_id}, execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(execution_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.grant", fn ->
      case Arca.ExecutionStanding.stored_of_execution(
             Cyfr.Actor.in_athanor(athanor_id),
             execution_id
           ) do
        nil -> {:error, :not_found}
        grant -> {:ok, grant}
      end
    end)
    |> Arca.Data.project()
  end

  def grant(%Cyfr.Actor{}, _execution_id), do: {:error, :no_athanor}

  # One transaction: the grant's check, then the read `query` builds from
  # the grant. A read-only effect's check needs no write lock.
  defp standing_check(athanor_id, attempt, opts, query) do
    transaction =
      if Keyword.get(opts, :read_only, false),
        do: &Arca.Repo.read_transaction/1,
        else: &Arca.Repo.locking_transaction/1

    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.standing", fn ->
      with {:ok, grant, verify} <- standing_inputs(athanor_id, attempt, opts, false) do
        fn ->
          Arca.ExecutionStanding.verify!(grant, verify)
          Arca.Repo.exists?(query.(grant))
        end
        |> transaction.()
        |> case do
          {:ok, held?} -> held?
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  # The grant and check a fenced write on `attempt` was handed, `:stored`
  # resolved to the stamp the row carries. A row that does not exist is
  # `lost_as`; a grant of another estate is not this attempt's standing.
  # arca:db-raise-ok called inside its caller's rescue.
  defp standing_inputs(athanor_id, attempt, opts, lost_as \\ {:error, :lost}) do
    stored = fn -> Arca.ExecutionStanding.stored(Cyfr.Actor.in_athanor(athanor_id), attempt) end

    case Arca.ExecutionStanding.inputs(opts, stored) do
      {:ok, nil, _verify} -> lost_as
      {:ok, %Cyfr.ExecutionGrant{athanor_id: ^athanor_id}, _verify} = ok -> ok
      {:ok, %Cyfr.ExecutionGrant{}, _verify} -> {:error, :not_standing}
      {:error, :missing_grant} = refused -> refused
    end
  end

  # An attempt query narrowed to the rows stamped with `grant`'s generation.
  defp stamped(query, %Cyfr.ExecutionGrant{generation: generation}),
    do: from(a in query, where: a.athanor_generation == ^generation)

  @doc """
  Hold the attempt a child is admitted under, inside the caller's admission
  transaction: `attempt` must own `execution_id`, be `running` and carry
  the child's grant, and the execution must be `running`. Answers 1 when
  it is, 0 when it is not (the
  caller rolls back). The write takes the attempt row's lock, so a close,
  cancel or lapse of the attempt either commits first, and the child is
  refused, or waits for the admission to commit, and finds the child to
  fail.
  """
  @spec hold_for_child!(Cyfr.Actor.t(), String.t(), String.t(), Cyfr.ExecutionGrant.t()) ::
          non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def hold_for_child!(
        %Cyfr.Actor{athanor_id: athanor_id},
        execution_id,
        attempt,
        %Cyfr.ExecutionGrant{athanor_id: athanor_id, generation: generation}
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(execution_id) and
             is_binary(attempt) do
    running_execution =
      from(e in Arca.Schemas.Execution,
        where: e.id == ^execution_id and e.athanor_id == ^athanor_id and e.status == "running",
        select: e.current_attempt
      )

    {count, _} =
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
        where: a.attempt == ^attempt and a.state == "running",
        where: a.athanor_generation == ^generation,
        where: a.attempt in subquery(running_execution)
      )
      |> Arca.Repo.update_all(inc: [fence: 0])

    count
  end

  def hold_for_child!(%Cyfr.Actor{}, _execution_id, _attempt, _grant),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionAttempts.hold_for_child!/4")

  @doc """
  Pause a running attempt inside the caller's transaction: `running →
  paused`, the running interval closed. Answers the milliseconds it ran,
  or `nil` when the attempt was not the running owner (the caller rolls
  back).
  """
  @spec pause!(Cyfr.Actor.t(), String.t()) :: non_neg_integer() | nil
  # arca:db-raise-ok inside the caller's transaction
  def pause!(%Cyfr.Actor{athanor_id: athanor_id}, attempt)
      when is_binary(athanor_id) and athanor_id != "" do
    close_interval!(athanor_id, attempt, "running", "paused", nil, nil)
  end

  def pause!(%Cyfr.Actor{}, _attempt),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionAttempts.pause!/2")

  @doc """
  Resume a paused attempt inside the caller's transaction with a fresh
  lease: `paused → running`, a new running interval opened, on the attempt
  stamped with `grant`'s generation, whose check the caller asked first.
  Answers the rows moved (1, or 0 when the attempt was not the paused
  owner under that stamp).
  """
  @spec resume!(Cyfr.Actor.t(), String.t(), DateTime.t(), Cyfr.ExecutionGrant.t()) ::
          non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def resume!(
        %Cyfr.Actor{athanor_id: athanor_id},
        attempt,
        %DateTime{} = until,
        %Cyfr.ExecutionGrant{athanor_id: athanor_id, generation: generation}
      )
      when is_binary(athanor_id) and athanor_id != "" do
    {count, _} =
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.attempt == ^attempt and a.state == "paused",
        where: a.athanor_generation == ^generation,
        where: a.attempt in subquery(owner(attempt))
      )
      |> Arca.Repo.update_all(
        set: [state: "running", lease_until: until, running_since: DateTime.utc_now()]
      )

    count
  end

  def resume!(%Cyfr.Actor{}, _attempt, _until, _grant),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionAttempts.resume!/4")

  @doc """
  Close an open attempt inside the caller's transaction as
  `completed | failed | cancelled` with its `outcome`, on the attempt
  stamped with `grant`'s generation, whose check the caller asked first.
  Answers the milliseconds its last running interval ran (0 when it was
  paused), or `nil` when the attempt was not the open owner under that
  stamp.
  """
  @spec close!(Cyfr.Actor.t(), String.t(), String.t(), String.t(), Cyfr.ExecutionGrant.t()) ::
          non_neg_integer() | nil
  # arca:db-raise-ok inside the caller's transaction
  def close!(
        %Cyfr.Actor{athanor_id: athanor_id},
        attempt,
        state,
        outcome,
        %Cyfr.ExecutionGrant{athanor_id: athanor_id} = grant
      )
      when is_binary(athanor_id) and athanor_id != "" and
             state in ["completed", "failed", "cancelled"] and
             outcome in @outcomes do
    close_interval!(athanor_id, attempt, @open_states, state, outcome, DateTime.utc_now(), grant)
  end

  def close!(%Cyfr.Actor{}, _attempt, _state, _outcome, _grant),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionAttempts.close!/5")

  @doc """
  Entry-point form of `close!/5` under the attempt's grant (`grant:` and
  `verify:`, `Arca.ExecutionStanding`): `{:ok, ran_ms}`,
  `{:error, :not_owner}`, or the check's refusal.
  """
  @spec close(Cyfr.Actor.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def close(%Cyfr.Actor{athanor_id: athanor_id} = actor, attempt, state, outcome, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.close", fn ->
      with {:ok, grant, verify} <-
             standing_inputs(athanor_id, attempt, opts, {:error, :not_owner}) do
        fn ->
          Arca.ExecutionStanding.verify!(grant, verify)

          case close!(actor, attempt, state, outcome, grant) do
            nil -> Arca.Repo.rollback(:not_owner)
            ran -> ran
          end
        end
        |> Arca.Repo.locking_transaction()
      end
    end)
    |> Arca.Data.project()
  end

  def close(%Cyfr.Actor{}, _attempt, _state, _outcome, _opts), do: {:error, :no_athanor}

  @doc """
  Retire a running attempt whose lease the sweeper observed lapsed:
  `running → lapsed`, fenced on that exact lease so a renewal that landed
  between the scan and this write matches nothing, and on the attempt's
  stamp (`grant:` and `verify:`, `Arca.ExecutionStanding`; a lapse is a
  retirement, so its check need not find the grant standing). Answers
  `{:ok, ran_ms}` when the attempt was retired, `{:ok, nil}` when it was
  not, or the check's refusal.
  """
  @spec lapse(String.t(), DateTime.t(), keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def lapse(attempt, %DateTime{} = seen, opts) when is_binary(attempt) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.lapse", fn ->
      stored = fn -> Arca.ExecutionStanding.stored(:any, attempt) end

      case Arca.ExecutionStanding.inputs(opts, stored) do
        {:ok, nil, _verify} ->
          {:ok, nil}

        {:ok, grant, verify} ->
          Arca.Repo.locking_transaction(fn ->
            Arca.ExecutionStanding.verify!(grant, verify)
            lapse!(attempt, seen, grant)
          end)

        {:error, :missing_grant} = refused ->
          refused
      end
    end)
    |> Arca.Data.project()
  end

  @doc false
  @spec lapse!(String.t(), DateTime.t(), Cyfr.ExecutionGrant.t()) :: non_neg_integer() | nil
  # `lapse/3` inside a caller's transaction that already asked the check.
  # arca:unscoped-ok the sweeper retires lapsed attempts across all
  # tenants; the id comes from its own scan, never from a request, and the
  # grant names the athanor.
  # arca:db-raise-ok inside the caller's transaction
  def lapse!(attempt, %DateTime{} = seen, %Cyfr.ExecutionGrant{} = grant) do
    lapsing =
      from(a in ExecutionAttempt,
        where: a.attempt == ^attempt and a.state == "running" and a.lease_until == ^seen,
        where: a.athanor_id == ^grant.athanor_id and a.athanor_generation == ^grant.generation
      )

    case Arca.Repo.one(lapsing) do
      nil ->
        nil

      %ExecutionAttempt{} = a ->
        upto = DateTime.add(seen, -lease_seconds(), :second)
        ran = interval_ms(a.running_since, upto)

        {1, _} =
          Arca.Repo.update_all(lapsing,
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
  end

  @doc """
  Open the successor of an execution's current attempt inside the
  caller's transaction: the predecessor is retired as `lapsed` unless it
  is already terminal, the successor is inserted `running` with the next
  fence, a fresh lease and the predecessor's stamp, and the pointer moves
  — one transaction, so two attempts never both own the row. `opts[:grant]`
  (required) is the grant whose check the caller asked first; a
  predecessor stamped otherwise rolls the transaction back as
  `:not_standing`. Answers `%{previous: t | nil, attempt: t, ran_ms: n}`
  where `ran_ms` is the predecessor's unaccounted running interval (0
  when it had none).
  """
  @spec takeover!(Cyfr.Actor.t(), String.t(), keyword()) :: %{
          previous: ExecutionAttempt.t() | nil,
          attempt: ExecutionAttempt.t(),
          ran_ms: non_neg_integer()
        }
  # arca:db-raise-ok inside the caller's transaction
  def takeover!(%Cyfr.Actor{athanor_id: athanor_id}, execution_id, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    # The cell's clock, so the interval this retires is measured against
    # the same clock the lease it replaces was written on: `upto` below
    # is derived from the predecessor's `lease_until`, which is database
    # time, and reading `now` off the member would fold its own skew into
    # the running time it accounts.
    now = Arca.ServerMetaStorage.now!()

    %Cyfr.ExecutionGrant{athanor_id: ^athanor_id, generation: generation} =
      Keyword.fetch!(opts, :grant)

    previous =
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
        where: a.attempt in subquery(current_of(execution_id))
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()

    # A successor inherits its predecessor's stamp unchanged: a grant of
    # any other generation is not this execution's.
    if previous && previous.athanor_generation != generation,
      do: Arca.Repo.rollback(:not_standing)

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
        athanor_generation: generation,
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

  def takeover!(%Cyfr.Actor{}, _execution_id, _opts),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionAttempts.takeover!/3")

  @doc """
  Entry-point form of `takeover!/3`, under the execution's grant
  (`grant:`, `:stored` for the current attempt's stamp, and `verify:`,
  `Arca.ExecutionStanding`): a recovery whose grant the check refuses
  opens no successor.
  """
  @spec takeover(Cyfr.Actor.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def takeover(%Cyfr.Actor{athanor_id: athanor_id} = actor, execution_id, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.takeover", fn ->
      stored = fn ->
        Arca.ExecutionStanding.stored_of_execution(
          Cyfr.Actor.in_athanor(athanor_id),
          execution_id
        )
      end

      case Arca.ExecutionStanding.inputs(opts, stored) do
        {:ok, %Cyfr.ExecutionGrant{athanor_id: ^athanor_id} = grant, verify} ->
          Arca.Repo.locking_transaction(fn ->
            Arca.ExecutionStanding.verify!(grant, verify)

            takeover!(
              actor,
              execution_id,
              opts |> Keyword.drop([:verify]) |> Keyword.put(:grant, grant)
            )
          end)

        {:ok, _none, _verify} ->
          {:error, :not_standing}

        {:error, :missing_grant} = refused ->
          refused
      end
    end)
    |> Arca.Data.project()
  end

  def takeover(%Cyfr.Actor{}, _execution_id, _opts), do: {:error, :no_athanor}

  @doc "The attempt that owns `execution_id`, or nil."
  @spec current(Cyfr.Actor.t(), String.t()) :: map() | nil | {:error, term()}
  def current(%Cyfr.Actor{athanor_id: athanor_id}, execution_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.current", fn ->
      Arca.Repo.one(
        from(a in ExecutionAttempt,
          where: a.athanor_id == ^athanor_id and a.execution_id == ^execution_id,
          where: a.attempt in subquery(current_of(execution_id))
        )
      )
    end)
    |> Arca.Data.project()
  end

  def current(%Cyfr.Actor{}, _execution_id), do: {:error, :no_athanor}

  @doc "One attempt by id, within the athanor."
  @spec get(Cyfr.Actor.t(), String.t()) :: map() | nil | {:error, term()}
  def get(%Cyfr.Actor{athanor_id: athanor_id}, attempt)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.get", fn ->
      Arca.Repo.one(
        from(a in ExecutionAttempt, where: a.athanor_id == ^athanor_id and a.attempt == ^attempt)
      )
    end)
    |> Arca.Data.project()
  end

  def get(%Cyfr.Actor{}, _attempt), do: {:error, :no_athanor}

  @doc """
  Running attempts whose lease lapsed before `now` (the sweep). Spans
  every tenant: the sweeper reaps what a crashed runner left when no
  tenant can be reconstructed. System-internal only.

  `now` is the cell's clock, `Arca.ServerMetaStorage.now!/0`, never the
  calling member's: a member whose own clock runs fast would otherwise
  list attempts a peer is still renewing, and lapse live work.
  """
  @spec list_stale(DateTime.t(), pos_integer()) :: [map()]
  def list_stale(%DateTime{} = now, limit \\ 50) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.list_stale", [], fn ->
      # arca:unscoped-ok the sweeper reaps lapsed attempts across all
      # tenants when no tenant can be reconstructed.
      Arca.Repo.all(
        from(a in ExecutionAttempt,
          where: a.state == "running" and a.lease_until < ^now,
          order_by: [asc: a.lease_until],
          limit: ^limit
        )
      )
    end)
    |> Arca.Data.project()
  end

  @doc "How long one lease is good for, in seconds."
  def lease_seconds, do: 180

  @doc """
  A fresh lease expiry, on the cell's clock.

  Two members could disagree about whether an attempt's lease has run out,
  and the disagreement would let both take it over, so the instant comes
  from `Arca.ServerMetaStorage.now!/0` and not from whichever member is
  writing. Raises when the store cannot answer it: a lease decision taken
  on a clock that could not be read is the one thing that must not happen
  quietly.
  """
  def lease_until, do: DateTime.add(Arca.ServerMetaStorage.now!(), lease_seconds(), :second)

  # Close the running interval of the owner attempt in `from_states`,
  # moving it to `to` with `outcome` (nil keeps the column) and
  # `ended_at`; with a grant, only the attempt stamped with its
  # generation. Answers the interval's milliseconds, or nil when no row
  # moved.
  # arca:db-raise-ok inside the caller's transaction
  defp close_interval!(athanor_id, attempt, from_states, to, outcome, ended_at, grant \\ nil) do
    from_states = List.wrap(from_states)

    owner =
      from(a in ExecutionAttempt,
        where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
        where: a.state in ^from_states,
        where: a.attempt in subquery(owner(attempt))
      )

    owner = if grant, do: stamped(owner, grant), else: owner
    row = owner |> Arca.QueryHelpers.for_update() |> Arca.Repo.one()

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

  # Step 1: the grant, the hold and the intent commit together, or none
  # does. The estate's lock is taken first, then the attempt's.
  defp record_intent(holder, write) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.record_intent", fn ->
      Arca.Repo.locking_transaction(fn ->
        Arca.ExecutionStanding.verify!(holder.grant, holder.verify)
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
  # estate's lock and then the attempt row's. A write the store applied is
  # confirmed only while the grant and the hold still stand and the intent
  # is still pending: a grant retired while the store call ran settles it
  # uncertain, exactly as a hold that ended does. A refusal and an unknown
  # outcome are what they are whoever holds the row.
  defp settle(holder, intent, effect) do
    settled =
      Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.settle", fn ->
        Arca.Repo.locking_transaction(fn ->
          held? =
            case holder.verify.(holder.grant) do
              :ok -> lock_held!(holder)
              {:error, :not_standing} -> false
              {:error, reason} -> Arca.Repo.rollback(reason)
            end

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
  defp lock_held!(%{
         athanor_id: athanor_id,
         attempt: attempt,
         fence: fence,
         runner: runner,
         grant: grant
       }) do
    # The cell's clock: whether the hold still stands is a question two
    # members could answer differently, and both would then let a write
    # land. Never this member's own.
    now = Arca.ServerMetaStorage.now!()

    {count, _} =
      from(a in stamped(running_owner(athanor_id, attempt, fence), grant),
        where: a.claimed_by == ^runner and a.lease_until > ^now
      )
      |> Arca.Repo.update_all(inc: [fence: 0])

    count == 1
  end

  # arca:db-raise-ok inside the caller's transaction
  defp point!(athanor_id, execution_id, attempt) do
    {1, _} =
      from(e in Arca.Schemas.Execution,
        where: e.id == ^execution_id and e.athanor_id == ^athanor_id
      )
      |> Arca.Repo.update_all(set: [current_attempt: attempt])

    :ok
  end

  # The pointer of the execution `attempt` belongs to, as a subquery a
  # write can require its own id to be in.
  defp owner(attempt) do
    from(e in Arca.Schemas.Execution,
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
    from(e in Arca.Schemas.Execution, where: e.id == ^execution_id, select: e.current_attempt)
  end

  # The milliseconds from `since` to `upto` (now when nil), never negative;
  # 0 when the interval never opened.
  defp interval_ms(nil, _upto), do: 0

  defp interval_ms(%DateTime{} = since, upto) do
    upto = upto || DateTime.utc_now()
    max(DateTime.diff(upto, since, :millisecond), 0)
  end
end
