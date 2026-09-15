# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SandboxTest do
  @moduledoc """
  A sync test's background work is stopped before its sandbox owner is:
  every dynamic supervisor this repository's applications start is swept,
  and each child's last database work lands while the owner still holds
  the connection.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.Sandbox

  @apps_root Path.expand("../../..", __DIR__) <> "/"

  test "every dynamic supervisor the repository's running applications start is swept" do
    running = repository_dynamic_supervisors()
    assert running != []
    assert Enum.sort(running) == Enum.sort(Enum.filter(Sandbox.supervisors(), &Process.whereis/1))
  end

  describe "a sync test's work" do
    setup do
      collector = spawn(fn -> collect(%{}) end)

      # Registered before the sandbox, so it runs after the owner is gone.
      on_exit(fn ->
        send(collector, {:reports, self()})
        assert_receive {:reports, reports}, 5_000

        for name <- repository_dynamic_supervisors() do
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
      for name <- repository_dynamic_supervisors() do
        assert {:ok, _child} =
                 DynamicSupervisor.start_child(name, last_query_child(name, collector))
      end
    end
  end

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

  # The tree the repository builds from `Supervisor.start_link/2` groups is
  # walked; a library's own supervisor is not descended into, and a dynamic
  # supervisor's children are the work a sweep stops.
  defp dynamic_supervisors(supervisor) do
    Enum.flat_map(Supervisor.which_children(supervisor), fn
      {_id, pid, :supervisor, modules} when is_pid(pid) ->
        cond do
          dynamic?(pid) -> [pid]
          modules == [Supervisor] -> dynamic_supervisors(pid)
          true -> []
        end

      _worker ->
        []
    end)
  end

  # A `Task.Supervisor` is a `DynamicSupervisor` too.
  defp dynamic?(pid), do: match?(%DynamicSupervisor{}, :sys.get_state(pid))
end
