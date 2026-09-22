# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Fixtures do
  @moduledoc """
  The rows a two-node case works on, made **on a member** and committed.

  Nothing here is checked out of a sandbox: a cluster member runs the real
  pool, and a fixture that rolled back at the end of a case would take the
  cell's own rows with it. Each fixture is therefore named uniquely for
  the case that made it, and left behind — the cluster database is the
  suite's own and is recreated, not reused.

  The functions run on whichever member a case names, which is itself part
  of what is under test: an athanor made on one member is read by the
  other because it is a row, not because anything was shared.
  """

  @compile {:no_warn_undefined,
            [
              Aqua.Runner,
              Arca.Athanors,
              Arca.BudgetReservations,
              Arca.CronSchedule,
              Arca.Execution,
              Arca.RateWindows,
              Arca.ScheduleOccurrences,
              Arca.ThreadStorage,
              Arca.TurnStorage,
              Cyfr.Actor,
              Cyfr.Authority.Budget,
              Cyfr.Boot,
              Cyfr.UUID7,
              Sanctum.Authority.BudgetCounter
            ]}

  @doc "An athanor of this case's own, created on the member this runs on."
  @spec athanor!(String.t()) :: map()
  def athanor!(label) do
    id = Cyfr.UUID7.generate_id("ath")
    slug = "cell-#{label}-#{System.unique_integer([:positive])}"

    {:ok, athanor} =
      Arca.Athanors.insert(Cyfr.Actor.system(), %{
        id: id,
        kind: "group",
        name: "Cluster #{label}",
        slug: slug,
        created_by: "system"
      })

    %{id: athanor.id, slug: athanor.slug}
  end

  @doc "An actor in `athanor_id`, as every fixture here writes under."
  @spec actor(String.t()) :: struct()
  def actor(athanor_id), do: Cyfr.Actor.in_athanor(athanor_id)

  @doc "A thread of `athanor_id`, with no turn holding it."
  @spec thread!(String.t(), String.t()) :: map()
  def thread!(athanor_id, title) do
    {:ok, thread} = Arca.ThreadStorage.create(actor(athanor_id), %{title: title})
    %{id: thread.id, athanor_id: athanor_id}
  end

  @doc "The thread row as it reads on this member, for a case to look at ownership."
  @spec thread(String.t(), String.t()) :: map() | nil
  def thread(athanor_id, thread_id) do
    case Arca.ThreadStorage.get(actor(athanor_id), thread_id) do
      {:ok, thread} -> thread
      _absent -> nil
    end
  end

  @doc """
  Accept a message on `thread_id` that opens an `accepted` turn, and answer
  the turn and the thread's consumed sequence — what a claimant names in
  its compare-and-set.
  """
  @spec accept!(String.t(), String.t(), String.t()) :: map()
  def accept!(athanor_id, thread_id, text) do
    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor(athanor_id), thread_id, %{
        message: %{
          author: "usr_cluster",
          kind: "text",
          content: text,
          client_id: "cluster-#{System.unique_integer([:positive])}"
        },
        turn: %{agent: "agent:local.aqua", requested_by: "system", model: nil, options: %{}}
      })

    {:ok, thread} = Arca.ThreadStorage.get(actor(athanor_id), thread_id)
    %{turn_id: turn.id, fence: turn.fence, turn_seq: thread.turn_seq, status: turn.status}
  end

  @doc """
  Start `turn_id` on this member: the turn goes `running`, the thread's
  claim is taken in the same transaction naming the sequence the claimant
  read, and `turns.runner_id` becomes this member's boot.

  Answers `{:ok, turn}` or the refusal — `{:error, {:busy, holder}}` when
  another turn holds the thread, `{:error, :stale}` when a peer accepted
  the next message first.
  """
  @spec start_turn(String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def start_turn(athanor_id, turn_id, turn_seq, fence) do
    case Arca.TurnStorage.start(actor(athanor_id), turn_id, %{fence: fence, turn_seq: turn_seq}) do
      {:ok, turn} -> {:ok, %{id: turn.id, status: turn.status, runner_id: turn.runner_id}}
      other -> other
    end
  end

  @doc """
  Take `thread_id`'s claim for `turn_id` against the consumed sequence
  `turn_seq` — §4.2's statement, on its own. Two members naming one
  sequence is the race the statement exists for.
  """
  @spec claim_thread(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def claim_thread(athanor_id, thread_id, turn_id, turn_seq) do
    case Arca.ThreadStorage.claim(actor(athanor_id), thread_id, turn_id, turn_seq) do
      {:ok, thread} -> {:ok, thread.active_turn_id}
      other -> other
    end
  end

  @doc "Who holds `thread_id`'s claim, as this member reads it."
  @spec claim_holder(String.t(), String.t()) :: map() | {:error, term()}
  def claim_holder(athanor_id, thread_id) do
    case Arca.ThreadStorage.claim_holder(actor(athanor_id), thread_id) do
      {:ok, holder} -> holder
      other -> other
    end
  end

  @doc "Whether this member would start a runner for `thread_id` (`Aqua.Runner.ensure/2`)."
  @spec ensure_runner(String.t(), String.t()) :: :started | {:error, term()}
  def ensure_runner(athanor_id, thread_id) do
    case Aqua.Runner.ensure(thread_id, athanor_id) do
      {:ok, pid} when is_pid(pid) -> :started
      other -> other
    end
  end

  @doc "This member's boot id."
  @spec boot() :: String.t()
  def boot, do: Cyfr.Boot.id()

  # ---------------------------------------------------------------------------
  # Budgets, rates and schedules — the tenant's durable ceilings
  # ---------------------------------------------------------------------------

  @doc """
  A root execution of `athanor_id` carrying the invocation reservation its
  authority's budget names, so both members can charge against one cap.
  """
  @spec budget!(String.t(), pos_integer()) :: map()
  def budget!(athanor_id, cap) do
    budget_id = "bgt_cluster_#{System.unique_integer([:positive])}"

    {:ok, %{execution: root, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: Cyfr.UUID7.execution_id(),
          reference: "formula:local.cluster:1.0.0",
          user_id: "usr_cluster",
          athanor_id: athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: budget_id, cap: cap}
      )

    %{budget_id: budget_id, root: root.id, attempt: attempt.attempt}
  end

  @doc "Charge one invocation against `budget_id` from this member."
  @spec charge(String.t(), String.t(), String.t(), String.t()) :: atom() | {:error, term()}
  def charge(athanor_id, budget_id, attempt, charge_id) do
    Arca.BudgetReservations.charge(
      actor(athanor_id),
      budget_id,
      %{id: charge_id, attempt: attempt, generation: 0, holder_execution_id: nil},
      1,
      []
    )
  end

  @doc "What `budget_id` has been charged, as this member reads it."
  @spec charged(String.t(), String.t()) :: non_neg_integer()
  def charged(athanor_id, budget_id),
    do: Arca.BudgetReservations.lookup(actor(athanor_id), budget_id).charged

  @doc "Whether this member's node-local in-flight counter admits one more of `budget_id`."
  @spec try_acquire(String.t(), pos_integer()) :: :ok | {:error, atom()}
  def try_acquire(budget_id, cap),
    do: Sanctum.Authority.BudgetCounter.try_acquire(%Cyfr.Authority.Budget{id: budget_id, cap: cap})

  @doc "Claim one of `bucket`'s allowance from this member."
  @spec take_rate(String.t(), String.t(), non_neg_integer(), pos_integer()) :: term()
  def take_rate(athanor_id, bucket, cap, window_ms),
    do: Arca.RateWindows.claim(actor(athanor_id), bucket, cap, window_ms)

  @doc "A cron schedule of `athanor_id`, due `seconds_ago` seconds ago."
  @spec due_schedule!(String.t(), pos_integer()) :: map()
  def due_schedule!(athanor_id, seconds_ago) do
    {:ok, schedule} =
      Arca.CronSchedule.create(%{
        user_id: "usr_cluster",
        athanor_id: athanor_id,
        name: "cluster-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: "reagent:local.cluster:1.0.0",
        resolved_reference: "reagent:local.cluster:1.0.0",
        profile_id: "prof_cluster",
        next_run_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      })

    %{id: schedule.id, next_run_at: schedule.next_run_at}
  end

  @doc """
  Claim `schedule_id`'s due occurrence for this member's boot, advancing
  the cursor to `next_run`. `{:ok, occurrence}`, `:held` or `:overlapping`.
  """
  @spec claim_occurrence(String.t(), DateTime.t()) :: {:ok, map()} | :held | :overlapping | term()
  def claim_occurrence(schedule_id, next_run) do
    {:ok, schedule} = Arca.CronSchedule.get_for_daemon(schedule_id)

    case Arca.ScheduleOccurrences.claim(schedule, Cyfr.Boot.id(), next_run) do
      {:ok, occurrence} ->
        {:ok, %{id: occurrence.id, state: occurrence.state, claimed_by: occurrence.claimed_by}}

      other ->
        other
    end
  end
end
