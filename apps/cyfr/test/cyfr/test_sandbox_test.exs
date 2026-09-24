# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("../integration/opus/support/nested_execution_helper.exs", __DIR__)

defmodule Cyfr.Test.SandboxTest do
  @moduledoc """
  A sync test's background work is stopped before its sandbox owner is:
  every dynamic supervisor this repository's applications start is swept,
  and each child's last database work lands while the owner still holds
  the connection. The Opus service's runners are swept through their pool
  instead: a runner the test left busy is ended and its exit reported,
  and the fresh runners stay pooled for the next test.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.{Sandbox, TwoServices}
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @apps_root Path.expand("../../..", __DIR__) <> "/"

  test "every dynamic supervisor the repository's running applications start is swept" do
    running = repository_dynamic_supervisors()
    assert running != []
    assert Enum.sort(running) == Enum.sort(Enum.filter(Sandbox.supervisors(), &Process.whereis/1))
  end

  test "the Opus service's runners are swept through their pool, not stopped" do
    assert Sandbox.pooled() == [Opus.RunnerPool.Runners]
    assert Opus.RunnerPool.Runners in repository_dynamic_supervisors()
  end

  describe "a sync test's work" do
    setup do
      collector = spawn(fn -> collect(%{}) end)

      # Registered before the sandbox, so it runs after the owner is gone.
      on_exit(fn ->
        send(collector, {:reports, self()})
        assert_receive {:reports, reports}, 5_000

        for name <- swept_by_stopping() do
          assert match?({:ok, _}, Map.get(reports, name)),
                 "#{inspect(name)}'s child did not finish its database work before the owner " <>
                   "stopped: #{inspect(Map.get(reports, name, :never_stopped))}"
        end
      end)

      Sandbox.setup!()
      {:ok, collector: collector}
    end

    test "is stopped under every dynamic supervisor while the owner still holds the connection",
         %{collector: collector} do
      for name <- swept_by_stopping() do
        assert {:ok, _child} =
                 DynamicSupervisor.start_child(name, last_query_child(name, collector))
      end
    end
  end

  describe "a sync test's runners" do
    setup tags do
      # Unlinked, so it outlives the test process for the check below.
      {:ok, seen} = Agent.start(fn -> %{} end)

      # Registered before the sandbox, so it runs after the sweep.
      on_exit(fn ->
        %{busy: busy, fresh: fresh} = Agent.get(seen, & &1)
        Agent.stop(seen)
        pooled = Map.new(Opus.RunnerPool.runners(Opus.RunnerPool), &{&1.id, &1.state})

        refute Map.has_key?(pooled, busy), "the busy runner outlived the sweep"

        for id <- fresh,
            do: assert(Map.has_key?(pooled, id), "a fresh runner was swept: #{id}")
      end)

      Sandbox.setup!(tags)
      TwoServices.watch!()

      test_path =
        Path.join(System.tmp_dir!(), "sandbox_runners_#{System.unique_integer([:positive])}")

      keys = [:base_path]
      previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
      Application.put_env(:arca, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        for {key, value} <- previous do
          if value,
            do: Application.put_env(:arca, key, value),
            else: Application.delete_env(:arca, key)
        end
      end)

      Sandbox.stop_work_on_exit()

      ctx = Sanctum.TestContext.local()
      :ok = Probe.publish_probe!(ctx)
      {:ok, _minted} = Bootstrap.run(ctx)
      {:ok, ctx: ctx, seen: seen}
    end

    test "a runner left busy is ended and the fresh ones stay pooled", %{ctx: ctx, seen: seen} do
      root_id = Prima.UUID7.execution_id()
      TwoServices.hold!(:tool_call, root_id, once: true)

      spawn(fn ->
        Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), Probe.held_input(),
          execution_id: root_id
        )
      end)

      assert_receive {:held, ^root_id, _call}, 30_000

      runners = Opus.RunnerPool.runners(Opus.RunnerPool)
      assert [%{id: busy}] = for(%{state: :busy} = runner <- runners, do: runner)
      fresh = for %{state: :fresh, id: id} <- runners, do: id
      Agent.update(seen, fn _ -> %{busy: busy, fresh: fresh} end)
    end
  end

  # The dynamic supervisors a sweep stops the children of.
  defp swept_by_stopping, do: repository_dynamic_supervisors() -- Sandbox.pooled()

  # A child that, told to stop, runs one query and reports how it went.
  defp last_query_child(name, collector) do
    %{
      id: name,
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             Process.flag(:trap_exit, true)

             receive do
               {:EXIT, _supervisor, _reason} -> send(collector, {:report, name, last_query()})
             end
           end
         ]}
    }
  end

  defp last_query do
    Ecto.Adapters.SQL.query(Arca.Repo, "SELECT 1", [])
  rescue
    error -> {:error, error}
  end

  defp collect(reports) do
    receive do
      {:report, name, result} -> collect(Map.put(reports, name, result))
      {:reports, from} -> send(from, {:reports, reports})
    end
  end

  # The name of every dynamic supervisor in the trees of the started
  # applications whose callback module is this repository's source.
  defp repository_modules?(modules) when is_list(modules) and modules != [] do
    Enum.all?(modules, fn module ->
      source = Code.ensure_loaded?(module) && Keyword.get(module.module_info(:compile), :source)
      is_list(source) and String.starts_with?(List.to_string(source), @apps_root)
    end)
  end

  defp repository_modules?(_modules), do: false

  defp repository_dynamic_supervisors do
    for {app, _description, _vsn} <- Application.started_applications(),
        {module, _args} <- [Application.spec(app, :mod)],
        source = Keyword.get(module.module_info(:compile), :source),
        source && String.starts_with?(List.to_string(source), @apps_root),
        {:ok, top} <- [:application.get_supervisor(app)],
        pid <- dynamic_supervisors(top) do
      case Process.info(pid, :registered_name) do
        {:registered_name, name} when is_atom(name) and name != [] -> name
        _ -> flunk("an unnamed dynamic supervisor cannot be swept: #{inspect(pid)}")
      end
    end
  end

  # The tree the repository builds is walked: its `Supervisor.start_link/2`
  # groups, and a supervisor a module of the repository starts from a
  # function of its own (the Opus service tree). A library's own supervisor
  # is not descended into, and a dynamic supervisor's children are the work
  # a sweep stops.
  defp dynamic_supervisors(supervisor) do
    Enum.flat_map(Supervisor.which_children(supervisor), fn
      {_id, pid, :supervisor, modules} when is_pid(pid) ->
        cond do
          dynamic?(pid) -> [pid]
          modules == [Supervisor] or repository_modules?(modules) -> dynamic_supervisors(pid)
          true -> []
        end

      _worker ->
        []
    end)
  end

  # A `Task.Supervisor` is a `DynamicSupervisor` too.
  defp dynamic?(pid), do: match?(%DynamicSupervisor{}, :sys.get_state(pid))
end
