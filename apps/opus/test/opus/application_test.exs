# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ApplicationTest do
  @moduledoc """
  The worker service's supervision tree is its own: the service with its
  keeper, its runner pool and the pool's handles, restarted together, and
  the listener CYFR reaches it through. Nothing of the control plane runs
  in it, and it reaches nothing of the control plane's.
  """

  use ExUnit.Case, async: true

  test "Opus.Supervisor supervises the service and its listener" do
    assert Process.whereis(Opus.Supervisor) != nil

    ids = for {id, _pid, _type, _modules} <- Supervisor.which_children(Opus.Supervisor), do: id

    for id <- [Opus.WorkerService.Tree, Opus.WorkerListener] do
      assert id in ids, "#{inspect(id)} is not a child of Opus.Supervisor"
    end
  end

  test "the worker service, its keeper, its pool and the pool's handles restart together" do
    ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Opus.WorkerService.Tree),
          do: id

    assert Enum.sort(ids) ==
             Enum.sort([
               Opus.Keeper.Direct,
               Opus.RunnerPool.Runners,
               Opus.RunnerPool,
               Opus.WorkerService
             ])

    assert Supervisor.count_children(Opus.WorkerService.Tree).active == 4
  end

  test "the listener serves the worker routes on the address the credentials name" do
    %Opus.Credentials{bind: bind, port: 0} = Opus.Credentials.current()

    {_, pid, _, _} =
      List.keyfind(Supervisor.which_children(Opus.Supervisor), Opus.WorkerListener, 0)

    assert {:ok, {^bind, port}} = ThousandIsland.listener_info(pid)
    assert port > 0

    {:ok, %Req.Response{status: 401, body: body}} =
      Req.post("http://127.0.0.1:#{port}" <> Prima.WorkerWire.worker_route(:status),
        body: "{}",
        retry: false,
        decode_body: false
      )

    assert Jason.decode!(body) == %{"error" => "malformed"}
  end

  test "the engine depends on and supervises nothing of the control plane" do
    for app <- [:cyfr, :phoenix, :ecto, :locus] do
      refute app in Application.spec(:opus, :applications),
             "#{app} is an application Opus starts"
    end

    for {_id, pid, _type, modules} <- Supervisor.which_children(Opus.Supervisor),
        module <- modules,
        is_atom(module) do
      assert String.starts_with?(Atom.to_string(module), "Elixir.Opus.") or
               module in [Bandit, DynamicSupervisor, Supervisor, Task.Supervisor],
             "#{inspect(module)} (#{inspect(pid)}) runs under Opus.Supervisor"
    end
  end
end
