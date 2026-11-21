# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MountTest do
  @moduledoc """
  The reads the programs controller makes of program rows
  (`Sanctum.Mount`).
  """

  use ExUnit.Case, async: false

  alias Sanctum.Mount
  alias Sanctum.TestContext

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {person, _user} = TestContext.person!(TestContext.local())
    {:ok, ctx: person}
  end

  # A program row of the athanor, written as the row store writes one.
  defp row!(ctx, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id("mcp"),
          name: "claude",
          transport: "program",
          mark: "driven",
          home: "kept",
          enabled: true,
          epoch: 1,
          revision: 0,
          config_json: ~s({"command":"claude"}),
          athanor_id: ctx.athanor_id,
          created_by: ctx.user_id
        },
        over
      )

    Arca.Repo.insert!(struct(Arca.Schemas.McpServer, attrs))
  end

  describe "the reads of program rows" do
    test "orphaned_homes/1 names each home no kept row of a live athanor holds, with its athanor",
         %{ctx: ctx} do
      kept = row!(ctx)
      scratch = row!(ctx, %{name: "scratchy", home: "scratch"})
      gone = row!(ctx, %{name: "gone"})
      Arca.Repo.delete!(gone)

      assert {:ok, orphans} = Mount.orphaned_homes([kept.id, scratch.id, gone.id])
      assert Enum.sort(orphans) == Enum.sort([{scratch.id, ctx.athanor_id}, {gone.id, nil}])

      Arca.Test.Actor.archive!(ctx.athanor_id)
      assert {:ok, orphans} = Mount.orphaned_homes([kept.id])
      assert orphans == [{kept.id, ctx.athanor_id}]
    end
  end
end
