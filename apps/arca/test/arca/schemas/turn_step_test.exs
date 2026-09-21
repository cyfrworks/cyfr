# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.TurnStepTest do
  @moduledoc """
  What becomes of a step dispatched and never closed is read from the row
  alone, the same way at every site that settles one.
  """

  use ExUnit.Case, async: true

  alias Arca.Schemas.TurnStep

  test "a model request is unanswered, whatever it served" do
    for purpose <- TurnStep.purposes() do
      assert TurnStep.unresolved(%TurnStep{kind: "model", purpose: purpose}) == :unanswered
    end
  end

  test "a replay-safe call may run again" do
    assert TurnStep.unresolved(%TurnStep{kind: "tool", purpose: "chat", recovery: "replay_safe"}) ==
             :replay
  end

  test "a flush's call is an unknown outcome that restricts nothing" do
    assert TurnStep.unresolved(%TurnStep{kind: "tool", purpose: "flush"}) == :unknown
  end

  test "any other call is uncertain" do
    for kind <- ["tool", "clone", "launch", "ui"] do
      assert TurnStep.unresolved(%TurnStep{kind: kind, purpose: "chat"}) == :uncertain
    end
  end
end
