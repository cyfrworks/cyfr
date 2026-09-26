# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.DesktopTest do
  @moduledoc """
  `Prism.Desktop`: a posture's slots in order with their sizes, each
  resolved to an installed tincture or a placeholder; a floating position
  as percentages; the layout read through `Compendium.layout/2`; and an
  edit made only through the gate's `layout.edit`, whose answer — a
  conflict over a stale revision included — is the answer.
  """

  use ExUnit.Case, async: false

  alias Prism.Desktop

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "desktop_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arca, :base_path, prev),
        else: Application.delete_env(:arca, :base_path)

      File.rm_rf!(base)
    end)

    _athanor = Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, ctx} = Sanctum.Caller.establish(session.token)
    {:ok, ctx: ctx}
  end

  defp document(slots) do
    %{
      "version" => 1,
      "postures" => %{
        "desk" => %{"desktop" => "tincture:local.desktop", "slots" => slots, "floating" => []}
      }
    }
  end

  @slots [
    %{"id" => "b", "tincture" => "tincture:local.weather", "size" => "card", "order" => 1},
    %{"id" => "a", "tincture" => "tincture:acme.gone", "size" => "icon", "order" => 1},
    %{"id" => "z", "tincture" => "tincture:local.notes", "size" => "full", "order" => 0}
  ]

  test "a posture's slots are in order, each resolved or a placeholder" do
    {:ok, layout} = Prima.Layout.validate(document(@slots))
    {:ok, desk} = Prima.Layout.posture(layout, "desk")

    installed = [
      %{publisher: "local", name: "weather", version: "1.0.0"},
      %{publisher: "local", name: "notes", version: "0.2.0"}
    ]

    assert [
             %{id: "z", size: :full, resolved: {:installed, %{name: "notes"}}},
             %{id: "a", size: :icon, tincture: "tincture:acme.gone", resolved: :placeholder},
             %{id: "b", size: :card, resolved: {:installed, %{name: "weather"}}}
           ] = Desktop.slots(desk, installed)

    assert Enum.all?(Desktop.slots(desk, []), &(&1.resolved == :placeholder))
  end

  test "a floating position is hundredths of a percent of the viewport" do
    assert Desktop.percent(%{x: 0, y: 10_000}) == %{x: 0.0, y: 100.0}
    assert Desktop.percent(%{x: 2500, y: 1234}) == %{x: 25.0, y: 12.34}
    assert_raise FunctionClauseError, fn -> Desktop.percent(%{x: 10_001, y: 0}) end
  end

  test "the layout is read, and edited only through the gate, stale revisions refused",
       %{ctx: ctx} do
    assert {:ok, %{revision: 0, shipped_default: true, arrangement: %{slots: []}}} =
             Desktop.layout(ctx, "desk")

    assert {:ok, %{revision: 1}} = Desktop.edit(ctx, document(@slots), 0)

    assert {:ok, %{revision: 1, arrangement: %{slots: [%{id: "z"}, %{id: "a"}, %{id: "b"}]}}} =
             Desktop.layout(ctx, "desk")

    # The document was published since revision 0 was read.
    assert {:error, {:conflict, sentence}} = Desktop.edit(ctx, document([]), 0)
    assert sentence =~ "get it again"

    # An edit is only ever an arrangement: an operation in it is refused.
    bad = put_in(document([]), ["postures", "desk", "operation"], "vault.list")
    assert {:error, {:invalid_argument, _sentence}} = Desktop.edit(ctx, bad, 1)

    assert {:ok, %{revision: 1}} = Desktop.layout(ctx, "desk")
  end
end
