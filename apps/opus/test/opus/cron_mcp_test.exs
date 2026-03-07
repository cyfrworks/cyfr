defmodule Opus.CronMCPTest do
  use ExUnit.Case, async: false

  alias Opus.CronMCP
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    ctx = Context.local()
    {:ok, ctx: ctx}
  end

  describe "tools/0" do
    test "returns schedule tool definition" do
      tools = CronMCP.tools()
      assert length(tools) == 1
      assert hd(tools).name == "schedule"
    end
  end

  describe "create action" do
    test "creates a schedule", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "name" => "test-create",
        "cron_expression" => "*/5 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      }

      assert {:ok, result} = CronMCP.handle("schedule", ctx, args)
      assert result.name == "test-create"
      assert result.cron_expression == "*/5 * * * *"
      assert result.status == "active"
      assert result.schedule_id != nil
    end

    test "creates with input and metadata", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "name" => "test-with-input",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0",
        "input" => %{"key" => "value"},
        "metadata" => %{"env" => "test"}
      }

      assert {:ok, result} = CronMCP.handle("schedule", ctx, args)
      assert result.input == %{"key" => "value"}
      assert result.metadata == %{"env" => "test"}
    end

    test "rejects invalid cron expression", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "name" => "bad-cron",
        "cron_expression" => "bad",
        "reference" => "reagent:local.test:1.0.0"
      }

      assert {:error, msg} = CronMCP.handle("schedule", ctx, args)
      assert msg =~ "Invalid cron"
    end

    test "rejects missing required fields", %{ctx: ctx} do
      args = %{"action" => "create", "name" => "no-ref"}
      assert {:error, msg} = CronMCP.handle("schedule", ctx, args)
      assert msg =~ "Missing required"
    end

    test "enforces per-user limit", %{ctx: ctx} do
      for i <- 1..25 do
        args = %{
          "action" => "create",
          "name" => "limit-test-#{i}",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        }

        assert {:ok, _} = CronMCP.handle("schedule", ctx, args)
      end

      args = %{
        "action" => "create",
        "name" => "limit-test-26",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      }

      assert {:error, msg} = CronMCP.handle("schedule", ctx, args)
      assert msg =~ "limit reached"
    end
  end

  describe "list action" do
    test "lists user schedules", %{ctx: ctx} do
      CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "list-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, result} = CronMCP.handle("schedule", ctx, %{"action" => "list"})
      assert result.count >= 1
      assert is_list(result.schedules)
    end
  end

  describe "get action" do
    test "gets schedule by id", %{ctx: ctx} do
      {:ok, created} = CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "get-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, result} = CronMCP.handle("schedule", ctx, %{
        "action" => "get",
        "schedule_id" => created.schedule_id
      })

      assert result.name == "get-test"
    end

    test "gets schedule by name", %{ctx: ctx} do
      CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "get-by-name",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, result} = CronMCP.handle("schedule", ctx, %{
        "action" => "get",
        "schedule_id" => "get-by-name"
      })

      assert result.name == "get-by-name"
    end

    test "returns error for missing schedule", %{ctx: ctx} do
      assert {:error, _} = CronMCP.handle("schedule", ctx, %{
        "action" => "get",
        "schedule_id" => "nonexistent"
      })
    end
  end

  describe "pause/resume actions" do
    test "pauses and resumes schedule", %{ctx: ctx} do
      {:ok, created} = CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "pause-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, paused} = CronMCP.handle("schedule", ctx, %{
        "action" => "pause",
        "schedule_id" => created.schedule_id
      })
      assert paused.status == "paused"

      assert {:ok, resumed} = CronMCP.handle("schedule", ctx, %{
        "action" => "resume",
        "schedule_id" => created.schedule_id
      })
      assert resumed.status == "active"
    end
  end

  describe "delete action" do
    test "soft-deletes schedule", %{ctx: ctx} do
      {:ok, created} = CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "delete-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, result} = CronMCP.handle("schedule", ctx, %{
        "action" => "delete",
        "schedule_id" => created.schedule_id
      })
      assert result.deleted == true

      # Should not be findable anymore
      assert {:error, _} = CronMCP.handle("schedule", ctx, %{
        "action" => "get",
        "schedule_id" => created.schedule_id
      })
    end
  end

  describe "invalid actions" do
    test "rejects unknown action", %{ctx: ctx} do
      assert {:error, _} = CronMCP.handle("schedule", ctx, %{"action" => "nope"})
    end

    test "rejects missing action", %{ctx: ctx} do
      assert {:error, _} = CronMCP.handle("schedule", ctx, %{})
    end

    test "rejects unknown tool" do
      assert {:error, _} = CronMCP.handle("unknown", %Context{}, %{})
    end
  end
end
