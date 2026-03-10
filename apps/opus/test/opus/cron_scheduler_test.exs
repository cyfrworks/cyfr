defmodule Opus.CronSchedulerTest do
  use ExUnit.Case, async: false

  alias Arca.CronSchedule

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
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
        _ -> nil
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
    test "logs error and records it when resolved_reference is nil" do
      # Allow the CronScheduler GenServer to use the sandbox connection
      Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), Opus.CronScheduler)

      # Create a schedule with nil resolved_reference to test the error path
      {:ok, schedule} =
        CronSchedule.create(%{
          user_id: "test_user",
          name: "nil-resolved-test",
          cron_expression: "0 * * * *",
          reference: "reagent:local.test",
          resolved_reference: nil,
          next_run_at: DateTime.utc_now()
        })

      # Send the :fire message directly to trigger the nil resolved_reference path
      send(Opus.CronScheduler, {:fire, schedule.id})

      # Give time for the GenServer to process
      Process.sleep(200)

      # Verify the error was recorded on the schedule
      updated = CronSchedule.get(schedule.id)
      assert updated.error_count == 1
    end
  end
end
