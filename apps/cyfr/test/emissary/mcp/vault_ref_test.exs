# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.VaultRefTest do
  @moduledoc """
  A header template is `vault:<entry>` or `<scheme> vault:<entry>`; it names
  its entry and renders to the entry's value after its scheme. A literal is
  no template, and `secret:` is a reference this server does not resolve.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.VaultRef

  test "a bare or scheme-prefixed reference is a template naming its entry" do
    assert {:ok, %{scheme: nil, name: "gh-token"}} = VaultRef.template("vault:gh-token")

    assert {:ok, %{scheme: "Bearer", name: "gh-token"}} =
             VaultRef.template("Bearer vault:gh-token")

    assert VaultRef.vault_ref?("Token vault:x")
  end

  test "a literal, an empty reference or a malformed scheme is no template" do
    for literal <- [
          "application/json",
          "Bearer abc",
          "vault:",
          "Bearer  vault:x",
          "a b vault:x",
          nil,
          7
        ] do
      assert VaultRef.template(literal) == :error, inspect(literal)
      refute VaultRef.vault_ref?(literal)
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

  test "secret: is a reference this server does not resolve" do
    assert VaultRef.unresolved_ref?("secret:x")
    refute VaultRef.unresolved_ref?("vault:x")
  end
end
