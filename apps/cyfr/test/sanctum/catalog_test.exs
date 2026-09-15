# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CatalogTest do
  use ExUnit.Case, async: false

  alias Sanctum.Catalog

  test "the one implementation is the operation catalog, and it answers the port" do
    assert Catalog.impl() == Cyfr.Ops.Catalog

    behaviours =
      Cyfr.Ops.Catalog.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Sanctum.Catalog in behaviours

    actions = Catalog.tool_actions()
    assert "system.status" in actions
    assert Enum.all?(actions, &(&1 =~ ~r/^[a-z_]+\.[a-z_]+$/))
  end

  test "a shape derives its tool roster through the port" do
    assert Sanctum.Consent.ShapeDerivation.all_tool_actions() == Catalog.tool_actions()
  end

  test "a grant's tool servers are answered through the port" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    ctx = Sanctum.TestContext.local()

    assert is_list(Catalog.tool_server_candidates(ctx))
    assert {:error, _} = Catalog.tool_server_candidate(ctx, "no-such-server")
  end

  # Consent reaches the operation catalog through this port and nowhere
  # else: no module under `sanctum/consent` names the transport.
  test "consent names no Emissary module" do
    root = Path.expand("../../../..", __DIR__)

    reaches =
      for file <-
            Cyfr.Test.SourceTree.files!(Path.join(root, "apps/cyfr/lib/sanctum/consent/**/*.ex")),
          line <- file |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
          line =~ ~r/\bEmissary\./,
          do: "#{Path.relative_to(file, root)}: #{String.trim(line)}"

    assert reaches == []
  end
end
