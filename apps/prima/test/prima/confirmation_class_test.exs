# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConfirmationClassTest do
  @moduledoc """
  The confirmation classes: a closed enum, ordered, whose wire spellings
  are pinned in `tests/fixtures/layout.json` under `confirmation_classes`.
  """

  use ExUnit.Case, async: true

  alias Prima.ConfirmationClass

  @vectors Path.expand("../../../../tests/fixtures/layout.json", __DIR__)

  test "the wire spellings and their order are the fixture's" do
    wire = (@vectors |> File.read!() |> Jason.decode!())["confirmation_classes"]

    assert Enum.map(ConfirmationClass.all(), &ConfirmationClass.to_string/1) == wire

    assert Enum.map(wire, &ConfirmationClass.parse/1) ==
             Enum.map(ConfirmationClass.all(), &{:ok, &1})
  end

  test "each class confirms what the classes below it confirm, and nothing above" do
    classes = ConfirmationClass.all()

    for {held, i} <- Enum.with_index(classes), {required, j} <- Enum.with_index(classes) do
      assert ConfirmationClass.at_least?(held, required) == i >= j, "#{held} vs #{required}"
    end

    refute ConfirmationClass.at_least?(:none, :session)
    assert ConfirmationClass.at_least?(:strong, :session)
  end

  test "anything that is not a class holds nothing and satisfies nothing" do
    refute ConfirmationClass.at_least?(:admin, :none)
    refute ConfirmationClass.at_least?(:strong, :admin)
    refute ConfirmationClass.valid?("session")
    assert ConfirmationClass.valid?(:session)

    for other <- ["Session", "", "admin", nil, :session] do
      assert ConfirmationClass.parse(other) == {:error, :unknown_class}
    end
  end
end
