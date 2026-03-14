defmodule Emissary.MCP.RunningTasksTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.RunningTasks
  alias Sanctum.Context

  setup do
    RunningTasks.init()
    :ok
  end

  describe "register/3 and cancel/2 with ownership" do
    test "owner can cancel their own task" do
      ctx = Context.build(user_id: "user_1", permissions: [:execute], authenticated: true, auth_method: :oidc)
      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_1", task, "user_1")
      assert :ok == RunningTasks.cancel("req_1", ctx)
    end

    test "non-owner cannot cancel another user's task" do
      ctx = Context.build(user_id: "user_2", permissions: [:execute], authenticated: true, auth_method: :oidc)
      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_2", task, "user_1")
      assert {:error, :unauthorized} = RunningTasks.cancel("req_2", ctx)

      # Clean up — cancel with owner context
      owner_ctx = Context.build(user_id: "user_1", permissions: [:execute], authenticated: true, auth_method: :oidc)
      RunningTasks.cancel("req_2", owner_ctx)
    end

    test "admin with wildcard can cancel any task" do
      admin_ctx = Context.local()
      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_3", task, "other_user")
      assert :ok == RunningTasks.cancel("req_3", admin_ctx)
    end

    test "admin with :admin permission can cancel any task" do
      admin_ctx = Context.build(user_id: "admin_user", permissions: [:execute, :admin], authenticated: true, auth_method: :oidc)
      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_4", task, "other_user")
      assert :ok == RunningTasks.cancel("req_4", admin_ctx)
    end

    test "cancel returns :not_found for unknown request_id" do
      ctx = Context.build(user_id: "user_1", permissions: [:execute], authenticated: true, auth_method: :oidc)
      assert {:error, :not_found} = RunningTasks.cancel("nonexistent", ctx)
    end
  end

end
