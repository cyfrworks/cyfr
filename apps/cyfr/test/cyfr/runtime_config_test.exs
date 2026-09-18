# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Cyfr.RuntimeConfig

  # Build a getenv reader over a plain map (blank/absent both read as nil-ish).
  defp env(map), do: fn key -> Map.get(map, key) end

  describe "switch/3 — on or off, never a silent default" do
    test "unset and blank take the default" do
      assert {:ok, true} = RuntimeConfig.switch(env(%{}), "CYFR_BUILDS", true)

      assert {:ok, false} =
               RuntimeConfig.switch(env(%{"CYFR_BUILDS" => "  "}), "CYFR_BUILDS", false)
    end

    test "every spelling of on and off, any case" do
      for on <- ~w(on ON true True yes 1) do
        assert {:ok, true} = RuntimeConfig.switch(env(%{"K" => on}), "K", false)
      end

      for off <- ~w(off OFF false False no 0) do
        assert {:ok, false} = RuntimeConfig.switch(env(%{"K" => off}), "K", true)
      end
    end

    test "an unrecognised spelling is an error naming the key, not the default" do
      assert {:error, message} =
               RuntimeConfig.switch(env(%{"CYFR_BUILDS" => "disabled"}), "CYFR_BUILDS", true)

      assert message =~ "CYFR_BUILDS"
      assert message =~ "disabled"
    end
  end

  describe "milliseconds/3 — a whole number in range, or the default" do
    test "unset and blank keep the default; a whole number in range is taken" do
      assert {:ok, nil} = RuntimeConfig.milliseconds(env(%{}), "K", 1_000..60_000)
      assert {:ok, nil} = RuntimeConfig.milliseconds(env(%{"K" => " "}), "K", 1_000..60_000)
      assert {:ok, 1_000} = RuntimeConfig.milliseconds(env(%{"K" => "1000"}), "K", 1_000..60_000)

      assert {:ok, 60_000} =
               RuntimeConfig.milliseconds(env(%{"K" => "60000"}), "K", 1_000..60_000)
    end

    test "a unit, a fraction, a sign or a value out of range is an error naming the key" do
      for bad <- ~w(999 60001 30s 1e4 1.5 -5000 +5000 0x10 five) do
        assert {:error, message} =
                 RuntimeConfig.milliseconds(
                   env(%{"CYFR_MCP_BRIDGE_IDLE_MS" => bad}),
                   "CYFR_MCP_BRIDGE_IDLE_MS",
                   1_000..60_000
                 )

        assert message =~ "CYFR_MCP_BRIDGE_IDLE_MS"
        assert message =~ bad
      end
    end
  end

  describe "resolve_auth_provider/1 — set-or-default, fail loud" do
    test "unset + no credentials => no auth (default)" do
      assert {:ok, nil} = RuntimeConfig.resolve_auth_provider(env(%{}))
    end

    test "unset + github credentials => OAuth (auto-detect)" do
      assert {:ok, Sanctum.Auth.OAuth} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_GITHUB_CLIENT_ID" => "x"}))
    end

    test "unset + google credentials => OAuth (auto-detect)" do
      assert {:ok, Sanctum.Auth.OAuth} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_GOOGLE_CLIENT_ID" => "x"}))
    end

    test "explicit oauth + credentials => OAuth" do
      assert {:ok, Sanctum.Auth.OAuth} =
               RuntimeConfig.resolve_auth_provider(
                 env(%{"CYFR_AUTH_PROVIDER" => "oauth", "CYFR_GITHUB_CLIENT_ID" => "x"})
               )
    end

    test "explicit oauth WITHOUT credentials => error (no silent downgrade)" do
      assert {:error, msg} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_AUTH_PROVIDER" => "oauth"}))

      assert msg =~ "CYFR_GITHUB_CLIENT_ID"
    end

    test "explicit oidc + full trio => OIDC" do
      assert {:ok, Sanctum.Auth.OIDC} =
               RuntimeConfig.resolve_auth_provider(
                 env(%{
                   "CYFR_AUTH_PROVIDER" => "oidc",
                   "CYFR_OIDC_ISSUER" => "https://auth.example.com",
                   "CYFR_OIDC_CLIENT_ID" => "cid",
                   "CYFR_OIDC_CLIENT_SECRET" => "secret"
                 })
               )
    end

    test "explicit oidc missing issuer => error naming the missing var" do
      assert {:error, msg} =
               RuntimeConfig.resolve_auth_provider(
                 env(%{
                   "CYFR_AUTH_PROVIDER" => "oidc",
                   "CYFR_OIDC_CLIENT_ID" => "cid",
                   "CYFR_OIDC_CLIENT_SECRET" => "secret"
                 })
               )

      assert msg =~ "CYFR_OIDC_ISSUER"
    end

    test "unknown value => error (closes the silent-no-auth footgun)" do
      assert {:error, msg} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_AUTH_PROVIDER" => "saml"}))

      assert msg =~ "Unknown CYFR_AUTH_PROVIDER"
    end

    test "blank string is treated as unset" do
      assert {:ok, nil} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_AUTH_PROVIDER" => "   "}))
    end
  end

  describe "resolve_paths/1" do
    test "unset => the documented defaults, expanded" do
      assert {:ok, paths} = RuntimeConfig.resolve_paths(env(%{}))

      assert paths.base_path == Path.expand("data")
      assert paths.seed_path == Path.expand("seed")
      assert paths.database_path == Path.join(paths.base_path, "cyfr.db")
    end

    test "every root is overridable, and the database follows the data root" do
      assert {:ok, paths} =
               RuntimeConfig.resolve_paths(
                 env(%{
                   "CYFR_DATA_PATH" => "/srv/cyfr",
                   "CYFR_SEED_PATH" => "/media/seed"
                 })
               )

      assert paths.base_path == "/srv/cyfr"
      assert paths.seed_path == "/media/seed"
      assert paths.database_path == "/srv/cyfr/cyfr.db"
    end

    test "CYFR_DATABASE_PATH points the SQLite file elsewhere" do
      assert {:ok, paths} =
               RuntimeConfig.resolve_paths(
                 env(%{"CYFR_DATA_PATH" => "/srv/cyfr", "CYFR_DATABASE_PATH" => "/db/cyfr.db"})
               )

      assert paths.database_path == "/db/cyfr.db"
    end

    test "a set-but-blank variable fails the boot instead of defaulting" do
      for var <- ~w(CYFR_DATA_PATH CYFR_SEED_PATH CYFR_DATABASE_PATH) do
        assert {:error, message} = RuntimeConfig.resolve_paths(env(%{var => "   "}))
        assert message =~ var
      end
    end
  end

  describe "resolve_pool_size/1" do
    test "unset => 20; a value must be a positive integer" do
      assert {:ok, 20} = RuntimeConfig.resolve_pool_size(env(%{}))
      assert {:ok, 64} = RuntimeConfig.resolve_pool_size(env(%{"CYFR_DB_POOL_SIZE" => "64"}))

      # One parser for both adapters: the value that refuses a Postgres boot
      # must refuse a SQLite boot identically.
      for bad <- ["nope", "0", "-4", "12x", "1.5"] do
        assert {:error, message} =
                 RuntimeConfig.resolve_pool_size(env(%{"CYFR_DB_POOL_SIZE" => bad}))

        assert message =~ "CYFR_DB_POOL_SIZE"
      end
    end
  end

  describe "resolve_storage/1" do
    test "unset => local default" do
      assert {:ok, :local} = RuntimeConfig.resolve_storage(env(%{}))
    end

    test "explicit local => local" do
      assert {:ok, :local} = RuntimeConfig.resolve_storage(env(%{"CYFR_STORAGE" => "local"}))
    end

    test "s3 with full credentials => {:s3, opts}" do
      assert {:ok, {:s3, opts}} =
               RuntimeConfig.resolve_storage(
                 env(%{
                   "CYFR_STORAGE" => "s3",
                   "CYFR_S3_BUCKET" => "b",
                   "CYFR_S3_REGION" => "us-east-1",
                   "CYFR_S3_ACCESS_KEY_ID" => "ak",
                   "CYFR_S3_SECRET_ACCESS_KEY" => "sk",
                   "CYFR_S3_PATH_STYLE" => "true",
                   "CYFR_S3_ENDPOINT" => "http://minio:9000"
                 })
               )

      assert opts[:bucket] == "b"
      assert opts[:region] == "us-east-1"
      assert opts[:access_key_id] == "ak"
      assert opts[:secret_access_key] == "sk"
      assert opts[:path_style] == true
      assert opts[:endpoint] == "http://minio:9000"
    end

    test "CYFR_S3_PATH_STYLE is a switch: on in any spelling, off by default, a misspelling refuses" do
      base = %{
        "CYFR_STORAGE" => "s3",
        "CYFR_S3_BUCKET" => "b",
        "CYFR_S3_REGION" => "r",
        "CYFR_S3_ACCESS_KEY_ID" => "ak",
        "CYFR_S3_SECRET_ACCESS_KEY" => "sk"
      }

      for on <- ~w(on yes 1 TRUE) do
        assert {:ok, {:s3, opts}} =
                 RuntimeConfig.resolve_storage(env(Map.put(base, "CYFR_S3_PATH_STYLE", on)))

        assert opts[:path_style] == true
      end

      assert {:ok, {:s3, opts}} = RuntimeConfig.resolve_storage(env(base))
      assert opts[:path_style] == false

      assert {:error, message} =
               RuntimeConfig.resolve_storage(env(Map.put(base, "CYFR_S3_PATH_STYLE", "virtual")))

      assert message =~ "CYFR_S3_PATH_STYLE"
    end

    test "s3 omits absent optional keys" do
      assert {:ok, {:s3, opts}} =
               RuntimeConfig.resolve_storage(
                 env(%{
                   "CYFR_STORAGE" => "s3",
                   "CYFR_S3_BUCKET" => "b",
                   "CYFR_S3_REGION" => "us-east-1",
                   "CYFR_S3_ACCESS_KEY_ID" => "ak",
                   "CYFR_S3_SECRET_ACCESS_KEY" => "sk"
                 })
               )

      refute Keyword.has_key?(opts, :endpoint)
      refute Keyword.has_key?(opts, :prefix)
      assert opts[:path_style] == false
    end

    test "s3 missing a required var => error naming it" do
      assert {:error, msg} =
               RuntimeConfig.resolve_storage(
                 env(%{"CYFR_STORAGE" => "s3", "CYFR_S3_REGION" => "us-east-1"})
               )

      assert msg =~ "CYFR_S3_BUCKET"
    end

    test "unknown value => error" do
      assert {:error, msg} = RuntimeConfig.resolve_storage(env(%{"CYFR_STORAGE" => "gcs"}))
      assert msg =~ "Unknown CYFR_STORAGE"
    end

    test "the receive timeout rides in the s3 opts, and a wrong one fails the boot" do
      base = %{
        "CYFR_STORAGE" => "s3",
        "CYFR_S3_BUCKET" => "b",
        "CYFR_S3_REGION" => "us-east-1",
        "CYFR_S3_ACCESS_KEY_ID" => "ak",
        "CYFR_S3_SECRET_ACCESS_KEY" => "sk"
      }

      assert {:ok, {:s3, opts}} =
               RuntimeConfig.resolve_storage(
                 env(Map.put(base, "CYFR_S3_RECEIVE_TIMEOUT_MS", "90000"))
               )

      assert opts[:receive_timeout_ms] == 90_000

      # Unset leaves the adapter's own default in charge rather than a nil.
      assert {:ok, {:s3, plain}} = RuntimeConfig.resolve_storage(env(base))
      refute Keyword.has_key?(plain, :receive_timeout_ms)

      for bad <- ["0", "-1", "sixty", "60s"] do
        assert {:error, msg} =
                 RuntimeConfig.resolve_storage(
                   env(Map.put(base, "CYFR_S3_RECEIVE_TIMEOUT_MS", bad))
                 )

        assert msg =~ "CYFR_S3_RECEIVE_TIMEOUT_MS", "#{bad} should be refused by name"
      end
    end
  end

  describe "resolve_workers/1 — the worker services, in order" do
    test "unset => the local Opus service" do
      assert {:ok, [%{id: "wrk_local", url: "http://127.0.0.1:4200", components: nil}]} =
               RuntimeConfig.resolve_workers(env(%{}))

      assert {:ok, [%{id: "wrk_local"}]} =
               RuntimeConfig.resolve_workers(env(%{"CYFR_WORKERS" => " "}))
    end

    test "entries are <service_id>=<url>, comma-separated, in order, each running any component" do
      assert {:ok,
              [
                %{id: "wrk_opus", url: "http://opus:4200", components: nil},
                %{id: "wrk_b-2", url: "https://b.internal", components: nil}
              ]} =
               RuntimeConfig.resolve_workers(
                 env(%{
                   "CYFR_WORKERS" =>
                     " wrk_opus = http://opus:4200/ ,, wrk_b-2=https://b.internal "
                 })
               )
    end

    test "a malformed id or URL, or an entry that is not a pair, refuses the boot naming the entry" do
      for bad <- [
            "opus=http://opus:4200",
            "wrk_=http://opus:4200",
            "wrk_#{String.duplicate("a", 65)}=http://opus:4200",
            "wrk_opus",
            "wrk_opus=",
            "wrk_opus=opus:4200",
            "wrk_opus=http://opus:4200/worker",
            "wrk_opus=ftp://opus:4200"
          ] do
        assert {:error, message} = RuntimeConfig.resolve_workers(env(%{"CYFR_WORKERS" => bad}))
        assert message =~ "CYFR_WORKERS"
        assert message =~ String.trim(bad)
      end
    end

    test "two entries of one service id refuse the boot" do
      assert {:error, message} =
               RuntimeConfig.resolve_workers(
                 env(%{"CYFR_WORKERS" => "wrk_a=http://a:4200,wrk_a=http://b:4200"})
               )

      assert message =~ ~s("wrk_a")
    end
  end

  describe "resolve_host_api/1 — where the host API listens" do
    test "unset => loopback, 4300" do
      assert {:ok, %{bind: {127, 0, 0, 1}, port: 4300}} = RuntimeConfig.resolve_host_api(env(%{}))
    end

    test "an IPv4 or IPv6 address and a port from 1 to 65535" do
      assert {:ok, %{bind: {0, 0, 0, 0}, port: 4301}} =
               RuntimeConfig.resolve_host_api(
                 env(%{"CYFR_HOST_API_BIND" => "0.0.0.0", "CYFR_HOST_API_PORT" => "4301"})
               )

      assert {:ok, %{bind: {0, 0, 0, 0, 0, 0, 0, 1}}} =
               RuntimeConfig.resolve_host_api(env(%{"CYFR_HOST_API_BIND" => "::1"}))
    end

    test "a value that is not an address, or not a port, refuses the boot naming it" do
      for bad <- ["cyfr", "127.0.0.1:4300", "256.1.1.1"] do
        assert {:error, message} =
                 RuntimeConfig.resolve_host_api(env(%{"CYFR_HOST_API_BIND" => bad}))

        assert message =~ "CYFR_HOST_API_BIND"
      end

      for bad <- ["0", "65536", "-1", "4300x", "port"] do
        assert {:error, message} =
                 RuntimeConfig.resolve_host_api(env(%{"CYFR_HOST_API_PORT" => bad}))

        assert message =~ "CYFR_HOST_API_PORT"
      end
    end
  end

  describe "resolve_worker_watch/1 — the watch's bounds, only the set ones" do
    test "unset => nothing configured, so the code's defaults stand" do
      assert {:ok, []} = RuntimeConfig.resolve_worker_watch(env(%{}))

      assert {:ok, []} =
               RuntimeConfig.resolve_worker_watch(
                 env(%{"CYFR_WORKER_WATCH_POLL_MS" => " ", "CYFR_WORKER_WATCH_MISSES" => ""})
               )
    end

    test "a poll interval in milliseconds and a count of misses, each within its range" do
      assert {:ok, [poll_ms: 2_000, misses: 5]} =
               RuntimeConfig.resolve_worker_watch(
                 env(%{"CYFR_WORKER_WATCH_POLL_MS" => "2000", "CYFR_WORKER_WATCH_MISSES" => "5"})
               )

      assert {:ok, [misses: 1]} =
               RuntimeConfig.resolve_worker_watch(env(%{"CYFR_WORKER_WATCH_MISSES" => "1"}))

      assert {:ok, [poll_ms: 60_000]} =
               RuntimeConfig.resolve_worker_watch(env(%{"CYFR_WORKER_WATCH_POLL_MS" => "60000"}))
    end

    test "a value outside its range, or not a whole number, refuses the boot naming it" do
      for bad <- ~w(999 60001 5s 1.5 -5000 five) do
        assert {:error, message} =
                 RuntimeConfig.resolve_worker_watch(env(%{"CYFR_WORKER_WATCH_POLL_MS" => bad}))

        assert message =~ "CYFR_WORKER_WATCH_POLL_MS"
        assert message =~ bad
      end

      for bad <- ~w(0 101 3x -1 many) do
        assert {:error, message} =
                 RuntimeConfig.resolve_worker_watch(env(%{"CYFR_WORKER_WATCH_MISSES" => bad}))

        assert message =~ "CYFR_WORKER_WATCH_MISSES"
        assert message =~ bad
      end
    end
  end

  describe "resolve_postgres/1" do
    test "url present => opts with defaults" do
      assert {:ok, opts} =
               RuntimeConfig.resolve_postgres(
                 env(%{"CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db"})
               )

      assert opts[:url] == "postgres://u:p@h:5432/db"
      assert opts[:pool_size] == 20
      assert opts[:ssl] == false
    end

    test "honors pool size and ssl overrides" do
      assert {:ok, opts} =
               RuntimeConfig.resolve_postgres(
                 env(%{
                   "CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db",
                   "CYFR_DB_POOL_SIZE" => "10",
                   "CYFR_DB_SSL" => "true"
                 })
               )

      assert opts[:pool_size] == 10
      assert opts[:ssl] == true
    end

    test "CYFR_DB_SSL is a switch: on in any spelling, a misspelling refuses" do
      url = %{"CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db"}

      for on <- ~w(on yes 1 TRUE) do
        assert {:ok, opts} = RuntimeConfig.resolve_postgres(env(Map.put(url, "CYFR_DB_SSL", on)))
        assert opts[:ssl] == true
      end

      assert {:error, message} =
               RuntimeConfig.resolve_postgres(env(Map.put(url, "CYFR_DB_SSL", "enabled")))

      assert message =~ "CYFR_DB_SSL"
    end

    # Set-or-default, never silent fallback: quietly serving 20 connections
    # to an operator who asked for 200 is a capacity incident found under
    # load, not at boot.
    test "a malformed pool size fails the boot instead of defaulting" do
      for bad <- ["nope", "0", "-4", "12x", "1.5"] do
        assert {:error, message} =
                 RuntimeConfig.resolve_postgres(
                   env(%{
                     "CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db",
                     "CYFR_DB_POOL_SIZE" => bad
                   })
                 )

        assert message =~ "CYFR_DB_POOL_SIZE"
      end
    end

    test "missing url => error (no silent localhost attempt)" do
      assert {:error, msg} = RuntimeConfig.resolve_postgres(env(%{}))
      assert msg =~ "CYFR_DATABASE_URL"
    end
  end
end
