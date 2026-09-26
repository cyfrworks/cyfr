# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SettingsTest do
  @moduledoc """
  The service's pool settings come from `config :opus` with defaults in
  code, each validated, the keeper the cyfr-keeper channel when unset and
  the retired `OPUS_KEEPER` refused, a runner's memory bound in the
  keeper's own range and never none; a
  runner's settings come from its process environment alone, and a
  runner that can see the service's key refuses to start.
  """

  # `pool!/0` reads the application environment, which one test alters.
  use ExUnit.Case, async: false

  alias Opus.Settings

  @runner_env %{
    "OPUS_RUNNER_ID" => "runner_1",
    "OPUS_SERVICE_ID" => "wrk_local",
    "OPUS_BOOT_ID" => "nonode@nohost#boot_1"
  }

  describe "pool/2" do
    test "defaults: four fresh runners, a 30 s idle TTL, a 5 s watchdog grace, a 2 s release grace, a 384 MiB runner bound" do
      assert {:ok,
              %{
                pool_size: 4,
                idle_ttl_ms: 30_000,
                watchdog_grace_ms: 5_000,
                release_grace_ms: 2_000,
                keeper: :channel,
                attach_dir: "/run/opus",
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
      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: Opus.Keeper.Direct], %{})
    end

    test "OPUS_KEEPER is retired: set to any keeper, or blank, it refuses naming it and the channel" do
      for value <- ["direct", "channel", ""], env <- [[], [keeper: :direct]] do
        assert {:error, {:retired, "OPUS_KEEPER"}} =
                 Settings.pool(env, %{"OPUS_KEEPER" => value})
      end

      assert Settings.retired("OPUS_KEEPER") =~ "OPUS_KEEPER is retired"
      assert Settings.retired("OPUS_KEEPER") =~ "cyfr-keeper"
    end

    # The release carries no host module, so the prefix is declared here:
    # an `OPUS_*` name it does not read refuses by name, whether the process
    # or an .env file a development boot sourced sets it.
    test "an OPUS_* name the release does not read refuses, naming it" do
      assert {:error, {:unknown, ["OPUS_POOL_SIZ"]}} =
               Settings.pool([], %{"OPUS_POOL_SIZ" => "4", "PATH" => "/bin"})

      assert {:error, {:unknown, ["OPUS_A", "OPUS_B"]}} =
               Settings.pool([], %{"OPUS_B" => "", "OPUS_A" => "1"})

      assert Settings.unknown(["OPUS_POOL_SIZ"]) =~
               "OPUS_POOL_SIZ is not a variable the opus release reads"

      # What it reads, what compose interpolates, and other prefixes pass.
      system =
        Map.new(
          Settings.variables() ++ Settings.compose_only() ++ ["KEEPER_CHANNEL", "CYFR_HOST"],
          &{&1, "set"}
        )

      assert Settings.unknown_names(system) == []

      # The retired name keeps its own refusal, and comes first.
      assert {:error, {:retired, "OPUS_KEEPER"}} =
               Settings.pool([], %{"OPUS_KEEPER" => "direct", "OPUS_BOGUS" => "1"})
    end

    test "pool!/0 refuses a stray OPUS_* name in the process environment" do
      System.put_env("OPUS_STRAY_FOR_TEST", "1")
      on_exit(fn -> System.delete_env("OPUS_STRAY_FOR_TEST") end)

      assert_raise ArgumentError, ~r/OPUS_STRAY_FOR_TEST is not a variable/, &Settings.pool!/0
    end

    test "the declared names are every OPUS_* name a runner is handed" do
      env =
        Settings.runner_environment(%{
          runner_id: "r",
          service_id: "wrk_local",
          boot: "b",
          host_url: "http://127.0.0.1:4300",
          watchdog_grace_ms: 5_000
        })

      assert Map.keys(env) -- Settings.variables() == []
      assert "OPUS_CONTROL_FD" in Settings.variables()
    end

    # A subtree runs in a runner's VM of its own in every build, the test
    # build included: there is no keeper that runs one in the service's.
    # The direct keeper is the test build's: without it, the channel alone.
    test "the keepers are the channel and the test build's direct keeper, and the channel alone without it" do
      assert Settings.keepers() == [:channel, :direct]
      assert Opus.Keeper.direct_keeper() == Opus.Keeper.Direct

      previous = Application.fetch_env!(:opus, :direct_keeper)
      Application.delete_env(:opus, :direct_keeper)

      try do
        assert Opus.Keeper.direct_keeper() == nil
        assert Settings.keepers() == [:channel]
        assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: :direct], %{})
        assert Settings.expected(:keeper) == "one of :channel"
        assert_raise ArgumentError, ~r/no direct keeper/, fn -> Opus.Keeper.module(:direct) end

        Application.put_env(:opus, :direct_keeper, Opus.Keeper.NotCompiled)
        assert Settings.keepers() == [:channel]
      after
        Application.put_env(:opus, :direct_keeper, previous)
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
      previous = Application.fetch_env(:opus, :runner_memory_bytes)
      Application.put_env(:opus, :runner_memory_bytes, 1_099_511_627_777)

      try do
        assert_raise ArgumentError, ~r/:runner_memory_bytes is malformed: a whole number/, fn ->
          Settings.pool!()
        end
      after
        case previous do
          {:ok, value} -> Application.put_env(:opus, :runner_memory_bytes, value)
          :error -> Application.delete_env(:opus, :runner_memory_bytes)
        end
      end
    end

    test "the attach directory is a clean absolute path" do
      assert {:ok, %{attach_dir: "/tmp/opus"}} = Settings.pool([attach_dir: "/tmp/opus"], %{})
      assert {:error, {:malformed, :attach_dir}} = Settings.pool([attach_dir: "run/opus"], %{})

      assert {:error, {:malformed, :attach_dir}} =
               Settings.pool([attach_dir: "/run/../opus"], %{})
    end

    test "pool!/0 refuses the boot with the key named" do
      previous = Application.get_env(:opus, :pool_size)
      Application.put_env(:opus, :pool_size, 0)

      try do
        assert_raise ArgumentError, ~r/:pool_size is malformed: a positive integer/, fn ->
          Settings.pool!()
        end
      after
        if previous,
          do: Application.put_env(:opus, :pool_size, previous),
          else: Application.delete_env(:opus, :pool_size)
      end
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
               Settings.runner(Map.put(@runner_env, "OPUS_RELAY_FD", "5"))

      assert {:ok, %{relay: {:socket, "/tmp/runner/relay.sock"}}} =
               Settings.runner(
                 Map.merge(@runner_env, %{
                   "OPUS_RELAY_FD" => "4",
                   "OPUS_RELAY_SOCKET" => "/tmp/runner/relay.sock"
                 })
               )

      assert {:ok, %{control_fd: 0, watchdog_grace_ms: 250}} =
               Settings.runner(
                 Map.merge(@runner_env, %{
                   "OPUS_CONTROL_FD" => "0",
                   "OPUS_WATCHDOG_GRACE_MS" => "250"
                 })
               )
    end

    test "refuses to start with the service's key in sight, before anything else is read" do
      with_key = Map.put(@runner_env, "OPUS_SERVICE_KEY", String.duplicate("0", 64))
      assert {:error, {:refused, "OPUS_SERVICE_KEY"}} = Settings.runner(with_key)

      assert {:error, {:refused, "OPUS_SERVICE_KEY"}} =
               Settings.runner(%{"OPUS_SERVICE_KEY" => "not even a key"})
    end

    test "runner!/0 refuses the boot naming what is wrong: this VM is no runner" do
      assert_raise ArgumentError, ~r/OPUS_RUNNER_ID is not set/, fn -> Settings.runner!() end
    end

    test "a missing or malformed variable refuses, naming it" do
      for name <- Map.keys(@runner_env) do
        assert {:error, {:missing, ^name}} = Settings.runner(Map.delete(@runner_env, name))
      end

      assert {:error, {:malformed, "OPUS_SERVICE_ID"}} =
               Settings.runner(%{@runner_env | "OPUS_SERVICE_ID" => "svc"})

      assert {:error, {:malformed, "OPUS_RUNNER_ID"}} =
               Settings.runner(%{@runner_env | "OPUS_RUNNER_ID" => "has space"})

      assert {:error, {:malformed, "OPUS_RELAY_FD"}} =
               Settings.runner(Map.put(@runner_env, "OPUS_RELAY_FD", "2"))

      assert {:error, {:malformed, "OPUS_RELAY_SOCKET"}} =
               Settings.runner(Map.put(@runner_env, "OPUS_RELAY_SOCKET", "relay.sock"))

      assert {:error, {:malformed, "OPUS_RELAY_SOCKET"}} =
               Settings.runner(Map.put(@runner_env, "OPUS_RELAY_SOCKET", "/tmp/../relay.sock"))

      assert {:error, {:malformed, "OPUS_CONTROL_FD"}} =
               Settings.runner(Map.put(@runner_env, "OPUS_CONTROL_FD", "-1"))

      assert {:error, {:malformed, "OPUS_WATCHDOG_GRACE_MS"}} =
               Settings.runner(Map.put(@runner_env, "OPUS_WATCHDOG_GRACE_MS", "0"))
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
               "OPUS_ROLE" => "runner",
               "OPUS_RUNNER_ID" => "runner_1",
               "OPUS_SERVICE_ID" => "wrk_local",
               "OPUS_BOOT_ID" => "boot_1",
               "OPUS_WATCHDOG_GRACE_MS" => "5000"
             }

      assert Enum.all?(env, fn {name, _} -> String.starts_with?(name, "OPUS_") end)
      assert {:ok, _settings} = Settings.runner(Map.put(env, "OPUS_CONTROL_FD", "0"))
    end
  end
end
