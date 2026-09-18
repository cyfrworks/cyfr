# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SettingsTest do
  @moduledoc """
  The service's pool settings come from `config :opus` with defaults in
  code, each validated, the keeper following the environment when unset;
  a runner's settings come from its process environment alone, and a
  runner that can see the service's key refuses to start.
  """

  # `pool!/0` reads the application environment, which one test alters.
  use ExUnit.Case, async: false

  alias Opus.Settings

  @runner_env %{
    "OPUS_RUNNER_ID" => "runner_1",
    "OPUS_SERVICE_ID" => "wrk_local",
    "OPUS_BOOT_ID" => "nonode@nohost#boot_1",
    "OPUS_HOST_URL" => "http://127.0.0.1:4300"
  }

  describe "pool/2" do
    test "defaults: four fresh runners, a 30 s idle TTL, a 5 s watchdog grace, a 2 s release grace" do
      assert {:ok,
              %{
                pool_size: 4,
                idle_ttl_ms: 30_000,
                watchdog_grace_ms: 5_000,
                release_grace_ms: 2_000,
                keeper: :direct,
                attach_dir: "/run/opus"
              }} = Settings.pool([], %{})
    end

    test "the keeper follows the environment when unset, and is what the configuration names when set" do
      assert {:ok, %{keeper: :spawn}} = Settings.pool([], %{"CYFR_SPAWN_CHANNEL" => "socket:[1]"})
      assert {:ok, %{keeper: :direct}} = Settings.pool([], %{"CYFR_SPAWN_CHANNEL" => ""})

      assert {:ok, %{keeper: :local}} =
               Settings.pool([keeper: :local], %{"CYFR_SPAWN_CHANNEL" => "socket:[1]"})

      assert {:ok, %{keeper: :direct}} =
               Settings.pool([keeper: :direct], %{"CYFR_SPAWN_CHANNEL" => "socket:[1]"})

      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: :remote], %{})
      assert {:error, {:malformed, :keeper}} = Settings.pool([keeper: "spawn"], %{})
    end

    # Subtrees in the service's own VM are the suite's way of holding a
    # guest; a release must not be able to select it, however configured,
    # so the choice is compiled in under the test environment alone.
    test "the local keeper is compiled in under the test environment alone" do
      assert :local in Settings.keepers()
      assert Settings.keepers() -- [:local] == [:spawn, :direct]

      source = File.read!(Path.expand("../../lib/opus/settings.ex", __DIR__))

      assert source =~
               ~S|@keepers if Mix.env() == :test, do: [:spawn, :direct, :local], else: [:spawn, :direct]|,
             "the keeper roster must be decided at compile time from the environment"
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
    test "reads the runner's settings from its environment, with the control descriptor and grace defaulted" do
      assert {:ok,
              %{
                runner_id: "runner_1",
                service_id: "wrk_local",
                boot: "nonode@nohost#boot_1",
                host_url: "http://127.0.0.1:4300",
                control_fd: 3,
                watchdog_grace_ms: 5_000
              }} = Settings.runner(@runner_env)

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

      assert {:error, {:malformed, "OPUS_HOST_URL"}} =
               Settings.runner(%{@runner_env | "OPUS_HOST_URL" => "not a url"})

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

      assert env == %{
               "OPUS_ROLE" => "runner",
               "OPUS_RUNNER_ID" => "runner_1",
               "OPUS_SERVICE_ID" => "wrk_local",
               "OPUS_BOOT_ID" => "boot_1",
               "OPUS_HOST_URL" => "http://127.0.0.1:4300",
               "OPUS_WATCHDOG_GRACE_MS" => "5000"
             }

      assert Enum.all?(env, fn {name, _} -> String.starts_with?(name, "OPUS_") end)
      assert {:ok, _settings} = Settings.runner(Map.put(env, "OPUS_CONTROL_FD", "0"))
    end
  end
end
