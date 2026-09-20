# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)
Code.require_file("support/formula_host_helper.exs", __DIR__)

defmodule Opus.OrphanChildrenTest do
  @moduledoc """
  A formula's children end with it and never outlive their deadline, which
  is their parent's at most.

  Every child — called, spawned or streamed — runs in its formula's
  runner, bounded by the smaller of its own node's timeout and what
  remained of its parent's subtree deadline when it was admitted: held at
  a host call past that, its call is killed and its row fails with the
  timeout, and the formula's guest is answered so. A formula whose run was
  cancelled or has closed admits no new child through `execution.run`,
  `execution.run_stream` or a spawn its runner asks for: no row, no charge
  row and no invoke slot is left behind. A `run_stream` child takes a
  charge row, as a spawned child does, and gives it back.

  The formula and its children are the `nested-probe`, each child asking
  for a catalog tool and held at that call on the suite's wire; a
  formula's close is held there too, to keep it running. The children the
  deadline case bounds are the probe under another name, whose consent,
  an edge of the formula's, grants it one second. What a formula whose
  run ended asks is asked as its runner asks it, over the wire with the
  keys of its attempt (`Opus.Test.FormulaHost`).
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.TwoServices
  alias Opus.Test.FormulaHost
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000
  @moduletag :capture_log

  @probe_node "formula:local.nested-probe"
  @brief "formula:local.brief-probe:0.1.0"
  @ended "The call failed."

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "orphan_children_#{System.unique_integer([:positive])}")

    keys = [:base_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The probe under another name, consented one second, is an edge of the
    # probe's own consent.
    :ok = Probe.publish_probe!(ctx, name: "brief-probe", limits: brief_limits())
    :ok = Probe.publish_probe!(ctx, isolate: false, dependencies: [@brief])
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, ctx: ctx}
  end

  describe "a formula that is no longer running" do
    test "admits no child once it was cancelled", %{ctx: ctx} do
      {root_id, authority, row} = held_root!(ctx)

      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, root_id)
      assert %{status: "cancelled"} = Arca.Repo.get!(Arca.Execution, root_id)

      refute_orphans_admitted(root_id, authority, row)
    end

    test "admits no child once it closed", %{ctx: ctx} do
      {root_id, authority, row} = held_root!(ctx)

      TwoServices.release!(row.close)
      assert_receive {:root, {:ok, %{status: :completed}}}, 30_000
      assert %{status: "completed"} = Arca.Repo.get!(Arca.Execution, root_id)

      refute_orphans_admitted(root_id, authority, row)
    end
  end

  test "a run_stream child takes a charge row and gives it back", %{ctx: ctx} do
    root_id = Cyfr.UUID7.execution_id()
    hold_children!(root_id)
    TwoServices.hold!(:complete, root_id, once: true)
    start_root(ctx, root_id, %{"op" => "call", "request" => request("run_stream")})

    assert_receive {:held, ^root_id, close}, 30_000
    assert_receive {:held, stream_id, stream}, 30_000
    authority = TwoServices.entered(root_id)

    assert Sanctum.Authority.budget(authority).in_flight == 1

    assert [%{holder_execution_id: ^stream_id, admitted_at: %DateTime{}}] =
             charges(ctx, authority)

    TwoServices.release!(stream)
    wait_until(fn -> Arca.Repo.get!(Arca.Execution, stream_id).status == "completed" end, 30_000)
    wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
    wait_until(fn -> charges(ctx, authority) == [] end)

    TwoServices.release!(close)
    assert_receive {:root, {:ok, %{output: output}}}, 30_000
    assert %{"output" => %{"execution_id" => ^stream_id}} = raw(output, "result_raw")
  end

  test "every child is killed at its deadline, within its parent's, held past it", %{ctx: ctx} do
    root_id = Cyfr.UUID7.execution_id()
    hold_children!(root_id)

    # A spawned child, a streamed one and a called one, the guest waiting on
    # the called one and then on the spawned one.
    start_root(ctx, root_id, %{
      "op" => "steps",
      "steps" => [
        %{"spawn" => request("run", @brief)},
        %{"call" => request("run_stream", @brief)},
        %{"call" => request("run", @brief)},
        %{"await" => 0}
      ]
    })

    held =
      for _ <- 1..3 do
        assert_receive {:held, id, _held}, 30_000
        id
      end

    started = System.monotonic_time(:millisecond)
    authority = TwoServices.entered(root_id)

    wait_until(
      fn -> Enum.all?(held, &(Arca.Repo.get!(Arca.Execution, &1).status == "failed")) end,
      15_000
    )

    assert System.monotonic_time(:millisecond) - started < 10_000

    # Each child's timeout is its own consented second capped by what was
    # left of the parent's, so it ends at or before the parent's deadline.
    timeout = ~r/^Execution timeout after (\d+)ms$/

    for id <- held do
      assert %{error_message: message} = Arca.Repo.get!(Arca.Execution, id)
      assert [_, ms] = Regex.run(timeout, message)
      assert String.to_integer(ms) in 1..1000
      wait_until(fn -> Cyfr.Execution.Attempt.whereis(id) == nil end)
    end

    # The formula's guest was answered each child's end, the called one's
    # and the spawned one's as the timeout.
    assert_receive {:root, {:ok, %{output: output}}}, 30_000
    %{"results" => [spawned, streamed, called, awaited]} = decoded(output)
    assert %{"task_id" => _} = Jason.decode!(spawned)
    assert %{"output" => %{"execution_id" => _}} = Jason.decode!(streamed)
    assert Jason.decode!(called)["error"]["message"] =~ ~r/Execution timeout after \d+ms/

    assert %{"status" => "error", "error" => %{"message" => spawned_answer}} =
             Jason.decode!(awaited)

    assert spawned_answer =~ ~r/Execution timeout after \d+ms/

    wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
    assert charges(ctx, authority) == []
  end

  # ---------------------------------------------------------------------------

  # The probe as a root, echoing, held at its close: its id, its authority
  # as its runner attached with it, the held close and the client its
  # runner holds.
  defp held_root!(ctx) do
    root_id = Cyfr.UUID7.execution_id()
    TwoServices.hold!(:complete, root_id, once: true)
    start_root(ctx, root_id, %{"op" => "echo"})
    assert_receive {:held, ^root_id, close}, 30_000

    {root_id, TwoServices.entered(root_id),
     %{close: close, host: FormulaHost.current!(ctx.athanor_id, root_id)}}
  end

  # A root run of the probe in a process of its own, which waits on it.
  defp start_root(ctx, root_id, input) do
    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:root,
         Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), input, execution_id: root_id)}
      )
    end)
  end

  # Each child of the root asks for a catalog tool, and is held at that
  # call: the test receives `{:held, id, held}` for each.
  defp hold_children!(root_id) do
    TwoServices.hold!(
      :tool_call,
      fn row, _call -> row != nil and row.parent_execution_id == root_id end,
      []
    )
  end

  defp request(action, reference \\ Probe.probe_ref()) do
    %{
      "tool" => "execution",
      "action" => action,
      "args" => %{"reference" => reference, "input" => Probe.held_input(), "type" => "formula"}
    }
  end

  defp request_json(action), do: Jason.encode!(request(action))

  # What the formula's own `call` host function answers for `action`,
  # asked as its runner asks it.
  defp formula_call(host, action, authority),
    do: Opus.FormulaHandler.execute(request_json(action), host, FormulaHost.opts(authority))

  defp refute_orphans_admitted(root_id, authority, row) do
    # The formula's attempt is gone: every host call its runner makes for a
    # child is refused before anything is admitted or charged.
    assert %{"error" => %{"message" => @ended}} =
             Jason.decode!(formula_call(row.host, "run", authority))

    assert %{"error" => %{"message" => @ended}} =
             Jason.decode!(formula_call(row.host, "run_stream", authority))

    {imports, tracker} =
      Opus.FormulaHandler.build_formula_imports(row.host, FormulaHost.opts(authority))

    %{"spawn" => {:fn, spawn_fn}} = imports["cyfr:formula/invoke@0.1.0"]
    assert %{"error" => %{"message" => @ended}} = Jason.decode!(spawn_fn.(request_json("run")))
    Opus.FormulaHandler.cleanup_registry(tracker)

    children = from(e in Arca.Execution, where: e.parent_execution_id == ^root_id, select: e.id)
    assert Arca.Repo.all(children) == []
    assert Sanctum.Authority.budget(authority).in_flight == 0
    assert charges(Sanctum.TestContext.local(), authority) == []
  end

  defp brief_limits do
    %{
      "timeout" => "1s",
      "max_memory_bytes" => 67_108_864,
      "max_request_size" => 1_048_576,
      "max_response_size" => 5_242_880,
      "rate_limit" => %{"requests" => 100, "window" => "1m"}
    }
  end

  defp decoded(output) when is_binary(output), do: Jason.decode!(output)
  defp decoded(output) when is_map(output), do: output

  defp raw(output, key), do: output |> decoded() |> Map.fetch!(key) |> Jason.decode!()

  defp charges(ctx, authority) do
    {:ok, charges} =
      Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), authority.budget.id)

    charges
  end
end
