# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ApprovalScopeTest do
  use ExUnit.Case, async: true

  alias Aqua.ApprovalScope

  test "every scope round-trips through its wire spelling" do
    for scope <- ApprovalScope.all() do
      assert scope |> ApprovalScope.to_string() |> ApprovalScope.parse() == scope
      assert ApprovalScope.parse(scope) == scope
    end
  end

  test "never is a scope of its own, not a once" do
    assert ApprovalScope.parse("never") == :never
    assert ApprovalScope.standing?(:never) == false
  end

  test "anything unrecognised reaches no further than the click" do
    for value <- ["forever", "", nil, 1, :later, %{}],
        do: assert(ApprovalScope.parse(value) == :once)
  end

  test "the standing scopes are the two that answer for unseen calls" do
    assert Enum.filter(ApprovalScope.all(), &ApprovalScope.standing?/1) == [
             :conversation,
             :always
           ]
  end
end
