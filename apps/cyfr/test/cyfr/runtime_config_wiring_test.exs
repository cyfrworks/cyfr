# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeConfigWiringTest do
  @moduledoc """
  Evaluates runtime.exs outside its test-environment guard to check
  resolver wiring, release selection, and deployment validation.

  `Config.Reader.read!/2` evaluates the file the way a booting release does,
  without applying the result, so the prod branch can be exercised from the
  test run.
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)

  # Enough for the prod branch to reach the database section; everything else
  # has a default or is gated behind a knob this test does not set.
  defp base_env do
    %{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr"
    }
  end

  defp with_env(overrides, fun) do
    env = Map.merge(base_env(), overrides)
    previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read_prod_config! do
    Config.Reader.read!(Path.join(@root, "config/runtime.exs"),
      env: :prod,
      imports: :disabled
    )
  end

  describe "the prod branch evaluates" do
    test "with only the required secrets set" do
      with_env(%{"CYFR_DATABASE" => nil}, fn ->
        config = read_prod_config!()

        assert is_list(config)
        assert Keyword.has_key?(config, :cyfr)
      end)
    end

    test "and supplies connection config for the adapter that was built" do
      with_env(%{"CYFR_DATABASE" => nil}, fn ->
        repo_config = read_prod_config!() |> get_in([:arca, Arca.Repo])

        assert is_list(repo_config)

        case Cyfr.RuntimeConfig.repo_adapter() do
          Ecto.Adapters.SQLite3 ->
            # SQLite-only keys must be present here and never in a Postgres
            # build — the split config.exs documents.
            assert Keyword.has_key?(repo_config, :database)
            assert repo_config[:journal_mode] == :wal

          Ecto.Adapters.Postgres ->
            assert Keyword.has_key?(repo_config, :url)
            refute Keyword.has_key?(repo_config, :journal_mode)
        end

        # The busy timeout is the pool's lock-wait deadline, config.exs's
        # value (`Arca.Repo.busy_timeout_ms/0`); the runtime file does not
        # restate it for either adapter.
        refute Keyword.has_key?(repo_config, :busy_timeout)
      end)
    end
  end

  describe "CYFR_WORKER_KEY" do
    test "is the 32-byte root its 64 hexadecimal digits spell, in either case" do
      root = :crypto.strong_rand_bytes(32)

      for text <- [Base.encode16(root, case: :lower), Base.encode16(root)] do
        with_env(%{"CYFR_WORKER_KEY" => text}, fn ->
          assert get_in(read_prod_config!(), [:cyfr, :worker_key]) == root
        end)
      end
    end

    test "unset or blank configures no root" do
      for value <- [nil, ""] do
        with_env(%{"CYFR_WORKER_KEY" => value}, fn ->
          assert get_in(read_prod_config!(), [:cyfr, :worker_key]) == nil
        end)
      end
    end

    test "a malformed key refuses the boot" do
      for text <- ["abc", String.duplicate("g", 64), Base.encode64(:crypto.strong_rand_bytes(32))] do
        with_env(%{"CYFR_WORKER_KEY" => text}, fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "CYFR_WORKER_KEY must be exactly 64 hexadecimal"
        end)
      end
    end
  end

  describe "the MCP bridge's lease and idle period" do
    test "unset, neither is configured; set, each is taken in milliseconds" do
      with_env(%{"CYFR_MCP_BRIDGE_LEASE_MS" => nil, "CYFR_MCP_BRIDGE_IDLE_MS" => nil}, fn ->
        cyfr = read_prod_config!()[:cyfr]
        refute Keyword.has_key?(cyfr, :mcp_bridge_lease_ms)
        refute Keyword.has_key?(cyfr, :mcp_bridge_idle_ms)
      end)

      with_env(
        %{"CYFR_MCP_BRIDGE_LEASE_MS" => "5000", "CYFR_MCP_BRIDGE_IDLE_MS" => "600000"},
        fn ->
          cyfr = read_prod_config!()[:cyfr]
          assert cyfr[:mcp_bridge_lease_ms] == 5_000
          assert cyfr[:mcp_bridge_idle_ms] == 600_000
        end
      )
    end

    test "a value that is not a whole number of milliseconds in range refuses the boot" do
      for {key, bad} <- [
            {"CYFR_MCP_BRIDGE_LEASE_MS", "999"},
            {"CYFR_MCP_BRIDGE_LEASE_MS", "30s"},
            {"CYFR_MCP_BRIDGE_IDLE_MS", "86400001"},
            {"CYFR_MCP_BRIDGE_IDLE_MS", "15m"}
          ] do
        with_env(%{key => bad}, fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ key
        end)
      end
    end
  end

  describe "the Locus builds service" do
    @builds_key :binary.copy(<<0xB1>>, 32)

    test "neither variable set: this server builds nothing" do
      with_env(%{"CYFR_LOCUS_BUILDS_URL" => nil, "CYFR_LOCUS_BUILDS_KEY" => nil}, fn ->
        cyfr = read_prod_config!()[:cyfr]
        assert cyfr[:locus_builds_url] == nil
        assert cyfr[:locus_builds_key] == nil
      end)
    end

    test "both set: the URL without its trailing slash, and the key's 32 bytes" do
      with_env(
        %{
          "CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100/",
          "CYFR_LOCUS_BUILDS_KEY" => Base.encode16(@builds_key)
        },
        fn ->
          cyfr = read_prod_config!()[:cyfr]
          assert cyfr[:locus_builds_url] == "http://locus-builds:4100"
          assert cyfr[:locus_builds_key] == @builds_key
        end
      )
    end

    test "one without the other, or a malformed value, refuses the boot by name and never echoes the key" do
      hex = Base.encode16(@builds_key, case: :lower)

      for {env, named} <- [
            {%{"CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100"}, "CYFR_LOCUS_BUILDS_KEY"},
            {%{"CYFR_LOCUS_BUILDS_KEY" => hex}, "CYFR_LOCUS_BUILDS_URL"},
            {%{"CYFR_LOCUS_BUILDS_URL" => "locus-builds:4100", "CYFR_LOCUS_BUILDS_KEY" => hex},
             "CYFR_LOCUS_BUILDS_URL"},
            {%{
               "CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100",
               "CYFR_LOCUS_BUILDS_KEY" => String.slice(hex, 0..62)
             }, "CYFR_LOCUS_BUILDS_KEY"}
          ] do
        with_env(
          Map.merge(%{"CYFR_LOCUS_BUILDS_URL" => nil, "CYFR_LOCUS_BUILDS_KEY" => nil}, env),
          fn ->
            error = assert_raise RuntimeError, fn -> read_prod_config!() end
            message = Exception.message(error)
            assert message =~ "[Cyfr] FATAL: "
            assert message =~ named
            refute message =~ String.slice(hex, 0..62)
          end
        )
      end
    end
  end

  describe "OPUS_RUNNER_MEMORY_BYTES" do
    defp opus_env(overrides) do
      Map.merge(
        %{
          "RELEASE_NAME" => "opus",
          "CYFR_SECRET_KEY_BASE" => nil,
          "OPUS_SERVICE_KEY" => String.duplicate("ab", 32),
          "OPUS_HOST_URL" => "http://cyfr:4300",
          "OPUS_RUNNER_MEMORY_BYTES" => nil
        },
        overrides
      )
    end

    test "unset leaves the setting's default; set, the whole of the keeper's range is taken" do
      with_env(opus_env(%{}), fn ->
        refute Keyword.has_key?(read_prod_config!()[:opus], :runner_memory_bytes)
      end)

      for bytes <- ["16777216", "402653184", "1099511627776"] do
        with_env(opus_env(%{"OPUS_RUNNER_MEMORY_BYTES" => bytes}), fn ->
          assert read_prod_config!()[:opus][:runner_memory_bytes] == String.to_integer(bytes)
        end)
      end
    end

    test "a value outside the keeper's range, a unit or a fraction refuses the boot by name" do
      for bad <- ["16777215", "1099511627777", "384M", "402653184.5", "-1", "none"] do
        with_env(opus_env(%{"OPUS_RUNNER_MEMORY_BYTES" => bad}), fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "[Cyfr] FATAL: OPUS_RUNNER_MEMORY_BYTES"
          assert Exception.message(error) =~ "bytes from 16777216 to 1099511627776"
        end)
      end
    end
  end

  describe "the releases this file configures" do
    test "the opus release configures nothing of CYFR's, and any other release is CYFR" do
      with_env(
        %{
          "RELEASE_NAME" => "opus",
          "CYFR_SECRET_KEY_BASE" => nil,
          "OPUS_SERVICE_KEY" => String.duplicate("ab", 32),
          "OPUS_HOST_URL" => "http://cyfr:4300"
        },
        fn -> refute Keyword.has_key?(read_prod_config!(), :cyfr) end
      )

      with_env(%{"RELEASE_NAME" => "cyfr"}, fn ->
        config = read_prod_config!()
        assert Keyword.has_key?(config[:cyfr], :workers)
        refute Keyword.has_key?(config, :opus)
      end)
    end
  end

  describe "CYFR_DATABASE — the one setting `.env` cannot decide" do
    # Verify .env selection agrees with the compile-time adapter; Ecto cannot switch adapters at runtime.

    test "agreeing with the built adapter is accepted" do
      built =
        case Cyfr.RuntimeConfig.repo_adapter() do
          Ecto.Adapters.SQLite3 -> "sqlite"
          Ecto.Adapters.Postgres -> "postgres"
        end

      with_env(%{"CYFR_DATABASE" => built}, fn ->
        assert is_list(read_prod_config!())
      end)
    end

    test "asking for the adapter that was NOT built refuses the boot" do
      other =
        case Cyfr.RuntimeConfig.repo_adapter() do
          Ecto.Adapters.SQLite3 -> "postgres"
          Ecto.Adapters.Postgres -> "sqlite"
        end

      with_env(%{"CYFR_DATABASE" => other}, fn ->
        error = assert_raise RuntimeError, fn -> read_prod_config!() end

        assert Exception.message(error) =~ "CYFR_DATABASE asks for"
        assert Exception.message(error) =~ "chosen when the release is COMPILED"
      end)
    end

    test "an unrecognised value refuses the boot rather than defaulting" do
      with_env(%{"CYFR_DATABASE" => "mysql"}, fn ->
        error = assert_raise RuntimeError, fn -> read_prod_config!() end
        assert Exception.message(error) =~ "unknown CYFR_DATABASE=mysql"
      end)
    end

    test "an empty value is a blank line, not a request" do
      # Copying `.env.example` leaves `CYFR_DATABASE=` behind; that must read
      # as "unset", matching the blank-vs-unset doctrine this file documents.
      with_env(%{"CYFR_DATABASE" => ""}, fn ->
        assert is_list(read_prod_config!())
      end)
    end
  end

  describe "the worker wire" do
    test "the cyfr release takes the local worker and loopback host API by default" do
      with_env(
        %{"CYFR_WORKERS" => nil, "CYFR_HOST_API_BIND" => nil, "CYFR_HOST_API_PORT" => nil},
        fn ->
          cyfr = read_prod_config!()[:cyfr]

          assert cyfr[:workers] == [
                   %{id: "wrk_local", url: "http://127.0.0.1:4200", components: nil}
                 ]

          assert cyfr[:host_api_bind] == {127, 0, 0, 1}
          assert cyfr[:host_api_port] == 4300

          # No address of its own: a deployment that was not told one
          # issues assignments naming none, and its worker posts to the
          # single address it was configured with.
          assert cyfr[:host_api_url] == nil
          refute Keyword.has_key?(read_prod_config!(), :opus)
        end
      )
    end

    test "CYFR_WORKERS, CYFR_HOST_API_BIND, _PORT and _URL are taken as set" do
      with_env(
        %{
          "CYFR_WORKERS" => "wrk_opus=http://opus:4200, wrk_b=https://b.internal/",
          "CYFR_HOST_API_BIND" => "0.0.0.0",
          "CYFR_HOST_API_PORT" => "4301",
          "CYFR_HOST_API_URL" => "http://cyfr-1:4301"
        },
        fn ->
          cyfr = read_prod_config!()[:cyfr]

          assert cyfr[:workers] == [
                   %{id: "wrk_opus", url: "http://opus:4200", components: nil},
                   %{id: "wrk_b", url: "https://b.internal", components: nil}
                 ]

          assert cyfr[:host_api_bind] == {0, 0, 0, 0}
          assert cyfr[:host_api_port] == 4301
          assert cyfr[:host_api_url] == "http://cyfr-1:4301"
        end
      )
    end

    test "a malformed worker entry, address or port refuses the boot by name" do
      for {var, value} <- [
            {"CYFR_WORKERS", "opus=http://opus:4200"},
            {"CYFR_WORKERS", "wrk_opus=opus:4200"},
            {"CYFR_HOST_API_BIND", "cyfr"},
            {"CYFR_HOST_API_PORT", "65536"}
          ] do
        with_env(%{var => value}, fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "[Cyfr] FATAL: #{var}"
        end)
      end
    end

    test "the opus release configures the worker service from OPUS_* alone" do
      key = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      with_env(
        %{
          "RELEASE_NAME" => "opus",
          "CYFR_SECRET_KEY_BASE" => nil,
          "OPUS_SERVICE_ID" => "wrk_opus",
          "OPUS_SERVICE_KEY" => key,
          "OPUS_HOST_URL" => "http://cyfr:4300/",
          "OPUS_BIND" => "0.0.0.0",
          "OPUS_PORT" => "4200"
        },
        fn ->
          config = read_prod_config!()

          assert config[:opus] == [
                   service_id: "wrk_opus",
                   service_key: key,
                   host_url: "http://cyfr:4300/",
                   bind: "0.0.0.0",
                   port: 4200
                 ]

          refute Keyword.has_key?(config, :cyfr)
        end
      )
    end

    test "the opus release refuses a missing key or host URL, and a malformed value, by name" do
      base = %{
        "RELEASE_NAME" => "opus",
        "CYFR_SECRET_KEY_BASE" => nil,
        "OPUS_SERVICE_KEY" => String.duplicate("ab", 32),
        "OPUS_HOST_URL" => "http://cyfr:4300"
      }

      for {overrides, message} <- [
            {%{"OPUS_SERVICE_KEY" => nil}, "OPUS_SERVICE_KEY is not set"},
            {%{"OPUS_HOST_URL" => nil}, "OPUS_HOST_URL is not set"},
            {%{"OPUS_SERVICE_KEY" => "abc"}, "OPUS_SERVICE_KEY must be"},
            {%{"OPUS_SERVICE_ID" => "opus"}, "OPUS_SERVICE_ID must be"},
            {%{"OPUS_HOST_URL" => "cyfr:4300"}, "OPUS_HOST_URL must be"},
            {%{"OPUS_BIND" => "cyfr"}, "OPUS_BIND must be"}
          ] do
        with_env(Map.merge(base, overrides), fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "[Cyfr] FATAL: " <> message
        end)
      end
    end

    test "a boot that runs Opus beside CYFR derives the service key from the root, minting one if unset" do
      root = :crypto.strong_rand_bytes(32)
      {:ok, derived} = Prima.WorkerAuth.worker_key(root, "wrk_local")

      with_env(
        %{
          "RELEASE_NAME" => nil,
          "CYFR_WORKER_KEY" => Base.encode16(root),
          "OPUS_SERVICE_KEY" => nil
        },
        fn ->
          config = read_prod_config!()
          assert config[:cyfr][:worker_key] == root
          assert config[:opus][:service_id] == "wrk_local"
          assert config[:opus][:service_key] == Base.encode16(derived, case: :lower)
          assert config[:opus][:host_url] == "http://127.0.0.1:4300"
          assert config[:opus][:port] == 4200
        end
      )

      with_env(
        %{"RELEASE_NAME" => nil, "CYFR_WORKER_KEY" => nil, "OPUS_SERVICE_KEY" => nil},
        fn ->
          config = read_prod_config!()
          minted = config[:cyfr][:worker_key]
          assert byte_size(minted) == 32
          {:ok, key} = Prima.WorkerAuth.worker_key(minted, "wrk_local")
          assert config[:opus][:service_key] == Base.encode16(key, case: :lower)
        end
      )
    end
  end
end
