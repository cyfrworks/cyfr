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
              Arca.Cache,
              Arca.Cache.Keys,
              Arca.ExecutionEvents,
              Cyfr.Actor,
              Cyfr.Authority.Budget,
              Cyfr.Boot,
              Cyfr.Execution,
              Cyfr.Execution.Events,
              Cyfr.UUID7,
              Sanctum.Authority.BudgetCounter,
              Sanctum.Caller,
              Sanctum.Context,
              Sanctum.Provisioning,
              Sanctum.Session,
              Sanctum.Tenancy.Athanors,
              Sanctum.Tenancy.Users
            ]}

  @doc """
  An athanor of this case's own, created on the member this runs on.

  The slug is taken from the athanor's own id rather than from
  `System.unique_integer/1`: a member's VM starts that counter again from
  the bottom, and this database outlives the run, so a second run of the
  suite against it would collide with the first run's rows.
  """
  @spec athanor!(String.t()) :: map()
  def athanor!(label) do
    id = Cyfr.UUID7.generate_id("ath")
    slug = "cell-#{label}-#{unique_of(id)}"

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

  defp unique_of(id) do
    id |> String.split("_") |> List.last() |> String.replace("-", "") |> String.slice(0, 20)
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
  @spec start_turn(String.t(), String.t(), non_neg_integer(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_turn(athanor_id, turn_id, turn_seq, fence, opts \\ []) do
    attrs =
      with_root(%{fence: fence, turn_seq: turn_seq}, Keyword.get(opts, :root, false), athanor_id)

    case Arca.TurnStorage.start(actor(athanor_id), turn_id, attrs) do
      {:ok, turn} -> {:ok, %{id: turn.id, status: turn.status, runner_id: turn.runner_id}}
      other -> other
    end
  end

  # A turn that will be suspended needs the root execution a real one
  # carries: `suspend/3` closes the attempt's running interval, and a turn
  # with no attempt has none to close.
  defp with_root(attrs, false, _athanor_id), do: attrs

  defp with_root(attrs, true, athanor_id) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(%{
        id: Cyfr.UUID7.execution_id(),
        reference: "formula:local.cluster-turn:1.0.0",
        user_id: "usr_cluster",
        athanor_id: athanor_id,
        component_type: "formula"
      })

    Map.merge(attrs, %{root_execution_id: execution.id, attempt: attempt.attempt})
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

  @doc """
  Set `turn_id` down from this member (`turn.suspend`'s storage half):
  every Tape row is preserved and the thread's claim is given up, so any
  member may pick the turn up.
  """
  @spec suspend_turn(String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def suspend_turn(athanor_id, turn_id, fence, reason) do
    case Arca.TurnStorage.suspend(actor(athanor_id), turn_id, %{fence: fence, reason: reason}) do
      {:ok, turn} -> {:ok, turn(turn)}
      other -> other
    end
  end

  @doc """
  Take `turn_id` on this member and carry it on (`turn.recover`'s storage
  half): the thread's claim and the recovery count in one transaction, so
  a member that did not take the claim cannot spend a recovery.
  """
  @spec recover_turn(String.t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def recover_turn(athanor_id, turn_id, fence) do
    case Arca.TurnStorage.recover(actor(athanor_id), turn_id, %{fence: fence}) do
      {:ok, turn} -> {:ok, turn(turn)}
      other -> other
    end
  end

  @doc "The turn row as this member reads it."
  @spec turn(String.t(), String.t()) :: map() | {:error, term()}
  def turn(athanor_id, turn_id) do
    case Arca.TurnStorage.get(actor(athanor_id), turn_id) do
      {:ok, row} -> turn(row)
      other -> other
    end
  end

  defp turn(row) do
    Map.take(row, [
      :id,
      :status,
      :paused_reason,
      :fence,
      :runner_id,
      :recovery_attempts,
      :thread_id
    ])
  end

  @doc "How many messages `thread_id` holds, as this member counts them."
  @spec messages(String.t(), String.t()) :: non_neg_integer()
  def messages(athanor_id, thread_id),
    do: length(Arca.ThreadStorage.messages(actor(athanor_id), thread_id))

  @doc "A pending approval on `thread_id`, as a row a decision is a compare-and-set on."
  @spec approval!(String.t(), String.t()) :: String.t()
  def approval!(athanor_id, thread_id) do
    {:ok, thread} = Arca.ThreadStorage.get(actor(athanor_id), thread_id)
    id = Cyfr.UUID7.generate_id("msg")

    Arca.ThreadStorage.insert_message!(actor(athanor_id), thread, %{
      id: id,
      author: "usr_cluster",
      kind: "approval",
      status: "pending",
      content: "may I?",
      approval_id: id
    })

    id
  end

  @doc "The pending approvals of `thread_id`, as this member reads them."
  @spec pending_approvals(String.t(), String.t()) :: [String.t()]
  def pending_approvals(athanor_id, thread_id) do
    athanor_id
    |> actor()
    |> Arca.ThreadStorage.pending_approvals(thread_id)
    |> Enum.map(& &1.id)
  end

  @doc "Decide `approval_id` from this member — a compare-and-set on its status."
  @spec decide(String.t(), String.t(), String.t()) :: term()
  def decide(athanor_id, approval_id, to) do
    case Arca.ThreadStorage.resolve_approval(actor(athanor_id), approval_id, ["pending"], to, %{
           decided_by: "usr_cluster"
         }) do
      {:ok, row} -> {:ok, row.status}
      other -> other
    end
  end

  @doc "Spend `turn_id`'s recovery budget down to the cap, as three recoveries would."
  @spec spend_recoveries(String.t(), String.t()) :: :ok
  def spend_recoveries(athanor_id, turn_id) do
    import Ecto.Query, only: [from: 2]

    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Turn, where: t.id == ^turn_id and t.athanor_id == ^athanor_id),
        set: [recovery_attempts: Arca.TurnStorage.recovery_cap()]
      )

    :ok
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
    do:
      Sanctum.Authority.BudgetCounter.try_acquire(%Cyfr.Authority.Budget{id: budget_id, cap: cap})

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

  # ---------------------------------------------------------------------------
  # Provisioning, sessions and event streams
  # ---------------------------------------------------------------------------

  @doc """
  Take `athanor_id`'s provisioning claim on this member, for the boot-
  scoped owner a fill runs under. `{:ok, claim}` or
  `{:error, :provisioning_busy}` — what a second first touch is answered.
  """
  @spec take_estate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def take_estate(athanor_id, entry_kind) do
    case Sanctum.Provisioning.take_claim(athanor_id, entry_kind) do
      {:ok, claim} -> {:ok, %{owner: claim.owner, fence: claim.fence, attempt: claim.attempt}}
      other -> other
    end
  end

  @doc "What this member sees of `athanor_id`'s filling: `:ready | :filling | :failed | :unfilled | :unavailable`."
  @spec estate_status(String.t()) :: atom()
  def estate_status(athanor_id),
    do:
      Sanctum.Provisioning.status(
        Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)
      )

  @doc "A person with a session of their own, and their group athanor."
  @spec person!() :: map()
  def person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|cluster-#{n}",
        provider: "github",
        email: "cluster#{n}@example.com",
        verified: true,
        name: "Cluster #{n}"
      })

    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.id, "Cluster #{n}")

    {:ok, session} =
      Sanctum.TestContext.create_session(%{
        Sanctum.Context.build(
          user_id: user.id,
          athanor_id: group.id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
        | provider: "github",
          email: user.email
      })

    %{
      user_id: user.id,
      athanor_id: group.id,
      token: session.token,
      hash: Sanctum.Session.token_hash(session.token)
    }
  end

  @doc "Establish a caller from `token` on this member, warming its memo."
  @spec establish(String.t()) :: {:ok, String.t()} | {:error, term()}
  def establish(token) do
    case Sanctum.Caller.establish(token) do
      {:ok, ctx} -> {:ok, ctx.athanor_id}
      other -> other
    end
  end

  @doc "Whether this member still holds a memo for `hash`."
  @spec memo?(binary()) :: boolean()
  def memo?(hash), do: Arca.Cache.match(Arca.Cache.Keys.match_established(hash)) != []

  @doc """
  The context a request holding `token` is established with on this
  member, as a term: what a context read before a retirement looks like
  when it is used again after one.
  """
  @spec context(String.t()) :: {:ok, Sanctum.Context.t()} | {:error, term()}
  def context(token), do: Sanctum.Caller.establish(token)

  @doc "Deny the person `user_id` from this member: the one-transaction eject."
  @spec deny!(String.t()) :: String.t()
  def deny!(user_id) do
    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
    {:ok, denied} = Sanctum.Tenancy.Users.deny(user)
    denied.status
  end

  @doc "Allow the person `user_id` again from this member."
  @spec allow!(String.t()) :: String.t()
  def allow!(user_id) do
    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
    {:ok, allowed} = Sanctum.Tenancy.Users.allow(user)
    allowed.status
  end

  @doc "Issue a key from `ctx` on this member: the issuance rereads the rows its binding names."
  @spec issue_key(Sanctum.Context.t()) :: {:ok, String.t()} | {:error, term()}
  def issue_key(ctx) do
    case Sanctum.ApiKey.create(ctx, %{name: "cluster-#{System.unique_integer([:positive])}"}) do
      {:ok, %{api_key: key}} -> {:ok, key}
      other -> other
    end
  end

  @doc "Archive `athanor_id` from this member, which announces the invalidation."
  @spec archive!(String.t()) :: atom()
  def archive!(athanor_id) do
    {:ok, athanor} = Arca.Athanors.get(Cyfr.Actor.system(), athanor_id)
    {:ok, archived} = Sanctum.Tenancy.Athanors.archive(athanor)
    archived.status
  end

  @doc "An execution of `athanor_id` with `n` durable events after its start."
  @spec stream!(String.t(), pos_integer()) :: map()
  def stream!(athanor_id, n) do
    {:ok, %{execution: execution}} =
      Arca.Execution.admit(%{
        id: Cyfr.UUID7.execution_id(),
        reference: "reagent:local.cluster-stream:0.1.0",
        user_id: "usr_cluster",
        athanor_id: athanor_id,
        component_type: "reagent"
      })

    seqs =
      for i <- 1..n do
        {:ok, row} =
          Arca.ExecutionEvents.append(actor(athanor_id), execution.id, "step.closed",
            data: %{"step" => "s#{i}"}
          )

        :ok = Cyfr.Execution.Events.publish(execution.id, execution, "step.closed", row.seq, %{})
        row.seq
      end

    %{id: execution.id, athanor_id: athanor_id, seqs: seqs}
  end

  @doc "Append and publish `n` more durable events on `execution_id`, answering their sequences."
  @spec stream_more!(String.t(), String.t(), pos_integer()) :: [non_neg_integer()]
  def stream_more!(athanor_id, execution_id, n) do
    execution = Arca.Execution.get_tenant(actor(athanor_id), execution_id)

    for i <- 1..n do
      {:ok, row} =
        Arca.ExecutionEvents.append(actor(athanor_id), execution_id, "step.closed",
          data: %{"more" => i}
        )

      :ok = Cyfr.Execution.Events.publish(execution_id, execution, "step.closed", row.seq, %{})
      row.seq
    end
  end

  @doc "The event ids this member would replay to a reader whose cursor is `after_seq`."
  @spec replay(String.t(), String.t(), non_neg_integer()) :: [String.t()]
  def replay(athanor_id, execution_id, after_seq) do
    execution_id
    |> Cyfr.Execution.events_since({after_seq, 0}, athanor_id)
    |> Enum.map(& &1.sequence)
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
