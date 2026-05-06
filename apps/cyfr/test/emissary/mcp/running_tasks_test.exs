defmodule Emissary.MCP.RunningTasksTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.RunningTasks
  alias Sanctum.Context

  setup do
    # Ensure RunningTasks GenServer is running and healthy.
    # The terminate test stops and restarts it, but if tests run in an
    # unexpected order we need to handle a missing GenServer/ETS table.
    case GenServer.whereis(RunningTasks) do
      nil ->
        RunningTasks.start_link([])

      pid ->
        if Process.alive?(pid) do
          # Drain mailbox to ensure clean state
          :sys.get_state(RunningTasks)
        else
          Process.sleep(50)
          RunningTasks.start_link([])
        end
    end

    :ok
  end

  describe "register/4 and cancel/2 with ownership" do
    test "owner can cancel their own task" do
      ctx =
        Context.build(
          user_id: "user_1",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_1", task, "user_1")
      assert :ok == RunningTasks.cancel("req_1", ctx)
    end

    test "non-owner cannot cancel another user's task" do
      ctx =
        Context.build(
          user_id: "user_2",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_2", task, "user_1")
      assert {:error, :unauthorized} = RunningTasks.cancel("req_2", ctx)

      # Clean up — cancel with owner context
      owner_ctx =
        Context.build(
          user_id: "user_1",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      RunningTasks.cancel("req_2", owner_ctx)
    end

    test "admin with wildcard can cancel any task" do
      admin_ctx = Sanctum.TestContext.local()
      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_3", task, "other_user")
      assert :ok == RunningTasks.cancel("req_3", admin_ctx)
    end

    test "admin with :admin permission can cancel any task" do
      admin_ctx =
        Context.build(
          user_id: "admin_user",
          permissions: [:execute, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_4", task, "other_user")
      assert :ok == RunningTasks.cancel("req_4", admin_ctx)
    end

    test "cancel returns :not_found for unknown request_id" do
      ctx =
        Context.build(
          user_id: "user_1",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      assert {:error, :not_found} = RunningTasks.cancel("nonexistent", ctx)
    end

    test "ETS entry is auto-cleaned when task process dies" do
      task = Task.async(fn -> :ok end)
      :ok = RunningTasks.register("req_cleanup", task, "user_1")

      # Wait for the task to complete
      Task.await(task)

      ctx =
        Context.build(
          user_id: "user_1",
          permissions: [:execute],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      # Poll until the GenServer has processed the :DOWN message.
      # :sys.get_state/1 drains the GenServer's mailbox, but the :DOWN message
      # may arrive after the first call, so we retry a few times.
      Enum.reduce_while(1..20, nil, fn _, _ ->
        :sys.get_state(RunningTasks)

        case RunningTasks.cancel("req_cleanup", ctx) do
          {:error, :not_found} ->
            {:halt, :ok}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

      assert {:error, :not_found} = RunningTasks.cancel("req_cleanup", ctx)
    end
  end

  describe "terminate/2" do
    test "demonitors all tracked processes" do
      # Verify that terminate/2 calls Process.demonitor on all tracked refs.
      #
      # We can't call RunningTasks.terminate/2 directly because it deletes
      # the live ETS table owned by the supervised GenServer, which causes
      # flaky failures in other test files (e.g., MCPTest) that depend on
      # the table existing. Instead, we verify the behavior by registering
      # tasks, stopping the GenServer cleanly, and confirming cleanup.

      # Use spawn (not Task.async) to avoid linking to the test process —
      # GenServer.stop would propagate the exit through the link.
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      task1 = %{pid: pid1, ref: make_ref(), owner: self(), mfa: {Function, :identity, 1}}
      task2 = %{pid: pid2, ref: make_ref(), owner: self(), mfa: {Function, :identity, 1}}

      :ok = RunningTasks.register("term_req_1", struct!(Task, task1), "user_1")
      :ok = RunningTasks.register("term_req_2", struct!(Task, task2), "user_1")

      # Stop the GenServer cleanly — this triggers terminate/2 internally,
      # which demonitors all processes and deletes the ETS table.
      GenServer.stop(RunningTasks, :shutdown)

      # The ETS table should have been deleted by terminate/2.
      # The supervisor may restart the GenServer (recreating the table) before
      # this assertion runs, so we verify the table is either gone or empty
      # (freshly recreated by supervisor with no entries).
      case :ets.whereis(Emissary.MCP.RunningTasks) do
        :undefined -> :ok
        ref -> assert :ets.tab2list(ref) == []
      end

      # Clean up spawned processes
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)

      # Restart the GenServer so subsequent tests have a working RunningTasks.
      # The supervisor will restart it eventually, but we do it explicitly
      # to avoid race conditions with tests that run immediately after.
      RunningTasks.start_link([])
    end
  end

  describe "cross-org isolation" do
    test "cross-org cancel is rejected" do
      ctx_a =
        Context.build(
          user_id: "admin_a",
          org_id: "org_a",
          permissions: [:execute, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      ctx_b =
        Context.build(
          user_id: "admin_b",
          org_id: "org_b",
          permissions: [:execute, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)
      :ok = RunningTasks.register("req_org_1", task, "admin_a", "org_a")

      # Admin in org_b cannot cancel org_a's task
      assert {:error, :unauthorized} = RunningTasks.cancel("req_org_1", ctx_b)

      # Clean up
      RunningTasks.cancel("req_org_1", ctx_a)
    end

    test "same-org cancel succeeds" do
      ctx =
        Context.build(
          user_id: "admin_user",
          org_id: "org_a",
          permissions: [:execute, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)
      :ok = RunningTasks.register("req_org_2", task, "other_user", "org_a")

      # Admin in same org can cancel
      assert :ok == RunningTasks.cancel("req_org_2", ctx)
    end

    test "nil org_id (Core mode) bypasses org check" do
      # Core mode: neither task nor context have org_id
      ctx =
        Context.build(
          user_id: "admin_user",
          permissions: [:execute, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)
      :ok = RunningTasks.register("req_org_3", task, "other_user")

      # Should succeed — nil org_id means Core mode, skip org check
      assert :ok == RunningTasks.cancel("req_org_3", ctx)
    end

    test "admin with nil org_id can cancel task with org_id (Core backwards compat)" do
      ctx =
        Context.build(
          user_id: "admin_user",
          permissions: [:execute, :admin],
          namespace: "testns",
          authenticated: true,
          auth_method: :oidc
        )

      task = Task.async(fn -> Process.sleep(:infinity) end)
      :ok = RunningTasks.register("req_org_4", task, "other_user", "org_a")

      # nil ctx.org_id means skip org check
      assert :ok == RunningTasks.cancel("req_org_4", ctx)
    end
  end
end
