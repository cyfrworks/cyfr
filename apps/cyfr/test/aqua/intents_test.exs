# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.IntentsTest do
  @moduledoc """
  The assistant's browser intents move the browser and write nothing:
  every kind `validate/1` reads is known to it, none of them writes a
  layout, and arranging the canvases is the `layout` tool's `edit`, which
  a running chain reaches through the gate like any tool.
  """

  use ExUnit.Case, async: true

  alias Aqua.Intents

  @root Path.expand("../../../..", __DIR__)

  # The kinds `validate/1` has a clause for: the whole vocabulary.
  defp kinds do
    Path.join(@root, "apps/cyfr/lib/aqua/intents.ex")
    |> Prima.Test.SourceTree.read()
    |> then(&Regex.scan(~r/def validate\(%\{"kind" => "([a-z_.]+)"\}/, &1))
    |> Enum.map(fn [_, kind] -> kind end)
  end

  test "every kind validate/1 reads is a known kind" do
    assert kinds() != []

    for kind <- kinds() do
      refute Intents.validate(%{"kind" => kind}) == {:error, "unknown kind: #{inspect(kind)}"}
    end
  end

  test "no intent writes a layout" do
    for kind <- kinds(), do: refute(kind =~ "layout")

    for kind <- ["ui.layout.edit", "ui.layout.set", "layout.edit"] do
      assert Intents.validate(%{"kind" => kind, "document" => %{}}) ==
               {:error, "unknown kind: #{inspect(kind)}"}
    end
  end

  test "layout.edit is an operation a running chain reaches through the gate" do
    assert {:ok, {Compendium.Providers.Layout, tool}} = Sanctum.Catalog.lookup("layout")
    assert %{"edit" => edit} = Sanctum.Annotations.actions_of(tool)
    assert :in_chain in edit.planes
    assert Sanctum.Catalog.chain_reachable?("layout", "edit")
    refute Sanctum.Catalog.host_intercepted?("layout", "edit")
  end
end
