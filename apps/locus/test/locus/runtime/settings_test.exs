# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.SettingsTest do
  @moduledoc """
  The service's pool settings come from `config :locus, :runtime` with
  defaults in code, each validated, the keeper the cyfr-locus channel when
  unset, no setting for how many runners are kept ahead or what bounds
  one, and no `LOCUS_RUNTIME_*` name in the environment that `Locus.Config`
  does not declare; the environment a runner is handed is its declared
  `RUNTIME_*` names alone, as `tests/fixtures/runner_control.json`'s
  `environment` writes it, and every environment of that section reads
  as its runner or is refused as it says, through `Locus.Config.runner/1`;
  the runtime role's settings and the release's log settings read and
  refuse every case of `tests/fixtures/locus_settings.json`, every
  variable's default and range edge with them, as the Go runtime role
  will; and the module reads no variable by name. `Locus.Config`'s suite
  holds how the rest of the environment is read.
  """

  # `pool!/0` reads the application environment, which one test alters.
  use ExUnit.Case, async: false

  alias Locus.Runtime.Credentials
  alias Locus.Runtime.Settings

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @environment Path.expand("../../../../../tests/fixtures/runner_control.json", __DIR__)
               |> File.read!()
               |> Jason.decode!()
               |> Map.fetch!("environment")

  @settings Path.expand("../../../../../tests/fixtures/locus_settings.json", __DIR__)
            |> File.read!()
            |> Jason.decode!()

  # The base URLs the host API's URL is read as (Prima.WorkerWire.base_url/1).
  @worker_api Path.expand("../../../../../tests/fixtures/worker_api.json", __DIR__)
              |> File.read!()
              |> Jason.decode!()

  describe "a runner's environment, as runner_control.json's environment holds it" do
    test "the service writes exactly the vector's environment for its settings" do
      %{"settings" => settings, "environment" => written} = @environment["written"]
      settings = Map.new(settings, fn {key, value} -> {String.to_existing_atom(key), value} end)

      assert Settings.runner_environment(settings) == written
    end

    test "every valid environment reads as its runner" do
      for %{"why" => why, "environment" => env, "runner" => runner} <- @environment["valid"] do
        assert {:ok, read} = Locus.Config.runner(env), why

        relay =
          case read.relay do
            {:fd, fd} -> %{"fd" => fd}
            {:socket, path} -> %{"socket" => path}
          end

        assert %{
                 "runner_id" => read.runner_id,
                 "service_id" => read.service_id,
                 "boot" => read.boot,
                 "control_fd" => read.control_fd,
                 "relay" => relay
               } == runner,
               why
      end
    end

    test "every invalid environment is refused, naming its variable" do
      for %{"why" => why, "environment" => env, "reason" => reason, "name" => name} <-
            @environment["invalid"] do
        assert Locus.Config.runner(env) == {:error, {String.to_existing_atom(reason), name}}, why
      end
    end
  end

  describe "pool/2" do
    test "defaults: a 15 min idle TTL, a 5 s watchdog grace, a 2 s release grace, and nothing else" do
      assert Settings.pool([], %{}) ==
               {:ok,
                %{
                  idle_ttl_ms: 900_000,
                  watchdog_grace_ms: 5_000,
                  release_grace_ms: 2_000,
                  keeper: :channel,
                  attach_dir: "/run/locus"
                }}

      # Each default has one definition, which a runner's grace takes too.
      for {key, value} <- [
            idle_ttl_ms: 900_000,
            watchdog_grace_ms: 5_000,
            release_grace_ms: 2_000
          ] do
        assert Settings.default(key) == value
      end
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

    # The release carries no host module, so `Locus.Config` declares the
    # prefix: a `LOCUS_RUNTIME_*` name the service does not read refuses by
    # name, whether the process or an .env file a development boot sourced
    # sets it.
    test "a LOCUS_RUNTIME_* name the service does not read refuses, naming it" do
      assert {:error, {:unknown, ["LOCUS_RUNTIME_POOL_SIZ"]}} =
               Settings.pool([], %{"LOCUS_RUNTIME_POOL_SIZ" => "4", "PATH" => "/bin"})

      assert {:error, {:unknown, ["LOCUS_RUNTIME_A", "LOCUS_RUNTIME_B"]}} =
               Settings.pool([], %{"LOCUS_RUNTIME_B" => "", "LOCUS_RUNTIME_A" => "1"})

      assert Locus.Config.unknown(["LOCUS_RUNTIME_POOL_SIZ"]) =~
               "LOCUS_RUNTIME_POOL_SIZ is not a variable the locus release reads"

      # What it reads, other roles' names and other prefixes pass.
      system =
        Map.new(
          Locus.Config.variables() ++ ["KEEPER_CHANNEL", "CYFR_HOST", "LOCUS_BUILDS_KEY"],
          &{&1, "set"}
        )

      assert Locus.Config.unknown_names(Map.keys(system), :runtime) == []
      assert {:ok, _pool} = Settings.pool([], system)
    end

    test "pool!/0 refuses a stray LOCUS_RUNTIME_* name in the process environment" do
      System.put_env("LOCUS_RUNTIME_STRAY_FOR_TEST", "1")
      on_exit(fn -> System.delete_env("LOCUS_RUNTIME_STRAY_FOR_TEST") end)

      assert_raise ArgumentError,
                   ~r/\A\[Locus\.Runtime\.Settings\] LOCUS_RUNTIME_STRAY_FOR_TEST is not a variable/,
                   &Settings.pool!/0
    end

    test "the declared names are every name a runner is handed" do
      env =
        Settings.runner_environment(%{
          runner_id: "r",
          service_id: "wrk_local",
          boot: "b",
          watchdog_grace_ms: 5_000
        })

      assert Map.keys(env) -- Locus.Config.variables(:runner) == []
      assert "RUNTIME_CONTROL_FD" in Locus.Config.variables(:runner)
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
      for key <- [:idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms],
          value <- [0, -1, "4", 4.0, nil] do
        assert {:error, {:malformed, ^key}} = Settings.pool([{key, value}], %{})
      end

      assert {:ok, %{idle_ttl_ms: 1, watchdog_grace_ms: 7, release_grace_ms: 9}} =
               Settings.pool([idle_ttl_ms: 1, watchdog_grace_ms: 7, release_grace_ms: 9], %{})
    end

    test "unset, the attach directory is the run folder cyfr-locus names, and a clean absolute path" do
      assert {:ok, %{attach_dir: "/run/locus/runtime"}} =
               Settings.pool([], %{"KEEPER_RUN_DIR" => "/run/locus/runtime"})

      assert {:ok, %{attach_dir: "/run/locus"}} = Settings.pool([], %{"KEEPER_RUN_DIR" => ""})

      assert {:error, {:malformed, :attach_dir}} =
               Settings.pool([], %{"KEEPER_RUN_DIR" => "run/locus/runtime"})

      assert {:ok, %{attach_dir: "/tmp/locus"}} =
               Settings.pool([attach_dir: "/tmp/locus"], %{
                 "KEEPER_RUN_DIR" => "/run/locus/runtime"
               })
    end

    test "the attach directory is a clean absolute path" do
      assert {:ok, %{attach_dir: "/tmp/locus"}} = Settings.pool([attach_dir: "/tmp/locus"], %{})
      assert {:error, {:malformed, :attach_dir}} = Settings.pool([attach_dir: "run/locus"], %{})

      assert {:error, {:malformed, :attach_dir}} =
               Settings.pool([attach_dir: "/run/../locus"], %{})
    end

    test "pool!/0 refuses the boot with the key named" do
      previous = Locus.Runtime.Test.Env.put(:idle_ttl_ms, 0)

      try do
        assert_raise ArgumentError,
                     ~r/config :locus, :runtime, :idle_ttl_ms is malformed: a positive integer/,
                     fn ->
                       Settings.pool!()
                     end
      after
        Locus.Runtime.Test.Env.restore(previous, [:idle_ttl_ms])
      end
    end
  end

  # What the runtime role reads from `env`: its settings and the log's,
  # every one, or the message its boot is refused with.
  defp runtime_settings(env) do
    case Locus.Config.from_env(&Map.get(env, &1), Map.keys(env)) do
      {:ok, settings} ->
        runtime = Keyword.fetch!(settings, :runtime)
        {:ok, pool} = Settings.pool(runtime, env)

        {:ok,
         %{
           "service_id" => runtime[:service_id],
           "service_key" => runtime[:service_key],
           "host_url" => runtime[:host_url],
           "bind" => runtime[:bind],
           "port" => runtime[:port],
           "idle_ttl_ms" => pool.idle_ttl_ms,
           "watchdog_grace_ms" => pool.watchdog_grace_ms,
           "release_grace_ms" => pool.release_grace_ms,
           "attach_dir" => pool.attach_dir,
           "log_level" => Atom.to_string(settings[:log_level]),
           "log_format" => Atom.to_string(settings[:log_format])
         }}

      {:error, message} ->
        {:error, message}
    end
  end

  describe "the runtime role's settings, as locus_settings.json holds them" do
    # Every row of the fixture is matched inside its loop, so a row without
    # a member fails instead of being passed over.

    test "the fixture's variables are the runtime role's and the release's log settings, in order" do
      names = Enum.map(@settings["variables"], & &1["name"])
      assert names === Locus.Config.variables(:runtime) ++ Locus.Config.variables(:release)
    end

    test "every variable's setting is one a read reads, and a required one has no default" do
      env = @settings["environment"]
      {:ok, read} = runtime_settings(env)

      settings =
        for variable <- @settings["variables"] do
          assert %{"name" => name, "setting" => setting, "default" => default} = variable
          assert Map.has_key?(read, setting), name

          if Map.get(variable, "required", false) do
            assert variable["required"] === true and default === nil, name
            assert read[setting] === env[name], name
            assert {:error, message} = runtime_settings(Map.delete(env, name)), name
            assert message =~ name, message
          end

          setting
        end

      assert Enum.sort(settings) === read |> Map.keys() |> Enum.sort()
      assert Enum.count(@settings["variables"], &Map.get(&1, "required", false)) == 2
    end

    test "every variable left unset takes the fixture's default" do
      {:ok, unset} = runtime_settings(@settings["environment"])

      for variable <- @settings["variables"], not Map.get(variable, "required", false) do
        assert %{"name" => name, "setting" => setting, "default" => default} = variable

        expected =
          case setting do
            "attach_dir" -> @settings["environment"]["KEEPER_RUN_DIR"]
            _ -> default
          end

        assert unset[setting] === expected, name
      end

      run_dir = Map.delete(@settings["environment"], "KEEPER_RUN_DIR")
      attach = Enum.find(@settings["variables"], &(&1["setting"] == "attach_dir"))
      assert {:ok, %{"attach_dir" => dir}} = runtime_settings(run_dir)
      assert dir === attach["default"] and attach["default_from"] === "KEEPER_RUN_DIR"
    end

    test "every variable's accepted is what its reader takes and what its refusal says it takes" do
      env = @settings["environment"]

      for variable <- @settings["variables"] do
        assert %{"name" => name, "setting" => setting, "accepted" => accepted} = variable
        assert {:error, message} = runtime_settings(Map.put(env, name, "x y")), name
        assert String.starts_with?(message, name), message

        case accepted do
          sentence when is_binary(sentence) ->
            assert message =~ sentence, message

          values when is_list(values) ->
            for value <- values do
              assert {:ok, %{^setting => ^value}} = runtime_settings(Map.put(env, name, value))
              assert message =~ value, message
            end
        end
      end

      levels = Enum.find(@settings["variables"], &(&1["setting"] == "log_level"))["accepted"]
      assert Enum.sort(levels) === Logger.levels() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "every range reads to its edges and is refused one past either, naming its variable" do
      ranged = for %{"min" => _} = variable <- @settings["variables"], do: variable
      assert length(ranged) == 4

      for variable <- ranged do
        assert %{"name" => name, "setting" => setting, "min" => min, "max" => max} = variable

        for value <- [min, max] do
          env = Map.put(@settings["environment"], name, Integer.to_string(value))
          assert {:ok, %{^setting => ^value}} = runtime_settings(env), "#{name}=#{value}"
        end

        for value <- [min - 1, max + 1] do
          env = Map.put(@settings["environment"], name, Integer.to_string(value))
          assert {:error, message} = runtime_settings(env), "#{name}=#{value}"
          assert String.starts_with?(message, name), message
        end
      end
    end

    test "every whole number reads in its most characters and is refused in one more" do
      bounded = for %{"max_length" => _} = variable <- @settings["variables"], do: variable
      assert length(bounded) == 4

      for variable <- bounded do
        assert %{"name" => name, "setting" => setting, "default" => default, "max_length" => most} =
                 variable

        text = &String.pad_leading(Integer.to_string(default), &1, "0")
        env = &Map.put(@settings["environment"], name, &1)
        assert {:ok, %{^setting => ^default}} = runtime_settings(env.(text.(most))), name
        assert {:error, message} = runtime_settings(env.(text.(most + 1))), name
        assert String.starts_with?(message, name), message
      end
    end

    test "the host API's URL reads by the grammar worker_api.json's base_urls hold, kept as written" do
      variable = Enum.find(@settings["variables"], &(&1["setting"] == "host_url"))
      assert variable["grammar"] === "worker_api.json base_urls"
      cases = @worker_api["base_urls"]
      assert length(cases) >= 30

      for row <- cases do
        assert %{"text" => text, "base" => base} = row
        env = Map.put(@settings["environment"], variable["name"], text)

        case base do
          nil ->
            assert {:error, _message} = runtime_settings(env), inspect(text)

          base ->
            # The setting as written; the credentials hold its base.
            assert {:ok, %{"host_url" => ^text}} = runtime_settings(env), inspect(text)
            assert {:ok, settings} = Locus.Config.from_env(&Map.get(env, &1), Map.keys(env))
            assert {:ok, %{host_url: ^base}} = Credentials.load(settings[:runtime]), inspect(text)
        end
      end
    end

    test "every environment of reads reads as its settings" do
      assert length(@settings["reads"]) >= 25

      for row <- @settings["reads"] do
        assert %{"why" => why, "environment" => env, "settings" => settings} = row
        assert runtime_settings(env) === {:ok, settings}, why
      end
    end

    test "every environment of refusals refuses the boot with its message, which shows no key" do
      assert length(@settings["refusals"]) >= 55
      key = @settings["environment"]["LOCUS_RUNTIME_KEY"]

      for row <- @settings["refusals"] do
        assert %{"why" => why, "environment" => env, "message" => message} = row
        assert runtime_settings(env) === {:error, message}, why
        refute message =~ String.slice(key, 0, 16), why
      end
    end
  end

  # `Locus.Config` declares and reads every variable of the release, and
  # the docs drift scan reads it alone, so this module's own source is
  # held here: it reads no variable by name, and the only names it spells
  # are the ones it hands a runner.
  describe "the source" do
    @source Path.expand("../../../lib/locus/runtime/settings.ex", __DIR__)

    # The calls that read the process environment, by module and function.
    # A module by its alias's segments, or an Erlang module by its atom.
    @env_reads [
      {[:System], :get_env},
      {[:System], :fetch_env},
      {[:System], :fetch_env!},
      {:os, :getenv}
    ]

    test "reads no variable by name, spells no LOCUS_ name, and only the RUNTIME_ names it hands a runner" do
      ast = @source |> File.read!() |> Code.string_to_quoted!()

      assert reads_by_name(ast) == [],
             "settings.ex reads the environment by name; Locus.Config reads every variable"

      literals = string_literals(ast)

      assert Enum.filter(literals, &String.starts_with?(&1, "LOCUS_")) == [],
             "settings.ex spells a LOCUS_ name; Locus.Config declares every one"

      written =
        Settings.runner_environment(%{
          runner_id: "r",
          service_id: "wrk_local",
          boot: "b",
          watchdog_grace_ms: 1
        })

      spelled =
        literals
        |> Enum.filter(&String.starts_with?(&1, "RUNTIME_"))
        |> Enum.uniq()
        |> Enum.sort()

      assert spelled == written |> Map.keys() |> Enum.sort()
      assert spelled -- Locus.Config.variables(:runner) == []
    end

    test "the scan finds a read by name in every form, and passes the whole environment's read" do
      for source <- [
            ~S[System.get_env("X")],
            ~S[System.get_env("X", "y")],
            ~S[System.fetch_env("X")],
            ~S[System.fetch_env!("X")],
            ~S[:os.getenv(~c"X")],
            ~S[:os.getenv(~c"X", ~c"y")],
            ~S["X" |> System.get_env()],
            ~S[f = &System.get_env/1],
            ~S[alias System, as: Env
               Env.get_env("X")],
            ~S[alias System, as: Env
               "X" |> Env.fetch_env!()],
            ~S[alias :os, as: OS
               OS.getenv(~c"X")],
            ~S|apply(System, :get_env, ["X"])|,
            ~S|apply(System, :fetch_env!, [name])|,
            ~S|alias System, as: Env
               apply(Env, :get_env, ["X", "y"])|
          ] do
        assert [_ | _] = reads_by_name(Code.string_to_quoted!(source)), source
      end

      for source <- [
            ~S[System.get_env()],
            ~S[:os.getenv()],
            ~S|apply(System, :get_env, [])|,
            ~S[alias Other, as: Env
               Env.get_env("X")],
            ~S|apply(Other, :get_env, ["X"])|
          ] do
        assert reads_by_name(Code.string_to_quoted!(source)) == [], source
      end

      assert "LOCUS_" in string_literals(Code.string_to_quoted!(~S["LOCUS_" <> name]))
    end
  end

  # Every call of an environment read that names a variable: one given an
  # argument, piped one, captured, or applied with a literal module and
  # function (`apply(System, :get_env, ["X"])`), the module spelled or
  # renamed (`alias System, as: Env`).
  defp reads_by_name(ast) do
    aliases = renames(ast)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [_value, call]} = node, found ->
          {node, record(node, call, found, aliases)}

        {:&, _, [{:/, _, [call, _arity]}]} = node, found ->
          {node, record(node, call, found, aliases)}

        {_call, _, [_ | _]} = node, found ->
          {node, record(node, node, found, aliases)}

        node, found ->
          {node, found}
      end)

    Enum.reverse(found)
  end

  defp record(node, call, found, aliases),
    do: if(env_read?(call, aliases), do: [Macro.to_string(node) | found], else: found)

  defp env_read?({{:., _, [module, function]}, _, args}, aliases) when is_list(args),
    do: {module_name(module, aliases), function} in @env_reads

  # `apply/3` with no arguments reads the whole environment, as the call does.
  defp env_read?({:apply, _, [module, function, arguments]}, aliases) when is_atom(function),
    do: arguments != [] and {module_name(module, aliases), function} in @env_reads

  defp env_read?(_call, _aliases), do: false

  # The modules the source renames, `alias Module, as: Name`, by name.
  defp renames(ast) do
    {_ast, renames} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [module, [as: {:__aliases__, _, [name]}]]} = node, renames ->
          {node, Map.put(renames, name, module_name(module, %{}))}

        node, renames ->
          {node, renames}
      end)

    renames
  end

  # A module as `@env_reads` names it: an alias by its segments, one the
  # source renames by the segments of the module it renames.
  defp module_name({:__aliases__, _, [name]}, aliases), do: Map.get(aliases, name, [name])
  defp module_name({:__aliases__, _, parts}, _aliases), do: parts
  defp module_name(module, _aliases) when is_atom(module), do: module
  defp module_name(_module, _aliases), do: nil

  # Every string the source spells, interpolated ones' text parts included.
  defp string_literals(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        text, found when is_binary(text) -> {text, [text | found]}
        node, found -> {node, found}
      end)

    found
  end
end
