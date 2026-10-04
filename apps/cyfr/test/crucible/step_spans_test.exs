# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.StepSpansTest do
  @moduledoc """
  A turn's model step emits each step span once — admission, first delta,
  completion and the whole `run_child` — carrying the four identifiers
  and no payload, whichever way its request travels; a clock marks only
  what happened, once; and `mix cyfr.bench.step` runs its steps to a
  printed table. Each of the bench's steps makes exactly one request to
  its upstream, with the key attached in `attached` mode and without it in
  `pinned`; the stub makes it for the bench's line, whole or after a
  display name, and for no other chat; and the upstream is stopped however
  a run ends.
  """

  use ExUnit.Case, async: false

  alias Crucible.StepSpans
  alias Cyfr.Test.StepBench

  @metadata_keys [:athanor_id, :component, :execution_id, :root_execution_id]

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    test = self()
    handler = "step-spans-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      StepSpans.events(),
      fn event, measurements, metadata, _config ->
        send(test, {:span, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  for mode <- ["attached", "pinned"] do
    test "a model step whose request is #{mode} emits each span once, with the call's identifiers and no payload" do
      Mix.Tasks.Cyfr.Bench.Step.run(["--mode", unquote(mode), "--steps", "1", "--warmup", "0"])

      # The chat step names its child; the catalyst's `describe` does not.
      step =
        for event <- StepSpans.events() do
          assert_receive {:span, ^event, measurements, %{execution_id: id} = metadata}
                         when is_binary(id)

          {event, measurements, metadata}
        end

      refute Enum.any?(drain(), fn {_event, _m, metadata} -> is_binary(metadata.execution_id) end)

      [%{execution_id: execution_id, root_execution_id: root_execution_id} | _] =
        Enum.map(step, &elem(&1, 2))

      for {_event, measurements, metadata} <- step do
        assert %{duration: duration} = measurements
        assert map_size(measurements) == 1 and is_integer(duration) and duration >= 0

        assert metadata |> Map.keys() |> Enum.sort() == @metadata_keys

        assert %{
                 execution_id: ^execution_id,
                 root_execution_id: ^root_execution_id,
                 athanor_id: "ath_test",
                 component: "catalyst:local.step-stub" <> _
               } = metadata

        assert "exec_" <> _ = execution_id
        assert "exec_" <> _ = root_execution_id
        refute execution_id == root_execution_id

        # The request, the streamed text, the answer and the key never ride.
        for payload <- ["bench_fetch", "one-byte", "The stub", "answers", "sk-step-stub"],
            do: refute(inspect(metadata) =~ payload)
      end

      assert_received {:mix_shell, :info, [table]}

      assert table =~
               "1 model steps on catalyst:local.step-stub after 0 warmup, mode #{unquote(mode)}"

      assert table =~ "upstream: 1 one-byte fetches"
    end
  end

  test "each step makes one request to the upstream, with the key attached only when attached" do
    for {mode, attached} <- [attached: 3, pinned: 0] do
      report = StepBench.run(steps: 2, warmup: 1, mode: mode)

      assert %{mode: ^mode, fetches: 3, attached_fetches: ^attached} = report, inspect(mode)
      assert report.steps == 2 and report.warmup == 1
      assert closed?(report.upstream_port), "the #{mode} run left its upstream listening"
    end
  end

  # The turn loop sends the bench's line after the person's display name in
  # the bench's athanor, where several people talk; a line sent whole is the
  # other form the stub reads. Each chat runs in the bench's athanor, on the
  # real host path, and the upstream counts what reached it.
  test "a chat makes the bench's request for its line, whole or after a display name, and for nothing else" do
    test = self()

    probe = fn %{ctx: ctx, request: request, fetches: fetches} ->
      line = Jason.encode!(%{"bench_fetch" => request})

      inputs = [
        whole: chat([line]),
        named: chat(["local|local|testns: " <> line]),
        person: chat(["hello"]),
        named_person: chat(["local|local|testns: hello"]),
        not_last: chat([line, "hello"]),
        no_messages: %{"operation" => "chat", "params" => %{}}
      ]

      made =
        for {form, input} <- inputs do
          before = fetches.()

          assert {:ok, %{output: %{"status" => 200}}} =
                   Crucible.run_root(ctx, :default, "catalyst:local.step-stub", input)

          {form, fetches.() - before}
        end

      send(test, {:made, made})
    end

    StepBench.run(steps: 1, warmup: 0, mode: :pinned, on_step: probe)

    assert_received {:made, made}

    assert made == [whole: 1, named: 1, person: 0, named_person: 0, not_last: 0, no_messages: 0]
  end

  test "the upstream is stopped and the athanor's environment restored when a run fails or times out" do
    test = self()
    base_path = Application.get_env(:arca, :base_path)
    seed_path = Application.get_env(:arca, :seed_path)

    failing = fn %{upstream_port: port} ->
      send(test, {:upstream, port})
      raise "a step failed"
    end

    assert_raise RuntimeError, "a step failed", fn ->
      StepBench.run(steps: 3, warmup: 0, mode: :attached, on_step: failing)
    end

    assert_received {:upstream, port}
    assert closed?(port), "a failed run left its upstream listening"

    # A turn that outlives its wait exits the bench (`Task.await/2`).
    timing_out = fn %{upstream_port: port} ->
      send(test, {:upstream, port})
      exit({:timeout, {Task, :await, [:turn, 60_000]}})
    end

    assert {:timeout, _} =
             catch_exit(StepBench.run(steps: 3, warmup: 0, mode: :pinned, on_step: timing_out))

    assert_received {:upstream, port}
    assert closed?(port), "a run that timed out left its upstream listening"

    assert Application.get_env(:arca, :base_path) == base_path
    assert Application.get_env(:arca, :seed_path) == seed_path
  end

  test "a clock emits admission, first delta and completion once, and only after the guest starts" do
    clock = StepSpans.start("catalyst:local.probe", execution_id: "exec_probe")

    StepSpans.pushed(clock, %{"type" => "text.delta", "text" => "early"})
    StepSpans.completed(clock)
    assert drain() == []

    StepSpans.guest_started(clock)
    StepSpans.guest_started(clock)
    StepSpans.pushed(clock, %{"type" => "usage", "usage" => %{}})
    StepSpans.pushed(clock, %{"type" => "tool_call.start", "index" => 0})
    StepSpans.pushed(clock, %{"type" => "text.delta", "text" => "late"})
    StepSpans.completed(clock)
    StepSpans.returned(clock)

    assert [
             [:cyfr, :execution, :child, :admission],
             [:cyfr, :execution, :child, :first_delta],
             [:cyfr, :execution, :child, :completion],
             [:cyfr, :execution, :run_child]
           ] = Enum.map(drain(), &elem(&1, 0))

    assert :ok = StepSpans.guest_started(nil)
    assert :ok = StepSpans.pushed(nil, %{"type" => "text.delta"})
    assert :ok = StepSpans.completed(nil)
    assert drain() == []
  end

  # The bench's catalyst is built reproducibly (`build.sh`): its binary and
  # the sources it is built from are the ones its README records, so a
  # source edit without a rebuild, or a binary from another build, fails
  # here.
  test "the step stub's binary and sources are the ones its README records" do
    dir = Path.expand("../support/test_wasm/step_stub", __DIR__)
    readme = File.read!(Path.join(dir, "README.md"))

    for name <- ["src/lib.rs", "Cargo.lock", "step_stub.wasm"] do
      assert [_, recorded] =
               Regex.run(~r/^#{Regex.escape(name)}\s+(sha256:[0-9a-f]{64})$/m, readme)

      assert Prima.Digest.sha256(File.read!(Path.join(dir, name))) == recorded, name
    end
  end

  test "mix cyfr.bench.step prints each measure's percentiles, the commit, the mode and the adapters in use" do
    Mix.Tasks.Cyfr.Bench.Step.run(["--steps", "3", "--warmup", "1"])

    assert_received {:mix_shell, :info, [table]}
    assert table =~ "3 model steps on catalyst:local.step-stub after 1 warmup, mode attached"
    assert table =~ ~r/^commit: [0-9a-f]{40}( with uncommitted changes)?$/m
    assert table =~ "database: #{inspect(Cyfr.RuntimeConfig.repo_adapter())}"
    assert table =~ "storage: #{inspect(Arca.Storage.configured_adapter())}"
    assert table =~ "upstream: 4 one-byte fetches, 4 with the key attached"

    for measure <- ["admission", "first delta", "time to first delta", "completion", "total"],
        do: assert(table =~ ~r/^#{measure} .*\d+\.\d\s+\d+\.\d\s+\d+\.\d$/m)
  end

  test "mix cyfr.bench.step refuses a mode it does not know" do
    assert_raise Mix.Error, ~r/--mode is attached or pinned/, fn ->
      Mix.Tasks.Cyfr.Bench.Step.run(["--mode", "direct", "--steps", "1", "--warmup", "0"])
    end
  end

  defp chat(lines) do
    messages =
      for text <- lines,
          do: %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}

    %{"operation" => "chat", "params" => %{"messages" => messages}}
  end

  defp closed?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000) do
      {:error, :econnrefused} ->
        true

      {:ok, socket} ->
        :gen_tcp.close(socket)
        false
    end
  end

  defp drain do
    receive do
      {:span, event, measurements, metadata} -> [{event, measurements, metadata} | drain()]
    after
      0 -> []
    end
  end
end
