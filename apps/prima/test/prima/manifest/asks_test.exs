# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.AsksTest do
  @moduledoc """
  A catalyst's `asks` block is held to its grammar at the one manifest
  validator, refused on every other type, and each declaration has the
  digest the plan's byte format fixes.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest
  alias Prima.Manifest.Asks

  defp validate(manifest), do: Manifest.validate(manifest, fn _path -> true end)

  defp catalyst(asks), do: %{"name" => "db", "type" => "catalyst", "asks" => asks}

  defp entry(name, title), do: %{"name" => name, "title" => title}

  defp refused(manifest) do
    assert {:error, {:invalid_manifest, [{:invalid_asks, sentence}]}} = validate(manifest)
    sentence
  end

  describe "a valid list" do
    test "passes the manifest's validator, and reads back in its order" do
      manifest =
        catalyst([
          entry("delete_table", "delete a table"),
          entry("delete_rows", "delete rows from a table"),
          entry("drop_v2", "Tabelle löschen - 2 Schritte")
        ])

      assert :ok = validate(manifest)

      assert Asks.from_manifest(manifest) == [
               %{name: "delete_table", title: "delete a table"},
               %{name: "delete_rows", title: "delete rows from a table"},
               %{name: "drop_v2", title: "Tabelle löschen - 2 Schritte"}
             ]
    end

    test "an empty list, sixteen entries, a 64-character name and an 80-character title pass" do
      assert :ok = validate(catalyst([]))
      assert :ok = validate(catalyst(for i <- 1..16, do: entry("a#{i}", "act #{i}")))

      long_name = "a" <> String.duplicate("b_9", 21)
      assert String.length(long_name) == 64
      # 80 code points, 160 bytes: the bound is code points.
      assert :ok = validate(catalyst([entry(long_name, String.duplicate("ö", 80))]))
    end

    test "asks is a key of the roster" do
      assert "asks" in Manifest.known_keys()
    end

    test "a manifest without the block declares none" do
      assert Asks.from_manifest(%{"type" => "catalyst"}) == []
      assert Asks.from_manifest(nil) == []
    end
  end

  describe "refused" do
    test "an unknown field, or a missing one, in an entry" do
      assert refused(catalyst([Map.put(entry("drop", "drop it"), "reason", "x")])) =~
               "exactly name and title"

      assert refused(catalyst([%{"name" => "drop"}])) =~ "exactly name and title"
      assert refused(catalyst(["drop"])) =~ "exactly name and title"
      assert refused(catalyst([nil])) =~ "exactly name and title"
    end

    test "a block that is not a list" do
      assert refused(catalyst(%{"drop" => "drop it"})) =~ "must be a list"
    end

    test "a duplicate name" do
      assert refused(catalyst([entry("drop", "drop it"), entry("drop", "drop again")])) =~
               ~s(asks names "drop" more than once)
    end

    test "a bad name" do
      for name <- [
            "Drop",
            "1drop",
            "_drop",
            "drop-it",
            "drop it",
            "",
            "a" <> String.duplicate("b", 64),
            7
          ] do
        assert refused(catalyst([entry(name, "drop it")])) =~ "asks names are lowercase",
               "#{inspect(name)} was not refused"
      end
    end

    test "a title past 80, blank, on two lines, or with a control or format character" do
      for title <- [
            String.duplicate("a", 81),
            "",
            "   ",
            "drop\nit",
            "drop\rit",
            "drop\tit",
            "drop\u0000it",
            "drop\u200Bit",
            "drop\u202Eit",
            "drop it.",
            "drop it; then delete everything",
            <<0xFF>>,
            nil
          ] do
        assert refused(catalyst([entry("drop", title)])) =~ "asks.drop: a title",
               "#{inspect(title)} was not refused"
      end
    end

    test "a seventeenth entry" do
      assert refused(catalyst(for i <- 1..17, do: entry("a#{i}", "act #{i}"))) =~
               "at most 16 actions"
    end

    test "asks on a reagent, a formula, any other type and a manifest with no type, even empty" do
      for type <- ["reagent", "formula", "tincture", "agent", nil],
          asks <- [[], [entry("drop", "drop it")]] do
        manifest =
          %{"name" => "db", "asks" => asks}
          |> Map.merge(if type, do: %{"type" => type}, else: %{})

        assert refused(manifest) == "asks is only valid on type catalyst",
               "#{inspect(type)} with #{inspect(asks)} was not refused"

        assert Asks.from_manifest(manifest) == []
      end
    end
  end

  describe "digest/1" do
    # Hand-computed: SHA-256 over <<len::32-big>> <> name <> <<len::32-big>> <> title.
    test "is the plan's byte format, by hand" do
      assert Asks.digest(%{name: "delete_table", title: "delete a table"}) ==
               "7d243de0ac284c221f499567c3013b9e5741e104a7bd3055718cbc3f3f0cec56"

      # The prefix counts UTF-8 bytes: "tabelle löschen" is 15 code points, 16 bytes.
      assert Asks.digest(%{name: "drop", title: "tabelle löschen"}) ==
               "21507c02198eda0803ac24e8e605c1848c385515d4b22d8dc6200d3be9ca9a3e"
    end

    test "the length prefix keeps the fields apart" do
      refute Asks.digest(%{name: "ab", title: "c"}) == Asks.digest(%{name: "a", title: "bc"})
    end
  end
end
