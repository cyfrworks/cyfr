# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.VaultRefTest do
  @moduledoc """
  A template is `vault:<entry>` or `<scheme> vault:<entry>`; it names its
  entry and renders to the entry's value after its scheme. `secret:<entry>`
  and a `vault:` naming no entry are references this server does not
  resolve, in the same two spellings; anything else is a literal.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.VaultRef

  test "a bare or scheme-prefixed reference is a template naming its entry" do
    assert {:ok, %{scheme: nil, name: "gh-token"}} = VaultRef.template("vault:gh-token")

    assert {:ok, %{scheme: "Bearer", name: "gh-token"}} =
             VaultRef.template("Bearer vault:gh-token")

    assert VaultRef.vault_ref?("Token vault:x")
  end

  test "a literal or a malformed scheme is no reference" do
    for literal <- [
          "application/json",
          "Bearer abc",
          "Bearer  vault:x",
          "a b vault:x",
          "Bearer  secret:x",
          "a b secret:x",
          " secret:x",
          "Secret:x",
          "vaults:x",
          nil,
          7
        ] do
      assert VaultRef.classify(literal) == :literal, inspect(literal)
      assert VaultRef.template(literal) == :error
      refute VaultRef.vault_ref?(literal)
      refute VaultRef.unresolved_ref?(literal)
    end
  end

  test "a template renders to its entry's value after its scheme" do
    {:ok, bare} = VaultRef.template("vault:k")
    {:ok, schemed} = VaultRef.template("Bearer vault:k")

    assert VaultRef.render(bare, "sk-1") == "sk-1"
    assert VaultRef.render(schemed, "sk-1") == "Bearer sk-1"
  end

  test "the names a header map references, sorted and once each" do
    headers = %{
      "authorization" => "Bearer vault:b",
      "x-api-key" => "vault:a",
      "x-other" => "vault:b",
      "content-type" => "application/json"
    }

    assert VaultRef.names(headers) == ["a", "b"]
  end

  test "secret:, bare or after a scheme, and vault: naming no entry are unresolved references" do
    for unresolved <- [
          "secret:x",
          "Token secret:x",
          "Bearer secret:vault:x",
          "secret:",
          "Bearer secret:",
          "vault:",
          "Bearer vault:"
        ] do
      assert VaultRef.classify(unresolved) == :unresolved, inspect(unresolved)
      assert VaultRef.unresolved_ref?(unresolved)
      assert VaultRef.template(unresolved) == :error
      refute VaultRef.vault_ref?(unresolved)
    end

    refute VaultRef.unresolved_ref?("vault:x")
    refute VaultRef.unresolved_ref?("Bearer vault:x")
    assert VaultRef.names(%{"a" => "Token secret:x", "b" => "vault:"}) == []
  end
end
