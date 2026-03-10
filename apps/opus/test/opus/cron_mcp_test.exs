defmodule Opus.CronMCPTest do
  use ExUnit.Case, async: false

  alias Opus.CronMCP
  alias Sanctum.Context

  # Valid minimal WASM with export section
  @valid_wasm (
    <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>  # magic + version
    <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>               # type section
    <<0x03, 0x02, 0x01, 0x00>> <>                           # function section
    <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>        # export section
    <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>                  # code section
  )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_cron_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:arca, :base_path, test_dir)
    Application.put_env(:arca, :components_path, Path.join(test_dir, "components"))

    ctx = Context.local()

    # Register the test component so existence checks pass
    Compendium.Registry.publish_bytes(ctx, @valid_wasm, %{
      name: "test",
      version: "1.0.0",
      type: "reagent",
      description: "Test component for cron tests"
    })

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

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

  describe "create action - resolution failures" do
    test "rejects create with version-less ref to nonexistent component", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "name" => "bad-resolve",
        "cron_expression" => "0 * * * *",
        "reference" => "c:local.nonexistent-component"
      }

      assert {:error, msg} = CronMCP.handle("schedule", ctx, args)
      assert msg =~ "Cannot create schedule"
      assert msg =~ "failed to resolve"
    end

    test "create with already-pinned ref fails when component not in registry", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "name" => "pinned-ref-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.nonexistent:1.0.0"
      }

      assert {:error, msg} = CronMCP.handle("schedule", ctx, args)
      assert msg =~ "not found in registry"
    end
  end

  describe "update action - resolution failures" do
    test "rejects update with version-less ref to nonexistent component", %{ctx: ctx} do
      {:ok, created} = CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "update-resolve-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:error, msg} = CronMCP.handle("schedule", ctx, %{
        "action" => "update",
        "schedule_id" => created.schedule_id,
        "reference" => "c:local.nonexistent-component"
      })

      assert msg =~ "Cannot update schedule reference"
      assert msg =~ "failed to resolve"
    end
  end

  describe "re-resolve action" do
    test "re-resolve returns error for nonexistent schedule", %{ctx: ctx} do
      assert {:error, msg} = CronMCP.handle("schedule", ctx, %{
        "action" => "re-resolve",
        "schedule_id" => "nonexistent"
      })

      assert msg =~ "Schedule not found"
    end

    test "re-resolve returns error when reference cannot be resolved", %{ctx: ctx} do
      # Create a schedule with a pinned ref, then manually update reference to version-less
      {:ok, created} = CronMCP.handle("schedule", ctx, %{
        "action" => "create",
        "name" => "re-resolve-fail",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      # Manually set reference to a version-less ref that can't resolve
      Arca.CronSchedule.update(created.schedule_id, %{reference: "c:local.nonexistent-component"})

      assert {:error, msg} = CronMCP.handle("schedule", ctx, %{
        "action" => "re-resolve",
        "schedule_id" => created.schedule_id
      })

      assert msg =~ "Failed to re-resolve"
    end

    test "re-resolve requires schedule_id", %{ctx: _ctx} do
      assert {:error, msg} = CronMCP.handle("schedule", %Context{}, %{
        "action" => "re-resolve"
      })

      assert msg =~ "Missing required argument: schedule_id"
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
