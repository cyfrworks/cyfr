# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.BackendDefinitionTest do
  @moduledoc """
  A stdio server's backends: named, capped per server, a command that
  names no vault entry, env names that are neither malformed nor reserved,
  and env values that are vault templates except for the non-secret names
  that may hold literals.
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
    assert refused([backend(%{"command" => String.duplicate("a", 4097)})]) =~ "longer"
  end

  test "env names are well formed and none is reserved" do
    for name <- ["lower", "1ST", "A-B", String.duplicate("A", 65)] do
      assert refused([backend(%{"env" => %{name => "vault:x"}})]) =~ "must match"
    end

    for name <-
          ~w(PATH HOME USER LOGNAME SHELL TMPDIR PWD CYFR_MCP_BRIDGE_KEY MCP_BRIDGE_PORT KEEPER_CHANNEL) do
      assert refused([backend(%{"env" => %{name => "vault:x"}})]) =~ "reserved"
    end
  end

  # The keeper's vectors hold the list the keeper and the bridge refuse, so
  # a backend CYFR accepts is one neither of them refuses for its names.
  test "the reserved prefixes are the keeper's vectors'" do
    vectors =
      Path.expand("../../../../../tests/fixtures/keeper_protocol.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert [_ | _] = vectors["reserved_env_prefixes"]
    assert BackendDefinition.reserved_prefixes() == vectors["reserved_env_prefixes"]
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
