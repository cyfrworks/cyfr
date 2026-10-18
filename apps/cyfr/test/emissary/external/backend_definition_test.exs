# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.BackendDefinitionTest do
  @moduledoc """
  A stdio server's backends: named, capped per server, a command that
  names no vault entry, env names that are neither malformed nor reserved,
  and env values that are vault templates except for the non-secret names
  that may hold literals; a command that places a vault-bound value on the
  command line is accepted and warned of.
  """
  use ExUnit.Case, async: true

  alias Emissary.External.BackendDefinition

  defp backend(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "github",
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
    [%{"name" => "github", "command" => command, "env" => env}]
  end

  defp refused(backends) do
    assert {:error, {:invalid_argument, message}} = BackendDefinition.validate(backends)
    message
  end

  test "a valid list is answered normalized, with an absent env as an empty map" do
    bare = %{"name" => "fs", "command" => "npx -y @modelcontextprotocol/server-filesystem /tmp"}

    assert {:ok, [first, second]} = BackendDefinition.validate([backend(), bare])
    assert first == backend()
    assert second == Map.put(bare, "env", %{})
  end

  test "backend names are lowercase slugs of at most 32 characters, unique within the server" do
    for name <- ["", "GitHub", "-lead", "has space", "a__b", String.duplicate("a", 33), 7] do
      assert refused([backend(%{"name" => name})]) =~ "Backend name"
    end

    assert {:ok, _} =
             BackendDefinition.validate([backend(%{"name" => String.duplicate("a", 32)})])

    assert refused([backend(), backend()]) =~ "used twice"
  end

  test "a server has at least one backend and at most the configured cap" do
    assert refused([]) =~ "at least one"
    assert refused(nil) =~ "must be a list"

    cap = BackendDefinition.max_backends()
    many = for i <- 1..(cap + 1), do: backend(%{"name" => "b#{i}"})
    assert refused(many) =~ "at most #{cap}"
    assert {:ok, _} = BackendDefinition.validate(Enum.take(many, cap))
  end

  test "a command is a non-empty string that names no vault entry" do
    assert refused([backend(%{"command" => "  "})]) =~ "needs a command"
    assert refused([backend(%{"command" => nil})]) =~ "command"
    assert refused([backend(%{"command" => "run --token vault:gh-token"})]) =~ "visible"
    assert refused([backend(%{"command" => "run VAULT:gh"})]) =~ "visible"
    assert refused([backend(%{"command" => "a" <> <<0>>})]) =~ "NUL"
    too_long = String.duplicate("a", Prima.LocusBackends.max_command_bytes() + 1)
    assert refused([backend(%{"command" => too_long})]) =~ "longer"

    assert {:ok, _} =
             BackendDefinition.validate([
               backend(%{"command" => binary_part(too_long, 1, byte_size(too_long) - 1)})
             ])
  end

  # A definition whose command places a vault-bound value on the command
  # line is the administrator's to make: it is accepted as written and
  # carries the warning.
  defp warned(backends) do
    assert {:ok, normalized} = BackendDefinition.validate(backends)
    assert normalized == Enum.map(backends, &Map.put_new(&1, "env", %{}))
    BackendDefinition.warnings(normalized)
  end

  @exposed "on the command line, where every process on the backends service, other " <>
             "athanors' backends included, can read it; the safe route is to let the " <>
             "program read it from its environment."

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
                 "Backend 'github' expands GITHUB_PERSONAL_ACCESS_TOKEN, a vault-bound env " <>
                   "name, in its command: the value is placed " <> @exposed
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
                 "Backend 'github' has #{inspect(form)} in its command beside the vault-bound " <>
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

      backends =
        token("run --a $A_TOKEN --c ${C_TOKEN} --d $(date)", env) ++
          [%{"name" => "other", "command" => "run --b $B_TOKEN", "env" => env}]

      assert [a, c, computed, b] = warned(backends)
      assert a =~ "Backend 'github' expands A_TOKEN, a vault-bound env name"
      assert c =~ "Backend 'github' expands C_TOKEN, a vault-bound env name"

      assert computed =~
               ~s(Backend 'github' has "$(" in its command beside the vault-bound B_TOKEN: )

      assert b =~ "Backend 'other' expands B_TOKEN, a vault-bound env name"
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
      assert warned([%{"name" => "bare", "command" => command}]) == []
    end

    test "a literal-name entry bound to the vault is vault-bound too" do
      assert [warning] = warned(token("run --log $DEBUG", %{"DEBUG" => "vault:dbg"}))
      assert warning =~ "Backend 'github' expands DEBUG"
    end

    test "the literal vault: refusal stands beside the warning" do
      assert refused(token("run --token vault:gh-token")) =~ "names a vault entry in its command"

      assert refused(token("run --token VAULT:gh-token", %{})) =~
               "names a vault entry in its command"
    end
  end

  test "env names are well formed and none is reserved" do
    for name <- ["lower", "1ST", "A-B", String.duplicate("A", 65)] do
      assert refused([backend(%{"env" => %{name => "vault:x"}})]) =~ "must match"
    end

    for name <-
          ~w(PATH HOME USER LOGNAME SHELL TMPDIR PWD CYFR_LOCUS_BACKENDS_KEY LOCUS_BACKENDS_PORT KEEPER_CHANNEL) do
      assert refused([backend(%{"env" => %{name => "vault:x"}})]) =~ "reserved"
    end
  end

  # The keeper's vectors and the backends wire's hold the list the keeper
  # and the backends service refuse, so a backend CYFR accepts is one
  # neither of them refuses for its names.
  test "the reserved names and prefixes are the keeper's and the backends wire's vectors'" do
    vectors = fn name ->
      Path.expand("../../../../../tests/fixtures/#{name}", __DIR__)
      |> File.read!()
      |> Jason.decode!()
    end

    keeper = vectors.("keeper_protocol.json")
    wire = vectors.("locus_backends.json")

    assert [_ | _] = keeper["reserved_env_prefixes"]
    assert BackendDefinition.reserved_prefixes() == keeper["reserved_env_prefixes"]
    assert BackendDefinition.reserved_prefixes() == wire["reserved_env_prefixes"]
    assert BackendDefinition.literal_names() == wire["literal_env_names"]

    for name <- Prima.LocusBackends.reserved_env_names() do
      assert refused([backend(%{"env" => %{name => "vault:x"}})]) =~ "reserved"
    end
  end

  test "an env value is a vault template; only the non-secret names may hold a literal" do
    assert refused([backend(%{"env" => %{"API_KEY" => "sk-literal"}})]) =~
             "must reference a vault entry"

    for unresolved <- ["secret:x", "Token secret:x", "vault:"] do
      assert refused([backend(%{"env" => %{"API_KEY" => unresolved}})]) =~ "does not resolve"
      assert refused([backend(%{"env" => %{"NODE_ENV" => unresolved}})]) =~ "does not resolve"
    end

    assert refused([backend(%{"env" => %{"API_KEY" => 42}})]) =~ "string value"

    for name <- BackendDefinition.literal_names() do
      assert {:ok, _} = BackendDefinition.validate([backend(%{"env" => %{name => "1"}})])
    end
  end

  test "a backend carries only a name, a command and an env" do
    assert refused([backend(%{"cwd" => "/"})]) =~ "unknown keys: cwd"
  end

  test "the vault entries the env templates reference, sorted and unique" do
    backends = [
      backend(),
      %{"name" => "b", "command" => "x", "env" => %{"A" => "vault:zeta", "B" => "vault:gh-token"}}
    ]

    assert BackendDefinition.entry_names(backends) == ["gh-token", "zeta"]
    assert BackendDefinition.entry_names(nil) == []
  end
end
