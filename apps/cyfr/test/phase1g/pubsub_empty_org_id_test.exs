defmodule Phase1g.PubSubEmptyOrgIdTest do
  use ExUnit.Case, async: false

  alias Sanctum.PubSub
  alias Sanctum.Context

  describe "empty org_id in Arx mode" do
    setup do
      original = Application.get_env(:cyfr, :edition, :core)
      on_exit(fn -> Application.put_env(:cyfr, :edition, original) end)
      :ok
    end

    test "raises ArgumentError for Context with empty org_id in Arx mode" do
      Application.put_env(:cyfr, :edition, :arx)
      ctx = %Context{user_id: "user_1", org_id: "", project_id: "proj_1"}

      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSub.topic("test:topic", ctx)
      end
    end

    test "raises ArgumentError for bare empty string in Arx mode" do
      Application.put_env(:cyfr, :edition, :arx)

      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSub.topic("test:topic", "")
      end
    end

    test "passes through in Core mode with empty org_id Context" do
      Application.put_env(:cyfr, :edition, :core)
      ctx = %Context{user_id: "user_1", org_id: "", project_id: "proj_1"}

      assert PubSub.topic("test:topic", ctx) == "test:topic"
    end

    test "passes through in Core mode with empty string org_id" do
      Application.put_env(:cyfr, :edition, :core)

      assert PubSub.topic("test:topic", "") == "test:topic"
    end
  end
end
