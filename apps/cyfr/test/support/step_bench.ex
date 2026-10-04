# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.StepBench do
  @moduledoc """
  The per-step latency of a turn's model step, measured in one BEAM
  against the real host path.

  An athanor is laid whose soul's model is `catalyst:local.step-stub`
  (`test_wasm/step_stub/`): a `model/chat@1` catalyst that reads no
  credential, emits a few `text.delta` events and answers one text block
  at once, so the time measured is the host's and not a provider's. Each
  step is one turn run by `Aqua.Loop` on a thread of its own: the loop
  claims the root, records and dispatches the chat step, and runs the
  catalyst as a child through `Crucible.run_child/5` — the chain's
  transition and invoke charge, admission with its hold and step barriers,
  the slot, the WASM runtime, the emit path and the terminal write.

  Before its first delta every chat step makes one request: a `GET` the
  turn's message carries as `{"bench_fetch": request}` (which the loop
  sends after the person's display name, as it sends a line where several
  people talk), to an upstream the bench serves on loopback that answers
  one byte. In both modes the stub's need declares an attach rule and the
  upstream's host, its egress grants that loopback address as a private
  one for `GET` over `http`, and its consent binds an attach-only entry
  whose destination is the upstream. The mode decides the request alone:

    * `:attached` names the need as its `connection`, so CYFR makes the
      request with the key attached (`Crucible.Host.AttachedFetch`) and
      relays the answer to the runner in sealed frames;
    * `:pinned` names no connection and carries no credential, so CYFR pins
      it and the worker service makes it.

  The difference in first delta between the modes is the hop's own share.

  The step's timings are the `Crucible.StepSpans` events of its chat
  step's child execution. Everything runs inside one SQL sandbox
  checkout, rolled back when the run ends, with storage and the seed tree
  in temporary directories removed with it. The upstream is the bench's:
  it is stopped and joined when the run ends, however it ends.
  """

  alias Aqua.Tape
  alias Sanctum.Consent.{Bootstrap, Commit, Plan}

  @stub_wasm Path.expand("test_wasm/step_stub/step_stub.wasm", __DIR__)
  @stub_name "step-stub"
  @stub "catalyst:local.#{@stub_name}"
  @stub_version "0.1.0"
  @soul "agent:local.aqua"
  @key_field "STUB_API_KEY"
  @key "sk-step-stub"
  @connection "api_key"
  @attach_rule %{"in" => "header", "name" => "authorization", "template" => "Bearer {value}"}
  @upstream_host "127.0.0.1"
  @upstream_path "/one-byte"
  @modes [:attached, :pinned]
  @turn_timeout_ms 60_000
  @span_timeout_ms 5_000

  @typedoc "How a step's request reaches the upstream."
  @type mode :: :attached | :pinned

  @typedoc "Percentiles of one measure, in milliseconds."
  @type percentiles :: %{p50: float(), p95: float(), p99: float()}

  @typedoc "What a run measured."
  @type report :: %{
          steps: pos_integer(),
          warmup: non_neg_integer(),
          mode: mode(),
          commit: String.t(),
          database: module(),
          storage: module(),
          upstream_port: :inet.port_number(),
          fetches: non_neg_integer(),
          attached_fetches: non_neg_integer(),
          admission: percentiles(),
          first_delta: percentiles(),
          time_to_first_delta: percentiles(),
          completion: percentiles(),
          total: percentiles()
        }

  defmodule Upstream do
    @moduledoc false
    # The bench's upstream: counts every request, and those that carry the
    # stub's key as the need's rule attaches it, and answers one byte.
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{counts: counts, attached: attached}) do
      :counters.add(counts, 1, 1)
      if get_req_header(conn, "authorization") == [attached], do: :counters.add(counts, 2, 1)
      send_resp(conn, 200, "1")
    end
  end

  @doc """
  Run `:steps` measured model steps after `:warmup` unmeasured ones, each
  making its request in `:mode` (`:attached` unless named), and answer
  their percentiles. The database must be migrated; the SQL sandbox is
  checked out here unless the calling process already owns a checkout.
  `:on_step`, when given, is called after each step, warmup included,
  inside the bench's athanor, with `%{step: n, ctx: ctx, request: request,
  upstream_port: port, fetches: fetches}`: the person's context, the
  request each step's message carries, and a function answering how many
  requests the upstream has received.
  """
  @spec run(keyword()) :: report()
  def run(opts) do
    steps = Keyword.fetch!(opts, :steps)
    warmup = Keyword.fetch!(opts, :warmup)
    mode = Keyword.get(opts, :mode, :attached)
    on_step = Keyword.get(opts, :on_step, fn _step -> :ok end)

    if not (is_integer(steps) and steps > 0 and is_integer(warmup) and warmup >= 0),
      do: raise(ArgumentError, "steps must be positive and warmup non-negative")

    if mode not in @modes,
      do: raise(ArgumentError, "mode must be one of #{inspect(@modes)}, not #{inspect(mode)}")

    prepare_database!()

    # Run alone (`mix cyfr.bench.step`), the service's runners reach CYFR
    # directly, so no proxy's hop is measured. Inside the suite they reach
    # it through the suite's wire for the whole run, which the bench keeps:
    # pointing them past it would restart the service and leave every later
    # test's holds and reads on a wire no call crosses.
    Cyfr.Test.OpusService.wire!(proxy: Cyfr.Test.TwoServices.wire() != nil)

    unless Crucible.available?(),
      do:
        raise("the Opus worker service of this boot does not answer; run from the umbrella root")

    with_upstream(fn upstream ->
      with_sandbox(fn ->
        with_athanor_env(fn ->
          ctx = athanor!(upstream.port)

          upstream
          |> Map.merge(%{mode: mode, on_step: on_step})
          |> measure(ctx, steps, warmup)
        end)
      end)
    end)
  end

  @doc "The report as the table `mix cyfr.bench.step` prints."
  @spec render(report()) :: String.t()
  def render(report) do
    rows = [
      {"admission (call to guest start)", report.admission},
      {"first delta (guest start to delta)", report.first_delta},
      {"time to first delta (call to delta)", report.time_to_first_delta},
      {"completion (guest start to row)", report.completion},
      {"total (run_child)", report.total}
    ]

    header = String.pad_trailing("measure", 38) <> pad("p50 ms") <> pad("p95 ms") <> pad("p99 ms")

    lines =
      for {label, p} <- rows do
        String.pad_trailing(label, 38) <> ms(p.p50) <> ms(p.p95) <> ms(p.p99)
      end

    Enum.join(
      [
        "#{report.steps} model steps on #{@stub} after #{report.warmup} warmup, mode #{report.mode}",
        "commit: #{report.commit}",
        "database: #{inspect(report.database)}  storage: #{inspect(report.storage)}",
        "upstream: #{report.fetches} one-byte fetches, #{report.attached_fetches} with the key attached",
        "",
        header | lines
      ],
      "\n"
    )
  end

  # ---------------------------------------------------------------------------
  # Environment
  # ---------------------------------------------------------------------------

  # What each app's test_helper does before a suite: refuse a database
  # built from another schema, and commit the athanor rows fixtures name.
  defp prepare_database! do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)
    Sanctum.TestContext.seed_athanors!()
  end

  # The upstream is linked to the caller, so it ends with a caller that
  # dies, and is stopped and joined here on every other exit: a return, a
  # raise or an exit such as a turn's timeout.
  defp with_upstream(fun) do
    counts = :counters.new(2, [:atomics])
    plug = {Upstream, %{counts: counts, attached: "Bearer " <> @key}}

    {:ok, server} =
      Bandit.start_link(
        plug: plug,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    try do
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      fun.(%{port: port, counts: counts})
    after
      stop(server)
    end
  end

  defp stop(server) do
    ThousandIsland.stop(server)
  catch
    :exit, _gone -> :ok
  end

  defp with_sandbox(fun) do
    owned? =
      case Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo) do
        :ok -> true
        {:already, _} -> false
      end

    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    try do
      fun.()
    after
      if owned?, do: Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)
    end
  end

  defp with_athanor_env(fun) do
    run_dir = Path.join(System.tmp_dir!(), "step_bench_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})

    try do
      Application.put_env(:arca, :base_path, Path.join(run_dir, "data"))
      Application.put_env(:arca, :seed_path, lay_seed!(Path.join(run_dir, "seed")))
      Arca.Cache.init()
      fun.()
    after
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end

      File.rm_rf!(run_dir)
    end
  end

  # The checkout the bench runs from, so every result names its code.
  defp commit do
    with {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true),
         {changes, 0} <-
           System.cmd("git", ["status", "--porcelain", "--untracked-files=no"],
             stderr_to_stdout: true
           ) do
      String.trim(head) <> if(changes == "", do: "", else: " with uncommitted changes")
    else
      _ -> "unknown (not a git checkout)"
    end
  end

  # ---------------------------------------------------------------------------
  # The athanor
  # ---------------------------------------------------------------------------

  # A seed tree with the stub catalyst and a soul that runs on it.
  defp lay_seed!(seed) do
    unit = Path.join([seed, "components", "catalysts", "local", @stub_name, @stub_version])
    File.mkdir_p!(unit)
    File.cp!(@stub_wasm, Path.join(unit, "catalyst.wasm"))
    File.write!(Path.join(unit, "cyfr-manifest.json"), Jason.encode!(stub_manifest()))

    File.mkdir_p!(Path.join(seed, "aqua"))

    File.write!(Path.join([seed, "aqua", "aqua.md"]), """
    ---
    title: AQUA
    catalyst_ref: #{@stub}
    model: #{@stub_name}
    ---

    You answer the person.
    """)

    seed
  end

  # One manifest for both modes: the need CYFR attaches to the upstream's
  # host, and the egress that reaches it.
  defp stub_manifest do
    %{
      "name" => @stub_name,
      "type" => "catalyst",
      "version" => @stub_version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst that streams a few deltas and answers at once",
      "contracts" => [Prima.Model.chat_contract()],
      "needs" => %{
        @connection => %{
          "type" => "api_key:step-stub",
          "reason" => "to have CYFR attach a key to the bench's request",
          "required" => true,
          "fields" => [@key_field],
          "attach" => @attach_rule,
          "hosts" => [@upstream_host]
        }
      },
      "caps" => %{
        "egress" => %{
          "domains" => [@upstream_host],
          "schemes" => ["http"],
          "methods" => ["GET"],
          "private_ips" => [@upstream_host]
        },
        "limits" => %{
          "timeout" => "1m",
          "max_memory_bytes" => 67_108_864,
          "max_request_size" => 1_048_576,
          "max_response_size" => 5_242_880,
          "rate_limit" => %{"requests" => 10_000, "window" => "1m"}
        }
      }
    }
  end

  # A person chatting in Prism: each bench turn is an interactive one.
  defp athanor!(port) do
    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)

    if @soul not in minted or @stub not in minted,
      do: raise("the bench athanor minted #{inspect(minted)}, not the soul and #{@stub}")

    bind_key!(ctx, port)
    ctx
  end

  # The key is attach-only, bound to the upstream's address: CYFR attaches
  # it to an attached request and hands it to no runner, in either mode.
  defp bind_key!(ctx, port) do
    params = %{
      name: "step-stub key",
      kind: "api_key",
      provider_hint: "step-stub",
      fields: %{@key_field => @key},
      destination: %{"hosts" => [@upstream_host], "scheme" => "http", "port" => port}
    }

    # Entering the key is a sensitive change, confirmed as its person
    # confirms it (`Sanctum.TestContext.confirmed/3`).
    entering =
      Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
        operation: "vault.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.Vault.create(entering, params)

    {:ok, plan} = Plan.plan(ctx, %{ref: @stub})
    decisions = %{ref: @stub, bindings: [%{need: @connection, entry_id: entry.id}]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    :ok
  end

  # The request every step's message carries: the same in both modes, but
  # for the connection it names in `:attached`.
  defp bench_request(%{mode: mode, port: port}) do
    request = %{"method" => "GET", "url" => "http://#{@upstream_host}:#{port}#{@upstream_path}"}
    if mode == :attached, do: Map.put(request, "connection", @connection), else: request
  end

  # ---------------------------------------------------------------------------
  # Measuring
  # ---------------------------------------------------------------------------

  defp measure(bench, ctx, steps, warmup) do
    bench_pid = self()
    handler = "step-bench-#{System.unique_integer([:positive])}"
    request = bench_request(bench)
    message = Jason.encode!(%{"bench_fetch" => request})
    fetches = fn -> :counters.get(bench.counts, 1) end
    commit = commit()

    :ok =
      :telemetry.attach_many(
        handler,
        Crucible.StepSpans.events(),
        fn event, %{duration: duration}, metadata, _config ->
          send(bench_pid, {:step_span, metadata.execution_id, event, duration})
        end,
        nil
      )

    try do
      step = fn n ->
        spans = step!(ctx, message)

        bench.on_step.(%{
          step: n,
          ctx: ctx,
          request: request,
          upstream_port: bench.port,
          fetches: fetches
        })

        spans
      end

      for n <- 1..warmup//1, do: step.(n)
      samples = for n <- (warmup + 1)..(warmup + steps), do: step.(n)

      %{
        steps: steps,
        warmup: warmup,
        mode: bench.mode,
        commit: commit,
        database: Cyfr.RuntimeConfig.repo_adapter(),
        storage: Arca.Storage.configured_adapter(),
        upstream_port: bench.port,
        fetches: :counters.get(bench.counts, 1),
        attached_fetches: :counters.get(bench.counts, 2),
        admission: percentiles(samples, & &1.admission),
        first_delta: percentiles(samples, & &1.first_delta),
        time_to_first_delta: percentiles(samples, &(&1.admission + &1.first_delta)),
        completion: percentiles(samples, & &1.completion),
        total: percentiles(samples, & &1.run_child)
      }
    after
      :telemetry.detach(handler)
    end
  end

  # One turn on a thread of its own, so every step sends the same request;
  # answers its chat step's four spans.
  defp step!(ctx, message) do
    {:ok, thread} = Arca.ThreadStorage.create(Sanctum.Context.actor(ctx))

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: message},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    task = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

    case Task.await(task, @turn_timeout_ms) do
      :completed -> :ok
      other -> raise "a bench turn did not complete: #{inspect(other)}"
    end

    {:ok, steps} = Tape.steps(ctx, turn)
    [%{child_execution_id: execution_id}] = Enum.filter(steps, &(&1.purpose == "chat"))
    spans = spans(execution_id)
    discard_spans()
    spans
  end

  defp spans(execution_id) do
    Enum.reduce(Crucible.StepSpans.events(), %{}, fn event, acc ->
      receive do
        {:step_span, ^execution_id, ^event, duration} -> Map.put(acc, name(event), duration)
      after
        @span_timeout_ms -> raise "the chat step #{execution_id} emitted no #{inspect(event)}"
      end
    end)
  end

  # The turn's other children (the catalyst's `describe`) are not the step.
  defp discard_spans do
    receive do
      {:step_span, _execution_id, _event, _duration} -> discard_spans()
    after
      0 -> :ok
    end
  end

  defp name([:cyfr, :execution, :child, measure]), do: measure
  defp name([:cyfr, :execution, :run_child]), do: :run_child

  defp percentiles(samples, measure) do
    sorted = samples |> Enum.map(measure) |> Enum.sort()
    %{p50: rank(sorted, 50), p95: rank(sorted, 95), p99: rank(sorted, 99)}
  end

  # Nearest rank, in milliseconds.
  defp rank(sorted, percentile) do
    index = max(ceil(percentile / 100 * length(sorted)) - 1, 0)
    System.convert_time_unit(Enum.at(sorted, index), :native, :microsecond) / 1000
  end

  defp pad(text), do: String.pad_leading(text, 10)
  defp ms(value), do: pad(:erlang.float_to_binary(value, decimals: 1))
end
