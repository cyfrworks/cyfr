# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Providers.TinctureTest do
  @moduledoc """
  The `tincture` tool's two declared operations: what they declare, and
  what the gate makes of the declaration. `invoke_public` serves any
  caller and `invoke_protected` an authenticated one; neither is reachable
  from a running chain or a guest-planed context; the arguments name the
  tincture, the dependency and its input and nothing that could select a
  tenant, a profile or a route — the public action names the tincture by
  its public address, which confers no authority; and the gate files one
  request-log row per call, naming the action. `/mcp` lists and serves
  them as it does any declared operation, to an anonymous caller of no
  athanor too.
  """

  use EmissaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Crucible.Providers.Tincture
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @dep "reagent:local.tinc-mcp-dep"
  @dep_ref "reagent:local.tinc-mcp-dep:0.1.0"
  # `Sanctum.TestContext.athanor!/0`'s group slug: the fixture athanor's
  # public address.
  @address "test"

  defmodule AnonymousAuthProvider do
    @moduledoc false
    # Sign-in is configured, and this caller presented no credential.
    def current_user(_conn), do: nil
  end

  defp operation(action) do
    [%{name: "tincture", operations: operations}] = Tincture.tools()
    Enum.find(operations, &(&1.action == action))
  end

  defp args(action, extra \\ %{}) do
    %{
      "action" => action,
      "publisher" => "local",
      "tincture_name" => "no-such-tincture",
      "reference" => "reagent:local.echo:1.0.0",
      "input" => %{}
    }
    |> Map.merge(if action == "invoke_public", do: %{"athanor" => @address}, else: %{})
    |> Map.merge(extra)
  end

  describe "the declarations" do
    test "two actions under one tool, each exactly as fixed" do
      assert [%{name: "tincture", operations: operations}] = Tincture.tools()
      assert Enum.map(operations, & &1.action) == ["invoke_public", "invoke_protected"]

      for {action, auth} <- [{"invoke_public", :anonymous}, {"invoke_protected", :required}] do
        op = operation(action)

        assert %Prima.Operation{
                 tool: "tincture",
                 kind: :execute,
                 planes: [:external],
                 consent: nil,
                 standing: false,
                 recovery: nil,
                 permission: nil,
                 scope: nil,
                 host: nil,
                 resource_schemes: []
               } = op

        assert op.auth == auth
      end

      tincture = [
        {"publisher", :string, true},
        {"tincture_name", :string, true},
        {"reference", :string, true},
        {"input", {:map, Prima.Arg.new(nil, :json)}, true}
      ]

      # The public action names the tincture by its public address; the
      # protected one works in the caller's own athanor and has none.
      assert Enum.map(operation("invoke_public").args, &{&1.name, &1.type, &1.required}) ==
               [{"athanor", :string, true} | tincture]

      assert Enum.map(operation("invoke_protected").args, &{&1.name, &1.type, &1.required}) ==
               tincture
    end

    test "the provider is configured, audited and in the operation table" do
      assert Tincture in Grimoire.configured_providers()
      assert Grimoire.Catalog.audit_action_kinds([Tincture]) == :ok
      assert {:ok, {Tincture, _tool}} = Grimoire.lookup("tincture")
      assert Tincture.service() == "crucible"
    end

    test "no action is reachable from a running chain" do
      for action <- ["invoke_public", "invoke_protected"] do
        refute Grimoire.chain_reachable?("tincture", action)
      end
    end
  end

  describe "discovery" do
    defp listed(ctx) do
      Grimoire.list_tools()
      |> Grimoire.Visibility.filter_for_context(ctx)
      |> Enum.find(&(&1["name"] == "tincture"))
    end

    test "a caller with no credential is shown the public action alone" do
      anonymous = Context.build(authenticated: false)
      assert %{"inputSchema" => schema} = listed(anonymous)
      assert schema["properties"]["action"]["enum"] == ["invoke_public"]
    end

    test "an authenticated caller is shown both" do
      assert %{"inputSchema" => schema} = listed(Sanctum.TestContext.local())

      assert Enum.sort(schema["properties"]["action"]["enum"]) ==
               ["invoke_protected", "invoke_public"]
    end
  end

  describe "the gate" do
    test "an unauthenticated caller reaches invoke_public, and invoke_protected refuses it" do
      public_ctx =
        Context.build(athanor_id: Sanctum.TestContext.athanor_id(), authenticated: false)

      # Admitted: the handler answers, and a tincture that does not exist
      # is not found.
      assert {:error, %Prima.Refusal{class: :not_found, stage: :execution}} =
               Grimoire.call_external("tincture", public_ctx, args("invoke_public"))

      assert {:error, %Prima.Refusal{class: :unauthenticated, stage: :admission}} =
               Grimoire.call_external("tincture", public_ctx, args("invoke_protected"))
    end

    test "a guest-planed context is refused both actions before any handler" do
      guest = %{Sanctum.TestContext.local() | plane: :guest}

      for action <- ["invoke_public", "invoke_protected"] do
        assert {:error, %Prima.Refusal{class: :forbidden, stage: :admission}} =
                 Grimoire.call_external("tincture", guest, args(action))
      end
    end

    test "no argument selects a tenant, a profile or a route" do
      ctx = Sanctum.TestContext.local()

      for {action, extra} <- [
            {"invoke_protected", %{"athanor" => "other"}},
            {"invoke_protected", %{"athanor_id" => "ath_other"}},
            {"invoke_public", %{"athanor_id" => "ath_other"}},
            {"invoke_protected", %{"profile" => "prof_other"}},
            {"invoke_public", %{"profile" => "prof_other"}},
            {"invoke_protected", %{"route" => "public"}}
          ] do
        assert {:error, %Prima.Refusal{class: :invalid_argument, stage: :admission}} =
                 Grimoire.call_external("tincture", ctx, args(action, extra))
      end

      # The public action cannot be called without its address.
      assert {:error, %Prima.Refusal{class: :invalid_argument, stage: :admission}} =
               Grimoire.call_external(
                 "tincture",
                 ctx,
                 Map.delete(args("invoke_public"), "athanor")
               )

      assert {:error,
              %Prima.Refusal{
                class: :invalid_argument,
                message: "Missing required field: reference"
              }} =
               Grimoire.call_external(
                 "tincture",
                 ctx,
                 Map.delete(args("invoke_protected"), "reference")
               )
    end

    test "the gate files one row per call, naming the action" do
      ctx = Sanctum.TestContext.local()

      assert {:error, %Prima.Refusal{class: :not_found}} =
               Grimoire.call_external("tincture", ctx, args("invoke_protected"))

      assert [row] =
               Arca.Repo.all(
                 from(l in Arca.Schemas.McpLog,
                   where: l.tool == "tincture" and l.athanor_id == ^ctx.athanor_id
                 )
               )

      assert row.action == "invoke_protected"
      assert row.method == "tools/call"
      assert row.status == "error"
    end
  end

  describe "over /mcp" do
    defp mcp(conn, id, method, params) do
      conn
      |> put_req_header("content-type", "application/json")
      |> mcp_post(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
      |> json_response(200)
    end

    test "the tool is listed and served, and the call is filed once", %{conn: conn} do
      %{"result" => %{"tools" => tools}} = mcp(conn, 1, "tools/list", %{})
      assert %{"inputSchema" => schema} = Enum.find(tools, &(&1["name"] == "tincture"))

      assert Enum.sort(schema["properties"]["action"]["enum"]) ==
               ["invoke_protected", "invoke_public"]

      # A refusal the handler made is the call's failed result, with its
      # sentence and no term.
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               mcp(build_conn(), 2, "tools/call", %{
                 "name" => "tincture",
                 "arguments" => args("invoke_protected")
               })

      assert text =~ "Not found"

      assert [row] =
               Arca.Repo.all(
                 from(l in Arca.Schemas.McpLog,
                   where:
                     l.tool == "tincture" and l.athanor_id == ^Sanctum.TestContext.athanor_id()
                 )
               )

      assert row.action == "invoke_protected"
    end
  end

  describe "an anonymous caller over /mcp" do
    setup do
      Arca.Cache.init()
      Application.put_env(:sanctum, :auth_provider, AnonymousAuthProvider)

      base = Path.join(System.tmp_dir!(), "tincture_mcp_#{System.unique_integer([:positive])}")
      keys = [cyfr: :opus_workers, arca: :base_path]
      prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
      Application.put_env(:arca, :base_path, base)
      ctx = Sanctum.TestContext.local()
      _athanor = Sanctum.TestContext.athanor!()

      on_exit(fn ->
        Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)
        File.rm_rf(base)

        for {{app, key}, value} <- prev do
          if value,
            do: Application.put_env(app, key, value),
            else: Application.delete_env(app, key)
        end
      end)

      {:ok, _dep} =
        Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
          name: "tinc-mcp-dep",
          version: "0.1.0",
          type: "reagent"
        })

      {:ok, ctx: ctx}
    end

    defp call(arguments) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> mcp_post(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => "tincture", "arguments" => arguments}
      })
      |> json_response(200)
    end

    test "is served under the address's active public profile", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-mcp-public")
      public_profile!(ctx, node)
      start_supervised!({ScriptedWorker, ref: @dep_ref, script: [%{"answer" => 3}]})
      ScriptedWorker.fresh_limits!(ctx, [@dep_ref])

      assert %{"result" => %{"content" => [%{"text" => text}]} = result} =
               call(
                 args("invoke_public", %{
                   "tincture_name" => "tinc-mcp-public",
                   "reference" => @dep_ref
                 })
               )

      refute result["isError"]
      assert %{"status" => "completed", "execution_id" => execution_id} = Jason.decode!(text)
      assert [%{execution_id: ^execution_id, authority: authority}] = ScriptedWorker.calls()
      assert authority.profile_kind == :public
    end

    test "an address with no active public profile is not found, and nothing warns",
         %{ctx: ctx} do
      _node = tincture!(ctx, "tinc-mcp-private")

      log =
        capture_log(fn ->
          assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
                   call(
                     args("invoke_public", %{
                       "tincture_name" => "tinc-mcp-private",
                       "reference" => @dep_ref
                     })
                   )

          assert text =~ "Not found"
        end)

      refute log =~ "TinctureAccess"
      refute log =~ "Crucible.Tincture"
    end
  end

  # A registered tincture that declares the dependency.
  defp tincture!(ctx, name) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"},
      "dependencies" => %{"static" => [%{"ref" => @dep, "reason" => "test"}]}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    "tincture:local.#{name}"
  end

  # An active public profile for the tincture `node`, with a head consent
  # binding its edge to the dependency.
  defp public_profile!(ctx, node) do
    id = "prof_public_#{System.unique_integer([:positive])}"
    {:ok, _ref, _type, component} = Crucible.Admission.inspect_component(ctx, node)
    {:ok, %{graph: activation}} = Compendium.Activation.resolve_verified(ctx, component)

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: id, kind: :public, source_ref: node, label: "public", status: :active},
        %{
          id: "consent_#{id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          # A public profile reaches only the edges it names.
          invoke_mode: :edge_only,
          shape_digest: "sha256:shape-#{id}",
          commit_digest: "sha256:commit-#{id}",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                node => %{
                  "limits" => AuthorityFixtures.limits_map(),
                  "edges" => %{"@ingress" => %{}, @dep => %{}}
                },
                @dep => %{"limits" => AuthorityFixtures.limits_map(), "edges" => %{}}
              }
            }),
          activation: activation,
          vault_refs: []
        }
      )
  end

  test "an action the tool does not declare falls to its catch-all" do
    assert {:error, {:invalid_argument, message}} =
             Tincture.handle("tincture", Sanctum.TestContext.local(), %{"action" => "invoke"})

    assert message =~ "Invalid tincture action"
  end
end
