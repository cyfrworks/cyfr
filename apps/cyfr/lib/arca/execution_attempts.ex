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
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.ExecutionAttempt

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

  @doc """
  Run `fun` while `runner` holds the attempt, as `held?/4` decides it, in
  one transaction with that decision: the write that finds the attempt
  takes its row's lock, and `fun` runs before the transaction commits. A
  close, cancel, lapse or takeover of the attempt writes its row, so it
  either commits first, and `fun` does not run, or waits until `fun` has
  returned.

  Answers `{:ok, result}` with what `fun` returned; `{:error, :lost}`
  when the attempt is not held, and `fun` did not run;
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec while_held(String.t(), String.t(), pos_integer(), String.t(), (-> result)) ::
          {:ok, result} | {:error, :lost | :database_error}
        when result: term()
  def while_held(athanor_id, attempt, fence, runner, fun)
      when is_binary(athanor_id) and is_binary(attempt) and is_integer(fence) and
             is_binary(runner) and is_function(fun, 0) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionAttempts.while_held", fn ->
      Arca.Repo.transaction(fn ->
        {count, _} =
          from(a in running_owner(athanor_id, attempt, fence), where: a.claimed_by == ^runner)
          |> Arca.Repo.update_all(inc: [fence: 0])

        if count == 1, do: fun.(), else: Arca.Repo.rollback(:lost)
      end)
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

        ran
    end
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
