# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.StepBench do
  @moduledoc """
  The per-step latency of a turn's model step, measured in one BEAM
  against the real host path.

  An estate is laid whose soul's model is `catalyst:local.step-stub`
  (`test_wasm/step_stub/`): a `model/chat@1` catalyst that reads its key,
  emits a few `text.delta` events and answers one text block at once, so
  the time measured is the host's and not a provider's. The stub's key is
  bound through the consent walk and the soul's edge selects it, as a
  model catalyst's is. Each step is one turn run by `Aqua.Loop` on a
  thread of its own: the loop claims the root, records and dispatches the
  chat step, and runs the catalyst as a child through
  `Cyfr.Execution.run_child/5` — the chain's transition and invoke charge,
  admission with its hold and step barriers, the vault unseal, the slot,
  the WASM runtime, the emit path and the terminal write.

  The step's timings are the `Cyfr.Execution.StepSpans` events of its chat
  step's child execution. Everything runs inside one SQL sandbox
  checkout, rolled back when the run ends, with storage and the seed tree
  in temporary directories removed with it.
  """

  alias Aqua.Tape
  alias Sanctum.Consent.{Bootstrap, Commit, Plan, Source}

  @stub_wasm Path.expand("test_wasm/step_stub/step_stub.wasm", __DIR__)
  @stub_name "step-stub"
  @stub "catalyst:local.#{@stub_name}"
  @stub_version "0.1.0"
  @soul "agent:local.aqua"
  @key_field "STUB_API_KEY"
  @turn_timeout_ms 60_000
  @span_timeout_ms 5_000

  @typedoc "Percentiles of one measure, in milliseconds."
  @type percentiles :: %{p50: float(), p95: float(), p99: float()}

  @typedoc "What a run measured."
  @type report :: %{
          steps: pos_integer(),
          warmup: non_neg_integer(),
          database: module(),
          storage: module(),
          admission: percentiles(),
          first_delta: percentiles(),
          time_to_first_delta: percentiles(),
          completion: percentiles(),
          total: percentiles()
        }

  @doc """
  Run `:steps` measured model steps after `:warmup` unmeasured ones and
  answer their percentiles. The database must be migrated; the SQL
  sandbox is checked out here unless the calling process already owns a
  checkout.
  """
  @spec run(keyword()) :: report()
  def run(opts) do
    steps = Keyword.fetch!(opts, :steps)
    warmup = Keyword.fetch!(opts, :warmup)

    if not (is_integer(steps) and steps > 0 and is_integer(warmup) and warmup >= 0),
      do: raise(ArgumentError, "steps must be positive and warmup non-negative")

    prepare_database!()

    # Run alone (`mix cyfr.bench.step`), the service's runners reach CYFR
    # directly, so no proxy's hop is measured. Inside the suite they reach
    # it through the suite's wire for the whole run, which the bench keeps:
    # pointing them past it would restart the service and leave every later
    # test's holds and reads on a wire no call crosses.
    Cyfr.Test.OpusService.wire!(proxy: Cyfr.Test.TwoServices.wire() != nil)

    unless Cyfr.Execution.available?(),
      do:
        raise("the Opus worker service of this boot does not answer; run from the umbrella root")

    with_sandbox(fn ->
      with_estate_env(fn ->
        ctx = estate!()
        measure(ctx, steps, warmup)
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
        "#{report.steps} model steps on #{@stub} after #{report.warmup} warmup",
        "database: #{inspect(report.database)}  storage: #{inspect(report.storage)}",
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

  defp with_estate_env(fun) do
    run_dir = Path.join(System.tmp_dir!(), "step_bench_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})

    try do
      Application.put_env(:cyfr, :base_path, Path.join(run_dir, "data"))
      Application.put_env(:cyfr, :seed_path, lay_seed!(Path.join(run_dir, "seed")))
      Application.put_env(:cyfr, :consent_source, Source.DB)
      Arca.Cache.init()
      fun.()
    after
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(run_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # The estate
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

  defp stub_manifest do
    %{
      "name" => @stub_name,
      "type" => "catalyst",
      "version" => @stub_version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst that streams a few deltas and answers at once",
      "contracts" => [Cyfr.Models.chat_contract()],
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:step-stub",
          "reason" => "to read a key as a model catalyst does",
          "required" => true,
          "fields" => [@key_field]
        }
      },
      "caps" => %{
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

  defp estate! do
    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)

    if @soul not in minted or @stub not in minted,
      do: raise("the bench estate minted #{inspect(minted)}, not the soul and #{@stub}")

    bind_key!(ctx)
    ctx
  end

  defp bind_key!(ctx) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "step-stub key",
        kind: "api_key",
        fields: %{@key_field => "sk-step-stub"}
      })

    {:ok, plan} = Plan.plan(ctx, %{ref: @stub})
    decisions = %{ref: @stub, bindings: [%{need: "api_key", entry_id: entry.id}]}
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

  # ---------------------------------------------------------------------------
  # Measuring
  # ---------------------------------------------------------------------------

  defp measure(ctx, steps, warmup) do
    bench = self()
    handler = "step-bench-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        Cyfr.Execution.StepSpans.events(),
        fn event, %{duration: duration}, metadata, _config ->
          send(bench, {:step_span, metadata.execution_id, event, duration})
        end,
        nil
      )

    try do
      for _ <- 1..warmup//1, do: step!(ctx)
      samples = for _ <- 1..steps, do: step!(ctx)

      %{
        steps: steps,
        warmup: warmup,
        database: Cyfr.RuntimeConfig.repo_adapter(),
        storage: Arca.Storage.configured_adapter(),
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
  defp step!(ctx) do
    {:ok, thread} = Arca.ThreadStorage.create(ctx)

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "hello"},
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
    Enum.reduce(Cyfr.Execution.StepSpans.events(), %{}, fn event, acc ->
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
