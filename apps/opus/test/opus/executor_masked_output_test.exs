# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutorMaskedOutputTest do
  @moduledoc """
  A credential handed to a run never leaves it unmasked: a vault field the
  run unsealed and an OAuth token dispensed to it are masked in the output,
  a failure message, a timeout error, the events the guest streams, what a
  parent is handed of its child, the kept result payload, the lifecycle
  events' data and the result the waiter receives. A run whose attempt ends
  before it closes the run records none of them.

  The guest is the step-stub catalyst (`test_wasm/step_stub/` in the cyfr
  suite). Its `chat` reads its key, streams "The stub ", "answers ", "at ",
  "once." and answers their concatenation; an operation it does not know
  is refused with "the stub answers describe, models and chat". Each
  credential is text the stub writes, so what it writes is what must come
  out masked — the key spans two deltas, and so does the token. The key's
  vault entry also holds an OAuth bundle whose access token is the token,
  and the token is dispensed by an `oauth_token` host call on the run's
  attempt as the guest starts, as a guest's `cyfr:oauth` call dispenses one.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Bootstrap, Commit, Plan, Source}

  @moduletag timeout: 120_000

  @stub_wasm Path.expand("../../../cyfr/test/support/test_wasm/step_stub/step_stub.wasm", __DIR__)
  @stub "catalyst:local.step-stub"
  @brief "catalyst:local.step-stub-brief"
  @soul "agent:local.aqua"
  @version "0.1.0"
  @key_field "STUB_API_KEY"
  @redacted "[REDACTED]"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    run_dir = Path.join(System.tmp_dir!(), "masked_output_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, Path.join(run_dir, "data"))
    Application.put_env(:cyfr, :seed_path, lay_seed!(Path.join(run_dir, "seed")))
    Application.put_env(:cyfr, :consent_source, Source.DB)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Execution.Semaphore.forgive_unreaped(ctx.athanor_id)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(run_dir)
    end)

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted and @stub in minted and @brief in minted

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

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "completed"
    refute_unmasked(row, secrets)

    assert {:ok, _row, payload} = Arca.ExecutionPayloads.get(ctx, id, "result")
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

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row, secrets)

    rows = event_rows(ctx, id)
    assert %{"error" => ^message} = Enum.find(rows, &(&1.type == "execution.failed")).data
    refute_unmasked(rows, secrets)
    refute_unmasked(live_events(), secrets)
    assert {:error, :not_found} = Arca.ExecutionPayloads.get(ctx, id, "result")
  end

  test "a timed-out run's error is masked in the row, its event and the result", %{ctx: ctx} do
    secrets = arm!(ctx, @brief, key: "timeout after", token: "1000ms")
    id = Cyfr.UUID7.execution_id()
    hold_guest!(id)

    assert {:error, message} =
             Cyfr.Execution.run_root(ctx, :default, @brief, chat(), execution_id: id)

    assert message == "Execution #{@redacted} #{@redacted}"

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row, secrets)

    rows = event_rows(ctx, id)
    assert %{"error" => ^message} = Enum.find(rows, &(&1.type == "execution.failed")).data
    refute_unmasked(rows, secrets)
  end

  test "what a parent is handed of its child is masked", %{ctx: ctx} do
    secrets = arm!(ctx, @stub, key: "stub answers", token: "at once")
    {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @soul)
    parent_id = Cyfr.UUID7.execution_id()

    request =
      Jason.encode!(%{
        "tool" => "execution",
        "action" => "run",
        "args" => %{"reference" => "#{@stub}:#{@version}", "input" => chat()}
      })

    handed =
      Opus.FormulaHandler.execute(request, Sanctum.Context.enter_guest(ctx),
        parent_execution_id: parent_id,
        root_execution_id: parent_id,
        authority: authority,
        declared_needs: [],
        parent_reference: @soul
      )

    assert %{"status" => "completed", "output" => %{"output" => envelope}} = Jason.decode!(handed)
    assert %{"data" => %{"content" => [%{"text" => text}]}} = envelope
    assert text == "The #{@redacted} #{@redacted}."
    refute_unmasked(handed, secrets)

    assert [child] = Arca.Repo.all(children_of(parent_id))
    refute_unmasked(child, secrets)
    refute_unmasked(Cyfr.Execution.Events.since(child.id, {0, 0}, ctx.athanor_id), secrets)
    refute_unmasked(event_rows(ctx, child.id), secrets)
    assert {:ok, _row, payload} = Arca.ExecutionPayloads.get(ctx, child.id, "result")
    assert payload =~ @redacted
    refute_unmasked(payload, secrets)
  end

  test "a run whose attempt ends mid-run records nothing unmasked", %{ctx: ctx} do
    secrets = arm!(ctx, @stub, key: "stub answers", token: "at once")
    id = Cyfr.UUID7.execution_id()
    :ok = Cyfr.Execution.subscribe_events(id, ctx)
    await_entry!(id)

    run =
      Task.async(fn ->
        Cyfr.Execution.run_root(ctx, :default, @stub, chat(), execution_id: id)
      end)

    assert_receive {:entered, ^id, guest}, 30_000

    attempt = Cyfr.Execution.Attempt.whereis(id)
    ref = Process.monitor(attempt)
    Process.exit(attempt, :kill)
    assert_receive {:DOWN, ^ref, :process, ^attempt, :killed}
    send(guest, :continue)

    assert {:error, message} = Task.await(run, 60_000)
    assert message == "Execution attempt ended before it closed"

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.status == "failed" and row.error_message == message
    refute_unmasked(row, secrets)
    refute_unmasked(live_events(), secrets)
    refute_unmasked(event_rows(ctx, id), secrets)
    assert {:error, :not_found} = Arca.ExecutionPayloads.get(ctx, id, "result")
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

  # Bind `key` as the component's vault field, in an entry whose OAuth bundle
  # holds `token`, and dispense `token` to every run of it as its guest
  # starts. Answers both, the credentials to look for.
  defp arm!(ctx, ref, key: key, token: token) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "#{ref} key",
        kind: "api_key",
        fields: %{@key_field => key},
        oauth: %{"access_token" => token}
      })

    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    handler = "masked-output-dispense-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id, reference: reference}, _config ->
          if String.starts_with?(reference, ref <> ":") do
            attempt = Cyfr.Test.AttemptFixtures.current!(ctx.athanor_id, id)

            %{"ok" => ^token} =
              Cyfr.Test.AttemptFixtures.call(attempt, "oauth_token", %{"provider" => "stub"})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    [key, token]
  end

  # Hold the guest of `id` at its authority's entry, past any timeout.
  defp hold_guest!(id) do
    handler = "masked-output-hold-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, metadata, _config ->
          if metadata.execution_id == id, do: Process.sleep(5_000)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Hold the guest of `id` at its authority's entry until the test sends
  # `:continue` to the process it names.
  defp await_entry!(id) do
    handler = "masked-output-entry-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, metadata, _config ->
          if metadata.execution_id == id do
            send(test, {:entered, id, self()})

            receive do
              :continue -> :ok
            after
              30_000 -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp chat, do: %{"operation" => "chat", "params" => %{}}

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
    {:ok, rows} = Arca.ExecutionEvents.since(ctx.athanor_id, id, 0)
    Enum.map(rows, &%{type: &1.type, data: Arca.ExecutionEvents.data(&1)})
  end

  defp children_of(parent_id) do
    import Ecto.Query, only: [from: 2]
    from(e in Arca.Execution, where: e.parent_execution_id == ^parent_id)
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
