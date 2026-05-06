defmodule SanctumTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  describe "local_context/0" do
    test "returns local context" do
      ctx = Sanctum.TestContext.local()

      assert ctx.user_id == "local|local|testns"
      assert Context.has_permission?(ctx, :execute)
    end
  end
end
