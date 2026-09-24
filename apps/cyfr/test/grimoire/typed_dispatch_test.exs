# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.TypedDispatchTest do
  use ExUnit.Case, async: false

  alias Grimoire.{Catalog, Probe, Visibility}
  alias Prima.{Operation, Refusal}
  alias Prima.Test.AuthorityFixtures
  alias Emissary.MCP.{Message, Router}

  setup do
    Cyfr.Test.Sandbox.setup!()

    source = AuthorityFixtures.formula_ref()

    graph =
      put_in(AuthorityFixtures.graph_map(), ["nodes", source, "edges", "@ingress", "tools"], [
        "typed_probe.echo",
        "typed_probe.empty",
        "typed_probe.admin_echo"
      ])

    {:ok, blob} = Prima.Authority.Blob.parse(graph)

    {:ok, authority} =
      Prima.Authority.root(AuthorityFixtures.profile(), blob,
        ceiling: AuthorityFixtures.ceiling()
      )

    {:ok, ctx: Sanctum.TestContext.local(), authority: authority}
  end

  defp wire(ctx, args) do
    Router.dispatch(ctx, %Message{
      type: :request,
      id: 1,
      method: "tools/call",
      params: %{"name" => "typed_probe", "arguments" => args}
    })
  end

  # An in-chain call comes from a real execution's attempt, which the host
  # names in its lineage.
  defp chain(ctx, args, authority, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :lineage, fn -> caller!(ctx) end)
    Catalog.call_in_chain("typed_probe", Sanctum.Context.enter_guest(ctx), args, authority, opts)
  end

  defp caller!(ctx),
    do: ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

  test "console, wire and in-chain calls refuse the same invalid values", %{
    ctx: ctx,
    authority: authority
  } do
    Catalog.with_providers([Probe.Typed], fn ->
      valid = %{"action" => "echo", "values" => [%{"count" => 0}]}

      invalid = [
        [],
        false,
        nil,
        "invalid",
        %{},
        %{"action" => nil},
        %{"action" => "absent"},
        Map.delete(valid, "values"),
        Map.put(valid, "unknown", true),
        Map.put(valid, "enabled", "false"),
        Map.put(valid, "values", []),
        Map.put(valid, "values", [%{"count" => 3}]),
        Map.put(valid, "values", [%{"count" => 0, "extra" => 1}]),
        Map.put(valid, "values", [%{"count" => 0.5}]),
        Map.put(valid, "values", [%{}]),
        Map.put(valid, "values", [false]),
        Map.put(valid, "values", List.duplicate(%{"count" => 0}, 3)),
        Map.put(valid, "label", ""),
        Map.put(valid, "label", "abcd"),
        Map.put(valid, "label", "ABC"),
        Map.put(valid, "mode", "never")
      ]

      for args <- invalid do
        # Every one is the gate's own refusal, made before the handler ran.
        assert {:error, %Refusal{stage: :admission} = reason} =
                 PrismWeb.Ops.call_tool(ctx, "typed_probe", args)

        assert {:error, ^reason} = chain(ctx, args, authority)
        assert {:error, :invalid_params, message} = wire(ctx, args)
        assert message == Prima.Refusal.message(reason)
      end
    end)
  end

  test "declared-action authorization refuses before remaining argument validation", %{
    authority: authority
  } do
    Catalog.with_providers([Probe.Typed], fn ->
      ctx =
        Sanctum.Context.build(
          user_id: "exec-only",
          athanor_id: "ath_test",
          scope: :athanor,
          permissions: [:execute],
          authenticated: true
        )

      args = %{"action" => "admin_echo"}

      assert {:error,
              %Refusal{stage: :admission, reason: {:missing_permission, :admin} = reason} =
                refusal} = PrismWeb.Ops.call_tool(ctx, "typed_probe", args)

      assert {:error, ^refusal} = chain(ctx, args, authority)
      assert {:error, :insufficient_permissions, message} = wire(ctx, args)
      assert message == Sanctum.Unauthorized.message(reason, ctx.auth_method)
    end)
  end

  test "presence and integer normalization agree across dispatch paths", %{
    ctx: ctx,
    authority: authority
  } do
    Catalog.with_providers([Probe.Typed], fn ->
      for args <- [
            %{"action" => "empty"},
            %{"action" => "echo", "values" => [%{"count" => 0}]},
            %{
              "action" => "echo",
              "values" => [%{"count" => 1.0}],
              "label" => nil,
              "enabled" => false
            }
          ] do
        assert {:ok, normalized} = Catalog.validate_arguments("typed_probe", args)
        assert {:ok, ^normalized} = PrismWeb.Ops.call_tool(ctx, "typed_probe", args)
        # In a chain the host's lineage rides beside the normalized arguments.
        assert {:ok, chained} = chain(ctx, args, authority)
        assert Map.drop(chained, ["parent_execution_id", "attempt"]) == normalized
        assert {:ok, %{"isError" => false, "content" => [%{"text" => json}]}} = wire(ctx, args)
        assert Jason.decode!(json) === normalized
      end
    end)
  end

  test "invalid spawn arguments consume no invoke allowance or reservation", %{
    ctx: ctx,
    authority: authority
  } do
    Catalog.with_providers([Probe.Typed], fn ->
      Sanctum.Test.AuthorityFixtures.reserve!(authority, ctx.athanor_id)
      before = Sanctum.Authority.budget(authority)

      assert {:error, %Refusal{stage: :admission, reason: {:invalid_argument, _}}} =
               chain(ctx, %{"action" => "echo", "values" => "not-an-array"}, authority,
                 guest_fn: :spawn
               )

      assert Sanctum.Authority.budget(authority) == before

      assert {:ok, []} =
               Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), authority.budget.id)
    end)
  end

  test "host lineage is applied after validation and replaces forged guest selectors", %{
    ctx: ctx,
    authority: authority
  } do
    Catalog.with_providers([Probe.Typed], fn ->
      args = %{"action" => "empty", "parent_execution_id" => "forged", "attempt" => "forged"}

      lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx, %{root_execution_id: "host-root"})

      assert {:ok, result} = chain(ctx, args, authority, lineage: lineage)
      assert result["parent_execution_id"] == lineage.parent_execution_id
      assert result["root_execution_id"] == "host-root"
      assert result["attempt"] == lineage.attempt
      import Ecto.Query

      logged =
        Arca.Repo.one!(
          from log in Arca.Schemas.McpLog,
            where: log.athanor_id == ^ctx.athanor_id and log.tool == "typed_probe"
        )

      input = Jason.decode!(logged.input)
      assert input["parent_execution_id"] == lineage.parent_execution_id
      assert input["root_execution_id"] == "host-root"
      assert input["attempt"] == lineage.attempt

      assert {:error, %Refusal{stage: :admission, reason: {:invalid_argument, _}}} =
               Catalog.call_external("typed_probe", ctx, args)
    end)
  end

  test "discovery filters drop hidden actions' properties and registration derives fresh views" do
    Catalog.with_providers([Probe.Typed], fn ->
      {:ok, wire} = Catalog.get_tool("typed_probe")
      filtered = Catalog.restrict_tool(wire, ["empty"])

      # Rebuilt from the declarations: the arguments of hidden actions leave.
      assert filtered["inputSchema"]["properties"]["action"]["enum"] == ["empty"]
      assert Map.keys(filtered["inputSchema"]["properties"]) == ["action"]
      refute Map.has_key?(filtered["inputSchema"], "oneOf")
      assert Map.keys(filtered["annotations"].actions) == ["empty"]

      # Without the declarations only the enum narrows.
      bare = Visibility.restrict_actions(wire, ["empty"])
      assert bare["inputSchema"]["properties"]["action"]["enum"] == ["empty"]
      assert Map.has_key?(bare["inputSchema"]["properties"], "label")

      # The same tool declared again, with `empty` requiring an `id`: the
      # table built with it derives every view from the new declarations.
      Catalog.with_providers([Probe.TypedChanged], fn ->
        assert {:error, {:invalid_argument, _}} =
                 Catalog.validate_arguments("typed_probe", %{"action" => "empty"})

        {:ok, changed_wire} = Catalog.get_tool("typed_probe")
        id = changed_wire["inputSchema"]["properties"]["id"]
        assert id["type"] == "string"
        assert id["description"] == "Actions: empty."
        # Required by one action only, so the shared schema does not require it.
        refute "id" in changed_wire["inputSchema"]["required"]
      end)

      # And the block's table is back once the inner one ends.
      assert {:ok, _} = Catalog.validate_arguments("typed_probe", %{"action" => "empty"})
    end)
  end

  test "every provider's tools are held with their canonical operations" do
    Catalog.with_providers([Probe.Typed], fn ->
      for provider <- Catalog.available_providers() ++ [Probe.Typed],
          tool <- provider.tools() do
        assert {:ok, {^provider, held}} = Catalog.lookup(tool.name)
        assert held.operations == tool.operations
        assert held.input_schema == Operation.schema(held.operations)
      end
    end)
  end
end
