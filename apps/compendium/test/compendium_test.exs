defmodule CompendiumTest do
  use ExUnit.Case
  doctest Compendium

  test "greets the world" do
    assert Compendium.hello() == :world
  end
end
