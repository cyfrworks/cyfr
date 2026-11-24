# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.DefinitionTest do
  @moduledoc """
  A program's definition: one command that names no vault entry, env names that are neither malformed nor reserved,
  and env values that are vault templates except for the non-secret names
  that may hold literals; a command that places a vault-bound value on the
  command line is accepted and warned of. A program is one kind, marked
  mcp or driven, both defined and run by the same rules.
  """
  use ExUnit.Case, async: true

  alias Opus.Programs.Definition

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        "command" => "npx -y @modelcontextprotocol/server-github",
        "env" => %{
          "GITHUB_PERSONAL_ACCESS_TOKEN" => "Bearer vault:gh-token",
          "NODE_ENV" => "production"
        }
      },
      overrides
    )
  end

  defp token(command, env \\ %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token"}) do
    %{"command" => command, "env" => env}
  end

  defp refused(config) do
    assert {:error, {:invalid_argument, message}} = Definition.validate(config)
    message
  end

  test "a valid config is answered as its definition, with an absent env as an empty map" do
    assert {:ok, definition} = Definition.validate(config(%{"timeout_ms" => 5_000}))
    assert definition == config()

    bare = %{"command" => "npx -y @modelcontextprotocol/server-filesystem /tmp"}
    assert {:ok, %{"command" => _, "env" => %{}}} = Definition.validate(bare)
  end

  test "a program is one command and one environment: a backends list is an unknown key" do
    assert refused(%{"backends" => [config()]}) =~ "unknown keys: backends"
    assert refused(config(%{"cwd" => "/"})) =~ "unknown keys: cwd"
    assert refused(nil) =~ "must be an object"
    assert Definition.program_name() == "program"
  end

  test "a command is a non-empty string that names no vault entry" do
    assert refused(config(%{"command" => "  "})) =~ "needs a command"
    assert refused(config(%{"command" => nil})) =~ "command"
    assert refused(%{"env" => %{}}) =~ "command"
    assert refused(config(%{"command" => "run --token vault:gh-token"})) =~ "visible"
    assert refused(config(%{"command" => "run VAULT:gh"})) =~ "visible"
    assert refused(config(%{"command" => "a" <> <<0>>})) =~ "NUL"
    too_long = String.duplicate("a", Prima.LocusBackends.max_command_bytes() + 1)
    assert refused(config(%{"command" => too_long})) =~ "longer"

    assert {:ok, _} =
             Definition.validate(
               config(%{"command" => binary_part(too_long, 1, byte_size(too_long) - 1)})
             )
  end

  # A definition whose command places a vault-bound value on the command
  # line is the administrator's to make: it is accepted as written and
  # carries the warning.
  defp warned(config) do
    assert {:ok, normalized} = Definition.validate(config)
    assert normalized == Map.put_new(config, "env", %{})
    Definition.warnings(normalized)
  end

  @exposed "on the command line, where every process of the program's own session " <>
             "can read it; the safe route is to let the program read it from its environment."

  describe "a vault-bound env name on the command line is warned of" do
    test "a command that expands a vault-bound name is accepted, with a warning naming it" do
      for command <- [
            ~s(npx server --token "$GITHUB_PERSONAL_ACCESS_TOKEN"),
            "npx server --token $GITHUB_PERSONAL_ACCESS_TOKEN",
            "npx server --token=${GITHUB_PERSONAL_ACCESS_TOKEN}",
            "npx server --token ${GITHUB_PERSONAL_ACCESS_TOKEN:-none}",
            "npx server --token ${GITHUB_PERSONAL_ACCESS_TOKEN#ghp_}",
            "sh -c 'npx server --token \\$GITHUB_PERSONAL_ACCESS_TOKEN'",
            "npx server --token $\\\nGITHUB_PERSONAL_ACCESS_TOKEN",
            "npx server --token $GITHUB_PERSONAL_\\\nACCESS_TOKEN"
          ] do
        assert warned(token(command)) == [
                 "The command expands GITHUB_PERSONAL_ACCESS_TOKEN, a vault-bound env " <>
                   "name: the value is placed " <> @exposed
               ],
               command
      end
    end

    test "beside a vault-bound name, a form that computes a value at run time is warned of" do
      for {command, form} <- [
            {"npx server --token \"$(printenv GITHUB_PERSONAL_ACCESS_TOKEN)\"", "$("},
            {"npx server --token `printenv GITHUB_PERSONAL_ACCESS_TOKEN`", "`"},
            {"npx server --id $((GITHUB_PERSONAL_ACCESS_TOKEN))", "$("},
            {"npx server --id $[GITHUB_PERSONAL_ACCESS_TOKEN]", "$["},
            {"V=GITHUB_PERSONAL_ACCESS_TOKEN; bash -c 'npx server --token ${!V}'", "${!"},
            {"bash -c 'npx server --token ${ printenv GITHUB_PERSONAL_ACCESS_TOKEN; }'", "${ "},
            {"bash -c 'npx server --token ${|REPLY=x;}'", "${|"},
            {"npx server --token $\\\n(printenv GITHUB_PERSONAL_ACCESS_TOKEN)", "$("}
          ] do
        assert warned(token(command)) == [
                 "The command has #{inspect(form)} beside the vault-bound " <>
                   "GITHUB_PERSONAL_ACCESS_TOKEN: a command substitution, arithmetic expansion " <>
                   "or indirection can place the value " <> @exposed
               ],
               command
      end

      env = %{"B_TOKEN" => "vault:b", "A_TOKEN" => "Bearer vault:a", "NODE_ENV" => "production"}
      assert [warning] = warned(token("run $(pwd)", env))
      assert warning =~ "beside the vault-bound A_TOKEN, B_TOKEN: "
    end

    test "every expanded name is warned of, then a computing form beside the others" do
      env = %{"A_TOKEN" => "vault:a", "B_TOKEN" => "vault:b", "C_TOKEN" => "vault:c"}

      assert [a, c, computed] = warned(token("run --a $A_TOKEN --c ${C_TOKEN} --d $(date)", env))
      assert a =~ "The command expands A_TOKEN, a vault-bound env name"
      assert c =~ "The command expands C_TOKEN, a vault-bound env name"
      assert computed =~ ~s(The command has "$(" beside the vault-bound B_TOKEN: )
    end

    test "a command that reads the value from its environment carries no warning" do
      for command <- [
            "npx server",
            "npx -y @modelcontextprotocol/server-github --stdio",
            "npx server --log $NODE_ENV --tz ${TZ}",
            "npx server --other $GITHUB_PERSONAL_ACCESS_TOKEN_FILE ${GITHUB_PERSONAL_ACCESS_TOKENS}",
            "npx server --price 5$ --len ${#GITHUB_PERSONAL_ACCESS_TOKEN}"
          ] do
        env = %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "vault:gh-token", "NODE_ENV" => "production"}
        assert warned(token(command, env)) == [], command
      end

      # With no vault-bound name a command may compute what it likes, and
      # expand the literal names it holds.
      env = %{"NODE_ENV" => "production"}
      command = "node \"$(npm root -g)/server/index.js\" --env $NODE_ENV `date +%s`"
      assert warned(token(command, env)) == []
      assert warned(token(command, %{})) == []
      assert warned(%{"command" => command}) == []
    end

    test "a literal-name entry bound to the vault is vault-bound too" do
      assert [warning] = warned(token("run --log $DEBUG", %{"DEBUG" => "vault:dbg"}))
      assert warning =~ "The command expands DEBUG"
    end

    test "the literal vault: refusal stands beside the warning" do
      assert refused(token("run --token vault:gh-token")) =~ "names a vault entry"

      assert refused(token("run --token VAULT:gh-token", %{})) =~ "names a vault entry"
    end
  end

  test "env names are well formed and none is reserved" do
    for name <- ["lower", "1ST", "A-B", String.duplicate("A", 65)] do
      assert refused(config(%{"env" => %{name => "vault:x"}})) =~ "must match"
    end

    for name <-
          ~w(PATH HOME USER LOGNAME SHELL TMPDIR PWD CYFR_LOCUS_BACKENDS_KEY LOCUS_BACKENDS_PORT KEEPER_CHANNEL) do
      assert refused(config(%{"env" => %{name => "vault:x"}})) =~ "reserved"
    end
  end

  # A terminal open adds TERM when a row names none, and the keeper refuses
  # a spawn whose environment passes its bound: a row at the bound opened
  # a run but could never open a terminal.
  test "an env names at most the keeper's bound less one variable besides TERM" do
    keeper =
      Path.expand("../../../../../tests/fixtures/keeper_protocol.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    max = Prima.LocusBackends.max_env_names()
    assert max == keeper["request_bounds"]["max_env"] - 1

    names = fn n -> Map.new(1..n, &{"V#{&1}", "vault:x"}) end
    assert {:ok, _} = Definition.validate(config(%{"env" => names.(max)}))

    assert {:ok, %{"env" => env}} =
             Definition.validate(config(%{"env" => Map.put(names.(max), "TERM", "vault:term")}))

    assert map_size(env) == max + 1

    assert refused(config(%{"env" => names.(max + 1)})) ==
             "config.env names at most #{max} variables besides TERM"
  end

  # The keeper's vectors and the backends wire's hold the prefixes the
  # keeper and the backends service refuse, and the wire's the names the
  # service lets hold a literal, so a program CYFR accepts is one neither
  # of them refuses for its env.
  test "the reserved prefixes and the literal names are the keeper's and the backends wire's vectors'" do
    vectors = fn name ->
      Path.expand("../../../../../tests/fixtures/#{name}", __DIR__)
      |> File.read!()
      |> Jason.decode!()
    end

    keeper = vectors.("keeper_protocol.json")
    wire = vectors.("locus_backends.json")

    assert [_ | _] = prefixes = keeper["reserved_env_prefixes"]
    assert wire["reserved_env_prefixes"] == prefixes
    assert Prima.LocusBackends.reserved_env_prefixes() == prefixes
    assert Prima.LocusBackends.literal_env_names() == wire["literal_env_names"]

    for name <- Prima.LocusBackends.reserved_env_names() ++ Enum.map(prefixes, &(&1 <> "TOKEN")) do
      assert refused(config(%{"env" => %{name => "vault:x"}})) =~ "reserved"
    end
  end

  test "an env value is a vault template; only the non-secret names may hold a literal" do
    assert refused(config(%{"env" => %{"API_KEY" => "sk-literal"}})) =~
             "must reference a vault entry"

    for unresolved <- ["secret:x", "Token secret:x", "vault:"] do
      assert refused(config(%{"env" => %{"API_KEY" => unresolved}})) =~ "does not resolve"
      assert refused(config(%{"env" => %{"NODE_ENV" => unresolved}})) =~ "does not resolve"
    end

    assert refused(config(%{"env" => %{"API_KEY" => 42}})) =~ "string value"
    assert refused(config(%{"env" => ["API_KEY"]})) =~ "must be an object"

    for name <- Prima.LocusBackends.literal_env_names() do
      assert {:ok, _} = Definition.validate(config(%{"env" => %{name => "1"}}))
    end
  end

  test "the vault entries the env templates reference, sorted and unique" do
    definition =
      config(%{
        "env" => %{
          "A" => "vault:zeta",
          "B" => "vault:gh-token",
          "C" => "Bearer vault:gh-token",
          "NODE_ENV" => "production"
        }
      })

    assert Definition.entry_names(definition) == ["gh-token", "zeta"]
    assert Definition.entry_names(%{}) == []
    assert Definition.entry_names(nil) == []
  end

  describe "one kind of program, marked by how it is spoken to" do
    defp row(overrides),
      do:
        Map.merge(
          Map.merge(config(), %{"transport" => "program", "home" => "scratch"}),
          overrides
        )

    test "a program saved as mcp and one saved as driven run through one definition" do
      assert {:ok, mcp} = Definition.validate_row(row(%{"mark" => "mcp"}))
      assert {:ok, driven} = Definition.validate_row(row(%{"mark" => "driven"}))

      # The columns differ in the mark alone, and the program a sync defines
      # from either row is the same, on the wire as in memory.
      assert Map.delete(mcp, :mark) == Map.delete(driven, :mark)
      assert {mcp.mark, driven.mark} == {"mcp", "driven"}

      stored = fn columns -> Map.merge(columns, %{transport: "program"}) end
      {:ok, definition} = Definition.validate(row(%{"mark" => "mcp"}))

      assert {:ok, program} = Definition.program(stored.(mcp), definition)
      assert {:ok, ^program} = Definition.program(stored.(driven), definition)
      assert program.name == Definition.program_name()
      assert Definition.wire(program).command == config()["command"]
    end

    test "the mark is mcp or driven, and nothing reads the old kinds" do
      for mark <- [nil, "pipe", "stdio", "MCP"] do
        assert {:error, {:invalid_argument, message}} =
                 Definition.validate_row(row(%{"mark" => mark}))

        assert message ==
                 "config.mark must be mcp (CYFR speaks MCP to it) or driven " <>
                   "(a person or a crew member runs it)"
      end

      for transport <- ["stdio", "pipe", "http"] do
        assert {:error, {:invalid_argument, "Only a row whose transport is program is a program"}} =
                 Definition.validate_row(row(%{"transport" => transport, "mark" => "mcp"}))
      end
    end

    test "a kept program of either mark names no login entry: its folder is its row's" do
      for mark <- ["mcp", "driven"] do
        assert {:ok, columns} =
                 Definition.validate_row(row(%{"mark" => mark, "home" => "kept"}))

        assert columns.home == "kept"
        refute Map.has_key?(columns, :login_entry_id)
      end

      refute "login_entry_id" in Definition.program_keys()
      refute "login_entry_id" in Definition.config_keys()
    end
  end

  test "each program brain is a definition its row can hold, its command starting with a driver" do
    names = Enum.map(Definition.brains(), & &1.name)
    assert names == Enum.uniq(names)

    drivers =
      for %{name: name, title: title, command: command} <- Definition.brains() do
        assert is_binary(title) and title != "", name
        assert Compendium.AquaPath.valid_name?(name), name
        assert {:ok, %{"command" => ^command}} = Definition.validate(%{"command" => command})

        row = %{transport: "program", config_json: Jason.encode!(%{"command" => command})}
        driver = Arca.McpServerStorage.driver(row)
        assert is_binary(driver), "#{name}: #{command} starts with no brain driver"
        driver
      end

    assert drivers == Enum.uniq(drivers)
    assert Definition.brain("claude-code").title == "Claude Code"
    assert Definition.brain("nope") == nil
  end
end
