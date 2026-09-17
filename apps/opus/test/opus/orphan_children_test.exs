# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OrphanChildrenTest do
  @moduledoc """
  A formula's children end with it and never outlive their deadline, which
  is their parent's at most.

  Every child — called, spawned or streamed — runs in a runner of its
  formula's group, bounded by the smaller of its own node's timeout and
  what remained of its parent's subtree deadline when it was admitted:
  held at its guest's entry past that, its component process is killed and
  its row fails with the timeout. A formula whose run
  was cancelled or has closed admits no new child through `execution.run`,
  `execution.run_stream` or a spawn: no row, no charge row and no invoke
  slot is left behind. A `run_stream` child takes a charge row, as a spawned
  child does, and gives it back.

  The formula and its children are the `nested-probe`, held at the entry
  to their guest until the test lets them go.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Authority.Blob
  alias Opus.Test.FormulaHost
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000
  @moduletag :capture_log

  @probe_node "formula:local.nested-probe"
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
      Cyfr.Execution.Semaphore.forgive_unreaped(ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Probe.publish_probe!(ctx)
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

      send(row.component, :continue)
      assert_receive {:root, {:ok, %{status: :completed}}}, 30_000
      assert %{status: "completed"} = Arca.Repo.get!(Arca.Execution, root_id)

      refute_orphans_admitted(root_id, authority, row)
    end
  end

  test "a run_stream child takes a charge row and gives it back", %{ctx: ctx} do
    {root_id, authority, row} = held_root!(ctx)
    hold_children!(root_id)

    streamed = formula_call(row.host, "run_stream", authority)
    assert %{"output" => %{"execution_id" => stream_id}} = Jason.decode!(streamed)
    assert_receive {:held, component, ^stream_id}, 30_000

    assert Sanctum.Authority.budget(authority).in_flight == 1

    assert [%{holder_execution_id: ^stream_id, admitted_at: %DateTime{}}] =
             charges(ctx, authority)

    send(component, :continue)
    wait_until(fn -> Arca.Repo.get!(Arca.Execution, stream_id).status == "completed" end, 30_000)
    wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
    wait_until(fn -> charges(ctx, authority) == [] end)

    send(row.component, :continue)
    assert_receive {:root, {:ok, _}}, 30_000
  end

  test "every child is killed at its deadline, within its parent's, held past it", %{ctx: ctx} do
    {:ok, consented} = Cyfr.Execution.authority_for(ctx, :default, @probe_node)
    short = with_timeout(consented, "1s")

    formula =
      FormulaHost.attached!(ctx: ctx, authority: short, component_ref: Probe.probe_ref())

    host = formula.host
    hold_children!(host.execution_id)
    test_pid = self()

    called =
      spawn_link(fn ->
        send(test_pid, {:called, formula_call(host, "run", short)})
      end)

    streamed = formula_call(host, "run_stream", short)
    assert %{"output" => %{"execution_id" => stream_id}} = Jason.decode!(streamed)

    {imports, tracker} =
      Opus.FormulaHandler.build_formula_imports(host, FormulaHost.opts(short))

    %{"spawn" => {:fn, spawn_fn}, "await" => {:fn, await_fn}} =
      imports["cyfr:formula/invoke@0.1.0"]

    assert %{"task_id" => task_id} = Jason.decode!(spawn_fn.(request("run")))

    held =
      for _ <- 1..3 do
        assert_receive {:held, component, id}, 30_000
        {id, component}
      end

    started = System.monotonic_time(:millisecond)
    ids = Enum.map(held, &elem(&1, 0))
    assert stream_id in ids

    wait_until(
      fn -> Enum.all?(ids, &(Arca.Repo.get!(Arca.Execution, &1).status == "failed")) end,
      15_000
    )

    assert System.monotonic_time(:millisecond) - started < 10_000

    # Each child's timeout is its own consented second capped by what was
    # left of the parent's, so it ends at or before the parent's deadline.
    timeout = ~r/^Execution timeout after (\d+)ms$/

    for {id, component} <- held do
      assert %{error_message: message} = Arca.Repo.get!(Arca.Execution, id)
      assert [_, ms] = Regex.run(timeout, message)
      assert String.to_integer(ms) in 1..1000

      wait_until(fn -> not Process.alive?(component) end)
      wait_until(fn -> Cyfr.Execution.Attempt.whereis(id) == nil end)
    end

    assert_receive {:called, called_answer}, 5_000
    assert called_answer =~ ~r/Execution timeout after \d+ms/
    refute Process.alive?(called)

    assert %{"status" => "error", "error" => %{"message" => spawned_answer}} =
             Jason.decode!(await_fn.(task_id))

    assert spawned_answer =~ ~r/Execution timeout after \d+ms/

    wait_until(fn -> Sanctum.Authority.budget(short).in_flight == 0 end)
    assert charges(ctx, short) == []
    assert %{status: "running"} = Arca.Repo.get!(Arca.Execution, host.execution_id)

    Opus.FormulaHandler.cleanup_registry(tracker)
  end

  # ---------------------------------------------------------------------------

  # The probe as a root, echoing, held at its guest's entry: its id, its
  # authority as its assignment carries it, and its row's attempt, its
  # held component and the client its runner holds.
  defp held_root!(ctx) do
    root_id = Cyfr.UUID7.execution_id()
    test_pid = self()
    handler = "orphan-root-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id, authority: authority}, _config ->
          if id == root_id do
            send(test_pid, {:entered, self(), authority})

            receive do
              :continue -> :ok
            after
              60_000 -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    spawn(fn ->
      send(
        test_pid,
        {:root,
         Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{"op" => "echo"},
           execution_id: root_id
         )}
      )
    end)

    assert_receive {:entered, component, authority}, 30_000
    execution = Arca.Repo.get!(Arca.Execution, root_id)

    {root_id, authority,
     %{
       attempt: execution.current_attempt,
       component: component,
       host: FormulaHost.current!(ctx.athanor_id, root_id)
     }}
  end

  # Children of `parent_id` wait at their guest's entry for `:continue`.
  defp hold_children!(parent_id) do
    test_pid = self()
    handler = "orphan-children-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id}, _config ->
          case Arca.Repo.get(Arca.Execution, id) do
            %{parent_execution_id: ^parent_id} ->
              send(test_pid, {:held, self(), id})

              receive do
                :continue -> :ok
              after
                60_000 -> :ok
              end

            _ ->
              :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp request(action) do
    Jason.encode!(%{
      "tool" => "execution",
      "action" => action,
      "args" => %{
        "reference" => Probe.probe_ref(),
        "input" => %{"op" => "echo"},
        "type" => "formula"
      }
    })
  end

  # What the formula's own `call` host function answers for `action`,
  # made through the formula's attempt `host`.
  defp formula_call(host, action, authority),
    do: Opus.FormulaHandler.execute(request(action), host, FormulaHost.opts(authority))

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
    assert %{"error" => %{"message" => @ended}} = Jason.decode!(spawn_fn.(request("run")))
    Opus.FormulaHandler.cleanup_registry(tracker)

    children = from(e in Arca.Execution, where: e.parent_execution_id == ^root_id, select: e.id)
    assert Arca.Repo.all(children) == []
    assert Sanctum.Authority.budget(authority).in_flight == 0
    assert charges(Sanctum.TestContext.local(), authority) == []
  end

  # `authority` with every node of its graph consenting `timeout`.
  defp with_timeout(%Cyfr.Authority{policy: %Blob{} = blob} = authority, timeout) do
    nodes =
      Map.new(blob.nodes, fn {ref, node} ->
        {ref, %{node | limits: %{node.limits | timeout: timeout}}}
      end)

    %{authority | policy: %{blob | nodes: nodes}}
  end

  defp charges(ctx, authority) do
    {:ok, charges} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
    charges
  end
end
