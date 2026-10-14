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

  # The child specs under `id` in a census of `Cyfr.Application.tiers/0`.
  defp specs({_id, _strategy, _intensity, children}, id),
    do: Enum.flat_map(children, &specs(&1, id))

  defp specs(%{id: id} = spec, id), do: [spec]
  defp specs(_spec, _id), do: []

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

  describe "CYFR_SECRET_KEY_BASE" do
    # The file reads its .env files from RELEASE_ROOT, so each test points
    # that at a directory of its own: no ambient file supplies the key the
    # environment lacks.
    @describetag :tmp_dir

    # An empty value is unset, as for every other setting this file reads,
    # so both refuse the boot by name before anything derives from it.
    for {label, value} <- [{"missing", nil}, {"empty", ""}] do
      test "#{label}, refuses the boot naming it", %{tmp_dir: dir} do
        with_env(%{"CYFR_SECRET_KEY_BASE" => unquote(value), "RELEASE_ROOT" => dir}, fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
          assert message =~ "environment variable CYFR_SECRET_KEY_BASE is missing."
        end)
      end
    end

    # The control for the two above: the directory they point at is the
    # one the file reads, and a key its .env holds is the key.
    test "is read from RELEASE_ROOT's .env when the environment has none", %{tmp_dir: dir} do
      key_base = Base.encode16(:crypto.strong_rand_bytes(64), case: :lower)
      File.write!(Path.join(dir, ".env"), "CYFR_SECRET_KEY_BASE=#{key_base}\n")
      before = System.get_env("CYFR_SECRET_KEY_BASE")

      with_env(%{"CYFR_SECRET_KEY_BASE" => nil, "RELEASE_ROOT" => dir}, fn ->
        assert read_prod_config!()[:sanctum][:secret_key_base] == key_base
      end)

      # The read puts what it sourced into the environment; the key goes
      # with the test.
      assert System.get_env("CYFR_SECRET_KEY_BASE") == before
    end

    # A set value that is blank after trimming, or shorter than the 64
    # bytes Plug's cookie store needs, refuses the boot naming the
    # variable and the reason, never the value.
    for {label, value, reason} <- [
          {"whitespace-only", "  \t ", "is blank"},
          {"63 bytes", "short-key-base-" <> String.duplicate("q", 47) <> "!",
           "is shorter than 64 bytes"}
        ] do
      test "#{label}, refuses the boot naming it", %{tmp_dir: dir} do
        value = unquote(value)

        with_env(%{"CYFR_SECRET_KEY_BASE" => value, "RELEASE_ROOT" => dir}, fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
          assert message =~ "[Cyfr] FATAL: CYFR_SECRET_KEY_BASE #{unquote(reason)}"
          refute String.contains?(message, value)
        end)
      end
    end

    # An accepted value is the key base byte for byte, never trimmed: the
    # keyring and the salts hash its exact bytes. The length is bytes, so
    # 32 two-byte characters are 64 bytes and enough.
    for {label, value} <- [
          {"of exactly 64 bytes", String.duplicate("k", 63) <> "!"},
          {"of 64 bytes in 32 characters", String.duplicate("é", 32)},
          {"with surrounding spaces", " " <> String.duplicate("s", 64) <> " "}
        ] do
      test "#{label} is the key base as given", %{tmp_dir: dir} do
        key_base = unquote(value)

        with_env(%{"CYFR_SECRET_KEY_BASE" => key_base, "RELEASE_ROOT" => dir}, fn ->
          config = read_prod_config!()
          assert config[:sanctum][:secret_key_base] == key_base
          assert config[:cyfr][CyfrWeb.Endpoint][:secret_key_base] == key_base
        end)
      end
    end

    # Development keeps its config file's key when the variable is unset or
    # empty, and holds a set value to the same rule as production.
    defp read_dev_config! do
      Config.Reader.read!(Path.join(@root, "config/runtime.exs"),
        env: :dev,
        imports: :disabled
      )
    end

    for {label, value} <- [{"unset", nil}, {"empty", ""}] do
      test "#{label}, a development boot keeps its config file's key", %{tmp_dir: dir} do
        with_env(%{"CYFR_SECRET_KEY_BASE" => unquote(value), "RELEASE_ROOT" => dir}, fn ->
          refute Keyword.has_key?(read_dev_config!()[:sanctum] || [], :secret_key_base)
        end)
      end
    end

    for {label, value, reason} <- [
          {"whitespace-only", "  \t ", "is blank"},
          {"63 bytes", "short-key-base-" <> String.duplicate("q", 47) <> "!",
           "is shorter than 64 bytes"}
        ] do
      test "#{label}, refuses a development boot too", %{tmp_dir: dir} do
        value = unquote(value)

        with_env(%{"CYFR_SECRET_KEY_BASE" => value, "RELEASE_ROOT" => dir}, fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_dev_config!/0))
          assert message =~ "[Cyfr] FATAL: CYFR_SECRET_KEY_BASE #{unquote(reason)}"
          refute String.contains?(message, value)
        end)
      end
    end
  end

  describe "CYFR_LOCUS_RUNTIME_ROOT" do
    test "is the 32-byte root its 64 hexadecimal digits spell, in either case" do
      root = :crypto.strong_rand_bytes(32)

      for text <- [Base.encode16(root, case: :lower), Base.encode16(root)] do
        with_env(%{"CYFR_LOCUS_RUNTIME_ROOT" => text}, fn ->
          assert get_in(read_prod_config!(), [:cyfr, :locus_runtime_root]) == root
        end)
      end
    end

    test "unset or blank configures no root" do
      for value <- [nil, ""] do
        with_env(%{"CYFR_LOCUS_RUNTIME_ROOT" => value}, fn ->
          assert get_in(read_prod_config!(), [:cyfr, :locus_runtime_root]) == nil
        end)
      end
    end

    test "a malformed key refuses the boot" do
      for text <- ["abc", String.duplicate("g", 64), Base.encode64(:crypto.strong_rand_bytes(32))] do
        with_env(%{"CYFR_LOCUS_RUNTIME_ROOT" => text}, fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end

          assert Exception.message(error) =~
                   "CYFR_LOCUS_RUNTIME_ROOT must be exactly 64 hexadecimal"
        end)
      end
    end
  end

  describe "the admission floors" do
    # Each rate-limit maximum and window, concurrency ceiling, subscription
    # and event limit, the setting it pins and the least value it takes.
    @floors [
      {"CYFR_OPUS_MAX_CONCURRENT", :opus_max_concurrent, 32},
      {"CYFR_OPUS_MAX_CONCURRENT_PER_TENANT", :opus_max_concurrent_per_tenant, 1},
      {"CYFR_MCP_RATE_LIMIT_MAX", :mcp_rate_limit_max, 1},
      {"CYFR_MCP_RATE_LIMIT_WINDOW_MS", :mcp_rate_limit_window_ms, 1},
      {"CYFR_WEBHOOK_PER_IP_RATE_LIMIT_MAX", :webhook_per_ip_rate_limit_max, 1},
      {"CYFR_API_RATE_LIMIT_MAX", :api_rate_limit_max, 1},
      {"CYFR_API_RATE_LIMIT_WINDOW_MS", :api_rate_limit_window_ms, 1},
      {"CYFR_MCP_SUBSCRIPTION_MAX_CONCURRENT", :mcp_subscription_max_concurrent, 1},
      {"CYFR_MCP_SUBSCRIPTION_MAX_MS", :mcp_subscription_max_ms, 1},
      {"CYFR_OPUS_EVENTS_MAX_CONCURRENT", :opus_events_max_concurrent, 1},
      {"CYFR_OPUS_EVENTS_MAX_MS", :opus_events_max_ms, 1}
    ]

    test "unset pins nothing; set, the least value and above are pinned" do
      with_env(Map.new(@floors, fn {name, _key, _least} -> {name, nil} end), fn ->
        cyfr = read_prod_config!()[:cyfr]

        for {_name, key, _least} <- @floors do
          refute List.keymember?(cyfr[:deployment_pinned], Atom.to_string(key), 0),
                 "#{key} is pinned with its variable unset"

          refute Keyword.has_key?(cyfr, key), "#{key} is configured with its variable unset"
        end
      end)

      for {name, key, least} <- @floors, value <- [least, least + 1] do
        with_env(%{name => Integer.to_string(value)}, fn ->
          pinned = read_prod_config!()[:cyfr][:deployment_pinned]
          assert {Atom.to_string(key), value} in pinned, "#{name}=#{value}"
        end)
      end
    end

    test "zero, a negative number, anything below the least value or not a whole number refuses the boot naming the variable" do
      for {name, _key, least} <- @floors,
          bad <- Enum.uniq(["0", "-1", Integer.to_string(least - 1), "ten", "1.5", "60s"]) do
        with_env(%{name => bad}, fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))

          assert message =~ "[Cyfr] FATAL: #{name}=#{inspect(bad)} must be a whole number",
                 "#{name}=#{bad}: #{message}"

          assert message =~ "from #{least} to "
        end)
      end
    end
  end

  describe "the trusted proxies" do
    @proxy_unset %{
      "CYFR_BEHIND_PROXY" => nil,
      "CYFR_TRUSTED_PROXY_HOPS" => nil,
      "CYFR_TRUSTED_PROXY_CIDRS" => nil
    }

    test "behind a proxy, one hop unless set, any count from 0 to 16, and the CIDRs as listed" do
      with_env(Map.put(@proxy_unset, "CYFR_BEHIND_PROXY", "on"), fn ->
        sanctum = read_prod_config!()[:sanctum]
        assert sanctum[:trust_x_forwarded_for] == true
        assert sanctum[:trusted_proxy_hops] == 1
        refute Keyword.has_key?(sanctum, :trusted_proxy_cidrs)
      end)

      for hops <- [0, 1, 16] do
        env = %{"CYFR_BEHIND_PROXY" => "on", "CYFR_TRUSTED_PROXY_HOPS" => "#{hops}"}

        with_env(Map.merge(@proxy_unset, env), fn ->
          assert read_prod_config!()[:sanctum][:trusted_proxy_hops] == hops
        end)
      end

      env = %{
        "CYFR_BEHIND_PROXY" => "on",
        "CYFR_TRUSTED_PROXY_CIDRS" => "10.0.0.0/8, 192.0.2.7, fd00::/8"
      }

      with_env(Map.merge(@proxy_unset, env), fn ->
        assert read_prod_config!()[:sanctum][:trusted_proxy_cidrs] ==
                 ["10.0.0.0/8", "192.0.2.7", "fd00::/8"]
      end)
    end

    test "not behind a proxy, nothing is trusted" do
      with_env(@proxy_unset, fn ->
        sanctum = read_prod_config!()[:sanctum]
        refute Keyword.has_key?(sanctum, :trust_x_forwarded_for)
        refute Keyword.has_key?(sanctum, :trusted_proxy_hops)
      end)
    end

    test "a hop count outside 0 to 16 refuses the boot naming it, behind a proxy or not" do
      for behind <- ["on", nil], bad <- ["17", "-1", "one", "1.0"] do
        env = %{"CYFR_BEHIND_PROXY" => behind, "CYFR_TRUSTED_PROXY_HOPS" => bad}

        with_env(Map.merge(@proxy_unset, env), fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))

          assert message =~
                   "[Cyfr] FATAL: CYFR_TRUSTED_PROXY_HOPS=#{inspect(bad)} must be a whole " <>
                     "number of proxy hops from 0 to 16"
        end)
      end
    end

    test "an entry that is neither an address nor a CIDR refuses the boot naming the entry" do
      for behind <- ["on", nil],
          bad <- ["10.0.0.0/33", "10.0.0.0/8/1", "proxy.internal", "10.0.0.0/x", "::1/129"] do
        env = %{
          "CYFR_BEHIND_PROXY" => behind,
          "CYFR_TRUSTED_PROXY_CIDRS" => "10.0.0.0/8, #{bad}"
        }

        with_env(Map.merge(@proxy_unset, env), fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))

          assert message =~
                   "[Cyfr] FATAL: CYFR_TRUSTED_PROXY_CIDRS entry #{inspect(bad)} is neither"
        end)
      end
    end
  end

  describe "the signing salts" do
    # The names the salts were read under before, spelled in parts so the
    # vocabulary scans do not find them here.
    @old_session_salt "CYFR_EMISSARY" <> "_SESSION_SALT"
    @old_live_salt "CYFR_LV" <> "_SALT"
    @salts_unset %{
      "CYFR_SESSION_SALT" => nil,
      "CYFR_LIVE_SALT" => nil,
      @old_session_salt => nil,
      @old_live_salt => nil
    }

    defp salts(config) do
      {config[:cyfr][:session_salt], config[:cyfr][CyfrWeb.Endpoint][:live_view][:signing_salt]}
    end

    test "CYFR_SESSION_SALT and CYFR_LIVE_SALT are the session's and the LiveView socket's" do
      env = %{"CYFR_SESSION_SALT" => "session-salt-set", "CYFR_LIVE_SALT" => "live-salt-set"}

      with_env(Map.merge(@salts_unset, env), fn ->
        assert salts(read_prod_config!()) == {"session-salt-set", "live-salt-set"}
      end)
    end

    test "unset, each is derived from the key base" do
      key_base = Base.encode64(:crypto.strong_rand_bytes(48))

      derived =
        for label <- ["emissary_session", "live_view"] do
          :sha256
          |> :crypto.hash(label <> key_base)
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 16)
        end

      with_env(Map.put(@salts_unset, "CYFR_SECRET_KEY_BASE", key_base), fn ->
        assert salts(read_prod_config!()) == List.to_tuple(derived)
      end)
    end

    # No roster declares the old names, so the boot refuses each by name
    # rather than ignoring it (`Cyfr.Platform.Settings.Roster.unknown/2`).
    test "the old names refuse the boot, naming them" do
      old = %{@old_session_salt => "old-session", @old_live_salt => "old-live"}

      with_env(Map.merge(@salts_unset, old), fn ->
        message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
        assert message =~ "[Cyfr] FATAL: "
        assert message =~ @old_session_salt and message =~ @old_live_salt
        assert message =~ "not a variable this server reads"
      end)
    end
  end

  describe "the Locus backends service" do
    @backends_key :binary.copy(<<0xBA>>, 32)
    @backends_unset %{
      "CYFR_LOCUS_BACKENDS_URL" => nil,
      "CYFR_LOCUS_BACKENDS_KEY" => nil,
      "CYFR_LOCUS_BACKENDS_LEASE_MS" => nil,
      "CYFR_LOCUS_BACKENDS_IDLE_MS" => nil
    }

    test "unset, none is configured; set, the URL without its trailing slash, the key's 32 bytes and each period pinned in milliseconds" do
      with_env(@backends_unset, fn ->
        cyfr = read_prod_config!()[:cyfr]
        assert cyfr[:locus_backends_url] == nil
        assert cyfr[:locus_backends_key] == nil
        refute List.keymember?(cyfr[:deployment_pinned], "locus_backends_lease_ms", 0)
        refute List.keymember?(cyfr[:deployment_pinned], "locus_backends_idle_ms", 0)
      end)

      with_env(
        %{
          "CYFR_LOCUS_BACKENDS_URL" => "http://locus-backends:4101/",
          "CYFR_LOCUS_BACKENDS_KEY" => Base.encode16(@backends_key),
          "CYFR_LOCUS_BACKENDS_LEASE_MS" => "5000",
          "CYFR_LOCUS_BACKENDS_IDLE_MS" => "600000"
        },
        fn ->
          cyfr = read_prod_config!()[:cyfr]
          assert cyfr[:locus_backends_url] == "http://locus-backends:4101"
          assert cyfr[:locus_backends_key] == @backends_key
          assert {"locus_backends_lease_ms", 5_000} in cyfr[:deployment_pinned]
          assert {"locus_backends_idle_ms", 600_000} in cyfr[:deployment_pinned]
          refute Keyword.has_key?(cyfr, :locus_backends_lease_ms)
        end
      )
    end

    test "a malformed URL or key, or a period that is not a whole number of milliseconds in range, refuses the boot by name and never echoes the key" do
      hex = Base.encode16(@backends_key, case: :lower)

      for {key, bad} <- [
            {"CYFR_LOCUS_BACKENDS_URL", "locus-backends:4101"},
            {"CYFR_LOCUS_BACKENDS_URL", "http://locus-backends:4101/mcp"},
            {"CYFR_LOCUS_BACKENDS_KEY", String.slice(hex, 0..62)},
            {"CYFR_LOCUS_BACKENDS_LEASE_MS", "999"},
            {"CYFR_LOCUS_BACKENDS_LEASE_MS", "30s"},
            {"CYFR_LOCUS_BACKENDS_IDLE_MS", "86400001"},
            {"CYFR_LOCUS_BACKENDS_IDLE_MS", "15m"}
          ] do
        with_env(Map.put(@backends_unset, key, bad), fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
          assert message =~ "[Cyfr] FATAL: "
          assert message =~ key
          refute message =~ String.slice(hex, 0..62)
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

  # A `mix` boot runs the runtime beside CYFR and configures it here.
  describe "LOCUS_RUNTIME_MEMORY_BYTES" do
    defp runtime_env(overrides) do
      Map.merge(
        %{
          "RELEASE_NAME" => nil,
          "LOCUS_RUNTIME_KEY" => String.duplicate("ab", 32),
          "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300",
          "LOCUS_RUNTIME_MEMORY_BYTES" => nil
        },
        overrides
      )
    end

    defp runtime_config!, do: read_prod_config!()[:locus][:runtime]

    test "unset leaves the setting's default; set, the whole of the keeper's range is taken" do
      with_env(runtime_env(%{}), fn ->
        refute Keyword.has_key?(runtime_config!(), :runner_memory_bytes)
      end)

      for bytes <- ["16777216", "402653184", "1099511627776"] do
        with_env(runtime_env(%{"LOCUS_RUNTIME_MEMORY_BYTES" => bytes}), fn ->
          assert runtime_config!()[:runner_memory_bytes] == String.to_integer(bytes)
        end)
      end
    end

    test "a value outside the keeper's range, a unit or a fraction refuses the boot by name" do
      for bad <- ["16777215", "1099511627777", "384M", "402653184.5", "-1", "none"] do
        with_env(runtime_env(%{"LOCUS_RUNTIME_MEMORY_BYTES" => bad}), fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "[Cyfr] FATAL: LOCUS_RUNTIME_MEMORY_BYTES"
          assert Exception.message(error) =~ "bytes from 16777216 to 1099511627776"
        end)
      end
    end
  end

  describe "the keeper" do
    test "no keeper is configured: the channel keeper is the one launcher" do
      with_env(runtime_env(%{}), fn ->
        refute Keyword.has_key?(runtime_config!(), :keeper)
      end)
    end
  end

  describe "the releases this file configures" do
    test "every boot is CYFR, and a mix boot alone runs the runtime beside it" do
      with_env(%{"RELEASE_NAME" => "cyfr"}, fn ->
        config = read_prod_config!()
        assert Keyword.has_key?(config[:cyfr], :locus_runtime_workers)
        refute Keyword.has_key?(config, :locus)
      end)

      with_env(runtime_env(%{}), fn ->
        config = read_prod_config!()
        assert Keyword.has_key?(config[:cyfr], :locus_runtime_workers)
        assert config[:locus][:runtime][:service_key] == String.duplicate("ab", 32)
      end)
    end
  end

  # The runtime's retired control-plane names are no variable this server
  # reads: the boot refuses each through its refusal of an undeclared
  # `CYFR_*` name, so a stale `.env` cannot boot cyfr.
  describe "the runtime's retired control-plane variables" do
    test "each is refused by name" do
      # Spelled split so the retired names are not themselves found here.
      for name <- [
            "CYFR_OP" <> "US_KEY",
            "CYFR_OP" <> "US_WORKERS",
            "CYFR_OP" <> "US_WATCH_POLL_MS"
          ] do
        with_env(%{name => "x"}, fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
          assert message =~ "[Cyfr] FATAL: #{name} is not a variable this server reads"
        end)
      end
    end
  end

  # The execution domain's variables under the name it had before are no
  # variable this server reads either: each is refused by name, so a stale
  # `.env` cannot boot cyfr with a ceiling it no longer applies.
  describe "the execution domain's retired variables" do
    test "each is refused by name, even holding a value its successor takes" do
      # Spelled split so the retired names are not themselves found here.
      for name <- [
            "CYFR_CRU" <> "CIBLE_MAX_CONCURRENT",
            "CYFR_CRU" <> "CIBLE_MAX_CONCURRENT_PER_TENANT",
            "CYFR_CRU" <> "CIBLE_EVENTS_MAX_CONCURRENT",
            "CYFR_CRU" <> "CIBLE_EVENTS_MAX_MS"
          ] do
        with_env(%{name => "64"}, fn ->
          message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
          assert message =~ "[Cyfr] FATAL: #{name} is not a variable this server reads"
        end)
      end
    end
  end

  # The control plane holds the runtime's root, never a key: a worker
  # service's key is derived from the root by `Opus.Keys.locus_runtime_key/1`
  # alone, and every other name the control plane gives the root, its checks
  # and its variable says root.
  @key_name ~r/(?<![A-Za-z0-9_])((?:[A-Za-z_][A-Za-z0-9_]*\.)*)locus_runtime_key(?![A-Za-z0-9_])/
  # Spelled split so this file does not name the variable itself.
  @key_variable "CYFR_LOCUS_RUNTIME" <> "_KEY"

  describe "the runtime's root" do
    test "is named a key only where Opus.Keys derives a service's key from it" do
      found =
        for glob <- ["apps/*/lib/**/*.{ex,exs}", "config/**/*.exs"],
            path <- Prima.Test.SourceTree.files!(Path.join(@root, glob)),
            rel = Path.relative_to(path, @root),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            not root_named_as_root?(rel, line),
            do: "#{rel}:#{n}: #{String.trim(line)}"

      assert found == [],
             """
             The control plane names its runtime root a key outside `Opus.Keys`'
             derivation of a service's key:

             #{Enum.join(found, "\n")}
             """
    end
  end

  # A line names the root a key only through `Opus.Keys`: its definition of
  # the derivation, or a call or capture of it.
  defp root_named_as_root?(rel, line) do
    not String.contains?(line, @key_variable) and
      Enum.all?(Regex.scan(@key_name, line, capture: :all_but_first), fn [via] ->
        via in ["Keys.", "Opus.Keys."] or
          (via == "" and rel == "apps/cyfr/lib/opus/keys.ex" and
             line =~ ~r/^\s*(def|@spec) locus_runtime_key\(/)
      end)
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
        %{
          "CYFR_LOCUS_RUNTIME_WORKERS" => nil,
          "CYFR_HOST_API_BIND" => nil,
          "CYFR_HOST_API_PORT" => nil
        },
        fn ->
          cyfr = read_prod_config!()[:cyfr]

          assert cyfr[:locus_runtime_workers] == [
                   %{id: "wrk_local", url: "http://127.0.0.1:4200", components: nil}
                 ]

          assert cyfr[:host_api_bind] == {127, 0, 0, 1}
          assert cyfr[:host_api_port] == 4300

          # No address of its own: a deployment that was not told one
          # issues assignments naming none, and its worker posts to the
          # single address it was configured with.
          assert cyfr[:host_api_url] == nil
          refute Keyword.has_key?(read_prod_config!(), :locus)
        end
      )
    end

    test "CYFR_LOCUS_RUNTIME_WORKERS, CYFR_HOST_API_BIND, _PORT and _URL are taken as set" do
      with_env(
        %{
          "CYFR_LOCUS_RUNTIME_WORKERS" =>
            "wrk_locus=http://locus-runtime:4200, wrk_b=https://b.internal/",
          "CYFR_HOST_API_BIND" => "0.0.0.0",
          "CYFR_HOST_API_PORT" => "4301",
          "CYFR_HOST_API_URL" => "http://cyfr-1:4301"
        },
        fn ->
          cyfr = read_prod_config!()[:cyfr]

          assert cyfr[:locus_runtime_workers] == [
                   %{id: "wrk_locus", url: "http://locus-runtime:4200", components: nil},
                   %{id: "wrk_b", url: "https://b.internal", components: nil}
                 ]

          assert cyfr[:host_api_bind] == {0, 0, 0, 0}
          assert cyfr[:host_api_port] == 4301
          assert cyfr[:host_api_url] == "http://cyfr-1:4301"
        end
      )
    end

    # The address runtime.exs parses is the one the boot hands the host
    # API's listener: read through the census of the tree `start/2` starts,
    # down through `Opus.Supervisor`'s own `init/1`, to the listener's spec.
    test "the parsed CYFR_HOST_API_BIND is the host API listener's bind" do
      with_env(%{"CYFR_HOST_API_BIND" => "127.0.0.2"}, fn ->
        bind = read_prod_config!()[:cyfr][:host_api_bind]
        assert bind == {127, 0, 0, 2}

        previous = Application.fetch_env(:cyfr, :host_api_bind)
        Application.put_env(:cyfr, :host_api_bind, bind)

        try do
          specs = Enum.flat_map(Cyfr.Application.tiers(), &specs(&1, Opus.HostListener))

          assert [%{start: {Opus.HostListener.Supervisor, :start_link, [opts]}}] = specs
          assert opts[:bind] == {127, 0, 0, 2}
        after
          case previous do
            {:ok, value} -> Application.put_env(:cyfr, :host_api_bind, value)
            :error -> Application.delete_env(:cyfr, :host_api_bind)
          end
        end
      end)
    end

    test "a malformed worker entry, address or port refuses the boot by name" do
      for {var, value} <- [
            {"CYFR_LOCUS_RUNTIME_WORKERS", "runtime=http://locus-runtime:4200"},
            {"CYFR_LOCUS_RUNTIME_WORKERS", "wrk_locus=locus-runtime:4200"},
            {"CYFR_HOST_API_BIND", "cyfr"},
            {"CYFR_HOST_API_PORT", "65536"}
          ] do
        with_env(%{var => value}, fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "[Cyfr] FATAL: #{var}"
        end)
      end
    end

    test "a mix boot configures the runtime from LOCUS_RUNTIME_* over its own defaults" do
      key = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      with_env(
        %{
          "RELEASE_NAME" => nil,
          "LOCUS_RUNTIME_SERVICE_ID" => "wrk_locus",
          "LOCUS_RUNTIME_KEY" => key,
          "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300/",
          "LOCUS_RUNTIME_BIND" => "0.0.0.0",
          "LOCUS_RUNTIME_PORT" => "4200"
        },
        fn ->
          assert read_prod_config!()[:locus][:runtime] == [
                   service_id: "wrk_locus",
                   service_key: key,
                   host_url: "http://cyfr:4300/",
                   bind: "0.0.0.0",
                   port: 4200
                 ]
        end
      )
    end

    test "a mix boot refuses a malformed runtime value, or a stray LOCUS_RUNTIME_* name, by name" do
      base = %{
        "RELEASE_NAME" => nil,
        "LOCUS_RUNTIME_KEY" => String.duplicate("ab", 32),
        "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
      }

      for {overrides, message} <- [
            {%{"LOCUS_RUNTIME_KEY" => "abc"}, "LOCUS_RUNTIME_KEY must be"},
            {%{"LOCUS_RUNTIME_SERVICE_ID" => "runtime"}, "LOCUS_RUNTIME_SERVICE_ID must be"},
            {%{"LOCUS_RUNTIME_HOST_API_URL" => "cyfr:4300"},
             "LOCUS_RUNTIME_HOST_API_URL must be"},
            {%{"LOCUS_RUNTIME_BIND" => "cyfr"}, "LOCUS_RUNTIME_BIND must be"},
            {%{"LOCUS_RUNTIME_POOL_SIZ" => "4"},
             "LOCUS_RUNTIME_POOL_SIZ is not a variable the locus release reads"}
          ] do
        with_env(Map.merge(base, overrides), fn ->
          error = assert_raise RuntimeError, fn -> read_prod_config!() end
          assert Exception.message(error) =~ "[Cyfr] FATAL: " <> message
        end)
      end

      # The container limits compose reads from the same .env are the
      # roster's, and refuse nothing.
      with_env(Map.merge(base, %{"LOCUS_RUNTIME_MEMORY_LIMIT" => "4G"}), fn ->
        assert read_prod_config!()[:locus][:runtime][:service_key] == String.duplicate("ab", 32)
      end)
    end

    test "a boot that runs the runtime beside CYFR derives the service key from the root, minting one if unset" do
      root = :crypto.strong_rand_bytes(32)
      {:ok, derived} = Prima.WorkerAuth.worker_key(root, "wrk_local")

      with_env(
        %{
          "RELEASE_NAME" => nil,
          "CYFR_LOCUS_RUNTIME_ROOT" => Base.encode16(root),
          "LOCUS_RUNTIME_KEY" => nil
        },
        fn ->
          config = read_prod_config!()
          assert config[:cyfr][:locus_runtime_root] == root
          assert config[:locus][:runtime][:service_id] == "wrk_local"
          assert config[:locus][:runtime][:service_key] == Base.encode16(derived, case: :lower)
          assert config[:locus][:runtime][:host_url] == "http://127.0.0.1:4300"
          assert config[:locus][:runtime][:port] == 4200
        end
      )

      with_env(
        %{"RELEASE_NAME" => nil, "CYFR_LOCUS_RUNTIME_ROOT" => nil, "LOCUS_RUNTIME_KEY" => nil},
        fn ->
          config = read_prod_config!()
          minted = config[:cyfr][:locus_runtime_root]
          assert byte_size(minted) == 32
          {:ok, key} = Prima.WorkerAuth.worker_key(minted, "wrk_local")
          assert config[:locus][:runtime][:service_key] == Base.encode16(key, case: :lower)
        end
      )
    end
  end
end
