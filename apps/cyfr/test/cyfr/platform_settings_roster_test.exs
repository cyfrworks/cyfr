# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.PlatformSettingsRosterTest do
  @moduledoc """
  The one declaration of every name the `cyfr` boot reads
  (`Cyfr.Platform.Settings.Roster`), held to the tree: each setting
  complete, restart-scoped only with an apply, stale-served only where a
  stale value refuses no one, and read through
  `Arca.PlatformSettings.effective/1`: no reader takes a live setting from
  the application environment, and no test puts one there. The
  compose-only class derived from `docker-compose.yml`; every documented
  and every read name declared. Then the boot itself, evaluated from
  `config/runtime.exs` the way a release evaluates it: presence recorded as
  pins, only the restart-scoped settings written to the application
  environment, every undeclared `CYFR_*` name refused by name, and an
  `opus` release that reads no roster refusing its own stray names.

  The checks are functions of the entries, so each is also run on a
  planted violation it must refuse.
  """

  # Sets the operating system's environment for the duration of a case.
  use ExUnit.Case, async: false

  alias Cyfr.Platform.Settings.Roster
  alias Cyfr.Platform.Settings.Roster.Entry

  @root Path.expand("../../../..", __DIR__)

  # ---------------------------------------------------------------------------
  # The rules, as functions of the entries
  # ---------------------------------------------------------------------------

  # A setting with neither a variable nor a default has no value anywhere
  # before someone stores one.
  defp unvalued(entries),
    do: for(%Entry{variable: nil, default: nil, key: key} <- entries, do: key)

  # A restart-scoped setting is applied at boot by one host step, so it
  # names one; the log level is the one live setting that does. Anything
  # else is no apply story, or one that nothing runs.
  defp apply_violations(entries) do
    Enum.flat_map(entries, fn %Entry{key: key, scope: scope, apply: apply} ->
      cond do
        scope not in [:live, :restart] -> [{key, :scope}]
        scope == :restart and not mfa?(apply) -> [{key, :restart_without_apply}]
        scope == :live and apply != nil and key != "log_level" -> [{key, :live_with_apply}]
        apply != nil and not mfa?(apply) -> [{key, :apply_not_an_mfa}]
        true -> []
      end
    end)
  end

  defp mfa?({module, function, 1}) when is_atom(module) and is_atom(function), do: true
  defp mfa?(_other), do: false

  # Caps that gate a creation and the security windows refuse a stale value;
  # rate limits, stream limits and cache bounds serve one.
  @refuse ~w(max_athanors max_groups_per_person max_pairs_per_person max_members_per_group
             max_threads_per_athanor mint_per_hour athanor_storage_bytes session_ttl_hours
             webhook_max_skew_seconds webhook_idempotency_ttl_seconds)

  defp stale_violations(entries) do
    for %Entry{key: key, stale: stale} <- entries,
        expected = if(key in @refuse, do: :refuse, else: :serve),
        stale != expected,
        do: {key, stale}
  end

  # A setting still written to the application environment (a
  # restart-scoped one) is written under the application its reader reads
  # it under, found in the code: a literal read of `{app, key}`, or a key
  # `Cyfr.Boundaries` records as read by a name the caller computes.
  defp misplaced(entries, reads) do
    by_name = Cyfr.Boundaries.config_keys_read_by_name()

    for %Entry{app: app, config: [head | _], key: key} <- entries,
        app != :logger,
        not MapSet.member?(reads, {app, head}),
        not Map.has_key?(by_name, head),
        do: {key, app, head}
  end

  # Restart-scoped settings are read once at boot from the application
  # environment, where the boot wrote a pinned value and the setting's
  # apply a stored one: `Arca.PlatformSettings.effective/1` answers the
  # stored row, which may be a value saved for the next boot and not the
  # one running, so these alone are read there.
  @restart_read ~w(crucible_max_concurrent crucible_max_concurrent_per_tenant)

  # The keywords a group of settings was once read under whole: the caps
  # under Sanctum and the worker watch's bounds under the host.
  @keywords ~w(caps opus_watch)

  # Every use of a live setting's value in the application environment,
  # under any application, by one of `verbs`: `{path, app, key}`. The key
  # is the setting's store key or one of `@keywords`.
  defp env_reads(sources, verbs) do
    names =
      MapSet.new(
        for(%Entry{key: key} <- Roster.entries(), key not in @restart_read, do: key) ++
          @keywords
      )

    pattern =
      Regex.compile!(
        "Application\\.(?:#{Enum.join(verbs, "|")})\\(\\s*:([a-z_]+),\\s*:([a-z_0-9]+)"
      )

    for {path, source} <- sources,
        [app, key] <- Regex.scan(pattern, source, capture: :all_but_first),
        MapSet.member?(names, key),
        do: {path, String.to_atom(app), String.to_atom(key)}
  end

  # The islands (Opus, Locus) read none of the roster's settings: each
  # declares its own under its own prefix, and may name a key of its own
  # alike (Locus's `:log_level`).
  @islands ~w(apps/opus/ apps/locus/)

  defp tree(glob) do
    for path <- Path.wildcard(Path.join(@root, glob)),
        relative = Path.relative_to(path, @root),
        not String.starts_with?(relative, @islands),
        do: {relative, File.read!(path)}
  end

  defp lib_reads do
    for path <- Path.wildcard(Path.join(@root, "apps/*/lib/**/*.ex")),
        [app, key] <-
          Regex.scan(
            ~r/Application\.(?:get_env|fetch_env!?)\(\s*:([a-z_]+),\s*:([a-z_0-9]+)/,
            File.read!(path),
            capture: :all_but_first
          ),
        into: MapSet.new(),
        do: {String.to_atom(app), String.to_atom(key)}
  end

  # The names docker-compose.yml interpolates that nothing in the tree
  # reads: every `${…}` name, less those a release's reader spells.
  defp derived_compose_only do
    compose = File.read!(Path.join(@root, "docker-compose.yml"))

    interpolated =
      ~r/\$\{([A-Z][A-Z0-9_]*)/ |> Regex.scan(compose, capture: :all_but_first) |> List.flatten()

    read =
      MapSet.new(
        spelled(~w(config/runtime.exs apps/cyfr/lib/cyfr/runtime_config.ex)) ++
          Roster.variables() ++
          Roster.deployment() ++
          Opus.Settings.variables() ++ Locus.Config.variables()
      )

    interpolated |> Enum.uniq() |> Enum.reject(&MapSet.member?(read, &1)) |> Enum.sort()
  end

  defp spelled(files) do
    for file <- files,
        [name] <-
          Regex.scan(~r/"([A-Z][A-Z0-9_]*[A-Z0-9])"/, File.read!(Path.join(@root, file)),
            capture: :all_but_first
          ),
        do: name
  end

  # The names an env example documents: its assignment lines, commented or not.
  defp documented(file) do
    ~r/^#?[ \t]*([A-Z][A-Z0-9_]*)=/m
    |> Regex.scan(File.read!(Path.join(@root, file)), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # The roster
  # ---------------------------------------------------------------------------

  describe "the entries" do
    test "every setting has a value somewhere: a variable, a default, or both" do
      assert unvalued(Roster.entries()) == []

      planted = %Entry{
        key: "planted",
        app: :cyfr,
        variable: nil,
        type: :integer,
        default: nil,
        validator: fn v -> {:ok, v} end,
        group: :planted,
        scope: :live,
        stale: :serve
      }

      assert unvalued([planted | Roster.entries()]) == ["planted"]
    end

    test "keys and variables are each declared once, every variable under the prefix" do
      keys = Enum.map(Roster.entries(), & &1.key)
      assert keys == Enum.uniq(keys)

      variables = Roster.variables()
      assert variables == Enum.uniq(variables)
      assert Enum.all?(variables, &String.starts_with?(&1, "CYFR_"))

      foreign = Enum.map(Roster.foreign(), &elem(&1, 0))

      for {a, b} <- [
            {variables, Roster.deployment()},
            {variables, Roster.compose_only()},
            {Roster.deployment(), Roster.compose_only()},
            {variables ++ Roster.deployment(), foreign}
          ] do
        assert MapSet.disjoint?(MapSet.new(a), MapSet.new(b))
      end
    end

    test "exactly the settings that move, and the three the tincture frames will read" do
      assert Enum.sort(Enum.map(Roster.entries(), & &1.key)) ==
               Enum.sort(~w(
                 max_athanors max_groups_per_person max_pairs_per_person max_members_per_group
                 max_threads_per_athanor mint_per_hour athanor_storage_bytes
                 crucible_max_concurrent crucible_max_concurrent_per_tenant
                 mcp_rate_limit_max mcp_rate_limit_window_ms api_rate_limit_max
                 api_rate_limit_window_ms webhook_per_ip_rate_limit_max
                 mcp_subscription_max_concurrent mcp_subscription_max_ms
                 crucible_events_max_concurrent crucible_events_max_ms
                 frame_stream_max_concurrent
                 session_ttl_hours webhook_max_skew_seconds webhook_idempotency_ttl_seconds
                 device_label health_ready_cache_ms decision_retention_days
                 opus_watch_poll_ms opus_watch_misses locus_backends_lease_ms
                 locus_backends_idle_ms log_level
                 asset_credential_window_s frame_credential_deadline_s
                 frame_invocation_max frame_invocation_window_ms
               ))

      for key <- ~w(asset_credential_window_s frame_credential_deadline_s) do
        {:ok, entry} = Roster.fetch(key)
        assert {entry.type, entry.default, entry.stale} == {:duration_s, 3_600, :serve}
        assert entry.config == nil, "#{key} has no reader to write it for yet"
      end

      for key <- ~w(frame_invocation_max frame_invocation_window_ms) do
        {:ok, entry} = Roster.fetch(key)
        assert entry.stale == :serve and entry.config == nil
      end
    end

    test "absent, only the API rate-limit pair inherits (the MCP pair's value)" do
      inheriting = for %Entry{inherit: true, key: key} <- Roster.entries(), do: key
      assert Enum.sort(inheriting) == ["api_rate_limit_max", "api_rate_limit_window_ms"]

      for key <- inheriting do
        {:ok, entry} = Roster.fetch(key)
        assert entry.default == nil and entry.variable != nil
      end
    end

    test "only the restart-scoped settings and the log level have a configuration path" do
      configured = for %Entry{config: [_ | _], key: key} <- Roster.entries(), do: key
      assert Enum.sort(configured) == Enum.sort(["log_level" | @restart_read])

      restart = for %Entry{scope: :restart, key: key} <- Roster.entries(), do: key
      assert Enum.sort(restart) == Enum.sort(@restart_read)

      {:ok, cap} = Roster.fetch("max_athanors")
      assert {cap.app, cap.config} == {:sanctum, nil}
    end

    test "each setting still configured is written under the application its reader reads it under" do
      reads = lib_reads()
      assert misplaced(Roster.entries(), reads) == []

      {:ok, slots} = Roster.fetch("crucible_max_concurrent")
      assert {slots.app, slots.config} == {:cyfr, [:crucible_max_concurrent]}

      # The slots under Sanctum would be written where nothing reads them.
      wrong = %{slots | app: :sanctum}

      assert misplaced([wrong], reads) == [
               {"crucible_max_concurrent", :sanctum, :crucible_max_concurrent}
             ]
    end

    test "no reader takes a live setting from the application environment, under any application" do
      reads =
        env_reads(tree("apps/*/lib/**/*.ex"), ~w(get_env fetch_env!? get_all_env compile_env!?))

      assert reads == [],
             """
             These read a platform setting from the application environment:

             #{Enum.map_join(reads, "\n", fn {path, app, key} -> "  #{path}: #{inspect(app)}, #{inspect(key)}" end)}

             A live setting is read through `Arca.PlatformSettings.effective/1`,
             which answers the environment's pin, the stored row or the default.
             """

      planted = [
        {"apps/sanctum/lib/planted.ex",
         "Keyword.get(Application.get_env(:sanctum, :caps, []), k)"},
        {"apps/cyfr/lib/planted.ex", "Application.fetch_env!(:cyfr, :mcp_rate_limit_max)"},
        {"apps/arca/lib/planted.ex", "Application.get_env(:arca, :session_ttl_hours)"},
        {"apps/cyfr/lib/slots.ex", "Application.get_env(:cyfr, :crucible_max_concurrent)"}
      ]

      assert env_reads(planted, ~w(get_env fetch_env!?)) == [
               {"apps/sanctum/lib/planted.ex", :sanctum, :caps},
               {"apps/cyfr/lib/planted.ex", :cyfr, :mcp_rate_limit_max},
               {"apps/arca/lib/planted.ex", :arca, :session_ttl_hours}
             ]
    end

    test "no test sets a live setting in the application environment" do
      puts =
        env_reads(
          tree("apps/*/test/**/*.ex") ++ tree("apps/*/test/**/*.exs") ++ tree("config/*.exs"),
          ~w(put_env)
        )

      assert puts == [],
             """
             These set a platform setting in the application environment, where
             no reader reads it:

             #{Enum.map_join(puts, "\n", fn {path, app, key} -> "  #{path}: #{inspect(app)}, #{inspect(key)}" end)}

             A test sets one through `Cyfr.Test.Settings.put/2` (the Sanctum
             suite, `Sanctum.Test.Settings.put/2`).
             """
    end

    test "the Sanctum suite's declaration is the roster's, for the settings Sanctum reads" do
      sanctum = Sanctum.Test.Settings.defaults()

      assert Map.take(Roster.defaults(), Map.keys(sanctum)) == sanctum

      assert Enum.sort(Map.keys(sanctum)) ==
               Enum.sort(for %Entry{app: :sanctum, key: key} <- Roster.entries(), do: key)
    end

    test "a restart-scoped setting names its apply; of the live ones, the log level alone" do
      assert apply_violations(Roster.entries()) == []

      restart = for %Entry{scope: :restart, key: key} <- Roster.entries(), do: key

      assert Enum.sort(restart) == [
               "crucible_max_concurrent",
               "crucible_max_concurrent_per_tenant"
             ]

      {:ok, level} = Roster.fetch("log_level")
      assert level.apply == {Cyfr.Platform.Settings, :apply_log_level, 1}

      {:ok, slots} = Roster.fetch("crucible_max_concurrent")
      assert slots.apply == {Cyfr.Platform.Settings, :apply_execution_slots, 1}

      assert apply_violations([%{slots | apply: nil}]) == [
               {"crucible_max_concurrent", :restart_without_apply}
             ]

      {:ok, rate} = Roster.fetch("mcp_rate_limit_max")

      assert apply_violations([%{rate | apply: {Cyfr.Platform.Settings, :x, 1}}]) == [
               {"mcp_rate_limit_max", :live_with_apply}
             ]
    end

    test "a cap or a security window refuses stale; every limit and cache bound serves" do
      assert stale_violations(Roster.entries()) == []

      {:ok, cap} = Roster.fetch("max_athanors")
      {:ok, rate} = Roster.fetch("mcp_rate_limit_max")

      assert stale_violations([%{cap | stale: :serve}, %{rate | stale: :refuse}]) == [
               {"max_athanors", :serve},
               {"mcp_rate_limit_max", :refuse}
             ]
    end

    test "each validator takes the environment's text and a typed value, and names the form" do
      {:ok, rate} = Roster.fetch("mcp_rate_limit_max")
      assert rate.validator.("240") == {:ok, 240}
      assert rate.validator.(240) == {:ok, 240}

      for bad <- ["0", "-1", "ten", "1.5", "60s", "", 0, :x] do
        assert {:error, "must be a whole number of requests from 1 to 1000000000"} =
                 rate.validator.(bad)
      end

      {:ok, slots} = Roster.fetch("crucible_max_concurrent")
      assert {:error, _} = slots.validator.("31")
      assert slots.validator.("32") == {:ok, 32}

      {:ok, bytes} = Roster.fetch("athanor_storage_bytes")
      assert bytes.validator.("1099511627776") == {:ok, 1_099_511_627_776}

      {:ok, level} = Roster.fetch("log_level")
      assert level.validator.("debug") == {:ok, :debug}
      assert level.validator.(:warning) == {:ok, :warning}
      assert {:error, "must be a Logger level: " <> _} = level.validator.("loud")

      {:ok, label} = Roster.fetch("device_label")
      assert label.validator.(" my-laptop ") == {:ok, "my-laptop"}
      assert {:error, _} = label.validator.(String.duplicate("a", 256))
    end

    test "the installed data is each key's default and stale policy, plain values" do
      defaults = Roster.defaults()

      assert map_size(defaults) == length(Roster.entries())
      assert defaults["max_groups_per_person"] == %{default: 50, stale: :refuse}
      assert defaults["log_level"] == %{default: :info, stale: :serve}

      for {_key, declared} <- defaults do
        assert Map.keys(declared) |> Enum.sort() == [:default, :stale]
        refute is_function(declared.default)
      end
    end
  end

  describe "the inventory" do
    test "the compose-only class is docker-compose.yml's names that no release reads" do
      assert Roster.compose_only() |> Enum.sort() == derived_compose_only()
      assert "CADDY_ACME_EMAIL" in Roster.compose_only()
      assert "CYFR_CPU_LIMIT" in Roster.compose_only()
    end

    test "every name .env.example documents is declared, under the prefix or not" do
      declared =
        MapSet.new(
          Roster.variables() ++
            Roster.deployment() ++
            Roster.compose_only() ++ Opus.Settings.variables() ++ Locus.Config.variables()
        )

      undeclared = Enum.reject(documented(".env.example"), &MapSet.member?(declared, &1))

      assert undeclared == [],
             ".env.example documents names no roster declares: #{inspect(undeclared)}"

      # A variable documented and declared nowhere fails the same check.
      refute "CYFR_PLANTED_KNOB" in declared
    end

    test "every deployment variable is one the boot reads" do
      sources =
        ~w(config/runtime.exs config/config.exs apps/cyfr/lib/cyfr/runtime_config.ex)
        |> Enum.map_join("\n", &File.read!(Path.join(@root, &1)))

      unread = Enum.reject(Roster.deployment(), &(sources =~ ~s|"#{&1}"|))
      assert unread == [], "the deployment list names variables nothing reads: #{inspect(unread)}"
    end

    test "every CYFR_* name the configuration spells is declared" do
      spelled =
        spelled(
          ~w(config/runtime.exs config/config.exs config/dev.exs config/prod.exs config/test.exs
             apps/cyfr/lib/cyfr/runtime_config.ex)
        )
        |> Enum.filter(&String.starts_with?(&1, "CYFR_"))
        |> Enum.uniq()

      assert Roster.unknown([], spelled) == []
    end
  end

  describe "unknown/2" do
    test "a file may name only the server's variables; the process may name another program's too" do
      assert Roster.unknown(["CYFR_HOST", "CYFR_MAX_ATHANORS", "CYFR_CPU_LIMIT", "PATH"], []) ==
               []

      assert Roster.unknown(["CYFR_RETIRED_KNOB"], []) == ["CYFR_RETIRED_KNOB"]

      assert Roster.unknown([], ["CYFR_TOKEN", "CYFR_TEST_RUN_ROOT", "HOME"]) == []
      assert Roster.unknown(["CYFR_TOKEN"], []) == ["CYFR_TOKEN"]
      assert Roster.unknown(["CYFR_B", "CYFR_A"], ["CYFR_A"]) == ["CYFR_A", "CYFR_B"]

      assert Roster.refusal(["CYFR_A"]) =~ "CYFR_A is not a variable this server reads"
    end

    test "every foreign name says whose it is" do
      for {name, owner} <- Roster.foreign() do
        assert String.starts_with?(name, "CYFR_")
        assert is_binary(owner) and String.length(owner) > 10, name
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The boot, evaluated
  # ---------------------------------------------------------------------------

  defp base_env do
    %{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr",
      "CYFR_DATABASE" => nil
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
    Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod, imports: :disabled)
  end

  defp refusal!, do: Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))

  # The .env files a release sources sit at its RELEASE_ROOT.
  defp with_env_file(lines, fun) do
    dir = Path.join(System.tmp_dir!(), "cyfr-roster-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), Enum.join(lines, "\n") <> "\n")

    try do
      with_env(%{"RELEASE_ROOT" => dir}, fun)
    after
      File.rm_rf!(dir)
    end
  end

  describe "config/runtime.exs" do
    test "a set setting is recorded as a pin; only a restart-scoped one is configured too" do
      with_env(
        %{
          "CYFR_MCP_RATE_LIMIT_MAX" => "240",
          "CYFR_SESSION_TTL_HOURS" => "0",
          "CYFR_CRUCIBLE_MAX_CONCURRENT" => "64"
        },
        fn ->
          config = read_prod_config!()

          assert config[:cyfr][:deployment_pinned] == [
                   {"crucible_max_concurrent", 64},
                   {"mcp_rate_limit_max", 240},
                   {"session_ttl_hours", 0}
                 ]

          # A live setting is read through the accessor, which answers the pin.
          refute Keyword.has_key?(config[:cyfr], :mcp_rate_limit_max)
          refute Keyword.has_key?(config[:sanctum] || [], :session_ttl_hours)

          # The slots are read once at boot, where the pin is written.
          assert config[:cyfr][:crucible_max_concurrent] == 64
        end
      )
    end

    test "nothing set pins nothing, and the production log level is info" do
      unset = Map.new(Roster.variables(), &{&1, nil})

      with_env(unset, fn ->
        config = read_prod_config!()

        assert config[:cyfr][:deployment_pinned] == []
        assert config[:logger][:level] == :info
        refute Keyword.has_key?(config[:cyfr], :mcp_rate_limit_max)
      end)

      with_env(Map.put(unset, "CYFR_LOG_LEVEL", "warning"), fn ->
        config = read_prod_config!()
        assert config[:logger][:level] == :warning
        assert config[:cyfr][:deployment_pinned] == [{"log_level", :warning}]
      end)
    end

    test "a cap set is a pin, and nothing writes the caps to the application environment" do
      unset = Map.new(Roster.variables(), &{&1, nil})

      with_env(Map.put(unset, "CYFR_MAX_ATHANORS", "5"), fn ->
        config = read_prod_config!()

        assert config[:cyfr][:deployment_pinned] == [{"max_athanors", 5}]
        refute Keyword.has_key?(config[:sanctum] || [], :caps)
      end)
    end

    test "a set value the validator refuses stops the boot naming the variable" do
      for {name, bad} <- [
            {"CYFR_MAX_ATHANORS", "-1"},
            {"CYFR_SESSION_TTL_HOURS", "a day"},
            {"CYFR_LOG_LEVEL", "loud"},
            {"CYFR_WEBHOOK_MAX_SKEW_SECONDS", "0"},
            {"CYFR_ASSET_CREDENTIAL_WINDOW_S", "1h"}
          ] do
        with_env(%{name => bad}, fn ->
          assert refusal!() =~ "[Cyfr] FATAL: #{name}=#{inspect(bad)} must be"
        end)
      end
    end

    test "a CYFR_* name nothing declares stops the boot naming it" do
      with_env(%{"CYFR_NO_SUCH_SETTING" => "64"}, fn ->
        message = refusal!()
        assert message =~ "[Cyfr] FATAL: CYFR_NO_SUCH_SETTING is not a variable"
      end)

      # Another program's name in the shell is not the server's to refuse.
      with_env(%{"CYFR_TOKEN" => "a-session", "CYFR_TEST_ANYTHING" => "1"}, fn ->
        assert is_list(read_prod_config!())
      end)
    end

    test "a .env file may carry the server's names alone" do
      with_env_file(["CYFR_MCP_RATE_LIMIT_MAX=240", "CADDY_ACME_EMAIL=a@example.com"], fn ->
        assert {"mcp_rate_limit_max", 240} in read_prod_config!()[:cyfr][:deployment_pinned]
      end)

      with_env_file(["CYFR_RETIRED_KNOB=1"], fn ->
        assert refusal!() =~ "CYFR_RETIRED_KNOB is not a variable this server reads"
      end)

      with_env_file(["CYFR_TOKEN=a-session"], fn ->
        assert refusal!() =~ "CYFR_TOKEN is not a variable this server reads"
      end)
    end

    test "unassigned, the CORS allowlist is the configured empty one" do
      with_env(%{"CYFR_CORS_ALLOWED_ORIGINS" => nil}, fn ->
        refute Keyword.has_key?(read_prod_config!()[:cyfr], :cors_allowed_origins)
      end)

      configured = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod)
      assert configured[:cyfr][:cors_allowed_origins] == []
    end
  end

  describe "an opus release booted alone" do
    defp opus_env(overrides) do
      Map.merge(
        %{
          "RELEASE_NAME" => "opus",
          "CYFR_SECRET_KEY_BASE" => nil,
          "OPUS_SERVICE_KEY" => String.duplicate("ab", 32),
          "OPUS_HOST_URL" => "http://cyfr:4300"
        },
        overrides
      )
    end

    test "reads no roster: a stray CYFR_* name is not its to refuse" do
      with_env(opus_env(%{"CYFR_RETIRED_KNOB" => "1"}), fn ->
        config = read_prod_config!()
        refute Keyword.has_key?(config, :cyfr)
        assert config[:logger][:level] == :info
      end)
    end

    test "refuses a stray OPUS_* name through Opus.Settings" do
      with_env(opus_env(%{"OPUS_POOL_SIZ" => "4"}), fn ->
        message = refusal!()
        assert message =~ "[Cyfr] FATAL: OPUS_POOL_SIZ is not a variable the opus release reads"
        assert message == "[Cyfr] FATAL: " <> Opus.Settings.unknown(["OPUS_POOL_SIZ"])
      end)
    end
  end
end
