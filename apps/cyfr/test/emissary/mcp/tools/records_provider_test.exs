# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Providers.RecordsTest do
  @moduledoc """
  The record tools (`Arca.Providers.Records`) and its `retention` tool,
  handed the caller's actor alone; and its files-resource reader, given
  the roots the admitted caller may read.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Arca.Providers.Records, as: MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Use a test-specific base path to avoid polluting real config
    test_path = Path.join(System.tmp_dir!(), "arca_mcp_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(), test_path: test_path}
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns the three record tools and the retention tool" do
      tools = MCP.tools()
      assert Enum.map(tools, & &1.name) == ["record", "mcp_log", "policy_log", "retention"]
      assert MCP.service() == "arca"
      refute Code.ensure_loaded?(Cyfr.Retention)
    end

    test "retention tool has 3 actions" do
      tool = Enum.find(MCP.tools(), &(&1.name == "retention"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["get", "set", "cleanup"]
    end

    test "record tool has 3 read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "record"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["get", "list", "payload"]
    end

    test "each tool has required schema fields" do
      for tool <- MCP.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.title)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
        assert tool.input_schema["type"] == "object"
        assert "action" in tool.input_schema["required"]
      end
    end

    test "the record tools and the retention tool take the actor" do
      assert Prima.Provider.context_kind(MCP) == :actor
    end
  end

  # ============================================================================
  # The files resource
  # ============================================================================

  describe "the arca://files/{path} template" do
    test "is advertised by the system provider that declares its read" do
      refute function_exported?(MCP, :resource_templates, 0)
      templates = Emissary.MCP.Tools.SystemProvider.resource_templates()
      assert [%{uriTemplate: "arca://files/{path}"} = template] = templates

      # Rendered from the layout table, so the advertised vocabulary can
      # never drift from it.
      for root <- Arca.Storage.tenant_roots() ++ Arca.Storage.key_read_roots() do
        assert template.description =~ root <> "/"
      end
    end

    test "the key roots are tenant roots" do
      assert Arca.Storage.key_read_roots() == ["threads", "data"]
      assert Arca.Storage.key_read_roots() -- Arca.Storage.tenant_roots() == []
    end
  end

  describe "read/3" do
    test "reads file resource", %{ctx: ctx} do
      :ok = Arca.put(actor(ctx), ["data", "test.txt"], "hello world")

      {:ok, result} = MCP.read(actor(ctx), "arca://files/data/test.txt", all_roots())
      assert result.mimeType == "application/octet-stream"
      assert Base.decode64!(result.content) == "hello world"
    end

    test "returns error for missing file", %{ctx: ctx} do
      {:error, msg} = MCP.read(actor(ctx), "arca://files/data/missing.txt", all_roots())
      assert err_msg(msg) =~ "not found"
    end

    test "an unknown resource is a typed argument refusal", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               MCP.read(actor(ctx), "arca://unknown/path", all_roots())

      assert msg =~ "Unknown resource"
    end

    # The path is caller input — the boundary answers, it never raises.
    test "a traversal path answers a typed error, never raises", %{ctx: ctx} do
      {:error, msg} = MCP.read(actor(ctx), "arca://files/data/../aqua/agent.json", all_roots())
      assert err_msg(msg) =~ "Invalid path"
    end

    test "an unknown root answers a typed error", %{ctx: ctx} do
      {:error, msg} = MCP.read(actor(ctx), "arca://files/nope/x", all_roots())
      assert err_msg(msg) =~ "Forbidden path"
    end

    test "an actor with no athanor is refused before any blob is read", %{ctx: ctx} do
      :ok = Arca.put(actor(ctx), ["data", "x"], "bytes")

      for tenantless <- [
            Sanctum.Context.actor(Sanctum.Context.internal()),
            %{actor(ctx) | athanor_id: nil},
            %{actor(ctx) | athanor_id: ""}
          ] do
        assert {:error, :missing_tenant} =
                 MCP.read(tenantless, "arca://files/data/x", all_roots())
      end
    end

    test "the roots it is given are the reach, intersected with the tenant roots", %{ctx: ctx} do
      :ok = Arca.put(actor(ctx), ["data", "reach.txt"], "g")
      :ok = Arca.put(actor(ctx), ["threads", "thread_r", "reach.bin"], "t")
      :ok = Arca.put(actor(ctx), ["aqua", "reach.md"], "a")

      key_roots = Arca.Storage.key_read_roots()
      assert {:ok, _} = MCP.read(actor(ctx), "arca://files/data/reach.txt", key_roots)
      assert {:ok, _} = MCP.read(actor(ctx), "arca://files/threads/thread_r/reach.bin", key_roots)

      # A root outside the list, a traversal out of a listed root and the
      # empty path refuse before any read.
      for uri <- [
            "arca://files/aqua/reach.md",
            "arca://files/data/../aqua/reach.md",
            "arca://files/data/../threads/thread_r/reach.bin",
            "arca://files/",
            "arca://files///"
          ] do
        assert {:error, {:invalid_argument, msg}} = MCP.read(actor(ctx), uri, key_roots)
        assert msg =~ "Forbidden path" or msg =~ "Invalid path", "#{uri}: #{msg}"
      end

      assert {:error, {:invalid_argument, "Forbidden path: aqua"}} =
               MCP.read(actor(ctx), "arca://files/aqua/reach.md", key_roots)

      # A root the layout does not know is no reach, whoever names it.
      assert {:error, {:invalid_argument, "Forbidden path: cache"}} =
               MCP.read(actor(ctx), "arca://files/cache/x", ["cache" | all_roots()])

      assert {:ok, _} = MCP.read(actor(ctx), "arca://files/aqua/reach.md", all_roots())

      assert {:error, {:invalid_argument, _}} =
               MCP.read(actor(ctx), "arca://files/aqua/reach.md", [])
    end
  end

  describe "record.payload" do
    # A completed execution's result is a payload a member reads by the
    # execution's id; another estate reads nothing.
    test "record.payload answers a retained result to a member of the athanor", %{ctx: ctx} do
      exec = "exec_payload_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.Execution, [
          %{
            id: exec,
            athanor_id: ctx.athanor_id,
            user_id: ctx.user_id,
            reference: "reagent:local.pay:0.1.0",
            status: "completed",
            started_at: now
          }
        ])

      {:ok, _} =
        Arca.ExecutionPayloads.put(
          Sanctum.Context.actor(ctx),
          exec,
          "result",
          ~s({"answer":42}),
          "api"
        )

      assert {:ok, %{execution_id: ^exec, kind: "result", bytes: 13, content: content}} =
               MCP.handle("record", actor(ctx), %{"action" => "payload", "id" => exec})

      assert Base.decode64!(content) == ~s({"answer":42})

      assert {:error, {:not_found, "Payload", _}} =
               MCP.handle("record", actor(ctx), %{
                 "action" => "payload",
                 "id" => exec,
                 "kind" => "input"
               })

      assert {:error, {:not_found, "Payload", _}} =
               MCP.handle("record", actor(%{ctx | athanor_id: "ath_elsewhere"}), %{
                 "action" => "payload",
                 "id" => exec
               })
    end

    test "in-chain, record.payload answers the calling execution its own payload for its attempt",
         %{ctx: ctx} do
      exec = "exec_payload_#{System.unique_integer([:positive])}"

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.Execution, [
          %{
            id: exec,
            athanor_id: ctx.athanor_id,
            user_id: ctx.user_id,
            reference: "formula:local.pay:0.1.0",
            status: "running",
            started_at: DateTime.utc_now(),
            current_attempt: "att_1"
          }
        ])

      {:ok, _} =
        Arca.ExecutionPayloads.put(
          Sanctum.Context.actor(ctx),
          exec,
          "input",
          ~s({"given":1}),
          "api"
        )

      guest = Context.enter_guest(ctx)

      # The lineage the host stamps names the caller and its attempt.
      stamped = %{
        "action" => "payload",
        "id" => exec,
        "kind" => "input",
        "parent_execution_id" => exec,
        "attempt" => "att_1"
      }

      assert {:ok, %{content: content}} = MCP.handle("record", actor(guest), stamped)
      assert Base.decode64!(content) == ~s({"given":1})

      # Another execution's payload, a stale attempt, or no attempt at all.
      assert {:error, {:invalid_argument, _}} =
               MCP.handle("record", actor(guest), %{
                 stamped
                 | "parent_execution_id" => "exec_other"
               })

      assert {:error, {:invalid_argument, _}} =
               MCP.handle("record", actor(guest), %{stamped | "attempt" => "att_0"})

      assert {:error, {:invalid_argument, _}} =
               MCP.handle("record", actor(guest), Map.delete(stamped, "attempt"))

      # A member names an attempt outright, and reads that attempt's.
      member = %{"action" => "payload", "id" => exec, "kind" => "input", "attempt" => "att_1"}
      assert {:ok, _} = MCP.handle("record", actor(ctx), member)

      assert {:error, {:not_found, "Payload", _}} =
               MCP.handle("record", actor(ctx), %{member | "attempt" => "att_0"})
    end
  end

  # ============================================================================
  # Retention Tool
  # ============================================================================

  describe "retention get action" do
    test "get returns default settings", %{ctx: ctx} do
      {:ok, result} = MCP.handle("retention", actor(ctx), %{"action" => "get"})

      assert result.action == "get"
      assert is_map(result.settings)
      assert result.settings["executions"] == 10_000
      assert result.settings["builds"] == 100
    end
  end

  describe "retention set action" do
    test "set updates settings", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "set",
          "settings" => %{"executions" => 5, "builds" => 3}
        })

      assert result.updated == true
      assert result.settings["executions"] == 5
      assert result.settings["builds"] == 3

      # Verify persisted
      {:ok, get_result} = MCP.handle("retention", actor(ctx), %{"action" => "get"})

      assert get_result.settings["executions"] == 5
    end

    test "set refuses an unknown key and a bad value in today's words", %{ctx: ctx} do
      assert {:error, {:invalid_argument, "Unknown retention setting: made_up"}} =
               MCP.handle("retention", actor(ctx), %{
                 "action" => "set",
                 "settings" => %{"made_up" => 5}
               })

      assert {:error,
              {:invalid_argument,
               "Invalid value for retention setting executions — use a positive integer"}} =
               MCP.handle("retention", actor(ctx), %{
                 "action" => "set",
                 "settings" => %{"executions" => 0}
               })

      assert {:error,
              {:invalid_argument, "Missing required parameter: settings (must be a JSON object)"}} =
               MCP.handle("retention", actor(ctx), %{"action" => "set"})
    end
  end

  describe "retention cleanup action" do
    test "cleanup runs with dry_run", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })

      assert result.action == "cleanup"
      assert result.dry_run == true
      assert is_integer(result.would_delete)
    end

    test "the cleanup vocabulary and settable keys are the retention roster", %{ctx: _ctx} do
      # A kind added to Arca.Retention.kinds/0 must be on this surface the
      # moment it exists — the enum fell two kinds behind once.
      retention =
        MCP.tools()
        |> Enum.find(&(&1.name == "retention"))

      roster = Enum.map(Arca.Retention.kinds(), & &1.key())

      assert action_schema(retention, "cleanup")["properties"]["cleanup_type"]["enum"] == roster

      assert action_schema(retention, "set")["properties"]["settings"]["properties"]
             |> Map.keys()
             |> Enum.sort() == Enum.sort(roster)
    end

    test "every kind is cleanable through the tool", %{ctx: ctx} do
      for kind <- Arca.Retention.kinds() do
        assert {:ok, %{deleted: n}} =
                 MCP.handle("retention", actor(ctx), %{
                   "action" => "cleanup",
                   "cleanup_type" => kind.key()
                 })

        assert is_integer(n)
      end
    end

    test "cleanup runs for executions", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "cleanup",
          "cleanup_type" => "executions"
        })

      assert result.action == "cleanup"
      assert result.cleanup_type == "executions"
      assert is_integer(result.deleted)
    end

    test "a kind whose store refuses renders as retention cleanup unavailable", %{ctx: ctx} do
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      assert {:error, {:unavailable, "Retention cleanup"} = reason} =
               MCP.handle("retention", actor(ctx), %{
                 "action" => "cleanup",
                 "cleanup_type" => "staging_days"
               })

      assert err_msg(reason) =~ "unavailable"
    end

    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("retention", actor(ctx), %{"action" => "invalid"})
      assert err_msg(msg) =~ "Invalid retention action"
    end
  end

  # The tool as the wire reaches it: the gate authorizes with the caller's
  # context and hands the handler the actor it projects.
  describe "retention through the gate" do
    test "an actor with no athanor is refused, whatever its scope" do
      platform =
        Sanctum.internal_context(permissions: [:storage_read, :storage_write, :admin])

      tenantless = %Context{
        user_id: "no_tenant_user",
        athanor_id: nil,
        permissions: MapSet.new([:storage_read, :storage_write, :admin]),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      }

      for ctx <- [platform, tenantless],
          args <- [
            %{"action" => "get"},
            %{"action" => "set", "settings" => %{"executions" => 5}},
            %{"action" => "cleanup", "cleanup_type" => "executions"}
          ] do
        assert {:error, :missing_tenant} = Cyfr.Ops.Catalog.call_external("retention", ctx, args),
               "#{inspect(ctx.scope)} #{args["action"]}"
      end
    end

    test "set answers the merged settings", %{ctx: ctx} do
      assert {:ok, _} =
               Cyfr.Ops.Catalog.call_external("retention", ctx, %{
                 "action" => "set",
                 "settings" => %{"executions" => 5}
               })

      assert {:ok, %{action: "set", updated: true, settings: settings}} =
               Cyfr.Ops.Catalog.call_external("retention", ctx, %{
                 "action" => "set",
                 "settings" => %{"builds" => 3}
               })

      assert settings["executions"] == 5
      assert settings["builds"] == 3
      assert settings["mcp_log_days"] == Arca.Retention.McpLogs.default()
      assert map_size(settings) == length(Arca.Retention.kinds())
    end

    test "corrupt settings render as corrupt, from every action", %{ctx: ctx} do
      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.RetentionSettings, [
          %{
            athanor_id: ctx.athanor_id,
            settings: ~s({"executions": 0}),
            revision: 1,
            inserted_at: now,
            updated_at: now
          }
        ])

      for args <- [
            %{"action" => "get"},
            %{"action" => "set", "settings" => %{"builds" => 3}},
            %{"action" => "cleanup", "cleanup_type" => "executions"}
          ] do
        assert {:error, {:corrupt, "Retention settings"} = reason} =
                 Cyfr.Ops.Catalog.call_external("retention", ctx, args),
               args["action"]

        assert err_msg(reason) =~ "Retention settings"
      end
    end

    test "settings that cannot be read render as unavailable", %{ctx: ctx} do
      # Dropped inside the sandbox transaction, which rolls it back.
      Arca.Repo.query!("DROP TABLE retention_settings")

      assert {:error, {:unavailable, "Retention settings"} = reason} =
               Cyfr.Ops.Catalog.call_external("retention", ctx, %{"action" => "get"})

      assert err_msg(reason) =~ "unavailable"
    end
  end

  # ============================================================================
  # Record Tool (Execution Records)
  # ============================================================================

  describe "record.get action" do
    test "returns execution by id", %{ctx: ctx} do
      exec_id = "exec_get_#{:rand.uniform(100_000)}"

      # Create record via internal API (kernel-only operation)
      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      {:ok, result} =
        MCP.handle("record", actor(ctx), %{
          "action" => "get",
          "id" => exec_id
        })

      assert result.id == exec_id
      assert result.status == "running"
    end

    test "returns error for nonexistent execution", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("record", actor(ctx), %{
          "action" => "get",
          "id" => "nonexistent_id"
        })

      assert err_msg(msg) =~ "not found"
    end

    test "returns error without id", %{ctx: ctx} do
      {:error, msg} = MCP.handle("record", actor(ctx), %{"action" => "get"})
      assert err_msg(msg) =~ "Missing required"
    end
  end

  describe "record.list action" do
    test "returns empty list when no executions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("record", actor(ctx), %{"action" => "list"})
      assert is_list(result.executions)
    end

    test "returns executions after recording", %{ctx: ctx} do
      exec_id = "exec_list_#{:rand.uniform(100_000)}"

      # Create record via internal API (kernel-only operation)
      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      {:ok, result} =
        MCP.handle("record", actor(ctx), %{
          "action" => "list"
        })

      ids = Enum.map(result.executions, & &1.id)
      assert exec_id in ids
    end

    test "invalid action returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("record", actor(ctx), %{"action" => "invalid"})
      assert err_msg(msg) =~ "Invalid record action"
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error handling" do
    test "returns a typed not-found for an unknown tool", %{ctx: ctx} do
      assert {:error, {:not_found, "tool", "unknown_tool"} = msg} =
               MCP.handle("unknown_tool", actor(ctx), %{})

      assert err_msg(msg) == "tool not found: unknown_tool"
    end
  end

  # ============================================================================
  # Authorization Rejection Tests
  # ============================================================================

  # ============================================================================
  # Retention Authorization
  # ============================================================================

  describe "retention authorization with application API key" do
    setup do
      app_ctx = %Context{
        user_id: "app_user",
        namespace: "app_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute, :storage_read]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, app_ctx: app_ctx}
    end

    test "can get retention settings", %{app_ctx: app_ctx} do
      {:ok, result} = Cyfr.Ops.Catalog.call_external("retention", app_ctx, %{"action" => "get"})
      assert is_map(result.settings)
    end

    test "cannot set retention settings", %{app_ctx: app_ctx} do
      # The dispatcher must enforce the declared :storage_write permission.
      assert {:error, {:missing_permission, :storage_write}} =
               Cyfr.Ops.Catalog.call_external("retention", app_ctx, %{
                 "action" => "set",
                 "settings" => %{"executions" => 5}
               })
    end

    test "cannot run cleanup", %{app_ctx: app_ctx} do
      assert {:error, {:missing_permission, :admin}} =
               Cyfr.Ops.Catalog.call_external("retention", app_ctx, %{
                 "action" => "cleanup",
                 "cleanup_type" => "executions"
               })
    end
  end

  describe "retention authorization with OIDC session" do
    setup do
      oidc_ctx = %Context{
        user_id: "oidc_user",
        namespace: "oidc_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute, :read, :write, :storage_read, :storage_write, :admin]),
        scope: :athanor,
        auth_method: :oidc,
        api_key_type: nil,
        authenticated: true
      }

      {:ok, oidc_ctx: oidc_ctx}
    end

    test "can set retention settings", %{oidc_ctx: oidc_ctx} do
      {:ok, result} =
        Cyfr.Ops.Catalog.call_external("retention", oidc_ctx, %{
          "action" => "set",
          "settings" => %{"executions" => 5}
        })

      assert result.updated == true
    end

    test "can run cleanup", %{oidc_ctx: oidc_ctx} do
      {:ok, result} =
        Cyfr.Ops.Catalog.call_external("retention", oidc_ctx, %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => true
        })

      assert result.dry_run == true
    end
  end

  # ============================================================================
  # Record Authorization (non-admin denied)
  # ============================================================================

  describe "record authorization with non-admin context" do
    setup do
      non_admin_ctx = %Context{
        user_id: "regular_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute, :storage_read]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, non_admin_ctx: non_admin_ctx}
    end

    test "cross-tenant record.get returns not-found", %{ctx: _ctx} do
      # Create execution in athanor alpha
      ctx_a =
        Sanctum.Context.build(
          user_id: "user_a",
          athanor_id: "ath_alpha",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      exec_id = "exec_cross_tenant_#{:rand.uniform(100_000)}"

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx_a.user_id,
          athanor_id: ctx_a.athanor_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      # Different tenant tries to get it
      ctx_b =
        Sanctum.Context.build(
          user_id: "user_b",
          athanor_id: "ath_beta",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      {:error, msg} =
        MCP.handle("record", actor(ctx_b), %{
          "action" => "get",
          "id" => exec_id
        })

      assert err_msg(msg) =~ "not found"

      # Original tenant can still get it
      {:ok, result} =
        MCP.handle("record", actor(ctx_a), %{
          "action" => "get",
          "id" => exec_id
        })

      assert result.id == exec_id
    end

    test "any member can see the athanor's records", %{
      ctx: ctx,
      non_admin_ctx: non_admin_ctx
    } do
      # Create a record owned by one user via the internal API
      exec_id = "exec_auth_#{:rand.uniform(100_000)}"

      {:ok, _} =
        Arca.Execution.record_start(%{
          id: exec_id,
          reference: "reagent:local.test:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          started_at: DateTime.utc_now(),
          status: "running",
          input: "{}"
        })

      # A fellow member of the same tenant can read it (members interchangeable).
      assert {:ok, _result} =
               MCP.handle("record", actor(non_admin_ctx), %{
                 "action" => "get",
                 "id" => exec_id
               })
    end
  end

  # ============================================================================
  # Edge Cases: Retention
  # ============================================================================

  describe "retention edge cases" do
    test "cleanup with unknown type returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "cleanup",
          "cleanup_type" => "unknown_type"
        })

      assert err_msg(msg) =~ "Cleanup failed" or err_msg(msg) =~ "Unknown cleanup_type"
    end

    test "defaults cleanup_type to executions", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "cleanup",
          "dry_run" => true
        })

      assert result.cleanup_type == "executions"
    end

    test "cleanup with builds type works", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "cleanup",
          "cleanup_type" => "builds",
          "dry_run" => true
        })

      assert result.cleanup_type == "builds"
    end

    test "cleanup returns integer count when not dry_run", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("retention", actor(ctx), %{
          "action" => "cleanup",
          "cleanup_type" => "executions",
          "dry_run" => false
        })

      assert result.cleanup_type == "executions"
      assert is_integer(result.deleted)
    end
  end

  # ============================================================================
  # Tool Discovery - Updated
  # ============================================================================

  # ============================================================================
  # Tool Schema Hardening
  # ============================================================================

  describe "mcp_log tool schema" do
    test "only exposes read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "mcp_log"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["list", "get", "correlate", "fan_outs", "stats"]

      refute "log_started" in actions
      refute "log_completed" in actions
      refute "log_failed" in actions
    end
  end

  describe "policy_log tool schema" do
    test "only exposes read-only actions" do
      tools = MCP.tools()
      tool = Enum.find(tools, &(&1.name == "policy_log"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      assert actions == ["list", "get", "correlate"]

      refute "log" in actions
    end
  end

  # ============================================================================
  # MCP Log Write Actions Denied (kernel-only)
  # ============================================================================

  describe "retired write/delete verbs are unknown at dispatch" do
    test "kernel-only and append-only verbs no longer exist on the surface", %{ctx: ctx} do
      # Undeclared actions must be refused before handler dispatch.
      retired = [
        {"record", "record_start"},
        {"record", "record_complete"},
        {"mcp_log", "log_started"},
        {"mcp_log", "log_completed"},
        {"mcp_log", "log_failed"},
        {"mcp_log", "delete"},
        {"policy_log", "log"},
        {"policy_log", "delete"}
      ]

      for {tool, verb} <- retired do
        {:error, {:unknown_action, name_action}} =
          Cyfr.Ops.Catalog.call_external(tool, ctx, %{"action" => verb})

        assert name_action == "#{tool}.#{verb}"
      end
    end
  end

  # ============================================================================
  # Edge Cases: Error Paths
  # ============================================================================

  describe "resource read error paths" do
    test "reads a file whole", %{ctx: ctx} do
      :ok = Arca.put(actor(ctx), ["data", "resource_test.txt"], "content")

      {:ok, result} = MCP.read(actor(ctx), "arca://files/data/resource_test.txt", all_roots())
      assert Base.decode64!(result.content) == "content"
    end

    test "handles nested path in resource URI", %{ctx: ctx} do
      :ok = Arca.put(actor(ctx), ["data", "nested", "file.txt"], "nested content")

      {:ok, result} = MCP.read(actor(ctx), "arca://files/data/nested/file.txt", all_roots())
      assert Base.decode64!(result.content) == "nested content"
    end
  end

  describe "correlate authorization" do
    setup do
      no_read_ctx = %Context{
        user_id: "regular_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, no_read_ctx: no_read_ctx}
    end

    test "mcp_log.correlate requires :storage_read like its siblings", %{no_read_ctx: ctx} do
      assert {:error, {:missing_permission, :storage_read}} =
               Cyfr.Ops.Catalog.call_external("mcp_log", ctx, %{
                 "action" => "correlate",
                 "request_id" => "req_x"
               })
    end

    test "policy_log.correlate requires :storage_read like its siblings", %{no_read_ctx: ctx} do
      assert {:error, {:missing_permission, :storage_read}} =
               Cyfr.Ops.Catalog.call_external("policy_log", ctx, %{
                 "action" => "correlate",
                 "request_id" => "req_x"
               })
    end

    test "correlate succeeds for a :storage_read context", %{ctx: ctx} do
      assert {:ok, %{request_id: "req_none"}} =
               MCP.handle("mcp_log", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => "req_none"
               })

      assert {:ok, %{request_id: "req_none"}} =
               MCP.handle("policy_log", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => "req_none"
               })
    end
  end

  describe "mcp_log.stats authorization" do
    setup do
      no_read_ctx = %Context{
        user_id: "regular_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:execute]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, no_read_ctx: no_read_ctx}
    end

    test "stats requires :storage_read like its siblings", %{no_read_ctx: ctx} do
      assert {:error, {:missing_permission, :storage_read}} =
               Cyfr.Ops.Catalog.call_external("mcp_log", ctx, %{"action" => "stats"})
    end

    test "stats succeeds for a :storage_read context", %{ctx: ctx} do
      assert {:ok, result} = MCP.handle("mcp_log", actor(ctx), %{"action" => "stats"})
      assert is_integer(result.total)
      assert is_integer(result.errors)
    end
  end

  # Walks every action each tool declares in its input schema and asserts the
  # handler denies an unprivileged context. Pins authorization on all current
  # actions and fails when a future action ships without an authorize call
  # (an unauthorized probe must never fall through to a data-bearing path).
  describe "declared tool actions all authorize" do
    test "every declared action denies a context without permissions" do
      no_perm_ctx = %Context{
        user_id: "no_perm_user",
        athanor_id: "ath_test",
        permissions: MapSet.new(),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      # Minimal args per action so the call reaches the authorize path
      # instead of the missing-required-argument clause. A new action with
      # required args must be added here — the "Unauthorized" assert below
      # fails on the missing-arg error otherwise, forcing the pin.
      extra_args = fn
        {"retention", "get"} -> %{}
        {_, action} when action in ["get", "payload"] -> %{"id" => "guard_probe"}
        {_, "correlate"} -> %{"request_id" => "guard_probe"}
        {_, "fan_outs"} -> %{"request_ids" => ["guard_probe"]}
        {_, "set"} -> %{"settings" => %{"executions" => 5}}
        _ -> %{}
      end

      for tool <- MCP.tools(),
          action <- tool.input_schema["properties"]["action"]["enum"] do
        args = Map.put(extra_args.({tool.name, action}), "action", action)

        case Cyfr.Ops.Catalog.call_external(tool.name, no_perm_ctx, args) do
          {:error, reason} ->
            assert Sanctum.Unauthorized.reason?(reason),
                   "#{tool.name}.#{action} error is not a permission denial: #{inspect(reason)}"

          other ->
            flunk(
              "#{tool.name}.#{action} succeeded for an unprivileged context: #{inspect(other)}"
            )
        end
      end
    end
  end

  describe "a storage outage is a refusal, never a crash" do
    # `get_tenant/2` is db-rescued, so an outage answers
    # `{:error, :database_error}`. Bound as the row it reaches
    # `execution_to_map/1`, whose `is_struct or is_map` guard raises —
    # and `list` answered the storage refusal while `get` answered "the
    # tool crashed". Dropping the table inside the sandbox transaction is
    # the outage: it rolls back with the test, on both adapters.
    test "record.get", %{ctx: ctx} do
      drop_executions!()

      assert {:error, reason} =
               MCP.handle("record", actor(ctx), %{"action" => "get", "id" => "exec_x"})

      assert err_msg(reason) =~ "unavailable"
    end

    test "mcp_log.get", %{ctx: ctx} do
      Arca.Repo.query!("DROP TABLE mcp_logs")

      assert {:error, reason} =
               MCP.handle("mcp_log", actor(ctx), %{"action" => "get", "id" => "req_x"})

      assert err_msg(reason) =~ "unavailable"
    end
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  defp all_roots, do: Arca.Storage.tenant_roots()

  # The provider answers typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Cyfr.Ops.Error.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end

  # An outage, simulated: the table is gone. Postgres holds the tables that
  # reference `executions` to it and drops them along; SQLite has no such
  # clause and no such need.
  #
  # config:compile-runtime-ok — must match what `Arca.Repo` compiled
  # against, as `Arca.TenantTables` does: the adapter is bound at compile
  # time, so a runtime branch on `__adapter__/0` is one the compiler
  # proves dead.
  @drop_executions (case Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3) do
                      Ecto.Adapters.Postgres -> "DROP TABLE executions CASCADE"
                      _sqlite -> "DROP TABLE executions"
                    end)

  defp drop_executions!, do: Arca.Repo.query!(@drop_executions)

  # One action's own declaration, as `Prima.Operation.cast/2` applies it;
  # the tool's discovery schema merges every action into one flat object.
  defp action_schema(tool, action) do
    case Enum.find(tool.operations, &(&1.action == action)) do
      nil ->
        flunk("missing schema for #{tool.name}.#{action}")

      operation ->
        operation.args
        |> Prima.Arg.schema()
        |> put_in(["properties", "action"], %{"type" => "string", "const" => action})
        |> Map.update!("required", &["action" | &1])
    end
  end
end
