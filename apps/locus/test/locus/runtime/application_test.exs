# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ApplicationTest do
  @moduledoc """
  The worker service's supervision tree is its own: the service with its
  keeper, its runner pool and the pool's handles, restarted together, and
  the listener CYFR reaches it through. Nothing of the control plane runs
  in it, and it reaches nothing of the control plane's. A service started
  without the cyfr-locus channel refuses to boot before it starts
  anything.
  """

  # Two cases replace the keeper setting and the process environment the
  # boot reads.
  use ExUnit.Case, async: false

  @locus_root Path.expand("../../..", __DIR__)
  @umbrella_root Path.expand("../../../../..", __DIR__)

  defp with_runtime_env(key, value, fun) do
    previous =
      if value == nil,
        do: Locus.Runtime.Test.Env.delete(key),
        else: Locus.Runtime.Test.Env.put(key, value)

    try do
      fun.()
    after
      Locus.Runtime.Test.Env.restore(previous, [key])
    end
  end

  defp with_system_env(name, value, fun) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end

  test "a service started without an inherited keeper channel refuses to boot, naming cyfr-locus" do
    supervisor = Process.whereis(Locus.Runtime.Supervisor)

    with_system_env("KEEPER_CHANNEL", nil, fn ->
      with_runtime_env(:keeper, :channel, fn ->
        error = assert_raise ArgumentError, fn -> Locus.Runtime.start_service() end
        assert Exception.message(error) =~ "Locus.Runtime.Keeper.Channel cannot run here"
        assert Exception.message(error) =~ "only through cyfr-locus"
        assert Exception.message(error) =~ "KEEPER_CHANNEL"
      end)

      # Unset is the channel keeper too: nothing falls back to a keeper
      # that isolates nothing.
      with_runtime_env(:keeper, nil, fn ->
        assert_raise ArgumentError, ~r/cyfr-locus/, fn -> Locus.Runtime.start_service() end
      end)
    end)

    assert_raise ArgumentError, ~r/only through cyfr-locus/, fn ->
      Locus.Runtime.keeper!(%{keeper: :channel, attach_dir: "/run/locus"}, %{})
    end

    # The refusal came before anything was started.
    assert Process.whereis(Locus.Runtime.Supervisor) == supervisor
  end

  test "the direct keeper is compiled from the test support alone and named by the test configuration alone" do
    refute File.exists?(Path.join(@locus_root, "lib/locus/runtime/keeper/direct.ex"))
    assert File.exists?(Path.join(@locus_root, "test/support/runtime/direct_keeper.ex"))
    assert Locus.Runtime.Keeper.direct_keeper() == Locus.Runtime.Keeper.Direct

    mix = File.read!(Path.join(@locus_root, "mix.exs"))
    assert mix =~ ~S|defp elixirc_paths(:test), do: ["lib", "test/support"]|
    assert mix =~ ~S|defp elixirc_paths(_), do: ["lib"]|
    assert mix =~ ~S|defp env(_env), do: []|
    refute mix =~ "Keeper.Direct,"

    # The test configuration names it, inside the test environment's block
    # in the app's own configuration, and nothing a release reads does.
    standalone = File.read!(Path.join(@locus_root, "config/config.exs"))
    [_before, test_block] = String.split(standalone, "if config_env() == :test do", parts: 2)
    assert test_block =~ "direct_keeper: Locus.Runtime.Keeper.Direct"

    if File.exists?(Path.join(@umbrella_root, "config/test.exs")) do
      assert File.read!(Path.join(@umbrella_root, "config/test.exs")) =~
               "direct_keeper: Locus.Runtime.Keeper.Direct"

      for file <- ~w(config.exs dev.exs prod.exs runtime.exs locus_runtime.exs),
          path = Path.join(@umbrella_root, "config/" <> file),
          File.exists?(path) do
        refute File.read!(path) =~ "Keeper.Direct", "config/#{file} names the direct keeper"
      end
    end

    named =
      for path <- Path.wildcard(Path.join(@locus_root, "lib/**/*.ex")),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ "Keeper.Direct",
          do: "#{Path.relative_to(path, @locus_root)}:#{n}"

    assert named == []
  end

  test "Locus.Runtime.Supervisor supervises the service and its listener" do
    assert Process.whereis(Locus.Runtime.Supervisor) != nil

    ids =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Locus.Runtime.Supervisor),
          do: id

    for id <- [Locus.Runtime.WorkerService.Tree, Locus.Runtime.WorkerListener] do
      assert id in ids, "#{inspect(id)} is not a child of Locus.Runtime.Supervisor"
    end
  end

  test "the worker service, its keeper, its pool and the pool's handles restart together" do
    ids =
      for {id, _pid, _type, _modules} <-
            Supervisor.which_children(Locus.Runtime.WorkerService.Tree),
          do: id

    assert Enum.sort(ids) ==
             Enum.sort([
               Locus.Runtime.Keeper.Direct,
               Locus.Runtime.RunnerPool.Runners,
               Locus.Runtime.RunnerPool,
               Locus.Runtime.WorkerService
             ])

    assert Supervisor.count_children(Locus.Runtime.WorkerService.Tree).active == 4
  end

  test "the listener serves the worker routes on the address the credentials name" do
    %Locus.Runtime.Credentials{bind: bind, port: 0} = Locus.Runtime.Credentials.current()

    {_, pid, _, _} =
      List.keyfind(
        Supervisor.which_children(Locus.Runtime.Supervisor),
        Locus.Runtime.WorkerListener,
        0
      )

    assert {:ok, {^bind, port}} = ThousandIsland.listener_info(pid)
    assert port > 0

    {:ok, %Req.Response{status: 401, body: body}} =
      Req.post("http://127.0.0.1:#{port}" <> Prima.WorkerWire.worker_route(:status),
        body: "{}",
        retry: false,
        decode_body: false
      )

    assert Jason.decode!(body) == %{"v" => 1, "error" => "malformed"}
  end

  test "the engine depends on and supervises nothing of the control plane" do
    for app <- [:cyfr, :phoenix, :ecto, :arca, :sanctum] do
      refute app in Application.spec(:locus, :applications),
             "#{app} is an application Locus starts"
    end

    for {_id, pid, _type, modules} <- Supervisor.which_children(Locus.Runtime.Supervisor),
        module <- modules,
        is_atom(module) do
      assert module == Locus.Runtime or
               String.starts_with?(Atom.to_string(module), "Elixir.Locus.Runtime.") or
               module in [Bandit, DynamicSupervisor, Supervisor, Task.Supervisor],
             "#{inspect(module)} (#{inspect(pid)}) runs under Locus.Runtime.Supervisor"
    end
  end
end
