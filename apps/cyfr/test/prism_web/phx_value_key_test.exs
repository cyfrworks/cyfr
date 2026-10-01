# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PhxValueKeyTest do
  @moduledoc """
  No element in the console carries its event's payload in a
  `phx-value-value` attribute.

  For a click LiveView sends the element's own `value` property under
  `value`, overwriting the attribute of that name: a button's is empty, a
  checkbox's is its box value, and a checkbox unticked sends no `value` at
  all. What the attribute names never reaches the handler, while the page
  shows the choice made. The LiveView test client sends the attribute as
  written, so a handler's own tests pass over it; this scan is what fails.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @app Path.expand("../..", __DIR__)

  test "no source under apps/cyfr/lib names a phx-value-value attribute" do
    files = SourceTree.files!(Path.join(@app, "lib/**/*.{ex,heex}"))

    offenders =
      for path <- files,
          {line, number} <- path |> SourceTree.read() |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, "phx-value-value"),
          do: "#{Path.relative_to(path, @app)}:#{number}"

    assert offenders == [],
           "carry the payload under another key (phx-value-choice, phx-value-door, ...): " <>
             Enum.join(offenders, ", ")
  end
end
