# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.StepSpansTest do
  @moduledoc """
  A turn's model step emits each step span once — admission, first delta,
  completion and the whole `run_child` — carrying the four identifiers
  and no payload; a clock marks only what happened, once; and
  `mix cyfr.bench.step` runs its steps to a printed table.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Execution.StepSpans

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

  test "a model step emits each span once, with the call's identifiers and no payload" do
    Mix.Tasks.Cyfr.Bench.Step.run(["--steps", "1", "--warmup", "0"])

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
      for payload <- ["hello", "The stub", "answers", "sk-step-stub"],
          do: refute(inspect(metadata) =~ payload)
    end
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
    dir = Path.expand("../../support/test_wasm/step_stub", __DIR__)
    readme = File.read!(Path.join(dir, "README.md"))

    for name <- ["src/lib.rs", "Cargo.lock", "step_stub.wasm"] do
      assert [_, recorded] =
               Regex.run(~r/^#{Regex.escape(name)}\s+(sha256:[0-9a-f]{64})$/m, readme)

      assert Cyfr.Digest.sha256(File.read!(Path.join(dir, name))) == recorded, name
    end
  end

  test "mix cyfr.bench.step prints each measure's percentiles and the adapters in use" do
    Mix.Tasks.Cyfr.Bench.Step.run(["--steps", "3", "--warmup", "1"])

    assert_received {:mix_shell, :info, [table]}
    assert table =~ "3 model steps on catalyst:local.step-stub after 1 warmup"
    assert table =~ "database: #{inspect(Cyfr.RuntimeConfig.repo_adapter())}"
    assert table =~ "storage: #{inspect(Arca.Storage.configured_adapter())}"

    for measure <- ["admission", "first delta", "time to first delta", "completion", "total"],
        do: assert(table =~ ~r/^#{measure} .*\d+\.\d\s+\d+\.\d\s+\d+\.\d$/m)
  end

  defp drain do
    receive do
      {:span, event, measurements, metadata} -> [{event, measurements, metadata} | drain()]
    after
      0 -> []
    end
  end
end
