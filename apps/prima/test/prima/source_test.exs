# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SourceTest do
  @moduledoc """
  The closed source classes, their canonical JSON and the fail-closed
  reading: an unknown or absent class reads as outside, and a set that
  does not decode reads as one unnamed outside source.
  """

  use ExUnit.Case, async: true

  alias Prima.Source

  test "the classes are closed at five, in their fixed order" do
    assert Source.classes() == [:pinned, :filed, :files_by_grant, :vault_disclosed, :outside]
  end

  test "only an outside source carries a name" do
    assert %Source{class: :outside, name: "example.com"} = Source.outside(" example.com ")
    assert %Source{class: :filed, name: nil} = Source.new(:filed, "ignored")
    assert %Source{class: :outside, name: nil} = Source.outside("  ")
  end

  test "a set's canonical JSON is sorted by class, then name, without duplicates" do
    set = [
      Source.outside("b.example"),
      Source.new(:filed),
      Source.outside("a.example"),
      Source.new(:pinned),
      Source.new(:filed)
    ]

    assert Source.encode(set) ==
             ~s([{"class":"pinned","name":null},{"class":"filed","name":null},) <>
               ~s({"class":"outside","name":"a.example"},{"class":"outside","name":"b.example"}])

    assert Source.decode(Source.encode(set)) == Source.set(set)
    assert Source.encode([]) == "[]"
    assert Source.decode("[]") == []
    assert Source.decode(nil) == []
  end

  test "an unknown or absent class reads as outside, keeping its name" do
    assert Source.from_json(%{"class" => "unsettled", "name" => "x"}) == Source.outside("x")
    assert Source.from_json(%{"name" => "feed"}) == Source.outside("feed")
    assert Source.from_json(%{class: :files_by_grant}) == Source.new(:files_by_grant)
    assert Source.from_json("filed") == Source.outside(nil)
  end

  test "a set that does not decode reads as one unnamed outside source" do
    for text <- ["not json", ~s({"class":"filed"}), "3"] do
      assert Source.decode(text) == [Source.outside(nil)]
    end
  end

  test "uncovered names the outside sources a cover does not name, never an unnamed one" do
    read = [Source.new(:filed), Source.outside("a.example"), Source.outside(nil)]

    assert Source.uncovered(read, [Source.outside("a.example")]) == [Source.outside(nil)]

    assert Source.uncovered(read, []) == [Source.outside(nil), Source.outside("a.example")]
    assert Source.uncovered([Source.new(:pinned)], []) == []
  end

  test "union and classes_of keep the fixed order" do
    assert Source.union([Source.outside("x")], [Source.new(:pinned)]) ==
             [Source.new(:pinned), Source.outside("x")]

    assert Source.classes_of([Source.outside("x"), Source.new(:filed), Source.outside("y")]) ==
             [:filed, :outside]
  end
end
