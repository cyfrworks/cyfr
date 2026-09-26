# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ApplicationTest do
  @moduledoc """
  The worker service's supervision tree is its own: the service with its
  keeper, its runner pool and the pool's handles, restarted together, and
  the listener CYFR reaches it through. Nothing of the control plane runs
  in it, and it reaches nothing of the control plane's. A service started
  without the cyfr-keeper channel, or with the retired `OPUS_KEEPER` set,
  refuses to boot before it starts anything.
  """

  # Two cases replace the keeper setting and the process environment the
  # boot reads.
  use ExUnit.Case, async: false

  @opus_root Path.expand("../..", __DIR__)

  defp with_opus_env(key, value, fun) do
    previous = Application.fetch_env(:opus, key)
    Application.put_env(:opus, key, value)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:opus, key, value)
        :error -> Application.delete_env(:opus, key)
      end
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

  test "a service started without an inherited keeper channel refuses to boot, naming cyfr-keeper" do
    supervisor = Process.whereis(Opus.Supervisor)

    with_system_env("KEEPER_CHANNEL", nil, fn ->
      with_opus_env(:keeper, :channel, fn ->
        error = assert_raise ArgumentError, fn -> Opus.Application.start(:normal, []) end
        assert Exception.message(error) =~ "Opus.Keeper.Channel cannot run here"
        assert Exception.message(error) =~ "only through cyfr-keeper"
        assert Exception.message(error) =~ "KEEPER_CHANNEL"
      end)

      # Unset is the channel keeper too: nothing falls back to a keeper
      # that isolates nothing.
      with_opus_env(:keeper, nil, fn ->
        assert_raise ArgumentError, ~r/cyfr-keeper/, fn -> Opus.Application.start(:normal, []) end
      end)
    end)

    assert_raise ArgumentError, ~r/only through cyfr-keeper/, fn ->
      Opus.Application.keeper!(%{keeper: :channel, attach_dir: "/run/opus"}, %{})
    end

    # The refusal came before anything was started.
    assert Process.whereis(Opus.Supervisor) == supervisor
  end

  test "a service that finds OPUS_KEEPER set refuses to boot, naming it retired" do
    for value <- ["direct", "channel", ""] do
      with_system_env("OPUS_KEEPER", value, fn ->
        assert_raise ArgumentError, ~r/OPUS_KEEPER is retired/, fn ->
          Opus.Application.start(:normal, [])
        end
      end)
    end
  end

  test "the direct keeper is compiled from the test support alone and named by the test build's environment" do
    refute File.exists?(Path.join(@opus_root, "lib/opus/keeper/direct.ex"))
    assert File.exists?(Path.join(@opus_root, "test/support/direct_keeper.ex"))
    assert Opus.Keeper.direct_keeper() == Opus.Keeper.Direct

    mix = File.read!(Path.join(@opus_root, "mix.exs"))
    assert mix =~ ~S|defp elixirc_paths(:test), do: ["lib", "test/support"]|
    assert mix =~ ~S|defp elixirc_paths(_), do: ["lib"]|
    assert mix =~ "direct_keeper: Opus.Keeper.Direct,"
    assert mix =~ ~S|defp env(_env), do: []|

    named =
      for path <- Path.wildcard(Path.join(@opus_root, "lib/**/*.ex")),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ "Keeper.Direct",
          do: "#{Path.relative_to(path, @opus_root)}:#{n}"

    assert named == []
  end

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

    assert Jason.decode!(body) == %{"v" => 1, "error" => "malformed"}
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
