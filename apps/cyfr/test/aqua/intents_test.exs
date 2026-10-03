# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.IntentsTest do
  @moduledoc """
  The assistant's browser intents move the browser and write nothing: the
  vocabulary is exactly what `validate/1` reads, none of it writes a
  layout, and arranging the desktop is the `layout` tool's `edit`, which
  a running chain reaches through the gate like any tool.
  """

  use ExUnit.Case, async: true

  alias Aqua.Intents

  @root Path.expand("../../../..", __DIR__)

  test "the vocabulary is exactly the kinds validate/1 reads" do
    read =
      Path.join(@root, "apps/cyfr/lib/aqua/intents.ex")
      |> Prima.Test.SourceTree.read()
      |> then(&Regex.scan(~r/def validate\(%\{"kind" => "([a-z_.]+)"\}/, &1))
      |> Enum.map(fn [_, kind] -> kind end)
      |> Enum.sort()

    assert read == Enum.sort(Intents.kinds())

    for kind <- Intents.kinds() do
      refute Intents.validate(%{"kind" => kind}) == {:error, "unknown kind: #{inspect(kind)}"}
    end
  end

  test "no intent writes a layout" do
    for kind <- Intents.kinds(), do: refute(kind =~ "layout")

    for kind <- ["ui.layout.edit", "ui.layout.set", "layout.edit"] do
      assert Intents.validate(%{"kind" => kind, "document" => %{}}) ==
               {:error, "unknown kind: #{inspect(kind)}"}
    end
  end

  test "layout.edit is an operation a running chain reaches through the gate" do
    assert {:ok, {Compendium.Providers.Layout, tool}} = Grimoire.lookup("layout")
    assert %{"edit" => edit} = Grimoire.declared_actions(tool)
    assert :in_chain in edit.planes
    assert Grimoire.chain_reachable?("layout", "edit")
    refute Grimoire.host_intercepted?("layout", "edit")
  end
end
