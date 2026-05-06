defmodule Sanctum.PubSubTest do
  use ExUnit.Case, async: false

  alias Sanctum.PubSub, as: PubSubHelper

  setup do
    # Reset edition to default after each test
    original = Application.get_env(:cyfr, :edition)
    on_exit(fn -> Application.put_env(:cyfr, :edition, original) end)
    :ok
  end

  describe "topic/2 with nil" do
    test "returns base topic" do
      assert "execution:events" == PubSubHelper.topic("execution:events", nil)
    end
  end

  describe "topic/2 with Context (core mode)" do
    test "passes through when no org_id" do
      Application.put_env(:cyfr, :edition, :core)

      ctx =
        Sanctum.Context.build(
          user_id: "u1",
          permissions: [:*],
          scope: :project,
          auth_method: :local,
          namespace: "testns",
          authenticated: true
        )

      assert "execution:events" == PubSubHelper.topic("execution:events", ctx)
    end

    test "passes through with org_id in core mode" do
      Application.put_env(:cyfr, :edition, :core)

      ctx =
        Sanctum.Context.build(
          user_id: "u1",
          org_id: "org_1",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert "execution:events" == PubSubHelper.topic("execution:events", ctx)
    end
  end

  describe "topic/2 with Context (arx mode)" do
    test "prefixes with tenant when org_id present" do
      Application.put_env(:cyfr, :edition, :arx)

      ctx =
        Sanctum.Context.build(
          user_id: "u1",
          org_id: "org_1",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert "tenant:org_1:default:execution:events" ==
               PubSubHelper.topic("execution:events", ctx)
    end

    test "raises ArgumentError when org_id is nil in arx mode" do
      Application.put_env(:cyfr, :edition, :arx)

      ctx =
        Sanctum.Context.build(
          user_id: "u1",
          permissions: [:*],
          scope: :project,
          auth_method: :local,
          namespace: "testns",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/requires a Context with org_id in Arx mode/, fn ->
        PubSubHelper.topic("execution:events", ctx)
      end
    end

    test "raises ArgumentError for nil context in arx mode" do
      Application.put_env(:cyfr, :edition, :arx)

      assert_raise ArgumentError, ~r/requires a non-nil context with org_id in Arx mode/, fn ->
        PubSubHelper.topic("execution:events", nil)
      end
    end

    test "raises ArgumentError for Context with empty-string org_id in arx mode" do
      Application.put_env(:cyfr, :edition, :arx)

      ctx =
        Sanctum.Context.build(
          user_id: "u1",
          org_id: "",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSubHelper.topic("execution:events", ctx)
      end
    end
  end

  describe "topic/2 with raw org_id string" do
    test "prefixes in arx mode" do
      Application.put_env(:cyfr, :edition, :arx)
      assert "tenant:org_x:events" == PubSubHelper.topic("events", "org_x")
    end

    test "raises ArgumentError for empty string org_id in arx mode" do
      Application.put_env(:cyfr, :edition, :arx)

      assert_raise ArgumentError, ~r/non-empty org_id/, fn ->
        PubSubHelper.topic("events", "")
      end
    end

    test "passes through in core mode" do
      Application.put_env(:cyfr, :edition, :core)
      assert "events" == PubSubHelper.topic("events", "org_x")
    end
  end
end
