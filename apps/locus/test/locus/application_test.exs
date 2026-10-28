# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ApplicationTest do
  @moduledoc """
  What a Locus node starts, and when it refuses to: a node serves the
  runtime, builds, backends, builds and backends, or nothing by the keys
  it holds, and refuses to hold the runtime's key beside either other
  key; one started by cyfr-locus starts its one client before every role
  it serves, the runtime's included; one that serves builds or backends
  does so under cyfr-locus, or, in a build that does not know the direct
  launcher (every build but the test environment's), not at all.
  """

  # Replaces the logger's level and default formatter for one test.
  use ExUnit.Case, async: false

  alias Locus.Application, as: App

  @release_launcher nil
  @none %{runtime: false, builds: false, backends: false}
  @runtime %{runtime: true, builds: false, backends: false}
  @builds %{runtime: false, builds: true, backends: false}
  @backends %{runtime: false, builds: false, backends: true}
  @both %{runtime: false, builds: true, backends: true}
  @backends_children [
    Locus.Backends.Owners,
    DynamicSupervisor,
    Locus.Backends.LeaseSweeper,
    Bandit
  ]

  defp ids(children) do
    Enum.map(children, fn
      {module, _opts} -> module
      %{id: id} -> id
      module when is_atom(module) -> module
    end)
  end

  test "a node holding the runtime key and the builds key refuses to boot, naming both" do
    error =
      assert_raise ArgumentError, fn ->
        App.roles!(%{runtime: true, builds: true, backends: false})
      end

    assert Exception.message(error) =~ "LOCUS_RUNTIME_KEY"
    assert Exception.message(error) =~ "LOCUS_BUILDS_KEY"
    refute Exception.message(error) =~ "LOCUS_BACKENDS_KEY"
  end

  test "a node holding the runtime key and the backends key refuses to boot, naming both" do
    error =
      assert_raise ArgumentError, fn ->
        App.roles!(%{runtime: true, builds: false, backends: true})
      end

    assert Exception.message(error) =~ "LOCUS_RUNTIME_KEY"
    assert Exception.message(error) =~ "LOCUS_BACKENDS_KEY"
    refute Exception.message(error) =~ "LOCUS_BUILDS_KEY"

    # All three keys: the refusal names every key held beside the runtime's.
    error =
      assert_raise ArgumentError, fn ->
        App.roles!(%{runtime: true, builds: true, backends: true})
      end

    assert Exception.message(error) =~ "LOCUS_BUILDS_KEY and LOCUS_BACKENDS_KEY"
  end

  test "a builds-and-backends node still boots, and the runtime alone is served" do
    assert App.roles!(@both) == @both
    assert ids(App.children(@both, true, @release_launcher)) |> hd() == Prima.Slots

    for roles <- [@none, @runtime, @builds, @backends] do
      assert App.roles!(roles) == roles
    end
  end

  test "a runtime node started by cyfr-locus starts the one client of it before the runtime's supervisor" do
    for launcher <- [Locus.Executor.direct_launcher(), @release_launcher] do
      assert ids(App.children(@runtime, true, launcher)) == [
               Prima.Slots,
               Locus.Keeper,
               Locus.Runtime.Supervisor
             ]

      # Its runners' relays attach where the runtime's settings say.
      assert {Locus.Keeper, opts} = Enum.at(App.children(@runtime, true, launcher), 1)
      assert opts[:attach_dir] == Locus.Runtime.Settings.pool!().attach_dir

      # A test boot holds no channel: its runtime runs on the direct keeper,
      # and no client starts.
      assert ids(App.children(@runtime, false, launcher)) == [
               Prima.Slots,
               Locus.Runtime.Supervisor
             ]
    end

    assert [
             %{
               id: Locus.Runtime.Supervisor,
               type: :supervisor,
               start: {Locus.Runtime, :start_service, []}
             }
           ] =
             Locus.Runtime.children(:service)
  end

  test "a node that holds neither key serves nothing, whoever started it" do
    assert ids(App.children(@none, false)) == [Prima.Slots]
    assert ids(App.children(@none, true)) == [Prima.Slots, Locus.Keeper]
    assert ids(App.children(@none, false, @release_launcher)) == [Prima.Slots]
  end

  test "a node that serves under cyfr-locus starts the keeper's client before the services that depend on it" do
    for launcher <- [Locus.Executor.direct_launcher(), @release_launcher] do
      assert ids(App.children(@builds, true, launcher)) == [Prima.Slots, Locus.Keeper, Bandit]

      assert ids(App.children(@backends, true, launcher)) ==
               [Prima.Slots, Locus.Keeper | @backends_children]

      # Both services on one node: the backends' children after the builds'.
      assert ids(App.children(@both, true, launcher)) ==
               [Prima.Slots, Locus.Keeper, Bandit | @backends_children]
    end
  end

  test "the backends children are the owners, the backend supervisor, the tick and the listener" do
    assert [
             {Locus.Backends.Owners, owners},
             {DynamicSupervisor, supervisor},
             {Locus.Backends.LeaseSweeper, sweeper},
             {Bandit, listener}
           ] = Locus.Backends.children()

    assert owners[:name] == Locus.Backends.Owners
    assert supervisor[:name] == Locus.Backends.BackendSupervisor
    assert sweeper[:owners] == Locus.Backends.Owners
    assert listener[:plug] == Locus.Backends.Service
    assert listener[:ip] == Locus.Config.backends_bind()
    assert listener[:port] == Locus.Config.backends_port()
    assert listener[:http_2_options] == [enabled: false]
    refute listener[:port] == Locus.Config.port()
  end

  test "serving without cyfr-locus refuses the boot wherever the direct launcher is unknown" do
    assert_raise RuntimeError,
                 ~r/every build and every backend only through cyfr-locus.*fd 3 is not that channel.*--pool build:… --/s,
                 fn -> App.children(@builds, false, @release_launcher) end

    assert_raise RuntimeError,
                 ~r/fd 3 is not that channel.*`cyfr-locus serve --pool backends:… --/s,
                 fn -> App.children(@backends, false, @release_launcher) end

    assert_raise RuntimeError,
                 ~r/--pool build:… --pool backends:… --/s,
                 fn -> App.children(@both, false, @release_launcher) end

    # The test build knows the launcher, and serves through it.
    assert Locus.Executor.direct_launcher() == Locus.DirectLauncher
    assert ids(App.children(@builds, false)) == [Prima.Slots, Bandit]
    assert ids(App.children(@backends, false)) == [Prima.Slots | @backends_children]
    assert ids(App.children(@both, false)) == [Prima.Slots, Bandit | @backends_children]
  end

  test "both services' nonce tables exist before the tree, owned by the application" do
    children =
      for {_id, pid, _type, _modules} <- Supervisor.which_children(Locus.Supervisor), do: pid

    for table <- [Locus.BuilderService.Nonces, Locus.Backends.Service.Nonces] do
      assert :ets.whereis(table) != :undefined
      # Neither a listener's restart nor the tree's forgets what it holds.
      owner = :ets.info(table, :owner)
      refute owner in children
      refute owner == Process.whereis(Locus.Supervisor)
    end
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
