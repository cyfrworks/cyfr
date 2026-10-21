# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.DecisionTest do
  @moduledoc """
  The decision record's tool (`Sanctum.Providers.Decision`), handed the
  caller's actor alone: the caller's athanor's decisions, the platform
  admin's global readers, and reads that record no decision of their own.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Providers.Decision, as: MCP

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  describe "tools/0" do
    test "declares the decision tool under sanctum, handed the actor", %{ctx: ctx} do
      assert Enum.map(MCP.tools(), & &1.name) == ["decision"]
      assert MCP.service() == "sanctum"
      assert Prima.Provider.context_kind(MCP) == :actor

      # The gate resolves the tool to this provider. A second declaration of
      # it on the roster refuses the catalog's boot (`:tool_registered_twice`).
      assert {:ok, {MCP, _meta}} = Sanctum.Catalog.lookup("decision")

      assert {:error, {:not_found, "tool", "record"}} = MCP.handle("record", actor(ctx), %{})
    end
  end

  describe "decision tool schema" do
    test "declares the tenant readers and the platform admin's global readers" do
      tool = Enum.find(MCP.tools(), &(&1.name == "decision"))

      assert tool.input_schema["properties"]["action"]["enum"] ==
               ["list", "get", "correlate", "list_global", "get_global"]

      for operation <- tool.operations do
        assert operation.kind == :read
        assert operation.planes == [:external]
        assert operation.permission == :storage_read

        assert operation.scope ==
                 if(operation.action in ["list_global", "get_global"], do: :platform)
      end

      assert action_schema(tool, "list")["properties"]["admission"]["enum"] ==
               ["admitted", "refused"]
    end
  end

  describe "decision tenant readers" do
    setup %{ctx: ctx} do
      other =
        Sanctum.Context.build(
          user_id: "user_other_decision",
          athanor_id: "ath_other_decision",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      request_id = Prima.UUID7.request_id()
      admitted = append!(ctx, request_id: request_id)

      refused =
        append!(ctx, request_id: request_id, admission: :refused, refusal_class: :forbidden)

      foreign = append!(other, request_id: request_id)

      host =
        append!(nil, request_id: request_id, admission: :refused, refusal_class: :unauthenticated)

      {:ok,
       other: other,
       request_id: request_id,
       admitted: admitted,
       refused: refused,
       foreign: foreign,
       host: host}
    end

    test "list answers the caller's athanor's decisions and never the host's", %{
      ctx: ctx,
      request_id: request_id,
      admitted: admitted,
      refused: refused
    } do
      assert {:ok, %{decisions: rows}} =
               MCP.handle("decision", actor(ctx), %{
                 "action" => "list",
                 "request_id" => request_id
               })

      assert ids(rows) == Enum.sort([admitted.call_id, refused.call_id])
      assert Enum.all?(rows, &(&1["athanor_id"] == ctx.athanor_id))
    end

    test "list filters by admission and class, and refuses a name outside the vocabulary",
         %{ctx: ctx, request_id: request_id, refused: refused} do
      assert {:ok, %{decisions: [row]}} =
               MCP.handle("decision", actor(ctx), %{
                 "action" => "list",
                 "request_id" => request_id,
                 "refusal_class" => "forbidden"
               })

      assert row["call_id"] == refused.call_id

      assert {:ok, %{decisions: [^row]}} =
               MCP.handle("decision", actor(ctx), %{
                 "action" => "list",
                 "request_id" => request_id,
                 "admission" => "refused"
               })

      assert {:error, {:invalid_argument, message}} =
               MCP.handle("decision", actor(ctx), %{
                 "action" => "list",
                 "refusal_class" => "not_a_class"
               })

      assert message =~ "refusal_class"

      assert {:error, {:invalid_argument, _}} =
               MCP.handle("decision", actor(ctx), %{"action" => "list", "since" => "yesterday"})
    end

    test "get renders every decision field under its own name", %{ctx: ctx, refused: refused} do
      assert {:ok, %{decision: row}} =
               MCP.handle("decision", actor(ctx), %{
                 "action" => "get",
                 "call_id" => refused.call_id
               })

      fields = Prima.Decision.__struct__() |> Map.from_struct() |> Map.keys()
      assert Enum.sort(Map.keys(row)) == Enum.sort(Enum.map(fields, &Atom.to_string/1))

      assert row["call_id"] == refused.call_id
      assert row["plane"] == "external"
      assert row["admission"] == "refused"
      assert row["refusal_class"] == "forbidden"
      assert row["completion"] == nil
      assert {:ok, _, _} = DateTime.from_iso8601(row["inserted_at"])
    end

    test "get of another tenant's or the host's call id answers not found", %{
      ctx: ctx,
      foreign: foreign,
      host: host
    } do
      for call_id <- [foreign.call_id, host.call_id, "call_missing"] do
        assert {:error, {:not_found, "Decision", ^call_id} = reason} =
                 MCP.handle("decision", actor(ctx), %{"action" => "get", "call_id" => call_id})

        assert err_msg(reason) =~ "not found"
      end
    end

    test "an actor with no athanor is refused", %{ctx: ctx} do
      tenantless = %{actor(ctx) | athanor_id: nil}

      assert {:error, :missing_tenant} =
               MCP.handle("decision", tenantless, %{"action" => "list"})

      assert {:error, :missing_tenant} =
               MCP.handle("decision", tenantless, %{"action" => "get", "call_id" => "call_x"})
    end

    test "decision.correlate joins the request's decisions to its other legs", %{
      ctx: ctx,
      request_id: request_id,
      admitted: admitted,
      refused: refused
    } do
      assert {:ok, result} =
               MCP.handle("decision", actor(ctx), %{
                 "action" => "correlate",
                 "request_id" => request_id
               })

      assert result.request_id == request_id
      assert ids(result.decisions) == Enum.sort([admitted.call_id, refused.call_id])

      for leg <- [:mcp_logs, :executions, :policy_logs],
          do: assert(is_list(Map.fetch!(result, leg)))
    end

    test "a storage outage is a refusal", %{ctx: ctx} do
      Arca.Repo.query!("DROP TABLE decision_logs")

      for args <- [
            %{"action" => "get", "call_id" => "call_x"},
            %{"action" => "list"},
            %{"action" => "correlate", "request_id" => "req_x"}
          ] do
        assert {:error, {:unavailable, "Storage"}} = MCP.handle("decision", actor(ctx), args)
      end
    end
  end

  describe "decision global readers" do
    setup %{ctx: ctx} do
      request_id = Prima.UUID7.request_id()
      tenant = append!(ctx, request_id: request_id)

      host =
        append!(nil, request_id: request_id, admission: :refused, refusal_class: :unauthenticated)

      admin = %{ctx | platform_admin: true}

      {:ok, request_id: request_id, tenant: tenant, host: host, admin: admin}
    end

    test "a platform admin reads the host's own decisions and no athanor's", %{
      admin: admin,
      request_id: request_id,
      tenant: tenant,
      host: host
    } do
      assert {:ok, %{decisions: rows}} =
               Sanctum.Gate.call_external("decision", admin, %{
                 "action" => "list_global",
                 "request_id" => request_id
               })

      assert ids(rows) == [host.call_id]

      assert {:ok, %{decision: %{"call_id" => call_id, "athanor_id" => nil}}} =
               Sanctum.Gate.call_external("decision", admin, %{
                 "action" => "get_global",
                 "call_id" => host.call_id
               })

      assert call_id == host.call_id

      # An athanor's decision answers as one never made, the operator's own
      # athanor's included: they read that one as a member, through `get`.
      assert {:error, {:not_found, "Decision", missing}} =
               MCP.handle("decision", actor(admin), %{
                 "action" => "get_global",
                 "call_id" => tenant.call_id
               })

      assert missing == tenant.call_id

      assert {:ok, %{decision: %{"call_id" => ^missing}}} =
               Sanctum.Gate.call_external("decision", admin, %{
                 "action" => "get",
                 "call_id" => tenant.call_id
               })
    end

    test "the global list takes no athanor to read" do
      tool = Enum.find(MCP.tools(), &(&1.name == "decision"))
      refute Map.has_key?(action_schema(tool, "list_global")["properties"], "athanor_id")
    end

    test "the gate refuses a caller without the operator capability", %{ctx: ctx, host: host} do
      for args <- [
            %{"action" => "list_global"},
            %{"action" => "get_global", "call_id" => host.call_id}
          ] do
        assert {:error, %Prima.Refusal{stage: :admission, reason: :platform_admin_required}} =
                 Sanctum.Gate.call_external("decision", ctx, args)
      end
    end

    test "the log refuses a caller without the operator capability on its own", %{
      ctx: ctx,
      host: host
    } do
      for args <- [
            %{"action" => "list_global"},
            %{"action" => "get_global", "call_id" => host.call_id}
          ] do
        assert {:error, :platform_admin_required = reason} =
                 MCP.handle("decision", actor(ctx), args)

        assert err_msg(reason) =~ "platform admin"
      end
    end
  end

  describe "decision through the gate" do
    test "reading decisions records no decision", %{ctx: ctx} do
      ref = make_ref()
      test = self()

      :telemetry.attach_many(
        {__MODULE__, ref},
        [[:cyfr, :sanctum, :decision, :admitted], [:cyfr, :sanctum, :decision, :refused]],
        fn _event, _measurements, metadata, _ -> send(test, {ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      request_id = Prima.UUID7.request_id()
      ctx = %{ctx | request_id: request_id}
      admin = %{ctx | platform_admin: true}

      for {caller, args} <- [
            {ctx, %{"action" => "list"}},
            {ctx, %{"action" => "get", "call_id" => "call_missing"}},
            {ctx, %{"action" => "correlate", "request_id" => request_id}},
            {admin, %{"action" => "list_global"}},
            {admin, %{"action" => "get_global", "call_id" => "call_missing"}}
          ] do
        Sanctum.Gate.call_external("decision", caller, args)
      end

      refute_received {^ref, _}
      assert {:ok, []} = Arca.DecisionLog.correlate(actor(ctx), request_id)
    end

    test "no decision action is reachable from a running chain", %{ctx: ctx} do
      tool = Enum.find(MCP.tools(), &(&1.name == "decision"))
      actions = tool.input_schema["properties"]["action"]["enum"]
      authority = granting(Enum.map(actions, &"decision.#{&1}"))

      lineage =
        ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

      guest = Sanctum.Context.enter_guest(%{ctx | platform_admin: true})

      for action <- actions do
        refute Sanctum.Catalog.in_chain_reachable?("decision", action)

        args =
          if action in ["get", "get_global"],
            do: %{"action" => action, "call_id" => "call_x"},
            else: %{"action" => action, "request_id" => "req_x"}

        assert {:error, %Prima.Refusal{stage: :admission, message: message}} =
                 Sanctum.Gate.call_in_chain("decision", guest, args, authority, lineage: lineage)

        assert message =~ "not reachable from a running chain"
      end
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
        authenticated: true
      }

      # Minimal args per action so the call reaches the authorize path
      # instead of the missing-required-argument clause. A new action with
      # required args must be added here — the "Unauthorized" assert below
      # fails on the missing-arg error otherwise, forcing the pin.
      extra_args = fn
        {_, action} when action in ["get", "get_global"] -> %{"call_id" => "guard_probe"}
        {_, "correlate"} -> %{"request_id" => "guard_probe"}
        _ -> %{}
      end

      for tool <- MCP.tools(),
          action <- tool.input_schema["properties"]["action"]["enum"] do
        args = Map.put(extra_args.({tool.name, action}), "action", action)

        case Sanctum.Gate.call_external(tool.name, no_perm_ctx, args) do
          {:error, %Prima.Refusal{stage: :admission, reason: reason}} ->
            assert Sanctum.Unauthorized.reason?(reason),
                   "#{tool.name}.#{action} error is not a permission denial: #{inspect(reason)}"

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

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # One decision appended under `ctx`'s actor, or under none for the
  # host's row, with `fields` over an admitted default.
  defp append!(ctx, fields) do
    decision =
      Prima.Decision.new(
        Keyword.merge(
          [
            call_id: Prima.UUID7.generate_id("call"),
            user_id: ctx && ctx.user_id,
            athanor_id: ctx && ctx.athanor_id,
            plane: :external,
            tool: "storage",
            action: "get",
            inserted_at: DateTime.utc_now(),
            admission: :admitted
          ],
          fields
        )
      )

    :ok = Arca.DecisionLog.append(ctx && actor(ctx), decision)
    decision
  end

  defp ids(rows), do: rows |> Enum.map(& &1["call_id"]) |> Enum.sort()

  defp granting(tools) do
    alias Prima.Test.AuthorityFixtures
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

  # The provider answers typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Sanctum.Refusals.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end

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
