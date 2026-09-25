# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.AdmissionLatencyTest.NoOp do
  @moduledoc false
  # The provider the measurement admits: a handler that does no work, so
  # what is timed is the admission path around it and nothing of its own.
  @behaviour Prima.Provider

  alias Prima.Operation

  @tool "admission_bench"

  def tool, do: @tool

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool(
        [
          Operation.new(@tool, "run", "Admission benchmark no-op", [],
            kind: :read,
            planes: [:external, :in_chain]
          )
        ],
        description: "Admission benchmark no-op"
      )
    ]
  end

  @impl true
  def handle(_tool, _ctx, _args), do: {:ok, %{"ok" => true}}
end

defmodule Grimoire.AdmissionLatencyTest do
  @moduledoc """
  The admission overhead of a call to a provider that does nothing, per
  scenario, as percentiles, written to `/tmp/a1/<phase>/<adapter>.json`
  (`A1_PHASE`, default `current`).

  Six scenarios. Four enter as a wire client does, through the MCP
  endpoint in-process (`Phoenix.ConnTest`, no network), so every plug in
  front of the gate is inside the number: an anonymous caller refused, a
  session established afresh, a session whose established context is
  memoized, and a session that no longer exists. Two enter the gate from
  inside a running chain (`Grimoire.call_in_chain/5`): an admitted call,
  and a call to a proxied tool on a server that is not there.

  Each scenario is measured warm (the pool's connections are open) and
  cold (every idle pool connection closed before each sample), one at a time
  and sixteen at once, and once more, one at a time and warm, while a
  separate process holds the write lock (`BEGIN IMMEDIATE` on SQLite,
  `LOCK TABLE decision_logs IN ACCESS EXCLUSIVE MODE` on PostgreSQL, where
  a tree without that table has nothing to hold). The throughput is
  admissions per second of the memoized session, sixteen at once.

  The established-context memo, which the suite turns off, is on, long
  enough that every memoized sample hits it. The write-behind stays as the
  suite configures it, inline: run asynchronously, the sink would be a
  process that owns a connection for good under `:auto` ownership, and
  the ownership timeout takes it back from under it. A sample that answers
  other than its scenario fails the case one at a time and under the held
  lock; sixteen at once, it is counted in the record as `unexpected`.

  Every call carries a request id under the prefix `bench_`: the
  transport's `x-request-id` for the wire scenarios, the chain's request
  id for the in-chain ones. The decision rows under that prefix, a
  tenant's and the host's alike, are deleted when the run ends.

  It runs against committed rows (the sandbox's `:auto` mode, no checkout)
  in an athanor of its own, whose rows it deletes when it ends, and every
  sample runs in a process of its own so its connection goes back to the
  pool when it is done. Under `:auto` ownership a process keeps the
  connection it first used until it exits, so sixteen in flight hold up to
  one connection each, and each process they start holds another.

  On SQLite it runs with the production busy timeout (5 s), restarting
  the repo under it and again under the suite's value when it ends; the
  record's environment names the value.

  Tagged `:benchmark`: excluded from the suite, run with
  `--only benchmark`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Grimoire.AdmissionLatencyTest.NoOp
  alias Prima.Authority
  alias Prima.Authority.Blob

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @scenarios ~w(anonymous_refusal fresh_session memo_hit invalid_session in_chain proxy_refusal)a
  @expected %{
    anonymous_refusal: :refused,
    fresh_session: :admitted,
    memo_hit: :admitted,
    invalid_session: :refused,
    in_chain: :admitted,
    proxy_refusal: :refused
  }

  @warmup 20
  @warm_samples 200
  @cold_samples 60
  @concurrency 16
  @warm_per_worker 25
  @cold_rounds 10
  @blocked_samples 10
  # Longer than the audit budget and its scheduler allowance together, so a
  # stall the budget bounds and one it does not read apart.
  @hold_ms 1_500

  @node "formula:local.admission-bench"

  test "the admission latency matrix" do
    Arca.Cache.init()
    preload!()
    restore_busy = production_busy_timeout!()
    # Every process takes a connection of its own, as a deployment's does.
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :auto)
    # The suite turns the established-context memo off; a memo hit is one
    # of the scenarios, so it is on, long enough that every memoized sample
    # hits it.
    restore = put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

    # Fixture work runs in a process of its own too: under `:auto`
    # ownership a process keeps its connection until it exits, and one
    # held past the ownership timeout is taken back from under it.
    fixture = isolated(&fixture!/0)

    try do
      Grimoire.Catalog.with_providers([NoOp], fn -> measure!(fixture) end)
    after
      await_stragglers!()
      restore.()
      isolated(fn -> cleanup!(fixture) end)
      isolated(&delete_bench_decisions!/0)
      restore_busy.()
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
    end
  end

  defp isolated(fun), do: fun |> Task.async() |> Task.await(:infinity)

  # Whatever the run started and is still running — an audit write that
  # outlived its caller's answer — is waited out before the repo restarts
  # or the ownership mode changes: either takes a connection back, and one
  # taken back while its statement steps inside the SQLite driver crashes
  # the VM. Every sample carries the run's pid among its callers, and so
  # does every process a sample starts that the sandbox would allow.
  defp await_stragglers! do
    me = self()

    refs =
      for pid <- Process.list(),
          pid != me,
          {:dictionary, dict} <- [Process.info(pid, :dictionary)],
          me in List.wrap(dict[:"$callers"]),
          do: Process.monitor(pid)

    for ref <- refs do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        60_000 -> flunk("a process the run started is still running after 60 s")
      end
    end

    :ok
  end

  # SQLite's lock wait is a connection's, fixed as the pool connects it. The
  # suite's 20 s outlasts DBConnection's 15 s client timeout, and a pool
  # that closes a connection whose statement is still inside the driver
  # crashes the VM; the measurement runs with the production 5 s
  # (`Arca.Repo`'s default) by restarting the repo under it, and restarts
  # it under the suite's value when it is done. The record names the value.
  @production_busy_timeout_ms 5_000

  defp production_busy_timeout!, do: repo_busy_timeout!(@production_busy_timeout_ms)

  defp repo_busy_timeout!(ms) do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
      config = Application.fetch_env!(:arca, Arca.Repo)
      Application.put_env(:arca, Arca.Repo, Keyword.put(config, :busy_timeout, ms))
      restart_repo!()

      fn ->
        Application.put_env(:arca, Arca.Repo, config)
        restart_repo!()
      end
    else
      fn -> :ok end
    end
  end

  defp restart_repo! do
    :ok = Supervisor.terminate_child(Arca.Supervisor, Arca.Repo)
    {:ok, _} = Supervisor.restart_child(Arca.Supervisor, Arca.Repo)
    :ok
  end

  defp busy_timeout_record do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3,
      do: Arca.Repo.config()[:busy_timeout],
      else: nil
  end

  # A release loads every module as it boots; the suite loads each on first
  # use, and a first use under the write lock's contention — an error path
  # a quiet run never reaches — waits on the code server, whose file reads
  # queue behind the driver's lock waits for the same dirty schedulers.
  # What is measured is admission, not first-use code loading.
  defp preload! do
    for {app, _description, _version} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        do: Code.ensure_loaded(module)

    :ok
  end

  defp put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The matrix
  # ---------------------------------------------------------------------------

  defp measure!(fixture) do
    adapter = adapter()
    blocker = isolated(fn -> blocker_kind(adapter) end)

    results =
      Map.new(@scenarios, fn scenario ->
        sample = scenario_fun(scenario, fixture)
        for _ <- 1..@warmup, do: run_sample(sample)

        warm_c1 =
          progress(scenario, "warm_c1", fn ->
            for _ <- 1..@warm_samples, do: run_sample(sample)
          end)

        cold_c1 =
          progress(scenario, "cold_c1", fn ->
            for _ <- 1..@cold_samples, do: cold(fn -> run_sample(sample) end)
          end)

        {warm_c16, wall_us} = progress(scenario, "warm_c16", fn -> concurrent_warm(sample) end)
        cold_c16 = progress(scenario, "cold_c16", fn -> concurrent_cold(sample) end)

        blocked_c1 =
          progress(scenario, "blocked_c1", fn ->
            for _ <- 1..@blocked_samples, do: blocked(blocker, sample)
          end)

        conditions = %{
          "warm_c1" => warm_c1,
          "cold_c1" => cold_c1,
          "warm_c16" => warm_c16,
          "cold_c16" => cold_c16,
          "blocked_c1" => blocked_c1
        }

        {scenario,
         %{
           conditions:
             Map.new(conditions, fn {k, v} ->
               {k, Map.put(percentiles(v), "unexpected", unexpected(scenario, v))}
             end),
           warm_c16_wall_us: wall_us
         }}
      end)

    %{warm_c16_wall_us: wall_us} = results.memo_hit
    throughput = Float.round(@concurrency * @warm_per_worker / (wall_us / 1_000_000), 1)

    report = %{
      "phase" => phase(),
      "adapter" => adapter,
      "commit" => commit(),
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "environment" => environment(),
      "blocker" => %{"kind" => blocker, "hold_ms" => @hold_ms},
      "samples" => %{
        "warmup" => @warmup,
        "warm_c1" => @warm_samples,
        "cold_c1" => @cold_samples,
        "warm_c16" => @concurrency * @warm_per_worker,
        "cold_c16" => @concurrency * @cold_rounds,
        "blocked_c1" => @blocked_samples
      },
      "unit" => "ms",
      "scenarios" =>
        Map.new(results, fn {scenario, %{conditions: c}} -> {Atom.to_string(scenario), c} end),
      "throughput" => %{"memo_hit_warm_c16_admissions_per_s" => throughput}
    }

    dir = Path.join("/tmp/a1", phase())
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{adapter}.json")
    File.write!(path, Jason.encode_to_iodata!(report, pretty: true))
    IO.puts(summary(report, path))

    # One at a time, and under the held lock, every sample answers as its
    # scenario does. Sixteen at once is measured as it comes: what answered
    # otherwise is counted in the record, which is written first.
    for {scenario, conditions} <- report["scenarios"],
        condition <- ~w(warm_c1 cold_c1 blocked_c1) do
      assert conditions[condition]["unexpected"] == 0,
             "#{scenario} #{condition}: #{conditions[condition]["unexpected"]} sample(s) " <>
               "answered other than #{@expected[String.to_existing_atom(scenario)]}"
    end
  end

  defp progress(scenario, condition, fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()

    IO.puts(
      "admission bench: #{scenario} #{condition} #{System.monotonic_time(:millisecond) - started} ms"
    )

    result
  end

  defp unexpected(scenario, samples),
    do: Enum.count(samples, fn {_us, outcome} -> outcome != @expected[scenario] end)

  # One sample, timed in a process of its own. `prepare` runs first and is
  # not timed. The process is not linked: a sample the pool gives up on
  # dies alone, and is recorded as `:crashed` after the time it took.
  defp run_sample({prepare, call}) do
    parent = self()
    callers = [parent | List.wrap(Process.get(:"$callers"))]
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        prepare.()
        started = System.monotonic_time(:microsecond)
        send(parent, {tag, :started, started})
        outcome = call.()
        send(parent, {tag, System.monotonic_time(:microsecond) - started, outcome})
      end)

    started =
      receive do
        {^tag, :started, started} -> started
        {:DOWN, ^monitor, :process, ^pid, _} -> System.monotonic_time(:microsecond)
      end

    receive do
      {^tag, elapsed, outcome} when is_integer(elapsed) ->
        Process.demonitor(monitor, [:flush])
        {elapsed, outcome}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {System.monotonic_time(:microsecond) - started, :crashed}
    end
  end

  defp cold(fun) do
    disconnect_all!()
    fun.()
  end

  # `Arca.Repo.disconnect_all/1` asks the pool module Ecto names, and the
  # sandbox's ownership manager answers no such call; the ownership pool's
  # own `disconnect_all/3` reaches the connection pool beneath it. Every
  # idle connection is closed at its next checkout, which reconnects.
  defp disconnect_all! do
    %{pid: manager} = Ecto.Adapter.lookup_meta(Arca.Repo)
    :ok = DBConnection.Ownership.disconnect_all(manager, 0, [])
  end

  # Sixteen workers, each running its samples back to back; the wall time
  # of the whole is the throughput's denominator.
  defp concurrent_warm(sample) do
    started = System.monotonic_time(:microsecond)

    samples =
      1..@concurrency
      |> Enum.map(fn _ ->
        Task.async(fn -> for _ <- 1..@warm_per_worker, do: run_sample(sample) end)
      end)
      |> Enum.flat_map(&Task.await(&1, :infinity))

    {samples, System.monotonic_time(:microsecond) - started}
  end

  # Rounds of sixteen started together on connections that must reconnect.
  defp concurrent_cold(sample) do
    for _ <- 1..@cold_rounds, reduce: [] do
      acc ->
        disconnect_all!()

        round =
          1..@concurrency
          |> Enum.map(fn _ -> Task.async(fn -> run_sample(sample) end) end)
          |> Enum.map(&Task.await(&1, :infinity))

        acc ++ round
    end
  end

  # One sample while a separate process holds the write lock. The lock is
  # given back when the sample answers or after `@hold_ms`, whichever is
  # first: a sample still waiting at the release was held by the lock.
  defp blocked(kind, sample) do
    parent = self()
    {blocker, monitor} = spawn_monitor(fn -> hold_lock(kind, parent) end)

    receive do
      {:locked, ^blocker} ->
        :ok

      {:DOWN, ^monitor, :process, ^blocker, reason} ->
        flunk("the blocker died: #{inspect(reason)}")
    end

    timer = Process.send_after(blocker, :release, @hold_ms)
    result = run_sample(sample)
    Process.cancel_timer(timer)
    send(blocker, :release)

    receive do
      {:DOWN, ^monitor, :process, ^blocker, _} -> :ok
    end

    result
  end

  defp hold_lock("begin_immediate", parent) do
    Arca.Repo.checkout(
      fn ->
        Arca.Repo.query!("BEGIN IMMEDIATE", [], log: false)
        send(parent, {:locked, self()})
        receive do: (:release -> :ok)
        Arca.Repo.query!("ROLLBACK", [], log: false)
      end,
      timeout: :infinity
    )
  end

  defp hold_lock("lock_table", parent) do
    Arca.Repo.transaction(
      fn ->
        Arca.Repo.query!("LOCK TABLE decision_logs IN ACCESS EXCLUSIVE MODE", [], log: false)
        send(parent, {:locked, self()})
        receive do: (:release -> :ok)
      end,
      timeout: :infinity
    )
  end

  defp hold_lock("none", parent) do
    send(parent, {:locked, self()})
    receive do: (:release -> :ok)
  end

  defp blocker_kind("sqlite"), do: "begin_immediate"

  defp blocker_kind("postgres") do
    case Arca.Repo.query!("SELECT to_regclass('decision_logs')::text", [], log: false) do
      %{rows: [[nil]]} -> "none"
      %{rows: [[_table]]} -> "lock_table"
    end
  end

  # ---------------------------------------------------------------------------
  # The scenarios
  # ---------------------------------------------------------------------------

  defp scenario_fun(:anonymous_refusal, _fixture), do: {&noop/0, fn -> mcp(nil) end}

  defp scenario_fun(:fresh_session, %{token: token}) do
    hash = Sanctum.Session.token_hash(token)
    {fn -> Sanctum.Caller.drop_memo(hash) end, fn -> mcp(token) end}
  end

  defp scenario_fun(:memo_hit, %{token: token}), do: {&noop/0, fn -> mcp(token) end}

  defp scenario_fun(:invalid_session, %{dead_token: token}),
    do: {&noop/0, fn -> mcp(token) end}

  defp scenario_fun(:in_chain, fixture) do
    {&noop/0,
     fn ->
       fixture.guest
       |> Map.put(:request_id, bench_request_id())
       |> then(
         &Grimoire.call_in_chain(NoOp.tool(), &1, %{"action" => "run"}, fixture.authority,
           lineage: fixture.lineage
         )
       )
       |> gate_outcome()
     end}
  end

  defp scenario_fun(:proxy_refusal, fixture) do
    {&noop/0,
     fn ->
       fixture.guest
       |> Map.put(:request_id, bench_request_id())
       |> then(
         &Grimoire.call_in_chain(
           "admission-bench-absent:run",
           &1,
           %{"action" => "run"},
           fixture.authority,
           lineage: fixture.lineage
         )
       )
       |> gate_outcome()
     end}
  end

  defp noop, do: :ok

  # Every call is stamped with a request id under `@bench_prefix`: the
  # transport's correlation id for the wire scenarios (`x-request-id`), the
  # chain's own for the in-chain ones. The decision rows the run wrote are
  # found by it and deleted when the run ends, with or without a tenant.
  @bench_prefix "bench_"

  defp bench_request_id,
    do: @bench_prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp gate_outcome({:ok, _}), do: :admitted
  defp gate_outcome({:error, _}), do: :refused

  defp mcp(token) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-request-id", bench_request_id())

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn =
      EmissaryWeb.ConnCase.mcp_post(conn, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => NoOp.tool(), "arguments" => %{"action" => "run"}}
      })

    with 200 <- conn.status,
         {:ok, %{"result" => %{"isError" => false}}} <- Jason.decode(conn.resp_body) do
      :admitted
    else
      _ -> :refused
    end
  end

  # ---------------------------------------------------------------------------
  # The fixture: an athanor of its own, a person seated in it, a live and a
  # destroyed session, and a running chain's lineage and authority.
  # ---------------------------------------------------------------------------

  defp fixture! do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Admission bench #{n}",
        slug: "admission-bench-#{n}",
        created_by: "system"
      })

    ctx =
      Sanctum.TestContext.issuer!(%{
        Sanctum.TestContext.local()
        | athanor_id: athanor.id,
          user_id: "local|local|admission-bench-#{n}",
          email: "admission-bench-#{n}@example.com"
      })

    {:ok, session} = Sanctum.Session.create(ctx)
    {:ok, dead} = Sanctum.Session.create(ctx)
    Sanctum.Session.destroy(dead.token)

    guest = Sanctum.Context.enter_guest(ctx)

    %{
      athanor_id: athanor.id,
      user_id: ctx.user_id,
      token: session.token,
      dead_token: dead.token,
      guest: guest,
      lineage: Cyfr.Test.AttemptFixtures.lineage!(guest),
      authority: authority_granting(["#{NoOp.tool()}.run"])
    }
  end

  defp authority_granting(pairs) do
    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 1_000_000, "window" => "1m"},
            "max_concurrent_tasks" => 64,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => Enum.sort(pairs)}}
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-admission-bench",
          consent_id: "consent-admission-bench",
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => "sha256:admission-bench"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    authority
  end

  # The rows are committed, so they are deleted: the estate's through the
  # tenant roster, then the estate, the person and their identities.
  defp cleanup!(%{athanor_id: athanor_id, user_id: user_id}) do
    Arca.RecordSink.flush()
    {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(athanor_id))
    Arca.Repo.delete_all(from(a in "athanors", where: a.id == ^athanor_id))
    Arca.Repo.delete_all(from(i in "external_identities", where: i.user_id == ^user_id))
    Arca.Repo.delete_all(from(u in "users", where: u.id == ^user_id))
    :ok
  end

  # The run's decision rows, a tenant's and the host's alike. A tree that
  # has no decision log yet has nothing to delete.
  defp delete_bench_decisions! do
    if decision_log?() do
      Arca.Repo.delete_all(
        from(r in "decision_logs",
          where:
            fragment("substr(?, 1, ?)", r.request_id, ^byte_size(@bench_prefix)) == ^@bench_prefix
        )
      )
    end

    :ok
  end

  defp decision_log? do
    case adapter() do
      "sqlite" ->
        match?(
          %{rows: [_ | _]},
          Arca.Repo.query!(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'decision_logs'",
            [],
            log: false
          )
        )

      "postgres" ->
        match?(
          %{rows: [[table]]} when is_binary(table),
          Arca.Repo.query!("SELECT to_regclass('decision_logs')::text", [], log: false)
        )
    end
  end

  # ---------------------------------------------------------------------------
  # The record
  # ---------------------------------------------------------------------------

  defp percentiles(samples) do
    sorted = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    n = length(sorted)
    at = fn q -> Enum.at(sorted, max(ceil(q * n) - 1, 0)) / 1000 end

    %{
      "n" => n,
      "p50" => Float.round(at.(0.50), 3),
      "p95" => Float.round(at.(0.95), 3),
      "p99" => Float.round(at.(0.99), 3),
      "max" => Float.round(List.last(sorted) / 1000, 3)
    }
  end

  defp adapter do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 -> "sqlite"
      Ecto.Adapters.Postgres -> "postgres"
    end
  end

  defp phase, do: System.get_env("A1_PHASE", "current")

  defp commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp environment do
    %{
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "schedulers_online" => System.schedulers_online(),
      "os" => inspect(:os.type()),
      "cpu" => cpu(),
      "pool_size" => Arca.Repo.config()[:pool_size],
      "sqlite_busy_timeout_ms" => busy_timeout_record()
    }
  end

  defp cpu do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {brand, 0} -> String.trim(brand)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp summary(report, path) do
    header = "admission latency (#{report["phase"]}, #{report["adapter"]}, ms p50/p95/p99)"

    rows =
      for scenario <- @scenarios,
          name = Atom.to_string(scenario),
          conditions = report["scenarios"][name] do
        cells =
          for condition <- ~w(warm_c1 cold_c1 warm_c16 cold_c16 blocked_c1) do
            %{"p50" => a, "p95" => b, "p99" => c, "unexpected" => u} = conditions[condition]
            "#{condition} #{a}/#{b}/#{c}" <> if(u > 0, do: " (#{u} unexpected)", else: "")
          end

        "  #{String.pad_trailing(name, 18)} " <> Enum.join(cells, "  ")
      end

    Enum.join(
      [header | rows] ++
        [
          "  throughput memo_hit warm c16: " <>
            "#{report["throughput"]["memo_hit_warm_c16_admissions_per_s"]} admissions/s",
          "  blocker: #{report["blocker"]["kind"]}, written to #{path}"
        ],
      "\n"
    )
  end
end
