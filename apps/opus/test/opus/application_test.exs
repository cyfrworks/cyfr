# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ApplicationTest do
  @moduledoc """
  The engine's supervision tree is its own: the shared engine, its cache,
  its task supervisor, the worker service with its runners, and the
  listener CYFR reaches it through. Nothing of the control plane runs in
  it, and it reaches nothing of the control plane's.
  """

  use ExUnit.Case, async: true

  test "Opus.Supervisor supervises the engine's own processes, the service and its listener" do
    assert Process.whereis(Opus.Supervisor) != nil

    ids = for {id, _pid, _type, _modules} <- Supervisor.which_children(Opus.Supervisor), do: id

    for id <- [
          Opus.SharedEngine,
          Opus.Cache,
          Opus.TaskSupervisor,
          Opus.WorkerService.Tree,
          Opus.WorkerListener
        ] do
      assert id in ids, "#{inspect(id)} is not a child of Opus.Supervisor"
    end
  end

  test "the worker service and its runners' supervisor restart together" do
    ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Opus.WorkerService.Tree),
          do: id

    assert Enum.sort(ids) == Enum.sort([Opus.WorkerService, Opus.WorkerService.Runners])
    assert Supervisor.count_children(Opus.WorkerService.Tree).active == 2
  end

  test "the listener serves the worker routes on the address the credentials name" do
    %Opus.Credentials{bind: bind, port: 0} = Opus.Credentials.current()
    {_, pid, _, _} = List.keyfind(Supervisor.which_children(Opus.Supervisor), Opus.WorkerListener, 0)
    assert {:ok, {^bind, port}} = ThousandIsland.listener_info(pid)
    assert port > 0

    {:ok, %Req.Response{status: 401, body: body}} =
      Req.post("http://127.0.0.1:#{port}" <> Cyfr.WorkerWire.worker_route(:status),
        body: "{}",
        retry: false,
        decode_body: false
      )

    assert Jason.decode!(body) == %{"error" => "malformed"}
  end

  test "no control-plane process runs beside the engine" do
    for name <- [Arca.Repo, Cyfr.Execution.Semaphore, Cyfr.Execution.Tree, Cyfr.Supervisor] do
      refute Process.whereis(name), "#{inspect(name)} is running in the opus suite"
    end

    for app <- [:cyfr, :phoenix, :locus] do
      refute List.keymember?(Application.started_applications(), app, 0),
             "#{app} is started in the opus suite"
    end
  end
end
