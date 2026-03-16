defmodule Opus.CronSchedulerTest do
  use ExUnit.Case, async: false

  alias Arca.CronSchedule

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Allow long-lived processes to use the sandbox checkout.
    # CronScheduler and tasks it spawns via TaskSupervisor do DB operations.
    for name <- [Opus.CronScheduler, Opus.TaskSupervisor] do
      case Process.whereis(name) do
        pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), pid)
        nil -> :ok
      end
    end

    :ok
  end

  defp create_schedule(name, cron \\ "0 * * * *") do
    next_run =
      case Opus.CronParser.parse(cron) do
        {:ok, parsed} ->
          case Opus.CronParser.next_run(parsed, DateTime.utc_now()) do
            {:ok, dt} -> dt
            _ -> nil
          end

        _ ->
          nil
      end

    CronSchedule.create(%{
      user_id: "test_user",
      name: name,
      cron_expression: cron,
      reference: "reagent:local.test:1.0.0",
      resolved_reference: "reagent:local.test:1.0.0",
      next_run_at: next_run
    })
  end

  describe "add/1 and remove/1" do
    test "can add and remove schedules" do
      {:ok, schedule} = create_schedule("add-test")

      # Should not crash
      Opus.CronScheduler.add(schedule.id)
      Opus.CronScheduler.remove(schedule.id)
    end
  end

  describe "pause/1 and resume/1" do
    test "can pause and resume schedules" do
      {:ok, schedule} = create_schedule("pause-test")
      Opus.CronScheduler.add(schedule.id)
      Opus.CronScheduler.pause(schedule.id)
      Opus.CronScheduler.resume(schedule.id)
      Opus.CronScheduler.remove(schedule.id)
    end
  end

  describe "reload/0" do
    test "reloads all schedules" do
      {:ok, _} = create_schedule("reload-test")
      Opus.CronScheduler.reload()
      # Should not crash, schedules are loaded
      Process.sleep(100)
    end
  end

  describe "fire_schedule with nil resolved_reference" do
    test "record_error correctly increments error_count for nil resolved_reference schedule" do
      # The fire_schedule GenServer path can't be tested through message-sending
      # because SQLite sandbox can't share connections with the GenServer process.
      # Instead, we directly test the record_error path that fire_schedule invokes
      # when resolved_reference is nil: build the same context fire_schedule would
      # build, call record_error, and verify the error_count increments.

      {:ok, schedule} =
        CronSchedule.create(%{
          user_id: "test_user",
          name: "nil-resolved-test-#{:rand.uniform(100_000)}",
          cron_expression: "0 * * * *",
          reference: "reagent:local.test",
          resolved_reference: nil,
          project_id: "default",
          next_run_at: DateTime.utc_now()
        })

      # Build the same context that fire_schedule/2 builds at line 185-188
      ctx =
        Sanctum.Context.for_scheduled(schedule.user_id,
          org_id: schedule.org_id,
          project_id: schedule.project_id
        )

      # This is the exact call fire_schedule makes on the nil branch (line 197)
      CronSchedule.record_error(
        ctx,
        schedule.id,
        "No resolved reference — re-create or update the schedule"
      )

      updated = CronSchedule.get_for_daemon(schedule.id)
      assert updated.error_count == 1
    end
  end
end
