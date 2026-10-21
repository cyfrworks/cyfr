# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ConfigTest do
  @moduledoc """
  A Locus node's settings come from the roster's `LOCUS_RUNTIME_*`,
  `LOCUS_BUILDS_*`, `LOCUS_BACKENDS_*` and `LOCUS_LOG_*` rows and nothing
  else: a node asks its environment for those names and the control
  plane's and no other, a full valid environment produces the documented
  settings, any one role's key alone is enough and none refuses, every
  malformed value refuses with a message naming its variable, and any of
  the control plane's variables in the environment refuses before
  anything else is read, whichever role the node serves, naming no value.
  The runtime's rows read into its `:runtime` keyword, or into nothing
  without its key; a runner's settings come from its `RUNTIME_*` rows
  alone, outside every prefix the keeper refuses in a spawn, and a runner
  that can see the service's key refuses to start. Every memory bound
  takes the keeper's range, read from `Prima.KeeperProtocol`. Where the
  environment was never read, every accessor answers its default and no
  key is held.
  """
  use ExUnit.Case, async: true

  alias Locus.Config

  @key_hex "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"
  @key Base.decode16!(@key_hex, case: :lower)
  @backends_key_hex "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
  @backends_key Base.decode16!(@backends_key_hex, case: :lower)
  @runtime_key_hex String.duplicate("ab", 32)

  # The control plane's own variables, in the list's order: a copy, so the
  # list cannot shrink without this suite noticing.
  @control_plane ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_LOCUS_RUNTIME_ROOT
                    CYFR_LOCUS_BUILDS_KEY CYFR_LOCUS_BACKENDS_KEY)

  # What a control-plane variable might hold: a key, which no refusal shows.
  @planted String.duplicate("5a", 32)

  # The one prefix each role's names carry.
  @prefixes %{
    runtime: "LOCUS_RUNTIME_",
    builds: "LOCUS_BUILDS_",
    backends: "LOCUS_BACKENDS_",
    release: "LOCUS_LOG_",
    runner: "RUNTIME_"
  }

  @runner_env %{
    "RUNTIME_RUNNER_ID" => "runner_1",
    "RUNTIME_SERVICE_ID" => "wrk_local",
    "RUNTIME_BOOT_ID" => "nonode@nohost#boot_1"
  }

  @backends_defaults [
    backends_key: nil,
    backends_bind: {0, 0, 0, 0},
    backends_port: 4101,
    backends_max_in_flight: 32,
    backends_init_timeout_ms: 15_000,
    backends_rpc_timeout_ms: 30_000,
    backends_memory_bytes: 536_870_912
  ]

  defp env(map), do: fn key -> Map.get(map, key) end

  # An environment that tells this test process every name it is asked.
  defp recording(map) do
    test = self()

    fn key ->
      send(test, {:asked, key})
      Map.get(map, key)
    end
  end

  # Every name asked since the last call, each once, sorted.
  defp asked, do: asked([])

  defp asked(names) do
    receive do
      {:asked, name} -> asked([name | names])
    after
      0 -> names |> Enum.uniq() |> Enum.sort()
    end
  end

  defp full do
    %{
      "LOCUS_BUILDS_KEY" => @key_hex,
      "LOCUS_BUILDS_BIND" => "127.0.0.1",
      "LOCUS_BUILDS_PORT" => "4101",
      "LOCUS_BUILDS_TIMEOUT_MS" => "60000",
      "LOCUS_BUILDS_MAX_CONCURRENT" => "4",
      "LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT" => "2",
      "LOCUS_BUILDS_MEMORY_BYTES" => "2147483648",
      "LOCUS_BUILDS_CARGO_SEED" => "/opt/cyfr/cargo-seed",
      "LOCUS_LOG_LEVEL" => "debug",
      "LOCUS_LOG_FORMAT" => "json",
      "LOCUS_BACKENDS_KEY" => @backends_key_hex,
      "LOCUS_BACKENDS_BIND" => "127.0.0.2",
      "LOCUS_BACKENDS_PORT" => "4201",
      "LOCUS_BACKENDS_MAX_IN_FLIGHT" => "8",
      "LOCUS_BACKENDS_INIT_TIMEOUT_MS" => "20000",
      "LOCUS_BACKENDS_RPC_TIMEOUT_MS" => "45000",
      "LOCUS_BACKENDS_MEMORY_BYTES" => "268435456"
    }
  end

  describe "the roster" do
    test "a node asks its environment for the roster's names and the control plane's, and no other" do
      environment =
        Map.merge(full(), %{
          "LOCUS_RUNTIME_KEY" => @runtime_key_hex,
          "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
        })

      _ = asked()
      assert {:ok, settings} = Config.from_env(recording(environment), Map.keys(environment))

      # Each role was read whole: its key is held.
      assert settings[:request_key] != nil and settings[:backends_key] == @backends_key
      assert settings[:runtime][:service_key] == @runtime_key_hex

      assert asked() ==
               Enum.sort(
                 @control_plane ++
                   Config.variables(:runtime) ++
                   Config.variables(:builds) ++
                   Config.variables(:release) ++ Config.variables(:backends)
               )

      # The runtime's reader asks for the runtime's rows and nothing else.
      assert {:ok, [_ | _]} = Config.runtime_from_env(recording(environment), [])
      assert asked() == Enum.sort(Config.variables(:runtime))
    end

    test "every name is one role's, under the role's one prefix, and none is unknown" do
      by_role = Enum.flat_map(Map.keys(@prefixes), &Config.variables/1)

      assert Enum.sort(by_role) == Enum.sort(Config.variables())
      assert Enum.uniq(Config.variables()) == Config.variables()

      for {role, prefix} <- @prefixes, name <- Config.variables(role) do
        assert String.starts_with?(name, prefix), "#{name} is #{role}'s, outside #{prefix}"
      end

      assert Config.unknown_names(Config.variables()) == []

      for {role, _prefix} <- @prefixes do
        assert Config.unknown_names(Config.variables(), role) == []
      end

      # A runner's names carry no prefix the keeper refuses in a spawn.
      for name <- Config.variables(:runner),
          prefix <- Prima.KeeperProtocol.reserved_env_prefixes() do
        refute String.starts_with?(name, prefix), "#{name} carries #{prefix}"
      end

      # One role's undeclared names, under its prefix alone.
      assert Config.unknown_names(
               ["LOCUS_RUNTIME_POOL_SIZ", "LOCUS_BUILDS_X", "RUNTIME_X", "LOCUS_RUNTIME_KEY"],
               :runtime
             ) == ["LOCUS_RUNTIME_POOL_SIZ"]
    end

    # A reader fetches its name by role and key, so two rows of one role
    # under one key would leave one of them read by no reader.
    test "no two rows share a variable, and no two rows of one role share a key" do
      rows = roster_rows()

      # The rows read from the source are the roster the module answers.
      assert Enum.map(rows, &elem(&1, 0)) == Config.variables()

      shared_variables =
        for {variable, count} <- Enum.frequencies_by(rows, &elem(&1, 0)), count > 1, do: variable

      assert shared_variables == [], "rows share these variables: #{inspect(shared_variables)}"

      shared_keys =
        for {role_key, count} <-
              Enum.frequencies_by(rows, fn {_variable, role, key} -> {role, key} end),
            count > 1,
            do: role_key

      assert shared_keys == [], "rows of one role share these keys: #{inspect(shared_keys)}"
    end
  end

  # The roster's `{variable, role, key}` rows, as `config.ex` spells them.
  defp roster_rows do
    {_ast, rows} =
      Path.expand("../../lib/locus/config.ex", __DIR__)
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(nil, fn
        {:@, _, [{:roster, _, [rows]}]} = node, nil -> {node, rows}
        node, rows -> {node, rows}
      end)

    assert is_list(rows), "config.ex holds no @roster"
    for {:{}, _, [variable, role, key]} <- rows, do: {variable, role, key}
  end

  test "a full valid environment produces the documented settings, holding the derived key only" do
    assert {:ok, settings} = Config.from_env(env(full()))

    assert settings == [
             request_key: Prima.BuilderProtocol.request_key(@key),
             bind: {127, 0, 0, 1},
             port: 4101,
             timeout_ms: 60_000,
             max_concurrent: 4,
             max_concurrent_per_tenant: 2,
             memory_bytes: 2_147_483_648,
             cargo_seed: "/opt/cyfr/cargo-seed",
             log_level: :debug,
             log_format: :json,
             backends_key: @backends_key,
             backends_bind: {127, 0, 0, 2},
             backends_port: 4201,
             backends_max_in_flight: 8,
             backends_init_timeout_ms: 20_000,
             backends_rpc_timeout_ms: 45_000,
             backends_memory_bytes: 268_435_456
           ]

    refute settings[:request_key] == @key
    refute inspect(settings) =~ @key_hex
    refute inspect(settings) =~ @backends_key_hex
  end

  test "the builds key alone is enough; everything else takes its default" do
    assert {:ok, settings} = Config.from_env(env(%{"LOCUS_BUILDS_KEY" => @key_hex}))

    assert settings ==
             [
               request_key: Prima.BuilderProtocol.request_key(@key),
               bind: {0, 0, 0, 0},
               port: 4100,
               timeout_ms: 270_000,
               max_concurrent: 2,
               max_concurrent_per_tenant: 1,
               memory_bytes: 1_073_741_824,
               cargo_seed: nil,
               log_level: :info,
               log_format: :text
             ] ++ @backends_defaults
  end

  test "the backends key alone is enough: the node serves backends and no builds" do
    assert {:ok, settings} = Config.from_env(env(%{"LOCUS_BACKENDS_KEY" => @backends_key_hex}))

    assert settings ==
             [
               request_key: nil,
               bind: {0, 0, 0, 0},
               port: 4100,
               timeout_ms: 270_000,
               max_concurrent: 2,
               max_concurrent_per_tenant: 1,
               memory_bytes: 1_073_741_824,
               cargo_seed: nil,
               log_level: :info,
               log_format: :text
             ] ++ Keyword.put(@backends_defaults, :backends_key, @backends_key)

    # The key is the service key itself: every owner's key derives from it.
    assert {:ok, _owner_key} =
             Prima.LocusBackends.owner_key(settings[:backends_key], %{
               athanor: "ath",
               server: "srv",
               generation: 1,
               epoch: 1
             })
  end

  test "the runtime's key alone is enough: the node serves the runtime and nothing else" do
    runtime_env = %{
      "LOCUS_RUNTIME_KEY" => @key_hex,
      "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300",
      "LOCUS_RUNTIME_BIND" => "0.0.0.0",
      "LOCUS_RUNTIME_PORT" => "4200"
    }

    assert {:ok, settings} = Config.from_env(env(runtime_env), Map.keys(runtime_env))
    assert settings[:request_key] == nil
    assert settings[:backends_key] == nil

    assert settings[:runtime] == [
             service_id: "wrk_local",
             service_key: @key_hex,
             host_url: "http://cyfr:4300",
             bind: "0.0.0.0",
             port: 4200
           ]

    # Without the runtime's key no runtime setting is written at all.
    assert {:ok, settings} = Config.from_env(env(%{"LOCUS_BUILDS_KEY" => @key_hex}))
    refute Keyword.has_key?(settings, :runtime)

    # A runtime value that does not parse refuses, naming its variable.
    assert {:error, message} =
             Config.from_env(env(Map.put(runtime_env, "LOCUS_RUNTIME_PORT", "http")))

    assert message =~ "LOCUS_RUNTIME_PORT"
  end

  test "none of the three keys refuses, naming each variable and their counterparts on the server" do
    assert {:error, message} = Config.from_env(env(%{}))
    assert message =~ "LOCUS_RUNTIME_KEY"
    assert message =~ "LOCUS_BUILDS_KEY"
    assert message =~ "LOCUS_BACKENDS_KEY"
    assert message =~ "CYFR_LOCUS_RUNTIME_ROOT"
    assert message =~ "CYFR_LOCUS_BUILDS_KEY"
    assert message =~ "CYFR_LOCUS_BACKENDS_KEY"

    assert {:error, ^message} =
             Config.from_env(
               env(%{
                 "LOCUS_RUNTIME_KEY" => " ",
                 "LOCUS_BUILDS_KEY" => "  ",
                 "LOCUS_BACKENDS_KEY" => ""
               })
             )
  end

  test "a malformed value refuses, naming its variable and the accepted form" do
    for {variable, bad, form} <- [
          {"LOCUS_BUILDS_KEY", "not-a-key", "64 hexadecimal digits"},
          {"LOCUS_BUILDS_KEY", String.slice(@key_hex, 0..62), "64 hexadecimal digits"},
          {"LOCUS_BUILDS_BIND", "builder", "IPv4 or IPv6 address"},
          {"LOCUS_BUILDS_PORT", "0", "port from 1 to 65535"},
          {"LOCUS_BUILDS_PORT", "http", "port from 1 to 65535"},
          {"LOCUS_BUILDS_TIMEOUT_MS", "999", "milliseconds from 1000 to 600000"},
          {"LOCUS_BUILDS_TIMEOUT_MS", "5m", "milliseconds from 1000 to 600000"},
          {"LOCUS_BUILDS_MAX_CONCURRENT", "0", "builds from 1 to 1024"},
          {"LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT", "1025", "builds from 1 to 1024"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "0", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "16777215", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "1099511627777", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "1G", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "1073741824.5", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "-1073741824", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "unlimited", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_LOG_LEVEL", "verbose", "Logger level"},
          {"LOCUS_LOG_FORMAT", "xml", "text or json"},
          {"LOCUS_BACKENDS_KEY", "not-a-key", "64 hexadecimal digits"},
          {"LOCUS_BACKENDS_BIND", "backends", "IPv4 or IPv6 address"},
          {"LOCUS_BACKENDS_PORT", "65536", "port from 1 to 65535"},
          {"LOCUS_BACKENDS_MAX_IN_FLIGHT", "0", "calls from 1 to 1024"},
          {"LOCUS_BACKENDS_MAX_IN_FLIGHT", "1025", "calls from 1 to 1024"},
          {"LOCUS_BACKENDS_INIT_TIMEOUT_MS", "999", "milliseconds from 1000 to 600000"},
          {"LOCUS_BACKENDS_RPC_TIMEOUT_MS", "600001", "milliseconds from 1000 to 600000"},
          {"LOCUS_BACKENDS_MEMORY_BYTES", "16777215", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BACKENDS_MEMORY_BYTES", "unlimited", "bytes from 16777216 to 1099511627776"}
        ] do
      assert {:error, message} = Config.from_env(env(Map.put(full(), variable, bad))), variable
      assert message =~ variable, message
      assert message =~ form, message
    end

    assert {:error, message} =
             Config.from_env(env(Map.put(full(), "LOCUS_BUILDS_KEY", "not-a-key")))

    refute message =~ "not-a-key"

    assert {:error, message} =
             Config.from_env(env(Map.put(full(), "LOCUS_BACKENDS_KEY", "not-a-key")))

    refute message =~ "not-a-key"
  end

  test "the memory bound takes the whole of the keeper's range, both ends, and nothing outside it" do
    # One range, the keeper protocol's.
    assert Config.memory_range() ==
             Prima.KeeperProtocol.min_memory_bytes()..Prima.KeeperProtocol.max_memory_bytes()//1

    assert Config.memory_range() == 16_777_216..1_099_511_627_776

    vectors =
      Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    # A spawn's own bound: a whole number refused for what it is, not for
    # the request it rides on, which carries a bound of its own.
    bounds = fn requests ->
      for %{
            "why" => "memory bound" <> _,
            "request" => %{"type" => "spawn", "memory_bytes" => bytes}
          } <-
            requests,
          is_integer(bytes),
          do: bytes
    end

    accepted =
      for %{"memory_bytes" => bytes} <- vectors["valid_requests"], do: bytes

    assert 16_777_216 in accepted and 1_099_511_627_776 in accepted

    runtime = %{
      "LOCUS_RUNTIME_KEY" => @runtime_key_hex,
      "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
    }

    # What the keeper accepts as a spawn's bound, this setting accepts.
    # The same for a build's bound, a backend's and a runner's.
    for {base, variable, read} <- [
          {full(), "LOCUS_BUILDS_MEMORY_BYTES", & &1[:memory_bytes]},
          {full(), "LOCUS_BACKENDS_MEMORY_BYTES", & &1[:backends_memory_bytes]},
          {runtime, "LOCUS_RUNTIME_MEMORY_BYTES", & &1[:runtime][:runner_memory_bytes]}
        ] do
      for bytes <- accepted do
        env = env(Map.put(base, variable, Integer.to_string(bytes)))
        assert {:ok, settings} = Config.from_env(env)
        assert read.(settings) == bytes
      end

      # And what the keeper refuses, this setting refuses at the boot.
      refused = bounds.(vectors["invalid_requests"])
      assert refused != []

      for bytes <- refused do
        env = env(Map.put(base, variable, Integer.to_string(bytes)))
        assert {:error, message} = Config.from_env(env)
        assert message =~ variable
      end
    end
  end

  # The release carries no host module, so the prefix is declared here.
  test "a LOCUS_* name the node does not read refuses the boot, naming it" do
    names = Map.keys(full()) ++ ["LOCUS_BUILDS_MAX_CONCURENT", "PATH"]

    assert {:error, message} = Config.from_env(env(full()), names)
    assert message =~ "LOCUS_BUILDS_MAX_CONCURENT is not a variable the locus release reads"
    assert message == Config.unknown(["LOCUS_BUILDS_MAX_CONCURENT"])

    assert Config.unknown_names(["LOCUS_B", "LOCUS_A", "LOCUS_A", "KEEPER_CHANNEL"]) ==
             ["LOCUS_A", "LOCUS_B"]

    assert Config.unknown_names(Config.variables()) == []
    assert {:ok, _settings} = Config.from_env(env(full()), Map.keys(full()))

    # The runtime role's names are the node's too, and the retired names
    # of the release's log setting are not.
    assert Config.unknown_names(Config.variables(:runtime) ++ Config.variables(:runner)) == []

    # Spelled split so the retired names are not themselves found here.
    retired = ["LOCUS_BUILDS_" <> "LOG_LEVEL", "LOCUS_BUILDS_" <> "LOG_FORMAT"]
    assert Config.unknown_names(retired) == Enum.sort(retired)

    assert {:error, message} =
             Config.from_env(env(full()), Map.keys(full()) ++ ["LOCUS_RUNTIME_POOL_SIZ"])

    assert message =~ "LOCUS_RUNTIME_POOL_SIZ is not a variable the locus release reads"

    # A runner's names are never refused as unknown.
    assert {:ok, _settings} =
             Config.from_env(env(full()), Map.keys(full()) ++ ["RUNTIME_PLANTED"])
  end

  # The one list every role's boot reads: no `RELEASE_NAME` is consulted.
  test "the control plane's five variables refuse a runtime node, each by name" do
    runtime = %{
      "LOCUS_RUNTIME_KEY" => @key_hex,
      "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
    }

    assert {:ok, _settings} = Config.from_env(env(runtime), Map.keys(runtime))
    refused_on(runtime)

    # The runtime's own variables and the rest of a process environment
    # are not the control plane's; every one of its five is, in order.
    assert Config.refused_environment(
             env(Map.merge(runtime, %{"PATH" => "/bin", "LOCUS_RUNTIME_PORT" => "4200"}))
           ) == []

    all =
      runtime
      |> Map.put("LOCUS_RUNTIME_PORT", "4200")
      |> Map.merge(Map.new(@control_plane, &{&1, @planted}))

    assert Config.refused_environment(env(all)) == @control_plane
  end

  test "the control plane's five variables refuse a builds node, each by name" do
    builds = %{"LOCUS_BUILDS_KEY" => @key_hex}
    assert {:ok, _settings} = Config.from_env(env(builds), Map.keys(builds))
    refused_on(builds)
  end

  test "the control plane's five variables refuse a backends node, each by name" do
    backends = %{"LOCUS_BACKENDS_KEY" => @backends_key_hex}
    assert {:ok, _settings} = Config.from_env(env(backends), Map.keys(backends))
    refused_on(backends)
  end

  defp refused_on(role_env) do
    refute Map.has_key?(role_env, "RELEASE_NAME")

    for variable <- @control_plane do
      with_variable = Map.put(role_env, variable, @planted)

      assert {:error, message} = Config.from_env(env(with_variable), Map.keys(with_variable)),
             variable

      assert message =~ variable
      assert message =~ "must not see"
      refute message =~ @planted
    end
  end

  test "a control-plane variable in the environment refuses the boot before anything else is read" do
    assert Config.refused_environment(fn _ -> "x" end) == @control_plane

    for variable <- @control_plane do
      assert Config.refused_environment(env(%{variable => @planted})) == [variable]

      assert {:error, message} = Config.from_env(env(Map.put(full(), variable, @planted)))
      assert message =~ variable
      assert message =~ "must not see"
      refute message =~ @planted

      # Refused first: with no key set the message is still about the control plane.
      assert {:error, ^message} = Config.from_env(env(%{variable => @planted}))
    end

    assert Config.refused_environment(env(full())) == []

    assert {:error, message} =
             Config.from_env(env(%{"CYFR_DATABASE_URL" => "x", "CYFR_LOCUS_RUNTIME_ROOT" => "y"}))

    assert message =~ "CYFR_DATABASE_URL, CYFR_LOCUS_RUNTIME_ROOT"
  end

  test "an unread environment leaves every accessor at its default and no key held" do
    assert Config.request_key() == nil
    assert Config.bind() == {0, 0, 0, 0}
    assert Config.port() == 4100
    assert Config.timeout_ms() == 270_000
    assert Config.max_concurrent() == 2
    assert Config.max_concurrent_per_tenant() == 1
    assert Config.memory_bytes() == 1_073_741_824
    assert Config.cargo_seed() == nil
    assert Config.log_level() == :info
    assert Config.log_format() == :text
    assert Config.log_formatter() == nil

    assert Config.backends_key() == nil
    assert Config.backends_bind() == {0, 0, 0, 0}
    assert Config.backends_port() == 4101
    assert Config.backends_max_in_flight() == Prima.LocusBackends.max_in_flight()
    assert Config.backends_init_timeout_ms() == 15_000
    assert Config.backends_rpc_timeout_ms() == 30_000
    assert Config.backends_memory_bytes() == 536_870_912

    # The facade reads the same settings.
    assert Locus.Backends.key() == Config.backends_key()
    assert Locus.Backends.port() == Config.backends_port()
    assert Locus.Backends.memory_bytes() == Config.backends_memory_bytes()
  end

  describe "runtime_from_env/2" do
    test "without the runtime's key, nothing: the node serves no runtime" do
      assert {:ok, nil} = Config.runtime_from_env(env(%{}), [])

      assert {:ok, nil} =
               Config.runtime_from_env(env(%{"LOCUS_RUNTIME_PORT" => "4200"}),
                 host_url: "http://h"
               )

      assert {:ok, nil} = Config.runtime_from_env(env(%{"LOCUS_RUNTIME_KEY" => "  "}), [])
    end

    test "the service's settings from LOCUS_RUNTIME_*, in the shape the credentials and the pool read" do
      environment = %{
        "LOCUS_RUNTIME_SERVICE_ID" => "wrk_locus",
        "LOCUS_RUNTIME_KEY" => @runtime_key_hex,
        "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300/",
        "LOCUS_RUNTIME_BIND" => "0.0.0.0",
        "LOCUS_RUNTIME_PORT" => "4200",
        "LOCUS_RUNTIME_POOL_SIZE" => "6",
        "LOCUS_RUNTIME_IDLE_TTL_MS" => "1000",
        "LOCUS_RUNTIME_WATCHDOG_GRACE_MS" => "2000",
        "LOCUS_RUNTIME_RELEASE_GRACE_MS" => "3000",
        "LOCUS_RUNTIME_MEMORY_BYTES" => "268435456",
        "LOCUS_RUNTIME_ATTACH_DIR" => "/run/locus"
      }

      assert {:ok, runtime} = Config.runtime_from_env(env(environment), [])

      assert runtime == [
               service_id: "wrk_locus",
               service_key: @runtime_key_hex,
               host_url: "http://cyfr:4300/",
               bind: "0.0.0.0",
               port: 4200,
               pool_size: 6,
               idle_ttl_ms: 1000,
               watchdog_grace_ms: 2000,
               release_grace_ms: 3000,
               runner_memory_bytes: 268_435_456,
               attach_dir: "/run/locus"
             ]

      assert {:ok, %Locus.Runtime.Credentials{port: 4200}} =
               Locus.Runtime.Credentials.load(runtime)

      assert {:ok, %{pool_size: 6, keeper: :channel}} = Locus.Runtime.Settings.pool(runtime, %{})
    end

    test "unset, a setting is the fallback's, else the service's default; the pool's stay unset" do
      assert {:ok, runtime} =
               Config.runtime_from_env(env(%{"LOCUS_RUNTIME_KEY" => @runtime_key_hex}),
                 host_url: "http://h:1"
               )

      assert runtime == [
               service_id: "wrk_local",
               service_key: @runtime_key_hex,
               host_url: "http://h:1",
               bind: "127.0.0.1",
               port: 4200
             ]

      # The fallback's key serves where the variable is unset; the
      # variable wins where it is set.
      fallback_key = String.duplicate("cd", 32)

      assert {:ok, [{:service_id, "wrk_local"}, {:service_key, ^fallback_key} | _]} =
               Config.runtime_from_env(env(%{}), service_key: fallback_key, host_url: "http://h")

      assert {:ok, [{:service_id, "wrk_local"}, {:service_key, @runtime_key_hex} | _]} =
               Config.runtime_from_env(env(%{"LOCUS_RUNTIME_KEY" => @runtime_key_hex}),
                 service_key: fallback_key,
                 host_url: "http://h"
               )
    end

    test "a missing or malformed value refuses, naming its variable and never echoing the key" do
      base = %{
        "LOCUS_RUNTIME_KEY" => @runtime_key_hex,
        "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
      }

      for {overrides, message} <- [
            {%{"LOCUS_RUNTIME_HOST_API_URL" => nil}, "LOCUS_RUNTIME_HOST_API_URL is not set"},
            {%{"LOCUS_RUNTIME_KEY" => "abc"}, "LOCUS_RUNTIME_KEY must be"},
            {%{"LOCUS_RUNTIME_SERVICE_ID" => "runtime"}, "LOCUS_RUNTIME_SERVICE_ID must be"},
            {%{"LOCUS_RUNTIME_HOST_API_URL" => "cyfr:4300"},
             "LOCUS_RUNTIME_HOST_API_URL must be"},
            {%{"LOCUS_RUNTIME_BIND" => "cyfr"}, "LOCUS_RUNTIME_BIND must be"},
            {%{"LOCUS_RUNTIME_PORT" => "http"}, "LOCUS_RUNTIME_PORT must be"},
            {%{"LOCUS_RUNTIME_PORT" => "65536"}, "LOCUS_RUNTIME_PORT must be"},
            {%{"LOCUS_RUNTIME_POOL_SIZE" => "0"}, "LOCUS_RUNTIME_POOL_SIZE"},
            {%{"LOCUS_RUNTIME_IDLE_TTL_MS" => "1s"}, "LOCUS_RUNTIME_IDLE_TTL_MS"},
            {%{"LOCUS_RUNTIME_WATCHDOG_GRACE_MS" => "600001"}, "LOCUS_RUNTIME_WATCHDOG_GRACE_MS"},
            {%{"LOCUS_RUNTIME_RELEASE_GRACE_MS" => "-1"}, "LOCUS_RUNTIME_RELEASE_GRACE_MS"},
            {%{"LOCUS_RUNTIME_ATTACH_DIR" => "run/locus"}, "LOCUS_RUNTIME_ATTACH_DIR must be"}
          ] do
        environment = base |> Map.merge(overrides) |> Map.reject(fn {_k, v} -> is_nil(v) end)

        assert {:error, refusal} = Config.runtime_from_env(env(environment), []),
               inspect(overrides)

        assert refusal =~ message, refusal
        refute refusal =~ @runtime_key_hex
      end
    end

    test "the memory bound takes the whole of the keeper's range, and nothing outside it" do
      base = %{
        "LOCUS_RUNTIME_KEY" => @runtime_key_hex,
        "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
      }

      assert {:ok, runtime} = Config.runtime_from_env(env(base), [])
      refute Keyword.has_key?(runtime, :runner_memory_bytes)

      for bytes <- ["16777216", "402653184", "1099511627776"] do
        environment = Map.put(base, "LOCUS_RUNTIME_MEMORY_BYTES", bytes)
        assert {:ok, runtime} = Config.runtime_from_env(env(environment), [])
        assert runtime[:runner_memory_bytes] == String.to_integer(bytes)
      end

      for bad <- ["16777215", "1099511627777", "384M", "402653184.5", "-1", "none"] do
        environment = Map.put(base, "LOCUS_RUNTIME_MEMORY_BYTES", bad)
        assert {:error, refusal} = Config.runtime_from_env(env(environment), [])
        assert refusal =~ "LOCUS_RUNTIME_MEMORY_BYTES"
        assert refusal =~ "bytes from 16777216 to 1099511627776"
      end
    end

    test "no keeper is read from the environment: the channel keeper is the one launcher" do
      environment = %{
        "LOCUS_RUNTIME_KEY" => @runtime_key_hex,
        "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
      }

      assert {:ok, runtime} = Config.runtime_from_env(env(environment), [])
      refute Keyword.has_key?(runtime, :keeper)
      assert {:ok, %{keeper: :channel}} = Locus.Runtime.Settings.pool(runtime, %{})
    end
  end

  describe "runner/1" do
    test "reads the runner's settings from its environment, with the descriptors and grace defaulted" do
      assert {:ok,
              %{
                runner_id: "runner_1",
                service_id: "wrk_local",
                boot: "nonode@nohost#boot_1",
                control_fd: 3,
                relay: {:fd, 4},
                watchdog_grace_ms: 5_000
              } = settings} = Config.runner(@runner_env)

      # A runner knows no address of CYFR's: it reaches CYFR through its relay.
      refute Map.has_key?(settings, :host_url)

      assert {:ok, %{relay: {:fd, 5}}} =
               Config.runner(Map.put(@runner_env, "RUNTIME_RELAY_FD", "5"))

      assert {:ok, %{relay: {:socket, "/tmp/runner/relay.sock"}}} =
               Config.runner(
                 Map.merge(@runner_env, %{
                   "RUNTIME_RELAY_FD" => "4",
                   "RUNTIME_RELAY_SOCKET" => "/tmp/runner/relay.sock"
                 })
               )

      assert {:ok, %{control_fd: 0, watchdog_grace_ms: 250}} =
               Config.runner(
                 Map.merge(@runner_env, %{
                   "RUNTIME_CONTROL_FD" => "0",
                   "RUNTIME_WATCHDOG_GRACE_MS" => "250"
                 })
               )
    end

    test "refuses to start with the service's key in sight, before anything else is read" do
      with_key = Map.put(@runner_env, "LOCUS_RUNTIME_KEY", String.duplicate("0", 64))
      assert {:error, {:refused, "LOCUS_RUNTIME_KEY"}} = Config.runner(with_key)

      assert {:error, {:refused, "LOCUS_RUNTIME_KEY"}} =
               Config.runner(%{"LOCUS_RUNTIME_KEY" => "not even a key"})
    end

    test "runner!/0 refuses the boot naming what is wrong: this VM is no runner" do
      assert_raise ArgumentError, ~r/\A\[Locus\.Config\] RUNTIME_RUNNER_ID is not set/, fn ->
        Config.runner!()
      end
    end

    test "a missing or malformed variable refuses, naming it" do
      for name <- Map.keys(@runner_env) do
        assert {:error, {:missing, ^name}} = Config.runner(Map.delete(@runner_env, name))
      end

      assert {:error, {:malformed, "RUNTIME_SERVICE_ID"}} =
               Config.runner(%{@runner_env | "RUNTIME_SERVICE_ID" => "svc"})

      assert {:error, {:malformed, "RUNTIME_RUNNER_ID"}} =
               Config.runner(%{@runner_env | "RUNTIME_RUNNER_ID" => "has space"})

      assert {:error, {:malformed, "RUNTIME_RELAY_FD"}} =
               Config.runner(Map.put(@runner_env, "RUNTIME_RELAY_FD", "2"))

      assert {:error, {:malformed, "RUNTIME_RELAY_SOCKET"}} =
               Config.runner(Map.put(@runner_env, "RUNTIME_RELAY_SOCKET", "relay.sock"))

      assert {:error, {:malformed, "RUNTIME_RELAY_SOCKET"}} =
               Config.runner(Map.put(@runner_env, "RUNTIME_RELAY_SOCKET", "/tmp/../relay.sock"))

      assert {:error, {:malformed, "RUNTIME_CONTROL_FD"}} =
               Config.runner(Map.put(@runner_env, "RUNTIME_CONTROL_FD", "-1"))

      assert {:error, {:malformed, "RUNTIME_WATCHDOG_GRACE_MS"}} =
               Config.runner(Map.put(@runner_env, "RUNTIME_WATCHDOG_GRACE_MS", "0"))
    end

    test "runner_environment/1 spells exactly the variables a runner reads" do
      env =
        Locus.Runtime.Settings.runner_environment(%{
          runner_id: "runner_1",
          service_id: "wrk_local",
          boot: "boot_1",
          host_url: "http://127.0.0.1:4300",
          watchdog_grace_ms: 5_000
        })

      # No address of CYFR's, whatever the service holds: the runner's host
      # calls leave through its relay.
      assert env == %{
               "RUNTIME_ROLE" => "runner",
               "RUNTIME_RUNNER_ID" => "runner_1",
               "RUNTIME_SERVICE_ID" => "wrk_local",
               "RUNTIME_BOOT_ID" => "boot_1",
               "RUNTIME_WATCHDOG_GRACE_MS" => "5000"
             }

      # Every name is the runner's own prefix: the keeper refuses any
      # `CYFR_`, `LOCUS_` or `KEEPER_` name in a spawn.
      assert Enum.all?(env, fn {name, _} -> String.starts_with?(name, "RUNTIME_") end)

      refute Enum.any?(env, fn {name, _} ->
               Enum.any?(
                 Prima.KeeperProtocol.reserved_env_prefixes(),
                 &String.starts_with?(name, &1)
               )
             end)

      assert {:ok, _settings} = Config.runner(Map.put(env, "RUNTIME_CONTROL_FD", "0"))
    end
  end
end

defmodule Locus.RuntimeConfigFileTest do
  @moduledoc """
  `config/locus_runtime.exs` evaluates the way the `locus` release boots:
  it writes exactly what `Locus.Config.from_env/1` answers, under `:locus`
  and no other application, and refuses the boot with the message, the
  control plane's builds key among the names it refuses. The release's
  one log setting reaches the logger by boot kind: a release node applies
  it whichever role it serves, a `mix` or test boot keeps its own logger,
  and a runner keeps its default.
  """
  # Sets the operating system's environment and the logger for the
  # duration of a test.
  use ExUnit.Case, async: false

  alias Locus.Application, as: App

  @root Path.expand("../../../..", __DIR__)
  @config_file Path.join(@root, "config/locus_runtime.exs")
  @key_hex "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"

  @cleared ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_LOCUS_RUNTIME_ROOT CYFR_LOCUS_BUILDS_KEY
              CYFR_LOCUS_BACKENDS_KEY) ++ Locus.Config.variables()

  # Every name `set` assigns is restored as well, so one no roster
  # declares does not outlive its test.
  defp with_env(set, fun) do
    previous = Map.new(@cleared ++ Map.keys(set), &{&1, System.get_env(&1)})

    try do
      Enum.each(@cleared, &System.delete_env/1)
      Enum.each(set, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  test "writes the settings under :locus and nothing else" do
    set = %{
      "LOCUS_BUILDS_KEY" => @key_hex,
      "LOCUS_BUILDS_PORT" => "4102",
      "LOCUS_BUILDS_MEMORY_BYTES" => "536870912"
    }

    with_env(set, fn ->
      config = Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
      {:ok, expected} = Locus.Config.from_env(&Map.get(set, &1))

      assert Keyword.keys(config) == [:locus]
      assert Enum.sort(config[:locus]) == Enum.sort(expected)
      assert config[:locus][:port] == 4102
      # The bound reaches `:locus` through the file as it stands: it writes
      # whatever `from_env/1` answers.
      assert config[:locus][:memory_bytes] == 536_870_912
    end)

    # A node given the backends key alone boots, serving backends.
    set = %{"LOCUS_BACKENDS_KEY" => @key_hex, "LOCUS_BACKENDS_PORT" => "4202"}

    with_env(set, fn ->
      config = Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
      {:ok, expected} = Locus.Config.from_env(&Map.get(set, &1))

      assert Keyword.keys(config) == [:locus]
      assert Enum.sort(config[:locus]) == Enum.sort(expected)
      assert config[:locus][:request_key] == nil
      assert config[:locus][:backends_port] == 4202
    end)
  end

  test "writes the runtime role's settings under :runtime, and nothing for a runner" do
    set = %{
      "LOCUS_RUNTIME_KEY" => @key_hex,
      "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300",
      "LOCUS_RUNTIME_POOL_SIZE" => "2"
    }

    with_env(set, fn ->
      config = Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
      {:ok, expected} = Locus.Config.from_env(&Map.get(set, &1))

      assert Keyword.keys(config) == [:locus]
      assert Enum.sort(config[:locus]) == Enum.sort(expected)
      assert config[:locus][:runtime][:service_key] == @key_hex
      assert config[:locus][:runtime][:pool_size] == 2
      assert config[:locus][:request_key] == nil
    end)

    # A runner reads its `RUNTIME_*` environment when it starts: the file
    # configures nothing for it, and refuses nothing.
    with_env(%{"RUNTIME_ROLE" => "runner"}, fn ->
      assert Config.Reader.read!(@config_file, env: :prod, imports: :disabled) == []
    end)
  end

  test "refuses the boot with the message naming the variable" do
    with_env(%{}, fn ->
      assert_raise RuntimeError, ~r/\[Locus\] FATAL: LOCUS_RUNTIME_KEY, LOCUS_BUILDS_KEY/, fn ->
        Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
      end
    end)

    # The runtime's key beside the builds key boots no node: the
    # application refuses it before any child starts (`Locus.Application`).
    assert_raise ArgumentError, ~r/LOCUS_RUNTIME_KEY.*LOCUS_BUILDS_KEY/s, fn ->
      Locus.Application.roles!(%{runtime: true, builds: true, backends: false})
    end

    with_env(%{"LOCUS_BUILDS_KEY" => @key_hex, "CYFR_DATABASE_URL" => "postgres://x"}, fn ->
      assert_raise RuntimeError,
                   ~r/FATAL: the locus release must not see CYFR_DATABASE_URL/,
                   fn ->
                     Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
                   end
    end)

    # The control plane's copy of the builds key is CYFR's too: a builds
    # node holds its own key under its own name, never the server's.
    planted = String.duplicate("5a", 32)

    with_env(%{"LOCUS_BUILDS_KEY" => @key_hex, "CYFR_LOCUS_BUILDS_KEY" => planted}, fn ->
      error =
        assert_raise RuntimeError,
                     ~r/FATAL: the locus release must not see CYFR_LOCUS_BUILDS_KEY/,
                     fn ->
                       Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
                     end

      refute error.message =~ planted
    end)

    # A misspelt name under a node's prefix is not ignored: the file hands
    # the whole environment to the guard, which refuses it by name.
    set = %{
      "LOCUS_RUNTIME_KEY" => @key_hex,
      "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300",
      "LOCUS_RUNTIME_POOL_SIZ" => "4"
    }

    with_env(set, fn ->
      assert_raise RuntimeError,
                   ~r/\[Locus\] FATAL: .*LOCUS_RUNTIME_POOL_SIZ is not a variable the locus release reads/s,
                   fn ->
                     Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
                   end
    end)

    assert System.get_env("LOCUS_RUNTIME_POOL_SIZ") == nil
  end

  test "log_formatter names Prima.JsonFormatter once the format is json" do
    Application.put_env(:locus, :log_format, :json)
    on_exit(fn -> Application.delete_env(:locus, :log_format) end)

    assert Locus.Config.log_formatter() == {Prima.JsonFormatter, :format}

    assert Code.ensure_loaded?(Prima.JsonFormatter) and
             function_exported?(Prima.JsonFormatter, :format, 4)
  end

  # Each test takes the steps a boot of its kind takes, from the
  # environment on, and puts back the logger level, the default handler
  # and the two log settings it changed, whatever the test's outcome.
  describe "the release's log setting, by boot kind" do
    setup do
      level = Logger.level()
      {:ok, handler} = :logger.get_handler_config(:default)
      settings = Map.new([:log_level, :log_format], &{&1, Application.fetch_env(:locus, &1)})

      on_exit(fn ->
        Logger.configure(level: level)
        restore_handler(handler)

        Enum.each(settings, fn
          {key, :error} -> Application.delete_env(:locus, key)
          {key, {:ok, value}} -> Application.put_env(:locus, key, value)
        end)
      end)

      %{handler: handler}
    end

    test "a release node applies LOCUS_LOG_LEVEL and LOCUS_LOG_FORMAT, serving the runtime or builds",
         %{handler: handler} do
      nodes = [
        {%{"LOCUS_RUNTIME_KEY" => @key_hex, "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"},
         %{runtime: true, builds: false, backends: false}},
        {%{"LOCUS_BUILDS_KEY" => @key_hex}, %{runtime: false, builds: true, backends: false}}
      ]

      for {role_env, roles} <- nodes do
        Logger.configure(level: :notice)
        :ok = :logger.update_handler_config(:default, :formatter, handler.formatter)
        set = Map.merge(role_env, %{"LOCUS_LOG_LEVEL" => "error", "LOCUS_LOG_FORMAT" => "json"})

        locus =
          with_env(set, fn ->
            Config.Reader.read!(@config_file, env: :prod, imports: :disabled)[:locus]
          end)

        # What the file wrote is the release node's application
        # environment: the two log settings go there, and its roles are
        # read from it as the node's start reads them.
        Application.put_env(:locus, :log_level, Keyword.fetch!(locus, :log_level))
        Application.put_env(:locus, :log_format, Keyword.fetch!(locus, :log_format))
        assert App.node_roles!(locus) == roles

        assert :ok = App.release_logging(App.node_roles!(locus))
        assert Logger.level() == :error, "#{inspect(roles)} left #{Logger.level()}"

        assert {:ok, %{formatter: {Logger.Formatter, config}}} =
                 :logger.get_handler_config(:default)

        assert inspect(config) =~ "Prima.JsonFormatter", inspect(roles)
      end
    end

    test "a mix or test boot serving the runtime keeps the logger its config files set" do
      # This boot never read config/locus_runtime.exs, and config/test.exs
      # gives it the runtime's key.
      Logger.configure(level: :critical)
      {:ok, handler} = :logger.get_handler_config(:default)
      Application.delete_env(:locus, :log_level)
      Application.delete_env(:locus, :log_format)

      roles = App.node_roles!(Application.get_all_env(:locus))
      assert roles.runtime

      assert :ok = App.release_logging(roles)
      assert Logger.level() == :critical
      assert {:ok, ^handler} = :logger.get_handler_config(:default)
    end

    test "a runner keeps its default logging: the file writes no log setting and its start applies none",
         %{handler: handler} do
      Logger.configure(level: :critical)

      set = %{
        "RUNTIME_ROLE" => "runner",
        "LOCUS_LOG_LEVEL" => "error",
        "LOCUS_LOG_FORMAT" => "json"
      }

      with_env(set, fn ->
        assert Config.Reader.read!(@config_file, env: :prod, imports: :disabled) == []

        # The application's start for a runner: its logging step, then its
        # settings, which this environment does not carry, so the start
        # ends there before any child.
        assert_raise ArgumentError, ~r/RUNTIME_RUNNER_ID is not set/, fn ->
          App.start(:normal, [])
        end
      end)

      assert Logger.level() == :critical

      assert {:ok, %{config: %{type: :standard_error}, formatter: formatter}} =
               :logger.get_handler_config(:default)

      assert formatter == handler.formatter
      refute inspect(formatter) =~ "JsonFormatter"
    end
  end

  # Puts the default handler back as it was: the runner's start replaces
  # it with one writing to standard error.
  defp restore_handler(handler) do
    if :logger.get_handler_config(:default) != {:ok, handler} do
      _ = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, handler.module, Map.drop(handler, [:id, :module]))
    end
  end
end
