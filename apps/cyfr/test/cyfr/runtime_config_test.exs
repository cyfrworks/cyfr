# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Cyfr.RuntimeConfig

  # Build a getenv reader over a plain map (blank/absent both read as nil-ish).
  defp env(map), do: fn key -> Map.get(map, key) end

  describe "oidc_config/1 — the OpenID Connect issuer, all three settings or none" do
    @trio %{
      "CYFR_OIDC_ISSUER" => "https://auth.example.com",
      "CYFR_OIDC_CLIENT_ID" => "cid",
      "CYFR_OIDC_CLIENT_SECRET" => "secret"
    }

    test "none set, or set blank, is no issuer" do
      assert {:ok, nil} = RuntimeConfig.oidc_config(env(%{}))

      assert {:ok, nil} =
               RuntimeConfig.oidc_config(env(Map.new(@trio, fn {k, _} -> {k, "  "} end)))
    end

    test "all three set is the issuer" do
      assert {:ok,
              %{issuer: "https://auth.example.com", client_id: "cid", client_secret: "secret"}} =
               RuntimeConfig.oidc_config(env(@trio))
    end

    test "a partly set issuer is refused, naming what is missing" do
      for missing <- Map.keys(@trio) do
        assert {:error, msg} = RuntimeConfig.oidc_config(env(Map.delete(@trio, missing)))
        assert msg =~ missing
      end

      assert {:error, msg} =
               RuntimeConfig.oidc_config(env(%{"CYFR_OIDC_ISSUER" => "https://auth.example.com"}))

      assert msg =~ "CYFR_OIDC_CLIENT_ID"
      assert msg =~ "CYFR_OIDC_CLIENT_SECRET"
    end
  end

  describe "company_login_config/3 — the company sign-in, its days and its issuer" do
    @company_oidc %{issuer: "https://auth.example.com", client_id: "cid", client_secret: "secret"}
    @workos_names ~w(CYFR_WORKOS_CLIENT_ID CYFR_WORKOS_API_KEY CYFR_WORKOS_ORGANIZATION)
    @workos_env %{
      "CYFR_WORKOS_CLIENT_ID" => "client_01HQCOMPANY",
      "CYFR_WORKOS_API_KEY" => "sk_test_company_api_key",
      "CYFR_WORKOS_ORGANIZATION" => "org_01HQCOMPANY"
    }
    @workos %{
      client_id: "client_01HQCOMPANY",
      api_key: "sk_test_company_api_key",
      organization: "org_01HQCOMPANY"
    }
    @join %{"CYFR_COMPANY_LOGIN" => "join"}
    @renew %{"CYFR_COMPANY_LOGIN" => "renew", "CYFR_COMPANY_LOGIN_DAYS" => "30"}

    # Every case but the issuer's own has an OpenID Connect issuer, so a
    # refusal is the one setting under test and never a missing issuer.
    defp company(map, oidc \\ @company_oidc, headless? \\ false),
      do: RuntimeConfig.company_login_config(env(map), oidc, headless?)

    # Whether `message` names `var` itself: CYFR_COMPANY_LOGIN inside
    # CYFR_COMPANY_LOGIN_DAYS does not count.
    defp names?(message, var), do: message =~ ~r/\b#{var}\b/

    test "unset or empty, the mode is off and nothing else is configured" do
      for mode <- [nil, "", "  "] do
        assert company(%{"CYFR_COMPANY_LOGIN" => mode}, nil) ==
                 {:ok, %{mode: :off, days: nil, issuer: nil, workos: nil}},
               "CYFR_COMPANY_LOGIN=#{inspect(mode)}"
      end
    end

    test "off, join and renew are the modes, renew with its days" do
      assert company(%{"CYFR_COMPANY_LOGIN" => "off"}, nil) ==
               {:ok, %{mode: :off, days: nil, issuer: nil, workos: nil}}

      assert company(@join) == {:ok, %{mode: :join, days: nil, issuer: :oidc, workos: nil}}
      assert company(@renew) == {:ok, %{mode: :renew, days: 30, issuer: :oidc, workos: nil}}
    end

    test "any other mode is refused, naming CYFR_COMPANY_LOGIN" do
      for mode <- ["on", "true", "JOIN", "Renew", "required", "joined"] do
        assert {:error, message} = company(%{"CYFR_COMPANY_LOGIN" => mode}), mode
        assert names?(message, "CYFR_COMPANY_LOGIN"), message
      end
    end

    test "renew without days is refused, naming CYFR_COMPANY_LOGIN_DAYS" do
      for days <- [nil, "", "  "] do
        assert {:error, message} = company(%{@renew | "CYFR_COMPANY_LOGIN_DAYS" => days}),
               "CYFR_COMPANY_LOGIN_DAYS=#{inspect(days)}"

        assert names?(message, "CYFR_COMPANY_LOGIN_DAYS"), message
      end
    end

    test "days that are not a positive whole number are refused, naming CYFR_COMPANY_LOGIN_DAYS" do
      for days <- ["0", "-1", "1.5", "30d", "01", "+30", "thirty"] do
        assert {:error, message} = company(%{@renew | "CYFR_COMPANY_LOGIN_DAYS" => days}), days
        assert names?(message, "CYFR_COMPANY_LOGIN_DAYS"), message
      end
    end

    test "days with any mode but renew are refused, naming CYFR_COMPANY_LOGIN_DAYS" do
      for mode <- ["join", "off", "", nil] do
        assert {:error, message} = company(%{@renew | "CYFR_COMPANY_LOGIN" => mode}),
               "CYFR_COMPANY_LOGIN=#{inspect(mode)}"

        assert names?(message, "CYFR_COMPANY_LOGIN_DAYS"), message
      end
    end

    test "any positive whole number of days is taken, with no ceiling" do
      for days <- [1, 36_500, 10_000_000] do
        assert company(%{@renew | "CYFR_COMPANY_LOGIN_DAYS" => Integer.to_string(days)}) ==
                 {:ok, %{mode: :renew, days: days, issuer: :oidc, workos: nil}}
      end
    end

    test "WorkOS set in part is refused, naming the settings that are missing and never the key" do
      partial =
        Enum.map(@workos_names, &[&1]) ++ Enum.map(@workos_names, &(@workos_names -- [&1]))

      cases =
        for(set <- partial, do: {Map.take(@workos_env, set), @workos_names -- set}) ++
          [{%{@workos_env | "CYFR_WORKOS_API_KEY" => "  "}, ["CYFR_WORKOS_API_KEY"]}]

      for {workos, missing} <- cases do
        assert {:error, message} = company(Map.merge(@join, workos)), inspect(missing)

        assert String.ends_with?(message, "; " <> Enum.join(missing, ", ") <> " is not set."),
               message

        refute message =~ @workos.api_key
      end
    end

    test "WorkOS with the mode off is refused, naming CYFR_COMPANY_LOGIN and never the key" do
      for mode <- [nil, "", "off"] do
        assert {:error, message} =
                 company(Map.put(@workos_env, "CYFR_COMPANY_LOGIN", mode)),
               "CYFR_COMPANY_LOGIN=#{inspect(mode)}"

        assert names?(message, "CYFR_COMPANY_LOGIN"), message
        refute message =~ @workos.api_key
      end
    end

    test "WorkOS on a headless node is refused, naming CYFR_HEADLESS and never the key" do
      for mode <- [@join, @renew] do
        assert {:error, message} = company(Map.merge(@workos_env, mode), nil, true)
        assert names?(message, "CYFR_HEADLESS"), message
        refute message =~ @workos.api_key

        assert {:ok, %{issuer: :workos}} = company(Map.merge(@workos_env, mode), nil, false)
      end
    end

    test "join or renew with neither WorkOS nor an OpenID Connect issuer is refused, naming both" do
      for mode <- [@join, @renew], headless? <- [false, true] do
        assert {:error, message} = company(mode, nil, headless?)
        assert message =~ "CYFR_COMPANY_LOGIN=#{mode["CYFR_COMPANY_LOGIN"]}", message

        for var <- ["CYFR_OIDC_ISSUER" | @workos_names],
            do: assert(names?(message, var), "#{var}: #{message}")
      end
    end

    test "with an OpenID Connect issuer and no WorkOS, the company issuer is :oidc" do
      for mode <- [@join, @renew] do
        assert {:ok, %{issuer: :oidc, workos: nil}} = company(mode, @company_oidc)
      end
    end

    test "with WorkOS, the company issuer is :workos whether or not OpenID Connect is configured" do
      for oidc <- [nil, @company_oidc] do
        assert company(Map.merge(@workos_env, @join), oidc) ==
                 {:ok, %{mode: :join, days: nil, issuer: :workos, workos: @workos}},
               "OpenID Connect: #{inspect(oidc)}"
      end
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
                   "CYFR_S3_PATH_STYLE" => "on",
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

    test "CYFR_S3_PATH_STYLE is a switch: on, off by default, any other spelling refuses" do
      base = %{
        "CYFR_STORAGE" => "s3",
        "CYFR_S3_BUCKET" => "b",
        "CYFR_S3_REGION" => "r",
        "CYFR_S3_ACCESS_KEY_ID" => "ak",
        "CYFR_S3_SECRET_ACCESS_KEY" => "sk"
      }

      assert {:ok, {:s3, opts}} =
               RuntimeConfig.resolve_storage(env(Map.put(base, "CYFR_S3_PATH_STYLE", "on")))

      assert opts[:path_style] == true

      for other <- ~w(yes 1 TRUE) do
        assert {:error, _message} =
                 RuntimeConfig.resolve_storage(env(Map.put(base, "CYFR_S3_PATH_STYLE", other)))
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
    test "unset => the local runtime" do
      assert {:ok, [%{id: "wrk_local", url: "http://127.0.0.1:4200", components: nil}]} =
               RuntimeConfig.resolve_workers(env(%{}))

      assert {:ok, [%{id: "wrk_local"}]} =
               RuntimeConfig.resolve_workers(env(%{"CYFR_LOCUS_RUNTIME_WORKERS" => " "}))
    end

    test "entries are <service_id>=<url>, comma-separated, in order, each running any component" do
      assert {:ok,
              [
                %{id: "wrk_locus", url: "http://locus-runtime:4200", components: nil},
                %{id: "wrk_b-2", url: "https://b.internal", components: nil}
              ]} =
               RuntimeConfig.resolve_workers(
                 env(%{
                   "CYFR_LOCUS_RUNTIME_WORKERS" =>
                     " wrk_locus = http://locus-runtime:4200/ ,, wrk_b-2=https://b.internal "
                 })
               )
    end

    test "a malformed id or URL, or an entry that is not a pair, refuses the boot naming the entry" do
      for bad <- [
            "runtime=http://locus-runtime:4200",
            "wrk_=http://locus-runtime:4200",
            "wrk_#{String.duplicate("a", 65)}=http://locus-runtime:4200",
            "wrk_locus",
            "wrk_locus=",
            "wrk_locus=locus-runtime:4200",
            "wrk_locus=http://locus-runtime:4200/worker",
            "wrk_locus=ftp://locus-runtime:4200"
          ] do
        assert {:error, message} =
                 RuntimeConfig.resolve_workers(env(%{"CYFR_LOCUS_RUNTIME_WORKERS" => bad}))

        assert message =~ "CYFR_LOCUS_RUNTIME_WORKERS"
        assert message =~ String.trim(bad)
      end
    end

    test "two entries of one service id refuse the boot" do
      assert {:error, message} =
               RuntimeConfig.resolve_workers(
                 env(%{"CYFR_LOCUS_RUNTIME_WORKERS" => "wrk_a=http://a:4200,wrk_a=http://b:4200"})
               )

      assert message =~ ~s("wrk_a")
    end
  end

  describe "resolve_host_api/1 — where the host API listens" do
    test "unset => loopback, 4300, and no address of this member's own" do
      assert {:ok, %{bind: {127, 0, 0, 1}, port: 4300, url: nil}} =
               RuntimeConfig.resolve_host_api(env(%{}))
    end

    test "CYFR_HOST_API_URL is the address this member's assignments carry" do
      assert {:ok, %{url: "http://cyfr-1:4300"}} =
               RuntimeConfig.resolve_host_api(env(%{"CYFR_HOST_API_URL" => "http://cyfr-1:4300"}))

      # A route is appended to it as it is, so the trailing slash goes.
      assert {:ok, %{url: "https://member-2.internal"}} =
               RuntimeConfig.resolve_host_api(
                 env(%{"CYFR_HOST_API_URL" => "https://member-2.internal/"})
               )
    end

    test "an address that is not a base URL a route appends to refuses the boot naming it" do
      for bad <- ["cyfr:4300", "ftp://cyfr:4300", "http://", "http://cyfr/host/v1", "/host/v1"] do
        assert {:error, message} =
                 RuntimeConfig.resolve_host_api(env(%{"CYFR_HOST_API_URL" => bad}))

        assert message =~ "CYFR_HOST_API_URL"
      end
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

  describe "resolve_cluster_topology/1 — how a cell's members find each other" do
    test "unset => no topology, which the cluster flag refuses on its own" do
      assert {:ok, []} = RuntimeConfig.resolve_cluster_topology(env(%{}))

      assert {:ok, []} =
               RuntimeConfig.resolve_cluster_topology(env(%{"CYFR_CLUSTER_NODES" => ""}))
    end

    test "named members are polled over EPMD" do
      assert {:ok, [cyfr: topology]} =
               RuntimeConfig.resolve_cluster_topology(
                 env(%{"CYFR_CLUSTER_NODES" => "cyfr@10.0.0.1, cyfr@10.0.0.2"})
               )

      assert topology[:strategy] == Cluster.Strategy.Epmd
      assert topology[:config][:hosts] == [:"cyfr@10.0.0.1", :"cyfr@10.0.0.2"]
    end

    test "a headless service is resolved by DNS, and needs the node basename with it" do
      assert {:ok, [cyfr: topology]} =
               RuntimeConfig.resolve_cluster_topology(
                 env(%{
                   "CYFR_CLUSTER_DNS_QUERY" => "cyfr-headless.svc",
                   "CYFR_CLUSTER_NODE_BASENAME" => "cyfr"
                 })
               )

      assert topology[:strategy] == Cluster.Strategy.DNSPoll
      assert topology[:config][:query] == "cyfr-headless.svc"
      assert topology[:config][:node_basename] == "cyfr"

      assert {:error, message} =
               RuntimeConfig.resolve_cluster_topology(
                 env(%{"CYFR_CLUSTER_DNS_QUERY" => "cyfr-headless.svc"})
               )

      assert message =~ "CYFR_CLUSTER_NODE_BASENAME"

      assert {:error, message} =
               RuntimeConfig.resolve_cluster_topology(
                 env(%{"CYFR_CLUSTER_NODE_BASENAME" => "cyfr"})
               )

      assert message =~ "CYFR_CLUSTER_DNS_QUERY"
    end

    test "two ways to find one cell is a refusal, not a merge" do
      assert {:error, message} =
               RuntimeConfig.resolve_cluster_topology(
                 env(%{
                   "CYFR_CLUSTER_NODES" => "cyfr@10.0.0.1",
                   "CYFR_CLUSTER_DNS_QUERY" => "cyfr-headless.svc"
                 })
               )

      assert message =~ "set one"
    end

    test "a list that names no node is a refusal, never an empty topology" do
      assert {:error, message} =
               RuntimeConfig.resolve_cluster_topology(env(%{"CYFR_CLUSTER_NODES" => " , ,"}))

      assert message =~ "names no server"
    end
  end

  describe "resolve_cell_cookie/1 — the cookie that bounds one cell" do
    test "unset => none, which the cluster flag refuses on its own" do
      assert {:ok, nil} = RuntimeConfig.resolve_cell_cookie(env(%{}))
      assert {:ok, nil} = RuntimeConfig.resolve_cell_cookie(env(%{"CYFR_CELL_COOKIE" => ""}))
    end

    test "32 characters or more is a cookie; less is a refusal naming its length" do
      cookie = String.duplicate("a", 32)

      assert {:ok, ^cookie} =
               RuntimeConfig.resolve_cell_cookie(env(%{"CYFR_CELL_COOKIE" => cookie}))

      assert {:error, message} =
               RuntimeConfig.resolve_cell_cookie(
                 env(%{"CYFR_CELL_COOKIE" => String.duplicate("a", 31)})
               )

      assert message =~ "is 31 characters"
      assert message =~ "openssl rand -hex 32"
    end
  end

  describe "resolve_locus_builds/1 — the builds service, both of its variables or neither" do
    @key_hex String.duplicate("0f", 32)

    test "unset => no builds service: this server builds nothing" do
      assert {:ok, nil} = RuntimeConfig.resolve_locus_builds(env(%{}))

      assert {:ok, nil} =
               RuntimeConfig.resolve_locus_builds(
                 env(%{"CYFR_LOCUS_BUILDS_URL" => " ", "CYFR_LOCUS_BUILDS_KEY" => ""})
               )
    end

    test "a base URL and a 64-digit key => the URL without its slash and the key's 32 bytes" do
      assert {:ok, %{url: "http://locus-builds:4100", key: key}} =
               RuntimeConfig.resolve_locus_builds(
                 env(%{
                   "CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100/",
                   "CYFR_LOCUS_BUILDS_KEY" => String.upcase(@key_hex)
                 })
               )

      assert key == :binary.copy(<<0x0F>>, 32)
    end

    test "one without the other refuses the boot naming the missing one" do
      assert {:error, message} =
               RuntimeConfig.resolve_locus_builds(
                 env(%{"CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100"})
               )

      assert message =~ "CYFR_LOCUS_BUILDS_KEY is not"

      assert {:error, message} =
               RuntimeConfig.resolve_locus_builds(env(%{"CYFR_LOCUS_BUILDS_KEY" => @key_hex}))

      assert message =~ "CYFR_LOCUS_BUILDS_URL is not"
      refute message =~ @key_hex
    end

    test "a URL with a path, or a key of another form, refuses the boot and never echoes the key" do
      for bad <- ["locus-builds:4100", "ftp://locus-builds", "http://locus-builds/locus/v1"] do
        assert {:error, message} =
                 RuntimeConfig.resolve_locus_builds(
                   env(%{"CYFR_LOCUS_BUILDS_URL" => bad, "CYFR_LOCUS_BUILDS_KEY" => @key_hex})
                 )

        assert message =~ "CYFR_LOCUS_BUILDS_URL"
      end

      for bad <- ["short", @key_hex <> "0", String.replace(@key_hex, "0", "g")] do
        assert {:error, message} =
                 RuntimeConfig.resolve_locus_builds(
                   env(%{
                     "CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100",
                     "CYFR_LOCUS_BUILDS_KEY" => bad
                   })
                 )

        assert message =~ "CYFR_LOCUS_BUILDS_KEY"
        refute message =~ bad
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
                   "CYFR_DB_SSL" => "on"
                 })
               )

      assert opts[:pool_size] == 10
      assert opts[:ssl] == true
    end

    test "CYFR_DB_SSL is a switch: on, and any other spelling refuses" do
      url = %{"CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db"}

      assert {:ok, opts} = RuntimeConfig.resolve_postgres(env(Map.put(url, "CYFR_DB_SSL", "on")))
      assert opts[:ssl] == true

      for other <- ~w(yes 1 TRUE) do
        assert {:error, _message} =
                 RuntimeConfig.resolve_postgres(env(Map.put(url, "CYFR_DB_SSL", other)))
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

  describe "resolve_access/1, as tests/fixtures/access_modes.json holds it" do
    # The access engine (apps/codex/internal/access) reads the same file and
    # agrees with every answer here.
    @access_vectors Path.expand("../../../../tests/fixtures/access_modes.json", __DIR__)

    defp access_vectors, do: @access_vectors |> File.read!() |> Jason.decode!()

    defp access_input(%{"file" => file, "process" => process, "release?" => release?}),
      do: %{file: file, process: process, release?: release?}

    # A result in the vector file's shape.
    defp access_json({:ok, access}) do
      listener = fn
        :none -> "none"
        {address, port} -> [address, port]
      end

      trust =
        case access.trust do
          :none -> "none"
          {:cidrs, cidrs} -> %{"cidrs" => cidrs}
          {:hops, hops} -> %{"hops" => hops}
        end

      assert Map.keys(access) |> Enum.sort() ==
               ~w(assertion canonical check_origins digest head hsts listeners mode origin trust)a

      %{
        "access" => %{
          "mode" => Atom.to_string(access.mode),
          "head" => access.head,
          "canonical" => access.canonical,
          "digest" => access.digest,
          "origin" => access.origin,
          "listeners" => %{
            "loopback" => listener.(access.listeners.loopback),
            "proxy" => listener.(access.listeners.proxy)
          },
          "trust" => trust,
          "hsts" => Atom.to_string(access.hsts),
          "check_origins" => access.check_origins,
          "assertion" => Atom.to_string(access.assertion)
        }
      }
    end

    defp access_json({:error, %{code: code, class: class, payload: payload} = refusal}) do
      assert map_size(refusal) == 3

      %{
        "refusal" => %{
          "code" => Atom.to_string(code),
          "class" => Atom.to_string(class),
          "payload" => Map.new(payload, fn {key, value} -> {Atom.to_string(key), value} end),
          "sentence" => Prima.Refusal.message({code, payload})
        }
      }
    end

    test "every boot vector resolves to its answer, refusals to their code, class, payload and sentence" do
      boot = access_vectors()["boot"]
      assert boot != []

      for vector <- boot do
        expected = Map.take(vector, ["access", "refusal"])
        assert map_size(expected) == 1, vector["name"]

        assert access_json(RuntimeConfig.resolve_access(access_input(vector["input"]))) ==
                 expected,
               vector["name"]
      end

      codes = for %{"refusal" => %{"code" => code}} <- boot, uniq: true, do: code

      # Every boot refusal the access resolver makes, and the malformed
      # setting, is among the vectors.
      assert Enum.sort(codes) ==
               Enum.sort(~w(access_source_conflict access_assertion_from_file access_missing
                            access_unknown_mode access_local_mismatch access_tailnet_host_invalid
                            access_tailnet_node_invalid access_public_host_invalid
                            access_public_url_mismatch access_key_outside_mode
                            access_bind_not_loopback access_setting_invalid))
    end

    test "the canonical bytes and digest of every derived head are these" do
      derive = access_vectors()["derive"]
      heads = for %{"head" => head} = vector <- derive, do: {head, vector}
      assert heads != []

      for {head, vector} <- heads do
        assert RuntimeConfig.access_digest(head) ==
                 %{canonical: vector["canonical"], digest: vector["digest"]},
               vector["name"]

        assert {:ok, digest} = Prima.JCS.hash(head)
        assert digest == vector["digest"]
        refute vector["canonical"] =~ "null"
      end

      # Every refused derivation is a row of the refusal table, of its class.
      refused = for %{"refusal" => refusal} = vector <- derive, do: {refusal, vector["name"]}
      assert refused != []

      for {%{"code" => code, "class" => class, "payload" => payload}, name} <- refused do
        reason =
          {String.to_existing_atom(code),
           Map.new(payload, fn {key, value} -> {String.to_existing_atom(key), value} end)}

        assert %Prima.Refusal{class: refused_class, message: message} =
                 Prima.Refusal.classify(reason)

        assert Atom.to_string(refused_class) == class, name
        assert message != Prima.Refusal.unconfirmed(), name
      end

      # Each derived head is its own: a change of port, email, builds URL
      # or node gives a new digest.
      digests = for {_head, vector} <- heads, do: vector["digest"]
      assert Enum.uniq(digests) == digests
    end

    test "the compose selection of a head" do
      profiles = access_vectors()["profiles"]
      assert profiles != []

      for %{"mode" => mode, "profiles" => expected} = vector <- profiles do
        assert RuntimeConfig.access_profiles(mode, vector["builds_url"]) == expected,
               inspect(vector)
      end
    end

    test "the names an access mode is written with" do
      names = access_vectors()["names"]

      for {section, check} <- [
            {"tailnet_names", &RuntimeConfig.tailnet_name?/1},
            {"node_ids", &RuntimeConfig.tailnet_node_id?/1},
            {"domains", &RuntimeConfig.public_domain?/1},
            {"builds_urls", &RuntimeConfig.builds_url?/1}
          ] do
        cases = names[section]
        assert Enum.any?(cases, & &1["valid"]) and Enum.any?(cases, &(not &1["valid"])), section

        for %{"value" => value, "valid" => valid, "why" => why} <- cases do
          assert check.(value) == valid, "#{section} #{inspect(value)} (#{why})"
        end
      end
    end

    test "a dev or test run without a mode is local, and a release without one is refused" do
      assert {:ok, %{mode: :local, assertion: :absent}} =
               RuntimeConfig.resolve_access(%{file: nil, process: %{}, release?: false})

      assert {:error, %{code: :access_missing, class: :setup_required, payload: %{}}} =
               RuntimeConfig.resolve_access(%{file: nil, process: %{}, release?: true})
    end

    test "with no .env read, the process alone decides and no source rule applies" do
      process = %{
        "CYFR_ACCESS" => "local",
        "CYFR_BIND_ADDRESS" => "172.16.230.2",
        "CYFR_LOCAL_INGRESS_ASSERTED" => "true"
      }

      assert {:ok, %{assertion: :process, listeners: %{loopback: {"172.16.230.2", 4000}}}} =
               RuntimeConfig.resolve_access(%{file: nil, process: process, release?: true})

      # The same assignment read from .env is refused, whatever its value.
      for value <- ["true", "false", ""] do
        assert {:error, %{code: :access_assertion_from_file}} =
                 RuntimeConfig.resolve_access(%{
                   file: %{"CYFR_LOCAL_INGRESS_ASSERTED" => value},
                   process: process,
                   release?: true
                 })
      end
    end
  end

  describe "resolve_access/1's input rules" do
    defp resolve_local(extra) do
      RuntimeConfig.resolve_access(%{
        file: nil,
        process: Map.merge(%{"CYFR_ACCESS" => "local"}, extra),
        release?: true
      })
    end

    test "a value that is not UTF-8 is refused by its name, never a crash" do
      public = %{
        "CYFR_ACCESS" => "public",
        "CYFR_HOST" => "cyfr.example.com",
        "CYFR_PUBLIC_URL" => "https://cyfr.example.com"
      }

      for key <- ~w(CADDY_ACME_EMAIL CYFR_LOCUS_BUILDS_URL CYFR_HOST CYFR_ACCESS CYFR_PORT) do
        assert {:error,
                %{
                  code: :access_setting_invalid,
                  class: :invalid_argument,
                  payload: %{key: ^key} = payload
                }} =
                 resolve_local(Map.put(public, key, "a" <> <<255>>)),
               key

        refute Map.has_key?(payload, :value), key
        assert String.valid?(Prima.Refusal.message({:access_setting_invalid, payload}))
      end

      # The file's own read is held to the same rule.
      assert {:error, %{code: :access_setting_invalid, payload: %{key: "CYFR_HOST"}}} =
               RuntimeConfig.resolve_access(%{
                 file: %{"CYFR_HOST" => <<255>>},
                 process: %{"CYFR_ACCESS" => "local", "CYFR_HOST" => <<255>>},
                 release?: true
               })
    end

    test "a malformed builds URL is refused before the head or its profiles" do
      for url <- [
            "http://locus-builds:bad",
            "http://locus-builds:4100/path",
            "http://locus-builds:4100?token=x",
            "http://user@locus-builds:4100",
            "ftp://locus-builds:4100",
            "not-a-url"
          ] do
        assert {:error,
                %{
                  code: :access_setting_invalid,
                  payload: %{key: "CYFR_LOCUS_BUILDS_URL", value: ^url}
                }} =
                 resolve_local(%{"CYFR_LOCUS_BUILDS_URL" => url}),
               url
      end
    end
  end
end
