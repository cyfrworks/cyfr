# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.SettingsTest do
  @moduledoc """
  The service's pool settings come from `config :locus, :runtime` with
  defaults in code, each validated, the keeper the cyfr-locus channel when
  unset, a runner's memory bound in the keeper's own range and never none,
  and no `LOCUS_RUNTIME_*` name in the environment that `Locus.Config`
  does not declare; the environment a runner is handed is its declared
  `RUNTIME_*` names alone; and the module reads no variable by name.
  `Locus.Config`'s suite holds how the environment is read.
  """

  # `pool!/0` reads the application environment, which one test alters.
  use ExUnit.Case, async: false

  alias Locus.Runtime.Settings

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

      # Each default has one definition, which a runner's grace takes too.
      for {key, value} <- [
            pool_size: 4,
            idle_ttl_ms: 30_000,
            watchdog_grace_ms: 5_000,
            release_grace_ms: 2_000,
            attach_dir: "/run/locus",
            runner_memory_bytes: 402_653_184
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
          host_url: "http://127.0.0.1:4300",
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
      assert Locus.Config.memory_range() == 16_777_216..1_099_511_627_776

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

  # `Locus.Config` declares and reads every variable of the release, and
  # the docs drift scan reads it alone, so this module's own source is
  # held here: it reads no variable by name, and the only names it spells
  # are the ones it hands a runner.
  describe "the source" do
    @source Path.expand("../../../lib/locus/runtime/settings.ex", __DIR__)

    # The calls that read the process environment, by module and function.
    @env_reads [{System, :get_env}, {System, :fetch_env}, {System, :fetch_env!}, {:os, :getenv}]

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
            ~S[f = &System.get_env/1]
          ] do
        assert [_ | _] = reads_by_name(Code.string_to_quoted!(source)), source
      end

      assert reads_by_name(Code.string_to_quoted!(~S[System.get_env()])) == []
      assert reads_by_name(Code.string_to_quoted!(~S[:os.getenv()])) == []
      assert "LOCUS_" in string_literals(Code.string_to_quoted!(~S["LOCUS_" <> name]))
    end
  end

  # Every call of an environment read that names a variable: one given an
  # argument, piped one, or captured.
  defp reads_by_name(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [_value, call]} = node, found -> {node, record(node, call, found)}
        {:&, _, [{:/, _, [call, _arity]}]} = node, found -> {node, record(node, call, found)}
        {_call, _, [_ | _]} = node, found -> {node, record(node, node, found)}
        node, found -> {node, found}
      end)

    Enum.reverse(found)
  end

  defp record(node, call, found),
    do: if(env_read?(call), do: [Macro.to_string(node) | found], else: found)

  defp env_read?({{:., _, [module, function]}, _, args}) when is_list(args),
    do: {module_name(module), function} in @env_reads

  defp env_read?(_call), do: false

  defp module_name({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_name(module) when is_atom(module), do: module
  defp module_name(_module), do: nil

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
