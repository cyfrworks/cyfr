defmodule SanctumTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context
  alias Sanctum.User

  describe "build_context/1" do
    test "builds context from user" do
      user = User.local()
      ctx = Sanctum.build_context(user)

      assert ctx.user_id == user.id
      assert ctx.org_id == nil
      assert ctx.scope == :personal
      assert MapSet.member?(ctx.permissions, :*)
    end
  end

  describe "local_context/0" do
    test "returns local context" do
      ctx = Sanctum.local_context()

      assert ctx.user_id == "local_user"
      assert Context.has_permission?(ctx, :execute)
    end
  end
end
