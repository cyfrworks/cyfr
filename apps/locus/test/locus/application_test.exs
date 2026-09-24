# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ApplicationTest do
  @moduledoc """
  What the builder starts, and when it refuses to: a node without a builds
  key serves nothing; one that serves does so under cyfr-spawn, or, in a
  build that does not know the direct launcher (every build but the test
  environment's), not at all.
  """

  # Replaces the logger's level and default formatter for one test.
  use ExUnit.Case, async: false

  alias Locus.Application, as: App

  @release_executors [Locus.Spawner]

  defp ids(children) do
    Enum.map(children, fn
      {module, _opts} -> module
      module when is_atom(module) -> module
    end)
  end

  test "a node that holds no builds key serves nothing, whoever started it" do
    assert ids(App.children(false, false)) == [Prima.Slots]
    assert ids(App.children(false, true)) == [Prima.Slots, Locus.Spawner]
    assert ids(App.children(false, false, @release_executors)) == [Prima.Slots]
  end

  test "a node that serves under cyfr-spawn starts the spawner before the listener that depends on it" do
    for executors <- [Locus.Executor.executors(), @release_executors] do
      assert ids(App.children(true, true, executors)) == [Prima.Slots, Locus.Spawner, Bandit]
    end
  end

  test "serving without cyfr-spawn refuses the boot wherever the direct launcher is unknown" do
    assert_raise RuntimeError,
                 ~r/runs a build only through cyfr-spawn.*fd 3 is not that channel/s,
                 fn -> App.children(true, false, @release_executors) end

    # The test build knows the launcher, and serves through it.
    assert Locus.DirectLauncher in Locus.Executor.executors()
    assert ids(App.children(true, false)) == [Prima.Slots, Bandit]
  end

  test "the running tree restarts a child with everything started after it" do
    # OTP's supervisor state record: {:state, name, strategy, ...}.
    assert Locus.Supervisor |> :sys.get_state() |> elem(2) == :rest_for_one
  end

  test "the build slots take their caps from the builder's settings and refuse, never queue" do
    assert {Prima.Slots, opts} = App.build_slots()
    assert opts[:name] == Locus.BuildSlots
    assert opts[:max] == Locus.Config.max_concurrent()
    assert opts[:key_max] == Locus.Config.max_concurrent_per_tenant()
    assert opts[:policy] == :reject
    assert opts[:child_reserve] == 0

    Application.put_env(:locus, :max_concurrent, 5)
    Application.put_env(:locus, :max_concurrent_per_tenant, 3)

    on_exit(fn ->
      Application.delete_env(:locus, :max_concurrent)
      Application.delete_env(:locus, :max_concurrent_per_tenant)
    end)

    assert {Prima.Slots, opts} = App.build_slots()
    assert {opts[:max], opts[:key_max]} == {5, 3}
  end

  test "the listener serves the builds service on the configured address, over HTTP/1.1 alone" do
    assert {Bandit, opts} = App.listener()
    assert opts[:plug] == Locus.BuilderService
    assert opts[:ip] == Locus.Config.bind()
    assert opts[:port] == Locus.Config.port()
    assert opts[:http_2_options] == [enabled: false]

    assert {Bandit, opts} = App.listener(ip: {127, 0, 0, 1}, port: 0)
    assert {opts[:ip], opts[:port]} == {{127, 0, 0, 1}, 0}
  end

  test "the log level and format the settings name are the logger's once applied" do
    level = Logger.level()
    {:ok, %{formatter: formatter}} = :logger.get_handler_config(:default)

    on_exit(fn ->
      Logger.configure(level: level)
      :logger.update_handler_config(:default, :formatter, formatter)
      Application.delete_env(:locus, :log_level)
      Application.delete_env(:locus, :log_format)
    end)

    Application.put_env(:locus, :log_level, :error)
    Application.put_env(:locus, :log_format, :json)
    assert :ok = App.configure_logging()

    assert Logger.level() == :error
    assert {:ok, %{formatter: {Logger.Formatter, config}}} = :logger.get_handler_config(:default)
    assert inspect(config) =~ "Prima.JsonFormatter"

    # Text leaves the handler's formatter as it was configured.
    :logger.update_handler_config(:default, :formatter, formatter)
    Application.put_env(:locus, :log_format, :text)
    assert :ok = App.configure_logging()
    assert {:ok, %{formatter: ^formatter}} = :logger.get_handler_config(:default)
  end
end
