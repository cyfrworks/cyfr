# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CardTest do
  @moduledoc """
  A card's instance, projected through its declaration: it shows only
  what its tincture declared, and a refresh that answers the wrong shape
  is refused.
  """

  use ExUnit.Case, async: true

  alias Prima.Card
  alias Prima.Manifest.Tincture

  @at ~U[2026-09-26 12:00:00Z]

  defp declaration do
    {:ok, declaration} =
      Tincture.from_manifest(%{
        "tincture" => %{
          "actions" => ["vault.list"],
          "streams" => [%{"name" => "vault.status"}],
          "cards" => [
            %{
              "name" => "today",
              "title" => "Today",
              "number" => "count",
              "list" => "names",
              "image" => "icons/card.png",
              "buttons" => [%{"label" => "Open", "action" => "vault.list"}],
              "stream" => "vault.status"
            },
            %{"name" => "bare", "title" => "Bare"}
          ]
        }
      })

    declaration
  end

  defp card(name) do
    {:ok, card} = Card.declared(declaration(), name)
    card
  end

  test "the declaration is the manifest grammar's own card" do
    assert %Tincture.Card{name: "today"} = card("today")
    assert :error = Card.declared(declaration(), "absent")
  end

  test "a refresh shows the declared fields and drops every other" do
    projection = %{"count" => 3, "names" => ["a", "b"], "secret" => "hunter2"}

    assert {:ok, %Card{} = shown} = Card.project(card("today"), projection, @at)
    assert shown.title == "Today"
    assert shown.number == 3
    assert shown.list == ["a", "b"]
    assert shown.image == "icons/card.png"
    assert [%Tincture.Button{label: "Open", action: "vault.list"}] = shown.buttons
    assert shown.stream == "vault.status"
    assert shown.refreshed_at == @at

    json = Card.to_json(shown)
    refute inspect(json) =~ "hunter2"
    assert json["number"] == 3
    assert json["refreshed_at"] == "2026-09-26T12:00:00Z"
  end

  test "a card that declares no number or list shows none, whatever the refresh answers" do
    assert {:ok, shown} = Card.project(card("bare"), %{"count" => 3, "names" => ["a"]}, @at)
    assert shown.number == nil
    assert shown.list == []

    json = Card.to_json(shown)
    refute Map.has_key?(json, "number")
    refute Map.has_key?(json, "image")
    refute Map.has_key?(json, "stream")
  end

  test "a declared field the refresh does not carry is absent" do
    assert {:ok, %Card{number: nil, list: []}} = Card.project(card("today"), %{}, @at)
  end

  test "a refresh of the wrong shape is refused" do
    for projection <- [
          %{"count" => 1.5},
          %{"count" => String.duplicate("9", 33)},
          %{"names" => "a"},
          %{"names" => [1]},
          %{"names" => Enum.map(1..9, &"n#{&1}")},
          %{"names" => [String.duplicate("x", 81)]}
        ] do
      assert {:error, {:invalid_card, _}} = Card.project(card("today"), projection, @at),
             inspect(projection)
    end

    assert {:error, {:invalid_card, _}} = Card.project(card("today"), [], @at)
  end
end
