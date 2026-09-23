# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.ExecutorMaskedOutputTest do
  @moduledoc """
  A credential handed to a run never leaves it unmasked: a vault field the
  run unsealed and an OAuth token dispensed to it are masked in the output,
  a failure message, a timeout error, the events the guest streams, what a
  parent is handed of its child, the kept result payload, the lifecycle
  events' data and the result the waiter receives. A run whose attempt ends
  before it closes the run records none of them.

  The guest is the step-stub catalyst (`test_wasm/step_stub/` in the cyfr
  suite), run in a runner of its own. Its `chat` reads its key, streams
  "The stub ", "answers ", "at ", "once." and answers their
  concatenation; an operation it does not know is refused with "the stub
  answers describe, models and chat". Each credential is text the stub
  writes, so what it writes is what must come out masked — the key spans
  two deltas, and so does the token. The key's vault entry also holds an
  OAuth bundle whose access token is the token, and the token is
  dispensed by an `oauth_token` host call on the run's attempt once its
  runner has attached, before its guest starts, as a guest's `cyfr:oauth`
  call dispenses one (`Cyfr.Test.TwoServices.arm!/3`). A run is held on
  the suite's wire where a case needs it at a known point. The parent is
  the `nested-probe` formula, whose consent's edge to the stub selects the
  stub's profile, as a shipped formula runs a shipped catalyst.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Test.TwoServices
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @moduletag timeout: 120_000

  @stub_wasm Path.expand("../../support/test_wasm/step_stub/step_stub.wasm", __DIR__)
  @stub "catalyst:local.step-stub"
  @brief "catalyst:local.step-stub-brief"
  @soul "agent:local.aqua"
  @probe_node "formula:local.nested-probe"
  @version "0.1.0"
  @key_field "STUB_API_KEY"
  @redacted "[REDACTED]"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    run_dir = Path.join(System.tmp_dir!(), "masked_output_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, Path.join(run_dir, "data"))
    Application.put_env(:arca, :seed_path, lay_seed!(Path.join(run_dir, "seed")))

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    :ok = Probe.publish_probe!(ctx, isolate: false, dependencies: ["#{@stub}:#{@version}"])
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted and @stub in minted and @brief in minted
    assert @probe_node in minted

    {:ok, ctx: ctx}
  end

  test "a completed run's output, stream, payload, events and result are masked", %{ctx: ctx} do
    secrets = arm!(ctx, @stub, key: "stub answers", token: "at once")
    id = Cyfr.UUID7.execution_id()
    :ok = Cyfr.Execution.subscribe_events(id, ctx)

    assert {:ok, result} =
             Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)

    assert %{"data" => %{"content" => [%{"text" => text}]}} = result.output
    assert text == "The #{@redacted} #{@redacted}."
    refute_unmasked(result, secrets)

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "completed"
    refute_unmasked(row, secrets)

    assert {:ok, _row, payload} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")

    assert payload =~ @redacted
    refute_unmasked(payload, secrets)

    live = live_events()
    assert streamed_text(live) == text
    refute_unmasked(live, secrets)

    replayed = Cyfr.Execution.Events.since(id, {0, 0}, ctx.athanor_id)
    assert streamed_text(replayed) == text
    refute_unmasked(replayed, secrets)

    refute_unmasked(event_rows(ctx, id), secrets)
  end

  test "a failed run's message is masked in the row, its event and the result", %{ctx: ctx} do
    secrets = arm!(ctx, @stub, key: "stub answers", token: "describe")
    id = Cyfr.UUID7.execution_id()
    :ok = Cyfr.Execution.subscribe_events(id, ctx)

    assert {:error, message} =
             Cyfr.Execution.run_root(ctx, :default, @stub, %{"operation" => "unknown"},
               execution_id: id
             )

    assert message == "the #{@redacted} #{@redacted}, models and chat"

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row, secrets)

    rows = event_rows(ctx, id)
    assert %{"error" => ^message} = Enum.find(rows, &(&1.type == "execution.failed")).data
    refute_unmasked(rows, secrets)
    refute_unmasked(live_events(), secrets)

    assert {:error, :not_found} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")
  end

  test "a timed-out run's error is masked in the row, its event and the result", %{ctx: ctx} do
    # The budget is what remains of the absolute deadline at receipt, so the
    # milliseconds vary; the words around them are the planted secrets.
    secrets = arm!(ctx, @brief, key: "Execution timeout", token: "after")
    id = Cyfr.UUID7.execution_id()
    hold_attach_past_deadline!(id)

    assert {:error, message} =
             Cyfr.Execution.run_root(ctx, :default, @brief, chat(), execution_id: id)

    assert message =~ ~r/^#{Regex.escape(@redacted)} #{Regex.escape(@redacted)} \d+ms$/

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row, secrets)

    rows = event_rows(ctx, id)
    assert %{"error" => ^message} = Enum.find(rows, &(&1.type == "execution.failed")).data
    refute_unmasked(rows, secrets)
  end

  test "what a parent is handed of its child is masked", %{ctx: ctx} do
    secrets = arm!(ctx, @stub, key: "stub answers", token: "at once")
    parent_id = Cyfr.UUID7.execution_id()

    request = %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{"reference" => "#{@stub}:#{@version}", "input" => chat()}
    }

    # The formula calls the stub and answers what its host function handed
    # it, verbatim.
    assert {:ok, %{output: output}} =
             Cyfr.Execution.run_root(
               ctx,
               :default,
               Probe.probe_ref(),
               %{"op" => "call", "request" => request},
               execution_id: parent_id
             )

    handed = decoded(output)["result_raw"]
    assert %{"status" => "completed", "output" => envelope} = Jason.decode!(handed)
    assert %{"data" => %{"content" => [%{"text" => text}]}} = envelope
    assert text == "The #{@redacted} #{@redacted}."
    refute_unmasked(handed, secrets)
    refute_unmasked(Arca.Repo.get!(Arca.Schemas.Execution, parent_id), secrets)

    assert [child] = Arca.Repo.all(children_of(parent_id))
    refute_unmasked(child, secrets)
    refute_unmasked(Cyfr.Execution.Events.since(child.id, {0, 0}, ctx.athanor_id), secrets)
    refute_unmasked(event_rows(ctx, child.id), secrets)

    assert {:ok, _row, payload} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), child.id, "result")

    assert payload =~ @redacted
    refute_unmasked(payload, secrets)
  end

  test "a run whose attempt ends mid-run records nothing unmasked", %{ctx: ctx} do
    secrets = arm!(ctx, @stub, key: "stub answers", token: "at once")
    id = Cyfr.UUID7.execution_id()
    :ok = Cyfr.Execution.subscribe_events(id, ctx)
    TwoServices.hold!(:push_deltas, id, once: true)

    run =
      Task.async(fn ->
        Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)
      end)

    # Held at its first delta: its guest wrote both credentials, and
    # nothing of it has reached the host yet.
    assert_receive {:held, ^id, held}, 30_000

    attempt = Cyfr.Execution.Attempt.whereis(id)
    ref = Process.monitor(attempt)
    Process.exit(attempt, :kill)
    assert_receive {:DOWN, ^ref, :process, ^attempt, :killed}
    TwoServices.release!(held)

    assert {:error, message} = Task.await(run, 60_000)
    assert message == "Execution attempt ended before it closed"

    row = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row, secrets)
    refute_unmasked(live_events(), secrets)
    refute_unmasked(event_rows(ctx, id), secrets)

    assert {:error, :not_found} =
             Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), id, "result")
  end

  # ---------------------------------------------------------------------------
  # The estate
  # ---------------------------------------------------------------------------

  defp lay_seed!(seed) do
    unit!(seed, @stub, "1m")
    unit!(seed, @brief, "1s")
    File.mkdir_p!(Path.join(seed, "aqua"))

    File.write!(Path.join([seed, "aqua", "aqua.md"]), """
    ---
    title: AQUA
    catalyst_ref: #{@stub}
    model: step-stub
    ---

    You answer the person.
    """)

    seed
  end

  defp unit!(seed, ref, timeout) do
    "catalyst:local." <> name = ref
    unit = Path.join([seed, "components", "catalysts", "local", name, @version])
    File.mkdir_p!(unit)
    File.cp!(@stub_wasm, Path.join(unit, "catalyst.wasm"))

    manifest = %{
      "name" => name,
      "type" => "catalyst",
      "version" => @version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst the masking matrix runs",
      "contracts" => [Cyfr.Models.chat_contract()],
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:#{name}",
          "reason" => "to read a key as a model catalyst does",
          "required" => true,
          "fields" => [@key_field]
        }
      },
      "caps" => %{
        "limits" => %{
          "timeout" => timeout,
          "max_memory_bytes" => 67_108_864,
          "max_request_size" => 1_048_576,
          "max_response_size" => 5_242_880,
          "rate_limit" => %{"requests" => 10_000, "window" => "1m"}
        }
      }
    }

    File.write!(Path.join(unit, "cyfr-manifest.json"), Jason.encode!(manifest))
  end

  # Bind `key` as `ref`'s vault field, in an entry whose OAuth bundle holds
  # `token`, and dispense `token` to every run of it once its runner has
  # attached. Answers both, the credentials to look for.
  defp arm!(ctx, ref, key: key, token: token),
    do: TwoServices.arm!(ctx, ref, key: key, token: token)

  # Hold the attach of `id`'s runner on the suite's wire until its
  # assignment's deadline has passed: the run then has no time left, and
  # its guest's call is killed as it starts.
  defp hold_attach_past_deadline!(id) do
    relay =
      spawn_link(fn ->
        receive do
          {:attach_held, %{args: %{"assignment" => token}}, conn} ->
            {:ok, assignment} = Cyfr.Assignment.read(token)

            wait_until(
              fn -> System.system_time(:millisecond) > assignment.deadline end,
              10_000,
              "the run's deadline to pass"
            )

            TwoServices.release!(conn)
        end
      end)

    TwoServices.Wire.hold(
      TwoServices.watch!(),
      &match?(%{callback: :attach, fields: %{execution_id: ^id}}, &1),
      once: true,
      holder: relay,
      notify: fn call, conn -> {:attach_held, call, conn} end
    )

    :ok
  end

  defp chat, do: %{"operation" => "chat", "params" => %{}}

  defp decoded(output) when is_binary(output), do: Jason.decode!(output)
  defp decoded(output) when is_map(output), do: output

  defp live_events do
    receive do
      {:execution_event, event} -> [event | live_events()]
    after
      200 -> []
    end
  end

  defp streamed_text(events) do
    for %{type: "emit", data: %{"type" => "text.delta", "text" => text}} <- events,
        into: "",
        do: text
  end

  defp event_rows(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), id, 0)
    Enum.map(rows, &%{type: &1.type, data: Arca.ExecutionEvents.data(&1)})
  end

  defp children_of(parent_id) do
    import Ecto.Query, only: [from: 2]
    from(e in Arca.Schemas.Execution, where: e.parent_execution_id == ^parent_id)
  end

  defp refute_unmasked(term, secrets) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    for secret <- secrets do
      refute text =~ secret, "#{inspect(secret)} left the run unmasked in: #{text}"
    end
  end
end
