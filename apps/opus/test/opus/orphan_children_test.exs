# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OrphanChildrenTest do
  @moduledoc """
  A formula's children end with it and never outlive their own deadline.

  Every child — called, spawned or streamed — is bounded by the timeout
  of its own node: held at its guest's entry past that timeout, its
  component process is killed and its row fails with the timeout, whatever
  its parent does. A formula whose run was cancelled or has closed admits
  no new child through `execution.run`, `execution.run_stream` or a spawn:
  no row, no charge row and no invoke slot is left behind. A `run_stream`
  child takes a charge row, as a spawned child does, and gives it back.

  The formula and its children are the `nested-probe`, held at the entry
  to their guest until the test lets them go.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Cyfr.Authority.Blob
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"
  @refused "Execution refused: its parent execution is no longer running"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

      refute_orphans_admitted(ctx, root_id, authority, row)
    end

    test "admits no child once it closed", %{ctx: ctx} do
      {root_id, authority, row} = held_root!(ctx)

      send(row.component, :continue)
      assert_receive {:root, {:ok, %{status: :completed}}}, 30_000
      assert %{status: "completed"} = Arca.Repo.get!(Arca.Execution, root_id)

      refute_orphans_admitted(ctx, root_id, authority, row)
    end
  end

  test "a run_stream child takes a charge row and gives it back", %{ctx: ctx} do
    {root_id, authority, row} = held_root!(ctx)
    hold_children!(root_id)

    streamed = formula_call(ctx, "run_stream", root_id, authority, row)
    assert %{"output" => %{"execution_id" => stream_id}} = Jason.decode!(streamed)
    assert_receive {:held, component, ^stream_id}, 30_000

    assert Sanctum.Authority.budget(authority).in_flight == 1

    assert [%{holder_execution_id: ^stream_id, admitted_at: %DateTime{}}] =
             charges(ctx, authority)

    send(component, :continue)
    wait_until(fn -> Arca.Repo.get!(Arca.Execution, stream_id).status == "completed" end, 30_000)
    wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
    assert charges(ctx, authority) == []

    send(row.component, :continue)
    assert_receive {:root, {:ok, _}}, 30_000
  end

  test "every child is killed at its own deadline, held past it", %{ctx: ctx} do
    {root_id, authority, row} = held_root!(ctx)
    hold_children!(root_id)
    short = with_timeout(authority, "1s")
    test_pid = self()

    called =
      spawn_link(fn ->
        send(test_pid, {:called, formula_call(ctx, "run", root_id, short, row)})
      end)

    streamed = formula_call(ctx, "run_stream", root_id, short, row)
    assert %{"output" => %{"execution_id" => stream_id}} = Jason.decode!(streamed)

    spawned =
      spawn_link(fn ->
        send(
          test_pid,
          {:spawned,
           Opus.Chain.run_child(short, Probe.probe_ref(), nil, %{"op" => "echo"},
             ctx: Sanctum.Context.enter_guest(ctx),
             attempt: row.attempt,
             parent_execution_id: root_id,
             root_execution_id: root_id,
             declared_needs: [],
             guest_fn: :spawn
           )}
        )
      end)

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

    for {id, component} <- held do
      assert %{error_message: "Execution timeout after 1000ms"} =
               Arca.Repo.get!(Arca.Execution, id)

      wait_until(fn -> not Process.alive?(component) end)
      wait_until(fn -> Cyfr.Execution.Attempt.whereis(id) == nil end)
    end

    assert_receive {:called, called_answer}, 5_000
    assert called_answer =~ "Execution timeout after 1000ms"
    assert_receive {:spawned, {:error, "Execution timeout after 1000ms"}}, 5_000
    refute Process.alive?(called) or Process.alive?(spawned)

    wait_until(fn -> Sanctum.Authority.budget(short).in_flight == 0 end)
    assert charges(ctx, short) == []
    assert %{status: "running"} = Arca.Repo.get!(Arca.Execution, root_id)

    send(row.component, :continue)
    assert_receive {:root, {:ok, _}}, 30_000
  end

  # ---------------------------------------------------------------------------

  # The probe as a root, echoing, held at its guest's entry: its id, its
  # authority as it runs, and its row's attempt and held component.
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
         Opus.run_root(ctx, :default, Probe.probe_ref(), %{"op" => "echo"}, execution_id: root_id)}
      )
    end)

    assert_receive {:entered, component, authority}, 30_000
    execution = Arca.Repo.get!(Arca.Execution, root_id)

    {root_id, authority,
     %{
       attempt: execution.current_attempt,
       activation_digest: execution.activation_digest,
       component: component
     }}
  end

  # Children of `root_id` wait at their guest's entry for `:continue`.
  defp hold_children!(root_id) do
    test_pid = self()
    handler = "orphan-children-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id}, _config ->
          case Arca.Repo.get(Arca.Execution, id) do
            %{parent_execution_id: ^root_id} ->
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

  # What the formula's own `call` host function answers for `action`, made
  # with the formula's authority, attempt and lineage.
  defp formula_call(ctx, action, root_id, authority, row) do
    request = %{
      "tool" => "execution",
      "action" => action,
      "args" => %{
        "reference" => Probe.probe_ref(),
        "input" => %{"op" => "echo"},
        "type" => "formula"
      }
    }

    Opus.FormulaHandler.execute(Jason.encode!(request), Sanctum.Context.enter_guest(ctx),
      parent_execution_id: root_id,
      root_execution_id: root_id,
      attempt: row.attempt,
      authority: authority,
      declared_needs: [],
      activation_digest: row.activation_digest,
      parent_reference: Probe.probe_ref()
    )
  end

  defp refute_orphans_admitted(ctx, root_id, authority, row) do
    # A called child is refused at its admission; a streamed or spawned one
    # already at its charge, which only a running parent attempt may take.
    assert %{"error" => %{"message" => @refused}} =
             Jason.decode!(formula_call(ctx, "run", root_id, authority, row))

    assert %{"error" => %{"message" => "Invocation denied: stale_attempt"}} =
             Jason.decode!(formula_call(ctx, "run_stream", root_id, authority, row))

    assert {:error, {:invoke_denied, :stale_attempt}} =
             Opus.Chain.run_child(authority, Probe.probe_ref(), nil, %{"op" => "echo"},
               ctx: Sanctum.Context.enter_guest(ctx),
               attempt: row.attempt,
               parent_execution_id: root_id,
               root_execution_id: root_id,
               declared_needs: [],
               guest_fn: :spawn
             )

    children = from(e in Arca.Execution, where: e.parent_execution_id == ^root_id, select: e.id)
    assert Arca.Repo.all(children) == []
    assert Sanctum.Authority.budget(authority).in_flight == 0
    assert charges(ctx, authority) == []
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
