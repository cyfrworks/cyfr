# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ResourceAdmissionTest do
  @moduledoc """
  An MCP `resources/read` is admitted by the one declared operation that
  owns the URI's scheme, through the catalog's gate, once:

    * `compendium://` — `component.read_resource`, `:component_read`;
    * `opus://` — `execution.read_resource`, `:storage_read`;
    * `arca://` — `resource.read`, `:storage_read`, reading only the roots
      the admitted context reaches;
    * `sanctum://` — `session.read_resource`, anonymous, answering the
      caller its own self-description from its context alone.

  The Router resolves and renders; it decides nothing. The boot audit
  holds what is advertised to what is declared.
  """

  use ExUnit.Case, async: false

  alias Arca.ControlPlane
  alias Grimoire.Catalog
  alias Prima.{Arg, Operation}
  alias Prima.Test.AuthorityFixtures
  alias Emissary.MCP.{Message, ResourceRegistry, Router}
  alias Sanctum.Context

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  # {tool, action, permission, auth, scheme, a URI it reads}
  @declarations [
    {"component", "read_resource", :component_read, :required, "compendium",
     "compendium://components/r:local.none:1.0.0"},
    {"execution", "read_resource", :storage_read, :required, "opus",
     "opus://executions/exec_none"},
    {"resource", "read", :storage_read, :required, "arca", "arca://files/data/none.txt"},
    {"session", "read_resource", nil, :anonymous, "sanctum", "sanctum://identity"}
  ]

  defp read(ctx, uri) do
    Router.dispatch(ctx, %Message{
      type: :request,
      id: 1,
      method: "resources/read",
      params: %{"uri" => uri}
    })
  end

  defp key(permissions) do
    Context.build(
      user_id: "user_resource_key",
      athanor_id: Sanctum.TestContext.local().athanor_id,
      permissions: permissions,
      auth_method: :api_key,
      authenticated: true
    )
  end

  defp anonymous do
    Context.build(
      user_id: nil,
      athanor_id: nil,
      permissions: [],
      auth_method: nil,
      authenticated: false
    )
  end

  describe "the declarations" do
    test "four read operations, one per scheme, each resolved from its scheme" do
      for {tool, action, permission, auth, scheme, uri} <- @declarations do
        assert {:ok, {_module, meta}} = Catalog.lookup(tool)
        op = Enum.find(meta.operations, &(&1.action == action))

        assert %Operation{kind: :read, planes: [:external], consent: nil} = op
        assert op.recovery == :replay_safe
        assert op.permission == permission
        assert op.auth == auth
        assert op.resource_schemes == [scheme]
        assert [%Arg{name: "uri", type: :string, required: true}] = op.args

        assert ResourceRegistry.resolve(uri) == {:ok, tool, action}
      end

      assert :ok = Catalog.audit_resource_schemes()
    end
  end

  describe "admission" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      ctx = Sanctum.TestContext.local()
      actor = Context.actor(ctx)
      :ok = Arca.put(actor, ["data", "reach.txt"], "data bytes")
      :ok = Arca.put(actor, ["threads", "thread_r", "reach.bin"], "thread bytes")
      :ok = Arca.put(actor, ["aqua", "reach.md"], "aqua bytes")
      {:ok, ctx: ctx}
    end

    test "component_read and storage_read each open their own schemes and not the other's" do
      component_key = key([:component_read])
      storage_key = key([:storage_read])

      # Refused at the gate, before any read, for the permission it lacks.
      for uri <- ["arca://files/data/reach.txt", "opus://executions/exec_none"] do
        assert {:error, :insufficient_permissions, message} = read(component_key, uri)
        assert message =~ "missing required permission 'storage_read'"
      end

      assert {:error, :insufficient_permissions, message} =
               read(storage_key, "compendium://components/r:local.none:1.0.0")

      assert message =~ "missing required permission 'component_read'"

      # Admitted, and the domain answers what is there.
      assert {:error, :resource_not_found, _} =
               read(component_key, "compendium://components/r:local.none:1.0.0")

      assert {:ok, %{"contents" => [%{"blob" => blob}]}} =
               read(storage_key, "arca://files/data/reach.txt")

      assert Base.decode64!(blob) == "data bytes"

      assert {:error, :resource_not_found, message} =
               read(storage_key, "opus://executions/exec_none")

      assert message =~ "not found"

      # The self-description needs neither.
      for ctx <- [component_key, storage_key, key([])] do
        assert {:ok, %{"contents" => [%{"text" => _}]}} = read(ctx, "sanctum://identity")
      end
    end

    test "an anonymous read is refused as the declaration's auth, with today's code" do
      for {tool, _action, _permission, :required, _scheme, uri} <- @declarations do
        assert {:error, {:tool_auth_required, ^tool}} =
                 Catalog.call_external(tool, anonymous(), %{
                   "action" => action_of(tool),
                   "uri" => uri
                 })

        assert {:error, :auth_required, _message} = read(anonymous(), uri)
      end
    end

    test "a narrow key reads threads/ and data/; a root outside them never", %{ctx: ctx} do
      storage_key = key([:storage_read])

      for uri <- ["arca://files/data/reach.txt", "arca://files/threads/thread_r/reach.bin"] do
        assert {:ok, %{"contents" => [_]}} = read(storage_key, uri)
      end

      for {uri, refusal} <- [
            {"arca://files/aqua/reach.md", "Forbidden path: aqua"},
            {"arca://files/notes/x.md", "Forbidden path: notes"},
            {"arca://files/payloads/x", "Forbidden path: payloads"},
            {"arca://files/data/../aqua/reach.md", "Invalid path"},
            {"arca://files/data/../threads/thread_r/reach.bin", "Invalid path"},
            {"arca://files/", "Forbidden path: /"}
          ] do
        assert {:error, :resource_not_found, message} = read(storage_key, uri)
        assert message =~ refusal, "#{uri}: #{message}"
      end

      # The roots are the admitted context's, never an argument: an extra
      # argument is refused by the declaration, whoever sends it.
      assert {:error, {:invalid_argument, _}} =
               Catalog.call_external("resource", storage_key, %{
                 "action" => "read",
                 "uri" => "arca://files/aqua/reach.md",
                 "roots" => ["aqua"]
               })

      # A person, or a key holding :admin, reads every tenant root.
      for reader <- [ctx, key([:storage_read, :admin])] do
        assert {:ok, %{"contents" => [%{"blob" => blob}]}} =
                 read(reader, "arca://files/aqua/reach.md")

        assert Base.decode64!(blob) == "aqua bytes"
      end
    end

    test "a caller with no athanor is refused before any blob is touched" do
      tenantless = %{key([:storage_read, :admin]) | athanor_id: nil}

      # `Arca.get/2` raises on an actor with no athanor; a typed refusal is
      # the proof the reader stopped before it.
      assert {:error, :missing_tenant} =
               Catalog.call_external("resource", tenantless, %{
                 "action" => "read",
                 "uri" => "arca://files/data/reach.txt"
               })
    end

    test "a guest-plane read is refused at the gate, on every scheme", %{ctx: ctx} do
      guest = Context.enter_guest(ctx)

      for {tool, action, _permission, _auth, _scheme, uri} <- @declarations do
        assert {:error, {:guest_plane_call, ^tool}} =
                 Catalog.call_external(tool, guest, %{"action" => action, "uri" => uri})

        assert {:error, :insufficient_permissions, message} = read(guest, uri)
        assert message =~ "guest-plane context cannot make external-plane call"
      end
    end

    test "no resource read is reachable from a running chain, whatever its grant", %{ctx: ctx} do
      authority =
        granting(for {tool, action, _, _, _, _} <- @declarations, do: "#{tool}.#{action}")

      guest = Context.enter_guest(ctx)

      for {tool, action, _permission, _auth, _scheme, uri} <- @declarations do
        refute Catalog.in_chain_reachable?(tool, action)

        assert {:error, message} =
                 Catalog.call_in_chain(
                   tool,
                   guest,
                   %{"action" => action, "uri" => uri},
                   authority,
                   lineage: caller!(ctx)
                 )

        assert message =~ "not reachable from a running chain"
      end
    end

    test "in a chain, a payload read under the actor keeps the own-execution and attempt rules",
         %{ctx: ctx} do
      authority = granting(["record.payload"])
      lineage = caller!(ctx)
      parent = lineage.parent_execution_id

      {:ok, _} =
        Arca.ExecutionPayloads.put(Context.actor(ctx), parent, "result", ~s({"own":1}), "api")

      chain = fn args ->
        Catalog.call_in_chain(
          "record",
          Context.enter_guest(ctx),
          Map.put(args, "action", "payload"),
          authority,
          lineage: lineage
        )
      end

      # Its own payload, for the attempt the host stamped.
      assert {:ok, %{content: content}} = chain.(%{"id" => parent, "kind" => "result"})
      assert Base.decode64!(content) == ~s({"own":1})

      # Another execution's: the injected lineage names the caller, and a
      # guest cannot supply its own.
      assert {:error, {:invalid_argument, message}} =
               chain.(%{"id" => "exec_other", "kind" => "result"})

      assert message =~ "the calling execution's own payload"

      assert {:error, {:invalid_argument, _}} =
               chain.(%{"id" => "exec_other", "parent_execution_id" => "exec_other"})
    end

    test "a stale index is never read: a write is what the next resource read answers", %{
      ctx: ctx
    } do
      unit = "components/reagents/local/fresh/0.1.0"

      put =
        &Catalog.call_external("file", ctx, %{"action" => "write", "path" => &1, "content" => &2})

      manifest = fn description ->
        Jason.encode!(%{"type" => "reagent", "version" => "0.1.0", "description" => description})
      end

      assert {:ok, _} =
               Catalog.call_external("file", ctx, %{
                 "action" => "write",
                 "path" => unit <> "/reagent.wasm",
                 "content" => Base.encode64(@valid_wasm),
                 "encoding" => "base64"
               })

      assert {:ok, _} = put.(unit <> "/cyfr-manifest.json", manifest.("first"))

      {:ok, _} =
        Compendium.Registry.register_from_arca(ctx, String.split(unit, "/"))

      assert description(read(ctx, "compendium://components/r:local.fresh:0.1.0")) == "first"

      # No notification is waited for: the read passes the projection
      # barrier, so it answers the write or refuses as unavailable.
      assert {:ok, _} = put.(unit <> "/cyfr-manifest.json", manifest.("second"))
      assert description(read(ctx, "compendium://components/r:local.fresh:0.1.0")) == "second"
    end

    test "a member that lost its control-plane slot admits no resource read", %{ctx: ctx} do
      ControlPlane.record(:lost)
      on_exit(fn -> ControlPlane.record(:unclaimed) end)

      for {tool, action, _permission, _auth, _scheme, uri} <- @declarations do
        assert {:error, :control_plane_lost} =
                 Catalog.call_external(tool, ctx, %{"action" => action, "uri" => uri})

        assert {:error, :resource_not_found, message} = read(ctx, uri)
        assert message == Prima.Refusal.message(:control_plane_lost)
      end

      ControlPlane.record(:unclaimed)
      assert {:ok, _} = read(ctx, "arca://files/data/reach.txt")
    end
  end

  describe "the self-description" do
    test "an anonymous caller is told its own empty identity, with no stored data read" do
      test = self()
      handler = "resource-admission-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, metadata, _ ->
          if self() == test, do: send(test, {:query, metadata[:source]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # A transport-stamped request, so nothing logs it from this process.
      caller = %{anonymous() | request_id: "req_resource_admission"}

      assert {:ok, %{"contents" => [%{"text" => identity}]}} =
               read(caller, "sanctum://identity")

      assert {:ok, %{"contents" => [%{"text" => permissions}]}} =
               read(caller, "sanctum://permissions")

      assert Jason.decode!(identity) == %{
               "user_id" => nil,
               "athanor_id" => nil,
               "scope" => "athanor"
             }

      assert Jason.decode!(permissions) == %{"permissions" => []}
      refute_received {:query, _}

      assert {:error, :resource_not_found, message} = read(caller, "sanctum://sessions")
      assert message =~ "Unknown resource URI"
    end
  end

  describe "the Router" do
    test "resolves and renders, and decides nothing itself" do
      source =
        Path.expand("../../../lib/emissary/mcp/router.ex", __DIR__)
        |> File.read!()

      [_, body] = String.split(source, "defp read_resource(ctx, uri, _id) do", parts: 2)
      [body | _] = String.split(body, "\n  defp ", parts: 2)

      assert length(String.split(body, "Catalog.call_external(")) == 2,
             "a resource read is one gate call"

      for decision <-
            ~w(require_permission has_permission? authorize_declared_action
               authorize_annotated_action Context.authorize .authenticated tenant_ok) do
        refute body =~ decision, "the Router's resource read makes a decision: #{decision}"
      end

      refute function_exported?(ResourceRegistry, :read, 2)
    end
  end

  describe "the boot audit" do
    defmodule Owned do
      @moduledoc false
      def tools, do: [tool("owned", ["owned"])]
      def resources, do: [%{uri: "owned://thing", name: "Thing"}]
      def resource_templates, do: [%{uriTemplate: "owned://items/{id}", name: "Item"}]

      def tool(name, schemes) do
        Operation.tool([
          Operation.new(name, "read_resource", "Read", [Arg.new("uri", :string, required: true)],
            kind: :read,
            planes: [:external],
            recovery: :replay_safe,
            resource_schemes: schemes
          )
        ])
      end
    end

    defmodule Unowned do
      @moduledoc false
      def tools, do: [Owned.tool("unowned", [])]
      def resources, do: [%{uri: "loose://thing", name: "Loose"}]
    end

    defmodule Unadvertised do
      @moduledoc false
      def tools, do: [Owned.tool("unadvertised", ["quiet"])]
    end

    defmodule Twice do
      @moduledoc false
      def tools, do: [Owned.tool("twice", ["owned"])]
      def resource_templates, do: [%{uriTemplate: "owned://other/{id}", name: "Other"}]
    end

    defmodule SameTool do
      @moduledoc false
      def tools, do: [Owned.tool("owned", [])]
    end

    defmodule Malformed do
      @moduledoc false
      def tools, do: [Owned.tool("malformed", [])]
      def resources, do: [%{uri: "no-scheme", name: "Bad"}]
    end

    test "passes when every advertised scheme has one reader of its own provider" do
      assert :ok = Catalog.audit_resource_schemes([Owned])
    end

    test "an advertised scheme no operation of its provider declares" do
      assert {:error, [%{provider: Unowned, scheme: "loose", reason: :unowned_scheme}]} =
               Catalog.audit_resource_schemes([Unowned])
    end

    test "a declared scheme its provider does not advertise" do
      assert {:error,
              [
                %{
                  provider: Unadvertised,
                  scheme: "quiet",
                  operation: "unadvertised.read_resource",
                  reason: :unadvertised_scheme
                }
              ]} = Catalog.audit_resource_schemes([Unadvertised])
    end

    test "a scheme declared twice, by two providers" do
      assert {:error, findings} = Catalog.audit_resource_schemes([Owned, Twice])

      assert %{
               scheme: "owned",
               operations: ["owned.read_resource", "twice.read_resource"],
               reason: :scheme_declared_twice
             } in findings
    end

    test "a tool name registered by two providers" do
      assert {:error, findings} = Catalog.audit_resource_schemes([Owned, SameTool])

      assert %{tool: "owned", providers: [Owned, SameTool], reason: :tool_registered_twice} in findings
    end

    test "an advertised URI that names no scheme" do
      assert {:error, [%{provider: Malformed, uri: "no-scheme", reason: :malformed_resource_uri}]} =
               Catalog.audit_resource_schemes([Malformed])
    end
  end

  defp action_of("resource"), do: "read"
  defp action_of(_tool), do: "read_resource"

  defp description({:ok, %{"contents" => [%{"text" => text}]}}),
    do: Jason.decode!(text)["description"]

  defp caller!(ctx),
    do: ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

  defp granting(tools) do
    source = AuthorityFixtures.formula_ref()

    {:ok, blob} =
      AuthorityFixtures.graph_map()
      |> put_in(["nodes", source, "edges", "@ingress", "tools"], Enum.sort(tools))
      |> Prima.Authority.Blob.parse()

    {:ok, authority} =
      Prima.Authority.root(AuthorityFixtures.profile(), blob,
        ceiling: AuthorityFixtures.ceiling()
      )

    authority
  end
end
