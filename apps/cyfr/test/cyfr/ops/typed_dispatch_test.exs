# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.TypedDispatchTest do
  use ExUnit.Case, async: false

  alias Cyfr.Ops.{Arg, Catalog, Operation, Visibility}
  alias Cyfr.Test.AuthorityFixtures
  alias Emissary.MCP.{Message, Router}

  defmodule Echo do
    def handle(_name, _ctx, args), do: {:ok, args}
  end

  defp definition do
    Operation.tool([
      Operation.new(
        "typed_probe",
        "echo",
        "Echo declared values",
        [
          Arg.new(
            "values",
            {:array,
             Arg.new(
               nil,
               {:record,
                [
                  Arg.new("count", :integer, required: true, min: 0, max: 2)
                ]}
             )},
            required: true,
            min: 1,
            max: 2
          ),
          Arg.new("label", :string, nullable: true, min: 1, max: 3, pattern: "^[a-z]+$"),
          Arg.new("enabled", :boolean),
          Arg.new("mode", :string, enum: ["auto", "ask"])
        ],
        kind: :read,
        planes: [:external, :in_chain]
      ),
      Operation.new("typed_probe", "empty", "No arguments", [],
        kind: :read,
        planes: [:external, :in_chain]
      ),
      Operation.new(
        "typed_probe",
        "admin_echo",
        "Gated echo",
        [Arg.new("secret", :string, required: true)],
        kind: :read,
        planes: [:external, :in_chain],
        permission: :admin
      )
    ])
  end

  setup do
    Cyfr.Test.Sandbox.setup!()
    Catalog.register_tool("typed_probe", Echo, definition())
    on_exit(fn -> Catalog.unregister_tool("typed_probe") end)

    source = AuthorityFixtures.formula_ref()

    graph =
      put_in(AuthorityFixtures.graph_map(), ["nodes", source, "edges", "@ingress", "tools"], [
        "typed_probe.echo",
        "typed_probe.empty",
        "typed_probe.admin_echo"
      ])

    {:ok, blob} = Cyfr.Authority.Blob.parse(graph)

    {:ok, authority} =
      Cyfr.Authority.root(AuthorityFixtures.profile(), blob, ceiling: AuthorityFixtures.ceiling())

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

  defp chain(ctx, args, authority, opts \\ []) do
    Catalog.call_in_chain("typed_probe", Sanctum.Context.enter_guest(ctx), args, authority, opts)
  end

  test "console, wire and in-chain calls refuse the same invalid values", %{
    ctx: ctx,
    authority: authority
  } do
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
      assert {:error, reason} = PrismWeb.Ops.call_tool(ctx, "typed_probe", args)
      assert {:error, ^reason} = chain(ctx, args, authority)
      assert {:error, :invalid_params, message} = wire(ctx, args)
      assert message == Cyfr.Ops.Error.message(reason)
    end
  end

  test "declared-action authorization refuses before remaining argument validation", %{
    authority: authority
  } do
    ctx =
      Sanctum.Context.build(
        user_id: "exec-only",
        athanor_id: "ath_test",
        scope: :athanor,
        permissions: [:execute],
        authenticated: true
      )

    args = %{"action" => "admin_echo"}

    assert {:error, {:missing_permission, :admin} = reason} =
             PrismWeb.Ops.call_tool(ctx, "typed_probe", args)

    assert {:error, ^reason} = chain(ctx, args, authority)
    assert {:error, :insufficient_permissions, message} = wire(ctx, args)
    assert message == Sanctum.Unauthorized.message(reason, ctx.auth_method)
  end

  test "presence and integer normalization agree across dispatch paths", %{
    ctx: ctx,
    authority: authority
  } do
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
      assert {:ok, ^normalized} = chain(ctx, args, authority)
      assert {:ok, %{"isError" => false, "content" => [%{"text" => json}]}} = wire(ctx, args)
      assert Jason.decode!(json) === normalized
    end
  end

  test "invalid spawn arguments consume no invoke allowance or reservation", %{
    ctx: ctx,
    authority: authority
  } do
    Sanctum.Test.AuthorityFixtures.reserve!(authority, ctx.athanor_id)
    before = Sanctum.Authority.budget(authority)

    assert {:error, {:invalid_argument, _}} =
             chain(ctx, %{"action" => "echo", "values" => "not-an-array"}, authority,
               guest_fn: :spawn
             )

    assert Sanctum.Authority.budget(authority) == before
    assert {:ok, []} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
  end

  test "host lineage is applied after validation and replaces forged guest selectors", %{
    ctx: ctx,
    authority: authority
  } do
    args = %{"action" => "empty", "parent_execution_id" => "forged", "attempt" => "forged"}

    lineage = %{
      parent_execution_id: "host-parent",
      root_execution_id: "host-root",
      attempt: "host-attempt"
    }

    assert {:ok, result} = chain(ctx, args, authority, lineage: lineage)
    assert result["parent_execution_id"] == "host-parent"
    assert result["root_execution_id"] == "host-root"
    assert result["attempt"] == "host-attempt"
    import Ecto.Query

    logged =
      Arca.Repo.one!(
        from log in Arca.McpLog,
          where: log.athanor_id == ^ctx.athanor_id and log.tool == "typed_probe"
      )

    input = Jason.decode!(logged.input)
    assert input["parent_execution_id"] == "host-parent"
    assert input["root_execution_id"] == "host-root"
    assert input["attempt"] == "host-attempt"
    assert {:error, {:invalid_argument, _}} = Catalog.call_external("typed_probe", ctx, args)
  end

  test "discovery filters drop hidden actions' properties and registration derives fresh views" do
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

    [echo, empty | _] = definition().operations
    changed = %{empty | args: [Arg.new("id", :string, required: true)]}
    Catalog.register_tool("typed_probe", Echo, %{definition() | operations: [echo, changed]})

    assert {:error, {:invalid_argument, _}} =
             Catalog.validate_arguments("typed_probe", %{"action" => "empty"})

    {:ok, changed_wire} = Catalog.get_tool("typed_probe")
    id = changed_wire["inputSchema"]["properties"]["id"]
    assert id["type"] == "string"
    assert id["description"] == "Actions: empty."
    # Required by one action only, so the shared schema does not require it.
    refute "id" in changed_wire["inputSchema"]["required"]
  end

  test "every cached provider retains its canonical operations after refresh" do
    send(Catalog, :refresh_cache)
    :sys.get_state(Catalog)

    for provider <- Catalog.available_providers(), tool <- provider.tools() do
      assert {:ok, {^provider, cached}} = Catalog.lookup(tool.name)
      assert cached.operations == tool.operations
      assert cached.input_schema == Operation.schema(cached.operations)
    end
  end
end
