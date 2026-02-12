defmodule LocusTest do
  use ExUnit.Case
  doctest Locus

  test "greets the world" do
    assert Locus.hello() == :world
  end
end
