defmodule Emissary.MCP.RunningTasksTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.RunningTasks
  alias Sanctum.Context

  setup do
    # RunningTasks is a GenServer started by the supervision tree.
    # Ensure it's running and healthy for each test — the terminate test
    # can crash the GenServer by deleting the ETS table, and pending casts
    # from prior tests may arrive after restart.
    ensure_running = fn ->
      # Ensure ETS table exists (may have been deleted by terminate test)
      if :ets.whereis(Emissary.MCP.RunningTasks) == :undefined do
        :ets.new(Emissary.MCP.RunningTasks, [:named_table, :public, :set])
      end

      case GenServer.whereis(RunningTasks) do
        nil ->
          RunningTasks.start_link([])

        pid ->
          if Process.alive?(pid) do
            # Drain any pending messages to ensure clean state.
            # This may crash if pending casts reference a deleted ETS table,
            # so catch and wait for supervisor restart.
            try do
              :sys.get_state(RunningTasks)
            catch
              :exit, _ ->
                Process.sleep(100)
                # Supervisor will restart, ensure ETS table for new process
                if :ets.whereis(Emissary.MCP.RunningTasks) == :undefined do
                  :ets.new(Emissary.MCP.RunningTasks, [:named_table, :public, :set])
                end

                if GenServer.whereis(RunningTasks) == nil do
                  RunningTasks.start_link([])
                end
            end
          else
            Process.sleep(100)

            if GenServer.whereis(RunningTasks) == nil do
              RunningTasks.start_link([])
            end
          end

          :ok
      end
    end

    ensure_running.()
    :ok
  end

  describe "register/4 and cancel/2 with ownership" do
    test "owner can cancel their own task" do
      ctx =
        Context.build(
          user_id: "user_1",
          permissions: [:execute],
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
          authenticated: true,
          auth_method: :oidc
        )

      RunningTasks.cancel("req_2", owner_ctx)
    end

    test "admin with wildcard can cancel any task" do
      admin_ctx = Context.local()
      task = Task.async(fn -> Process.sleep(:infinity) end)

      :ok = RunningTasks.register("req_3", task, "other_user")
      assert :ok == RunningTasks.cancel("req_3", admin_ctx)
    end

    test "admin with :admin permission can cancel any task" do
      admin_ctx =
        Context.build(
          user_id: "admin_user",
          permissions: [:execute, :admin],
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
      # Create real monitors to verify demonitor works
      {pid1, ref1} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      {pid2, ref2} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      state = %{
        monitors: %{ref1 => "req_1", ref2 => "req_2"},
        pids: %{"req_1" => ref1, "req_2" => ref2}
      }

      # Call terminate directly — skip ETS deletion by ensuring the table
      # still exists for other tests (terminate will try to delete it,
      # the setup block will recreate it if needed)
      assert :ok == RunningTasks.terminate(:shutdown, state)

      # Clean up spawned processes
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)

      # Recreate the ETS table if terminate deleted it
      if :ets.whereis(Emissary.MCP.RunningTasks) == :undefined do
        :ets.new(Emissary.MCP.RunningTasks, [:named_table, :public, :set])
      end
    end
  end

  describe "cross-org isolation" do
    test "cross-org cancel is rejected" do
      ctx_a =
        Context.build(
          user_id: "admin_a",
          org_id: "org_a",
          permissions: [:execute, :admin],
          authenticated: true,
          auth_method: :oidc
        )

      ctx_b =
        Context.build(
          user_id: "admin_b",
          org_id: "org_b",
          permissions: [:execute, :admin],
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
