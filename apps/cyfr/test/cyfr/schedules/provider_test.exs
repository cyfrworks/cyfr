# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Schedules.ProviderTest do
  use ExUnit.Case, async: false

  alias Cyfr.Schedules.Provider
  alias Sanctum.Context

  # Valid minimal WASM with export section
  # magic + version
  # type section
  # function section
  # export section
  # code section
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_cron_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()

    # Register the test component so existence checks pass
    Compendium.Registry.publish_bytes(ctx, @valid_wasm, %{
      name: "test",
      version: "1.0.0",
      type: "reagent",
      description: "Test component for cron tests"
    })

    # A schedule binds a consented profile at create; seed one owner
    # profile for the target these tests point at.
    Sanctum.Test.ConsentFixtures.start_source!()
    Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.test", profile_id: "prof-cron")

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: ctx}
  end

  describe "tools/0" do
    test "returns schedule tool definition" do
      tools = Provider.tools()
      assert length(tools) == 1
      assert hd(tools).name == "schedule"
    end
  end

  describe "create action" do
    test "creates a schedule", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "test-create",
        "cron_expression" => "*/5 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      }

      assert {:ok, result} = Provider.handle("schedule", ctx, args)
      assert result.name == "test-create"
      assert result.cron_expression == "*/5 * * * *"
      assert result.status == "active"
      assert result.schedule_id != nil
    end

    test "creates with input and metadata", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "test-with-input",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0",
        "input" => %{"key" => "value"},
        "metadata" => %{"env" => "test"}
      }

      assert {:ok, result} = Provider.handle("schedule", ctx, args)
      assert result.input == %{"key" => "value"}
      assert result.metadata == %{"env" => "test"}
    end

    test "rejects invalid cron expression", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "bad-cron",
        "cron_expression" => "bad",
        "reference" => "reagent:local.test:1.0.0"
      }

      assert {:error, msg} = Provider.handle("schedule", ctx, args)
      assert msg =~ "Invalid cron"
    end

    test "rejects missing required fields", %{ctx: ctx} do
      args = %{"action" => "create", "name" => "no-ref"}
      assert {:error, msg} = Provider.handle("schedule", ctx, args)
      assert msg =~ "Missing required"
    end

    test "enforces per-user limit", %{ctx: ctx} do
      for i <- 1..25 do
        args = %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "limit-test-#{i}",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        }

        assert {:ok, _} = Provider.handle("schedule", ctx, args)
      end

      args = %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "limit-test-26",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      }

      assert {:error, msg} = Provider.handle("schedule", ctx, args)
      assert msg =~ "limit reached"
    end
  end

  describe "list action" do
    test "lists user schedules", %{ctx: ctx} do
      Provider.handle("schedule", ctx, %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "list-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, result} = Provider.handle("schedule", ctx, %{"action" => "list"})
      assert result.count >= 1
      assert is_list(result.schedules)
    end
  end

  describe "get action" do
    test "gets schedule by id", %{ctx: ctx} do
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "get-test",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:ok, result} =
               Provider.handle("schedule", ctx, %{
                 "action" => "get",
                 "schedule_id" => created.schedule_id
               })

      assert result.name == "get-test"
    end

    test "gets schedule by name", %{ctx: ctx} do
      Provider.handle("schedule", ctx, %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "get-by-name",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.test:1.0.0"
      })

      assert {:ok, result} =
               Provider.handle("schedule", ctx, %{
                 "action" => "get",
                 "schedule_id" => "get-by-name"
               })

      assert result.name == "get-by-name"
    end

    test "returns error for missing schedule", %{ctx: ctx} do
      assert {:error, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "get",
                 "schedule_id" => "nonexistent"
               })
    end
  end

  describe "pause/resume actions" do
    test "pauses and resumes schedule", %{ctx: ctx} do
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "pause-test",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:ok, paused} =
               Provider.handle("schedule", ctx, %{
                 "action" => "pause",
                 "schedule_id" => created.schedule_id
               })

      assert paused.status == "paused"

      assert {:ok, resumed} =
               Provider.handle("schedule", ctx, %{
                 "action" => "resume",
                 "schedule_id" => created.schedule_id
               })

      assert resumed.status == "active"
    end

    test "a paused schedule still occupies its cap slot", %{ctx: ctx} do
      # The cap counts every non-deleted row, so pause → create-another
      # cannot mint a 26th seat — and resume therefore needs no cap check.
      {:ok, first} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "cap-pause-0",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      for i <- 1..24 do
        assert {:ok, _} =
                 Provider.handle("schedule", ctx, %{
                   "action" => "create",
                   "profile_id" => "prof-cron",
                   "name" => "cap-pause-#{i}",
                   "cron_expression" => "0 * * * *",
                   "reference" => "reagent:local.test:1.0.0"
                 })
      end

      assert {:ok, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "pause",
                 "schedule_id" => first.schedule_id
               })

      assert {:error, msg} =
               Provider.handle("schedule", ctx, %{
                 "action" => "create",
                 "profile_id" => "prof-cron",
                 "name" => "cap-pause-25",
                 "cron_expression" => "0 * * * *",
                 "reference" => "reagent:local.test:1.0.0"
               })

      assert msg =~ "limit reached"

      # And the paused seat resumes cleanly at the cap.
      assert {:ok, resumed} =
               Provider.handle("schedule", ctx, %{
                 "action" => "resume",
                 "schedule_id" => first.schedule_id
               })

      assert resumed.status == "active"
    end
  end

  describe "delete action" do
    test "soft-deletes schedule", %{ctx: ctx} do
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "delete-test",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:ok, result} =
               Provider.handle("schedule", ctx, %{
                 "action" => "delete",
                 "schedule_id" => created.schedule_id
               })

      assert result.deleted == true

      # Should not be findable anymore
      assert {:error, _} =
               Provider.handle("schedule", ctx, %{
                 "action" => "get",
                 "schedule_id" => created.schedule_id
               })
    end
  end

  describe "profile binding" do
    test "create without a profile_id is refused", %{ctx: ctx} do
      assert {:error, message} =
               Provider.handle("schedule", ctx, %{
                 "action" => "create",
                 "name" => "unbound",
                 "cron_expression" => "0 * * * *",
                 "reference" => "reagent:local.test:1.0.0"
               })

      assert message =~ "profile_id is required"
    end

    test "update with an explicit nil profile_id (unbind) is refused", %{ctx: ctx} do
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "no-unbind",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:error, message} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => created.schedule_id,
                 "profile_id" => nil
               })

      assert message =~ "profile_id is required"
    end

    test "update that re-points the reference re-runs the binding gate", %{ctx: ctx} do
      # Revalidate profile binding when a schedule target changes, even without a profile_id update.
      Compendium.Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "unblessed",
        version: "1.0.0",
        type: "reagent",
        description: "No profile is bound to this one"
      })

      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "repoint-gate",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:error, message} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => created.schedule_id,
                 "reference" => "reagent:local.unblessed:1.0.0"
               })

      assert message =~ "profile binding refused"

      # The row was not moved.
      {:ok, row} = Arca.CronSchedule.get_by_id_or_name(ctx, created.schedule_id)
      assert row.resolved_reference == "reagent:local.test:1.0.0"
    end

    test "update re-pointing within the profile's authorized target passes", %{ctx: ctx} do
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "repoint-ok",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:ok, updated} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => created.schedule_id,
                 "reference" => "reagent:local.test:1.0.0"
               })

      assert updated.resolved_reference == "reagent:local.test:1.0.0"
    end
  end

  describe "create action - resolution failures" do
    test "rejects create with version-less ref to nonexistent component", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "bad-resolve",
        "cron_expression" => "0 * * * *",
        "reference" => "c:local.nonexistent-component"
      }

      assert {:error, msg} = Provider.handle("schedule", ctx, args)
      assert msg =~ "Cannot create schedule"
      assert msg =~ "failed to resolve"
    end

    test "create with already-pinned ref fails when component not in registry", %{ctx: ctx} do
      args = %{
        "action" => "create",
        "profile_id" => "prof-cron",
        "name" => "pinned-ref-test",
        "cron_expression" => "0 * * * *",
        "reference" => "reagent:local.nonexistent:1.0.0"
      }

      assert {:error, msg} = Provider.handle("schedule", ctx, args)
      assert msg =~ "not found in registry"
    end
  end

  describe "update action - resolution failures" do
    test "rejects update with version-less ref to nonexistent component", %{ctx: ctx} do
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "update-resolve-test",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      assert {:error, msg} =
               Provider.handle("schedule", ctx, %{
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
      assert {:error, msg} =
               Provider.handle("schedule", ctx, %{
                 "action" => "re_resolve",
                 "schedule_id" => "nonexistent"
               })

      assert msg =~ "Schedule not found"
    end

    test "re-resolve returns error when reference cannot be resolved", %{ctx: ctx} do
      # Create a schedule with a pinned ref, then manually update reference to version-less
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "re-resolve-fail",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      # Manually set reference to a version-less ref that can't resolve
      Arca.CronSchedule.update(ctx, created.schedule_id, %{
        reference: "c:local.nonexistent-component"
      })

      assert {:error, msg} =
               Provider.handle("schedule", ctx, %{
                 "action" => "re_resolve",
                 "schedule_id" => created.schedule_id
               })

      assert msg =~ "Failed to re-resolve"
    end

    test "re-resolve requires schedule_id", %{ctx: _ctx} do
      assert {:error, msg} =
               Provider.handle("schedule", %Context{}, %{
                 "action" => "re_resolve"
               })

      assert msg =~ "Missing required argument: schedule_id"
    end

    test "re-resolve re-checks the profile binding against the new version", %{ctx: ctx} do
      # Changing a schedule version must pass the same profile-binding gates as creation and update.
      {:ok, created} =
        Provider.handle("schedule", ctx, %{
          "action" => "create",
          "profile_id" => "prof-cron",
          "name" => "re-resolve-rebinds",
          "cron_expression" => "0 * * * *",
          "reference" => "reagent:local.test:1.0.0"
        })

      # A schedule bound to an authorized target still re-resolves: the two
      # gates now run on this path, and they pass.
      assert {:ok, after_} =
               Provider.handle("schedule", ctx, %{
                 "action" => "re_resolve",
                 "schedule_id" => created.schedule_id
               })

      assert after_.resolved_reference == "reagent:local.test:1.0.0"

      # And the row kept its binding rather than being re-pointed unbound.
      {:ok, row} = Arca.CronSchedule.get_by_id_or_name(ctx, created.schedule_id)
      assert row.profile_id == "prof-cron"
    end
  end

  describe "invalid actions" do
    test "rejects unknown action", %{ctx: ctx} do
      assert {:error, _} = Provider.handle("schedule", ctx, %{"action" => "nope"})
    end

    test "rejects missing action", %{ctx: ctx} do
      assert {:error, _} = Provider.handle("schedule", ctx, %{})
    end

    test "rejects unknown tool" do
      assert {:error, _} = Provider.handle("unknown", %Context{}, %{})
    end
  end
end
