# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.OperationTableTest do
  use ExUnit.Case, async: false

  alias Sanctum.OperationTable

  test "the one implementation is the operation catalog, and it answers the port" do
    assert OperationTable.impl!() == Sanctum.Catalog

    behaviours =
      Sanctum.Catalog.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert OperationTable in behaviours

    actions = OperationTable.tool_actions()
    assert "system.status" in actions
    assert Enum.all?(actions, &(&1 =~ ~r/^[a-z_]+\.[a-z_]+$/))
  end

  test "an uninstalled port raises where it is asked, rather than answering an empty roster" do
    installed = OperationTable.impl!()
    on_exit(fn -> OperationTable.install!(installed) end)
    OperationTable.reset()

    error = assert_raise OperationTable.NotInstalledError, fn -> OperationTable.tool_actions() end
    assert error.message =~ "Sanctum.OperationTable.install!/1"
    assert_raise OperationTable.NotInstalledError, fn -> OperationTable.impl!() end
  end

  test "an install that does not answer every callback is refused, and changes nothing" do
    assert_raise ArgumentError, ~r/does not implement Sanctum.OperationTable: missing/, fn ->
      OperationTable.install!(Sanctum.Consent.Components)
    end

    assert OperationTable.impl!() == Sanctum.Catalog
  end

  test "a shape derives its tool roster through the port" do
    assert Sanctum.Consent.ShapeDerivation.all_tool_actions() == OperationTable.tool_actions()
  end

  test "a grant's tool servers are answered through the port", tags do
    Cyfr.Test.Sandbox.setup!(tags)
    ctx = Sanctum.TestContext.local()

    assert is_list(OperationTable.tool_server_candidates(ctx))
    assert {:error, _} = OperationTable.tool_server_candidate(ctx, "no-such-server")
  end

  # Consent reaches the operation catalog through this port and nowhere
  # else: no module under `sanctum/consent` names the transport.
  test "consent names no Emissary module" do
    root = Path.expand("../../../..", __DIR__)

    reaches =
      for file <-
            Prima.Test.SourceTree.files!(
              Path.join(root, "apps/sanctum/lib/sanctum/consent/**/*.ex")
            ),
          line <- file |> Prima.Test.SourceTree.read() |> Prima.Test.CodeLines.lines(),
          line =~ ~r/\bEmissary\./,
          do: "#{Path.relative_to(file, root)}: #{String.trim(line)}"

    assert reaches == []
  end
end
