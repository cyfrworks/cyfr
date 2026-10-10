# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.SettingsTest do
  @moduledoc """
  The service's pool settings come from `config :locus, :runtime` with
  defaults in code, each validated, the keeper the cyfr-locus channel when
  unset, a runner's memory bound in the keeper's own range and never none;
  the service's `LOCUS_RUNTIME_*` environment reads into that keyword, or
  into nothing without the runtime's key; a runner's settings come from
  its `RUNTIME_*` environment alone, outside every prefix the keeper
  refuses in a spawn, and a runner that can see the service's key refuses
  to start.
  """

  # `pool!/0` reads the application environment, which one test alters.
  use ExUnit.Case, async: false

  alias Locus.Runtime.Settings

  @runner_env %{
    "RUNTIME_RUNNER_ID" => "runner_1",
    "RUNTIME_SERVICE_ID" => "wrk_local",
    "RUNTIME_BOOT_ID" => "nonode@nohost#boot_1"
  }

  @key_hex String.duplicate("ab", 32)

  defp getenv(map), do: &Map.get(map, &1)

  describe "pool/2" do
    test "defaults: four fresh runners, a 30 s idle TTL, a 5 s watchdog grace, a 2 s release grace, a 384 MiB runner bound" do
      assert {:ok,
              %{
                pool_size: 4,
                idle_ttl_ms: 30_000,
                watchdog_grace_ms: 5_000,
                release_grace_ms: 2_000,
                keeper: :channel,
                attach_dir: "/run/locus",
                runner_memory_bytes: 402_653_184
              }} = Settings.pool([], %{})

      assert {:ok, 402_653_184} = Settings.runner_memory_bytes([])
    end

    test "unset, the keeper is the channel whatever the environment says; set, what the configuration names" do
      for system <- [%{}, %{"KEEPER_CHANNEL" => ""}, %{"KEEPER_CHANNEL" => "socket:[1]"}] do
        assert {:ok, %{keeper: :channel}} = Settings.pool([], system)
      end

      assert {:ok, %{keeper: :direct}} =
               Settings.pool([keeper: :direct], %{"KEEPER_CHANNEL" => "socket:[1]"})

      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: :remote], %{})
      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: :local], %{})
      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: "channel"], %{})
      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: :spawn], %{})

      assert {:error, {:malformed, :keeper}} =
               Settings.pool([keeper: Locus.DirectLauncher.Runner], %{})
    end

    # The release carries no host module, so the prefix is declared here:
    # a `LOCUS_RUNTIME_*` name the service does not read refuses by name,
    # whether the process or an .env file a development boot sourced sets
    # it.
    test "a LOCUS_RUNTIME_* name the service does not read refuses, naming it" do
      assert {:error, {:unknown, ["LOCUS_RUNTIME_POOL_SIZ"]}} =
               Settings.pool([], %{"LOCUS_RUNTIME_POOL_SIZ" => "4", "PATH" => "/bin"})

      assert {:error, {:unknown, ["LOCUS_RUNTIME_A", "LOCUS_RUNTIME_B"]}} =
               Settings.pool([], %{"LOCUS_RUNTIME_B" => "", "LOCUS_RUNTIME_A" => "1"})

      assert Settings.unknown(["LOCUS_RUNTIME_POOL_SIZ"]) =~
               "LOCUS_RUNTIME_POOL_SIZ is not a variable the locus release reads"

      # What it reads, other roles' names and other prefixes pass.
      system =
        Map.new(
          Settings.variables() ++ ["KEEPER_CHANNEL", "CYFR_HOST", "LOCUS_BUILDS_KEY"],
          &{&1, "set"}
        )

      assert Settings.unknown_names(system) == []
      assert Settings.unknown_names(Map.keys(system)) == []
    end

    test "pool!/0 refuses a stray LOCUS_RUNTIME_* name in the process environment" do
      System.put_env("LOCUS_RUNTIME_STRAY_FOR_TEST", "1")
      on_exit(fn -> System.delete_env("LOCUS_RUNTIME_STRAY_FOR_TEST") end)

      assert_raise ArgumentError,
                   ~r/LOCUS_RUNTIME_STRAY_FOR_TEST is not a variable/,
                   &Settings.pool!/0
    end

    test "the declared names are every name a runner is handed" do
      env =
        Settings.runner_environment(%{
          runner_id: "r",
          service_id: "wrk_local",
          boot: "b",
          host_url: "http://127.0.0.1:4300",
          watchdog_grace_ms: 5_000
        })

      assert Map.keys(env) -- Settings.variables() == []
      assert "RUNTIME_CONTROL_FD" in Settings.variables()
    end

    # A subtree runs in a runner's VM of its own in every build, the test
    # build included: there is no keeper that runs one in the service's.
    # The direct keeper is the test build's: without it, the channel alone.
    test "the keepers are the channel and the test build's direct keeper, and the channel alone without it" do
      assert Settings.keepers() == [:channel, :direct]
      assert Locus.Runtime.Keeper.direct_keeper() == Locus.DirectLauncher.Runner

      previous = Locus.Runtime.Test.Env.delete(:direct_keeper)

      try do
        assert Locus.Runtime.Keeper.direct_keeper() == nil
        assert Settings.keepers() == [:channel]
        assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: :direct], %{})
        assert Settings.expected(:keeper) == "one of :channel"

        assert_raise ArgumentError, ~r/no direct keeper/, fn ->
          Locus.Runtime.Keeper.module(:direct)
        end

        Locus.Runtime.Test.Env.put(:direct_keeper, Locus.Runtime.Keeper.NotCompiled)
        assert Settings.keepers() == [:channel]
      after
        Locus.Runtime.Test.Env.restore(previous, [:direct_keeper])
      end
    end

    test "a bound that is not a positive integer refuses, naming its key" do
      for key <- [:pool_size, :idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms],
          value <- [0, -1, "4", 4.0, nil] do
        assert {:error, {:malformed, ^key}} = Settings.pool([{key, value}], %{})
      end

      assert {:ok, %{pool_size: 2, idle_ttl_ms: 1, watchdog_grace_ms: 7, release_grace_ms: 9}} =
               Settings.pool(
                 [pool_size: 2, idle_ttl_ms: 1, watchdog_grace_ms: 7, release_grace_ms: 9],
                 %{}
               )
    end

    test "a runner's memory bound is a whole number of bytes in the keeper's range, never none" do
      assert Settings.runner_memory_range() == 16_777_216..1_099_511_627_776

      for bytes <- [16_777_216, 536_870_912, 1_099_511_627_776] do
        assert {:ok, %{runner_memory_bytes: ^bytes}} =
                 Settings.pool([runner_memory_bytes: bytes], %{})

        assert {:ok, ^bytes} = Settings.runner_memory_bytes(runner_memory_bytes: bytes)
      end

      for bytes <- [nil, 0, -1, 16_777_215, 1_099_511_627_777, 5.0e8, "512M", :none] do
        assert {:error, {:malformed, :runner_memory_bytes}} =
                 Settings.pool([runner_memory_bytes: bytes], %{})

        assert {:error, {:malformed, :runner_memory_bytes}} =
                 Settings.runner_memory_bytes(runner_memory_bytes: bytes)
      end

      assert Settings.expected(:runner_memory_bytes) ==
               "a whole number of bytes from 16777216 (16 MiB) to 1099511627776 (1 TiB)"
    end

    test "pool!/0 refuses the boot on a malformed memory bound, naming it" do
      previous = Locus.Runtime.Test.Env.put(:runner_memory_bytes, 1_099_511_627_777)

      try do
        assert_raise ArgumentError, ~r/:runner_memory_bytes is malformed: a whole number/, fn ->
          Settings.pool!()
        end
      after
        Locus.Runtime.Test.Env.restore(previous, [:runner_memory_bytes])
      end
    end

    test "the attach directory is a clean absolute path" do
      assert {:ok, %{attach_dir: "/tmp/locus"}} = Settings.pool([attach_dir: "/tmp/locus"], %{})
      assert {:error, {:malformed, :attach_dir}} = Settings.pool([attach_dir: "run/locus"], %{})

      assert {:error, {:malformed, :attach_dir}} =
               Settings.pool([attach_dir: "/run/../locus"], %{})
    end

    test "pool!/0 refuses the boot with the key named" do
      previous = Locus.Runtime.Test.Env.put(:pool_size, 0)

      try do
        assert_raise ArgumentError,
                     ~r/config :locus, :runtime, :pool_size is malformed: a positive integer/,
                     fn ->
                       Settings.pool!()
                     end
      after
        Locus.Runtime.Test.Env.restore(previous, [:pool_size])
      end
    end
  end

  describe "from_env/2" do
    test "without the runtime's key, nothing: the node serves no runtime" do
      assert {:ok, nil} = Settings.from_env(getenv(%{}))

      assert {:ok, nil} =
               Settings.from_env(getenv(%{"LOCUS_RUNTIME_PORT" => "4200"}), host_url: "http://h")

      assert {:ok, nil} = Settings.from_env(getenv(%{"LOCUS_RUNTIME_KEY" => "  "}))
    end

    test "the service's settings from LOCUS_RUNTIME_*, in the shape the credentials and the pool read" do
      env = %{
        "LOCUS_RUNTIME_SERVICE_ID" => "wrk_locus",
        "LOCUS_RUNTIME_KEY" => @key_hex,
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

      assert {:ok, runtime} = Settings.from_env(getenv(env))

      assert runtime == [
               service_id: "wrk_locus",
               service_key: @key_hex,
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

      assert {:ok, %{pool_size: 6, keeper: :channel}} = Settings.pool(runtime, %{})
    end

    test "unset, a setting is the fallback's, else the service's default; the pool's stay unset" do
      assert {:ok, runtime} =
               Settings.from_env(getenv(%{"LOCUS_RUNTIME_KEY" => @key_hex}),
                 host_url: "http://h:1"
               )

      assert runtime == [
               service_id: "wrk_local",
               service_key: @key_hex,
               host_url: "http://h:1",
               bind: "127.0.0.1",
               port: 4200
             ]

      # The fallback's key serves where the variable is unset; the
      # variable wins where it is set.
      fallback_key = String.duplicate("cd", 32)

      assert {:ok, [{:service_id, "wrk_local"}, {:service_key, ^fallback_key} | _]} =
               Settings.from_env(getenv(%{}), service_key: fallback_key, host_url: "http://h")

      assert {:ok, [{:service_id, "wrk_local"}, {:service_key, @key_hex} | _]} =
               Settings.from_env(getenv(%{"LOCUS_RUNTIME_KEY" => @key_hex}),
                 service_key: fallback_key,
                 host_url: "http://h"
               )
    end

    test "a missing or malformed value refuses, naming its variable and never echoing the key" do
      base = %{
        "LOCUS_RUNTIME_KEY" => @key_hex,
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
        env = base |> Map.merge(overrides) |> Map.reject(fn {_k, v} -> is_nil(v) end)
        assert {:error, refusal} = Settings.from_env(getenv(env)), inspect(overrides)
        assert refusal =~ message, refusal
        refute refusal =~ @key_hex
      end
    end

    test "the memory bound takes the whole of the keeper's range, and nothing outside it" do
      base = %{
        "LOCUS_RUNTIME_KEY" => @key_hex,
        "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
      }

      assert {:ok, runtime} = Settings.from_env(getenv(base))
      refute Keyword.has_key?(runtime, :runner_memory_bytes)

      for bytes <- ["16777216", "402653184", "1099511627776"] do
        env = Map.put(base, "LOCUS_RUNTIME_MEMORY_BYTES", bytes)
        assert {:ok, runtime} = Settings.from_env(getenv(env))
        assert runtime[:runner_memory_bytes] == String.to_integer(bytes)
      end

      for bad <- ["16777215", "1099511627777", "384M", "402653184.5", "-1", "none"] do
        env = Map.put(base, "LOCUS_RUNTIME_MEMORY_BYTES", bad)
        assert {:error, refusal} = Settings.from_env(getenv(env))
        assert refusal =~ "LOCUS_RUNTIME_MEMORY_BYTES"
        assert refusal =~ "bytes from 16777216 to 1099511627776"
      end
    end

    test "no keeper is read from the environment: the channel keeper is the one launcher" do
      env = %{"LOCUS_RUNTIME_KEY" => @key_hex, "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"}
      assert {:ok, runtime} = Settings.from_env(getenv(env))
      refute Keyword.has_key?(runtime, :keeper)
      assert {:ok, %{keeper: :channel}} = Settings.pool(runtime, %{})
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
              } = settings} = Settings.runner(@runner_env)

      # A runner knows no address of CYFR's: it reaches CYFR through its relay.
      refute Map.has_key?(settings, :host_url)

      assert {:ok, %{relay: {:fd, 5}}} =
               Settings.runner(Map.put(@runner_env, "RUNTIME_RELAY_FD", "5"))

      assert {:ok, %{relay: {:socket, "/tmp/runner/relay.sock"}}} =
               Settings.runner(
                 Map.merge(@runner_env, %{
                   "RUNTIME_RELAY_FD" => "4",
                   "RUNTIME_RELAY_SOCKET" => "/tmp/runner/relay.sock"
                 })
               )

      assert {:ok, %{control_fd: 0, watchdog_grace_ms: 250}} =
               Settings.runner(
                 Map.merge(@runner_env, %{
                   "RUNTIME_CONTROL_FD" => "0",
                   "RUNTIME_WATCHDOG_GRACE_MS" => "250"
                 })
               )
    end

    test "refuses to start with the service's key in sight, before anything else is read" do
      with_key = Map.put(@runner_env, "LOCUS_RUNTIME_KEY", String.duplicate("0", 64))
      assert {:error, {:refused, "LOCUS_RUNTIME_KEY"}} = Settings.runner(with_key)

      assert {:error, {:refused, "LOCUS_RUNTIME_KEY"}} =
               Settings.runner(%{"LOCUS_RUNTIME_KEY" => "not even a key"})
    end

    test "runner!/0 refuses the boot naming what is wrong: this VM is no runner" do
      assert_raise ArgumentError, ~r/RUNTIME_RUNNER_ID is not set/, fn -> Settings.runner!() end
    end

    test "a missing or malformed variable refuses, naming it" do
      for name <- Map.keys(@runner_env) do
        assert {:error, {:missing, ^name}} = Settings.runner(Map.delete(@runner_env, name))
      end

      assert {:error, {:malformed, "RUNTIME_SERVICE_ID"}} =
               Settings.runner(%{@runner_env | "RUNTIME_SERVICE_ID" => "svc"})

      assert {:error, {:malformed, "RUNTIME_RUNNER_ID"}} =
               Settings.runner(%{@runner_env | "RUNTIME_RUNNER_ID" => "has space"})

      assert {:error, {:malformed, "RUNTIME_RELAY_FD"}} =
               Settings.runner(Map.put(@runner_env, "RUNTIME_RELAY_FD", "2"))

      assert {:error, {:malformed, "RUNTIME_RELAY_SOCKET"}} =
               Settings.runner(Map.put(@runner_env, "RUNTIME_RELAY_SOCKET", "relay.sock"))

      assert {:error, {:malformed, "RUNTIME_RELAY_SOCKET"}} =
               Settings.runner(Map.put(@runner_env, "RUNTIME_RELAY_SOCKET", "/tmp/../relay.sock"))

      assert {:error, {:malformed, "RUNTIME_CONTROL_FD"}} =
               Settings.runner(Map.put(@runner_env, "RUNTIME_CONTROL_FD", "-1"))

      assert {:error, {:malformed, "RUNTIME_WATCHDOG_GRACE_MS"}} =
               Settings.runner(Map.put(@runner_env, "RUNTIME_WATCHDOG_GRACE_MS", "0"))
    end

    test "runner_environment/1 spells exactly the variables a runner reads" do
      env =
        Settings.runner_environment(%{
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

      assert {:ok, _settings} = Settings.runner(Map.put(env, "RUNTIME_CONTROL_FD", "0"))
    end
  end
end
