# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Schedules.ProviderTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Opus.Schedules.Provider
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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_cron_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

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

    Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.test",
      profile_id: "prof-cron"
    )

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
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

      assert {:error, {:invalid_argument, message}} =
               Provider.handle("schedule", ctx, %{
                 "action" => "update",
                 "schedule_id" => created.schedule_id,
                 "reference" => "reagent:local.unblessed:1.0.0"
               })

      assert message ==
               "profile binding refused: the profile belongs to another component"

      # The row was not moved.
      {:ok, row} =
        Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), created.schedule_id)

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

  describe "a profile binding the store cannot read, or reads damaged" do
    # The binding's own class is the class the gate answers and records:
    # an outage is `unavailable` and a damaged head `corrupt`, each in the
    # binding's sentence, never the caller's argument; and the schedule is
    # as it was.
    @outage "profile binding refused: the profile's consent cannot be read right now — try again"
    @damaged "profile binding refused: the profile's consent is damaged and cannot be used — " <>
               "revoke profile prof-cron and grant it again"

    @create %{
      "action" => "create",
      "profile_id" => "prof-cron",
      "name" => "refused-bind",
      "cron_expression" => "*/5 * * * *",
      "reference" => "reagent:local.test:1.0.0"
    }

    @tag :capture_log
    test "a create over a consent outage is unavailable, and no schedule is written",
         %{ctx: ctx} do
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

      refused!(ctx, "create", @create, @outage, "unavailable")
      assert names(ctx) == []
    end

    test "a create over a damaged head is corrupt, and no schedule is written", %{ctx: ctx} do
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, "prof-cron", scope: "sideways")

      refused!(ctx, "create", @create, @damaged, "corrupt")
      assert names(ctx) == []
    end

    @tag :capture_log
    test "a repointing update over a consent outage is unavailable, and the schedule stands",
         %{ctx: ctx} do
      {:ok, created} = Provider.handle("schedule", ctx, Map.put(@create, "name", "repointed"))
      before = stored(ctx, created.schedule_id)
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

      refused!(ctx, "update", repoint(created), @outage, "unavailable")
      Arca.Repo.query!("ALTER TABLE consents_unavailable RENAME TO consents")
      assert stored(ctx, created.schedule_id) == before
    end

    test "a repointing update over a damaged head is corrupt, and the schedule stands",
         %{ctx: ctx} do
      {:ok, created} = Provider.handle("schedule", ctx, Map.put(@create, "name", "repointed"))
      before = stored(ctx, created.schedule_id)
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, "prof-cron", scope: "sideways")

      refused!(ctx, "update", repoint(created), @damaged, "corrupt")
      assert stored(ctx, created.schedule_id) == before
    end

    # An update that re-points the schedule's reference and binding, and
    # changes its timing beside them.
    defp repoint(created) do
      %{
        "action" => "update",
        "schedule_id" => created.schedule_id,
        "reference" => "reagent:local.test:1.0.0",
        "profile_id" => "prof-cron",
        "cron_expression" => "*/7 * * * *"
      }
    end

    # `action` over MCP answers a failed tool result whose one text block is
    # `sentence`, as every refusal the tool returns is answered; the gate
    # classes it `class` and records its one call admitted and failed in
    # that class.
    defp refused!(ctx, action, args, sentence, class) do
      assert decided(ctx) == []
      answer = over_mcp(ctx, args)

      refute Map.has_key?(answer, "error")

      assert {answer["result"]["isError"], answer["result"]["content"]} ==
               {true, [%{"type" => "text", "text" => sentence}]}

      assert decided(ctx) == [{action, "admitted", "failed", class}]
    end

    defp over_mcp(ctx, args) do
      message = %Prima.MCP.Message{
        type: :request,
        id: 1,
        method: "tools/call",
        params: %{"name" => "schedule", "arguments" => args}
      }

      case Emissary.MCP.Router.dispatch(ctx, message) do
        {:ok, result} -> Prima.MCP.Message.encode_result(1, result)
        {:error, code, text} -> Prima.MCP.Message.encode_error(1, code, text)
        {:error, code, text, data} -> Prima.MCP.Message.encode_error(1, code, text, data)
      end
    end

    # The gate's records of the schedule tool in the context's athanor.
    defp decided(ctx) do
      Arca.Repo.all(
        Ecto.Query.from(d in Arca.Schemas.DecisionLog,
          where: d.athanor_id == ^ctx.athanor_id and d.tool == "schedule",
          select: {d.action, d.admission, d.completion, d.completion_class}
        )
      )
    end

    # The whole stored row of a schedule.
    defp stored(ctx, id) do
      {:ok, row} = Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), id)
      row
    end

    defp names(ctx) do
      {:ok, rows} = Arca.CronSchedule.list(Sanctum.Context.actor(ctx))
      for row <- rows, row.name == "refused-bind", do: row.name
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
      Arca.CronSchedule.update(Sanctum.Context.actor(ctx), created.schedule_id, %{
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
      {:ok, row} =
        Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), created.schedule_id)

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

  describe "feeds" do
    test "a feed is invisible to the schedule tool, by id and by name", %{ctx: ctx} do
      {:ok, feed} = feed!(ctx, "btc")

      assert {:ok, %{schedules: schedules, count: 0}} =
               Provider.handle("schedule", ctx, %{"action" => "list"})

      assert schedules == []

      for action <- ~w(get update pause resume delete re_resolve), id <- [feed.id, "btc"] do
        assert {:error, message} =
                 Provider.handle("schedule", ctx, %{"action" => action, "schedule_id" => id}),
               "#{action} #{id} reached a feed"

        assert message =~ "Schedule not found"
      end

      # Nothing the tool was asked touched the feed.
      assert {:ok, %{status: "active", name: "btc", run_count: 0}} =
               Arca.CronSchedule.get_feed(Context.actor(ctx), feed.id)
    end

    test "a schedule may take a feed's name, and the tool finds only the schedule", %{ctx: ctx} do
      {:ok, feed} = feed!(ctx, "btc")
      {:ok, created} = Provider.handle("schedule", ctx, schedule_args("btc"))
      refute created.schedule_id == feed.id

      assert {:ok, %{schedule_id: id}} =
               Provider.handle("schedule", ctx, %{"action" => "get", "schedule_id" => "btc"})

      assert id == created.schedule_id

      assert {:ok, %{deleted: true, schedule_id: ^id}} =
               Provider.handle("schedule", ctx, %{"action" => "delete", "schedule_id" => "btc"})

      assert {:ok, %{status: "active"}} = Arca.CronSchedule.get_feed(Context.actor(ctx), feed.id)
    end

    test "the schedule cap ignores feeds", %{ctx: ctx} do
      for i <- 1..Opus.Feeds.max_per_athanor(), do: {:ok, _} = feed!(ctx, "feed-#{i}")

      for i <- 1..25 do
        assert {:ok, _} = Provider.handle("schedule", ctx, schedule_args("cap-#{i}"))
      end

      assert {:error, message} = Provider.handle("schedule", ctx, schedule_args("cap-26"))
      assert message =~ "limit reached"
      assert {:ok, 25} = Arca.CronSchedule.count_active(Context.actor(ctx), "schedule")
      assert {:ok, 10} = Arca.CronSchedule.count_active(Context.actor(ctx), "feed")
    end
  end

  defp schedule_args(name) do
    %{
      "action" => "create",
      "profile_id" => "prof-cron",
      "name" => name,
      "cron_expression" => "0 * * * *",
      "reference" => "reagent:local.test:1.0.0"
    }
  end

  defp feed!(ctx, name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{},
        "interval_minutes" => 5,
        "result_shape" => %{"type" => "json"},
        "actions" => []
      })

    Arca.CronSchedule.create_feed(Context.actor(ctx), %{
      binding: binding,
      resolved_reference: "catalyst:local.markets:1.0.0",
      profile_id: "prof-cron",
      cap: Opus.Feeds.max_per_athanor()
    })
  end
end
