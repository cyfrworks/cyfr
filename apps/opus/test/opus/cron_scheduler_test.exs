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
end
