# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerShareTest do
  @moduledoc """
  The sharing sheet (`PrismWeb.SystemLayer.Share`): what it offers, what
  it says the caps mean, and the `share.create` arguments it holds a
  submission to before anything is dispatched. The sheet in the layer,
  its confirmation and the share it makes are the Vault page's tests
  (`PrismWeb.VaultLiveTest`, "sharing a key").
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PrismWeb.SystemLayer.Share

  @threads [%{id: "sth_traders", name: "Traders"}, %{id: "sth_pair", name: "Alice"}]
  @subject %{entry_id: "vlt_1", name: "market key", threads: @threads}
  @prompt %{id: "share-vlt_1", kind: :share, action: :credential_sharing, subject: @subject}

  defp sheet(administrator, prompt \\ @prompt),
    do:
      render_component(&Share.sheet/1,
        id: "system-layer",
        prompt: prompt,
        administrator: administrator,
        myself: nil
      )

  defp text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  describe "the sheet" do
    test "offers everyone and the person's threads, a pair by its name, and no list of people" do
      html = sheet(false)

      assert text(html, ~s([data-test="share-audience"] label)) ==
               ["Everyone on this CYFR", "Traders", "Alice"]

      values =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(input[name="audience"]))
        |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))

      assert values == ["everyone", "shared_thread:sth_traders", "shared_thread:sth_pair"]
      refute html =~ ~s(type="checkbox")
      refute html =~ "checked"
    end

    test "warns before any audience is chosen, including for an entry holding no key" do
      for name <- ["market key", "Claude Code sign-in"], administrator <- [true, false] do
        prompt = put_in(@prompt, [:subject, :name], name)
        html = sheet(administrator, prompt)

        assert text(html, ~s([data-test="share-warning"] p)) == [
                 "You are responsible for following the provider's terms when sharing this entry.",
                 "What recipients send reaches the provider as you.",
                 "Recipients use your provider limits up to the caps you set and never see your key or other secrets. You can revoke the share at any time."
               ]

        refute html =~ "checked"
        refute html =~ "CYFR attaches it"
      end
    end

    test "starts with both caps empty and says what empty, 0 and a number mean" do
      html = sheet(false)

      caps =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(input[type="number"]))

      assert Enum.flat_map(caps, &LazyHTML.attribute(&1, "name")) ==
               ["person_daily", "total_daily"]

      assert Enum.flat_map(caps, &LazyHTML.attribute(&1, "value")) == []

      assert text(html, ~s([data-test="share-caps-meaning"])) == [
               "An empty cap is no limit. 0 admits no use. A number is the most requests " <>
                 "that day; a day ends at midnight UTC."
             ]
    end

    test "says what an uncapped share to everyone means, and to the platform administrator " <>
           "what it means for a newcomer's AQUA" do
      assert text(sheet(false), ~s([data-test="share-uncapped"])) == [
               "Shared with everyone and no cap, anyone on this CYFR may use it without limit."
             ]

      [administrator] = text(sheet(true), ~s([data-test="share-uncapped"]))
      assert administrator =~ "anyone on this CYFR may use it without limit"
      assert administrator =~ "each new person's AQUA uses when it fits"
    end

    test "asks for no value and offers no component policy" do
      html = sheet(true)
      refute html =~ ~s(type="password")
      refute html =~ ~s(name="fields")
      refute html =~ "policy"
    end

    test "never names the words a person does not read" do
      words = ~w(home hub cell node door glass)

      for administrator <- [true, false],
          word <- words,
          do: refute(sheet(administrator) =~ ~r/\b#{word}\b/i, word)
    end
  end

  describe "args/2" do
    test "an audience of everyone, or of one of the prompt's threads" do
      assert Share.args(@subject, %{"audience" => "everyone"}) ==
               {:ok, %{"entry_id" => "vlt_1", "audience" => "everyone"}}

      assert Share.args(@subject, %{"audience" => "shared_thread:sth_pair"}) ==
               {:ok, %{"entry_id" => "vlt_1", "audience" => "thread", "thread_id" => "sth_pair"}}

      for chosen <- [
            nil,
            "",
            "shared_thread:sth_elsewhere",
            "shared_thread:",
            "group:sth_traders",
            "listed",
            "sth_traders"
          ] do
        assert {:error, "Choose who it is shared with" <> _} =
                 Share.args(@subject, %{"audience" => chosen}),
               inspect(chosen)
      end
    end

    test "an empty cap is absent, which is no limit; 0 and a number are sent as counts" do
      assert Share.args(@subject, %{
               "audience" => "everyone",
               "person_daily" => " ",
               "total_daily" => ""
             }) == {:ok, %{"entry_id" => "vlt_1", "audience" => "everyone"}}

      assert Share.args(@subject, %{
               "audience" => "everyone",
               "person_daily" => "0",
               "total_daily" => " 25 "
             }) ==
               {:ok,
                %{
                  "entry_id" => "vlt_1",
                  "audience" => "everyone",
                  "person_daily" => 0,
                  "total_daily" => 25
                }}

      for cap <- ["-1", "1.5", "ten", "3 a day", "0x10"] do
        assert {:error, "A cap is a whole number" <> _} =
                 Share.args(@subject, %{"audience" => "everyone", "person_daily" => cap}),
               cap
      end
    end
  end

  describe "caps/1 and audience_value/1" do
    test "both caps are named, an empty one nil" do
      assert Share.caps(%{"person_daily" => "", "total_daily" => "4"}) ==
               {:ok, %{"person_daily" => nil, "total_daily" => 4}}

      assert Share.caps(%{}) == {:ok, %{"person_daily" => nil, "total_daily" => nil}}
    end

    test "an audience reads back as the choice that names it" do
      for audience <- [
            %{"audience" => "everyone"},
            %{"audience" => "thread", "thread_id" => "sth_traders"}
          ] do
        assert {:ok, ^audience} = Share.audience(Share.audience_value(audience), @threads)
      end
    end
  end
end
