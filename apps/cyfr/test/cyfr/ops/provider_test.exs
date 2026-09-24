# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ProviderTest do
  # Not async: the projection cases register probe tools in the shared
  # catalog and the boot case swaps the provider roster.
  use ExUnit.Case, async: false

  alias Cyfr.Ops.{Arg, Catalog, Operation, Provider}
  alias Cyfr.Test.AuthorityFixtures

  # A handler that answers what it was given, so a test can see exactly
  # the input the gate handed it.
  defmodule ActorProbe do
    @moduledoc false
    def context_kind, do: :actor
    def handle(_name, input, _args), do: {:ok, %{input: input}}
  end

  defmodule ContextProbe do
    @moduledoc false
    def handle(_name, input, _args), do: {:ok, %{input: input}}
  end

  defmodule BadKind do
    @moduledoc false
    @behaviour Cyfr.Ops.Provider

    @impl true
    def service, do: "bad_kind"

    @impl true
    def context_kind, do: :session

    @impl true
    def tools do
      [
        Operation.tool([
          Operation.new("bad_kind_probe", "peek", "Peek", [], kind: :read, planes: [:external])
        ])
      ]
    end

    @impl true
    def handle(_name, _input, _args), do: {:ok, %{}}
  end

  defmodule CrashingKind do
    @moduledoc false
    def context_kind, do: raise("no")
  end

  defmodule MockToolProvider do
    @behaviour Cyfr.Ops.Provider

    @impl true
    def service, do: "mock"

    @impl true
    def tools do
      [
        Operation.tool(
          [
            Operation.new("mock", "echo", "Echo an input", [Arg.new("input", :string)],
              kind: :read,
              planes: [:external]
            )
          ],
          description: "A mock tool for testing"
        )
      ]
    end

    @impl true
    def handle("mock", _ctx, %{"action" => "echo"} = args),
      do: {:ok, %{echoed: args["input"]}}

    def handle(_tool, _ctx, _args), do: {:error, "Unknown tool"}
  end

  test "the shared behaviour defines provider callbacks" do
    callbacks = Provider.behaviour_info(:callbacks)
    assert {:service, 0} in callbacks
    assert {:tools, 0} in callbacks
    assert {:handle, 3} in callbacks
  end

  test "providers expose canonical operations and derived discovery and policy" do
    [tool] = MockToolProvider.tools()
    assert tool.name == "mock"
    assert [%Operation{action: "echo"}] = tool.operations
    assert tool.input_schema == Operation.schema(tool.operations)
    assert Provider.action_enum(tool) == ["echo"]

    assert tool.annotations.actions["echo"] == %{
             kind: :read,
             planes: [:external],
             auth: :required
           }

    assert {:ok, %{"action" => "echo", "input" => "hello"}} =
             Operation.cast(tool, %{"action" => "echo", "input" => "hello"})
  end

  test "a provider handles its declared operation with an opaque context" do
    assert {:ok, %{echoed: "hello"}} =
             MockToolProvider.handle("mock", make_ref(), %{"action" => "echo", "input" => "hello"})

    assert {:error, _} = MockToolProvider.handle("unknown", make_ref(), %{})
  end

  test "every loadable configured provider implements the moved behaviour" do
    for module <- Cyfr.Ops.Catalog.available_providers() do
      assert function_exported?(module, :service, 0)
      assert function_exported?(module, :tools, 0)
      assert function_exported?(module, :handle, 3)

      for tool <- module.tools() do
        assert is_list(tool.operations) and tool.operations != []
        Enum.each(tool.operations, &Operation.validate!/1)
        assert tool.input_schema == Operation.schema(tool.operations)
      end
    end
  end

  test "optional tool metadata accompanies derived annotations" do
    [definition] = MockToolProvider.tools()

    tool =
      Operation.tool(definition.operations,
        title: "Human Readable Name",
        icons: [%{src: "icon.png", mimeType: "image/png"}],
        output_schema: %{"type" => "object"}
      )

    assert tool.title == "Human Readable Name"
    assert tool.icons == [%{src: "icon.png", mimeType: "image/png"}]
    assert tool.output_schema == %{"type" => "object"}
    assert tool.annotations == definition.annotations
  end

  describe "context_kind" do
    test "is :context when not declared, and closed to :context | :actor" do
      assert Provider.context_kind(ContextProbe) == :context
      assert Provider.context_kind(MockToolProvider) == :context
      assert Provider.context_kind(ActorProbe) == :actor

      assert_raise ArgumentError, ~r/:context or :actor/, fn ->
        Provider.context_kind(BadKind)
      end
    end

    test "the configured :actor providers are the storage doors, and only they" do
      actors =
        for module <- Catalog.configured_providers(),
            Provider.context_kind(module) == :actor,
            do: module

      assert Enum.sort(actors) == [Arca.Providers.Files, Arca.Providers.Records]
      assert :ok = Catalog.audit_context_kinds()
    end

    test "the audit reports a value outside the set, or one that cannot be read" do
      assert {:error, [%{provider: BadKind, reason: :invalid_context_kind}]} =
               Catalog.audit_context_kinds([BadKind, ContextProbe, ActorProbe])

      assert {:error, [%{provider: CrashingKind, reason: :invalid_context_kind}]} =
               Catalog.audit_context_kinds([CrashingKind])
    end

    test "a provider declaring a handler input the gate cannot honour refuses the catalog's boot" do
      previous = Application.fetch_env!(:cyfr, :tool_providers)
      Application.put_env(:cyfr, :tool_providers, previous ++ [BadKind])

      try do
        assert_raise RuntimeError, ~r/handler inputs failed the catalog audit.*BadKind/s, fn ->
          Catalog.init([])
        end
      after
        Application.put_env(:cyfr, :tool_providers, previous)
      end
    end
  end

  defp probe(name) do
    Operation.tool([
      Operation.new(name, "peek", "Answer the handler's input", [],
        kind: :read,
        planes: [:external, :in_chain]
      )
    ])
  end

  defp chain(name, ctx, authority) do
    lineage =
      ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

    Catalog.call_in_chain(
      name,
      Sanctum.Context.enter_guest(ctx),
      %{"action" => "peek"},
      authority,
      lineage: lineage
    )
  end

  # What a handler may learn from an actor: who and where, never how the
  # caller proved it or what it may do.
  @actor_fields MapSet.new(Map.keys(Map.from_struct(%Cyfr.Actor{})))

  defp actor_only!(input, ctx, plane) do
    assert %Cyfr.Actor{} = input
    refute is_struct(input, Sanctum.Context)
    assert MapSet.new(Map.keys(Map.from_struct(input))) == @actor_fields
    assert input == %{Sanctum.Context.actor(ctx) | plane: plane, request_id: input.request_id}
  end

  describe "the projection" do
    setup do
      Cyfr.Test.Sandbox.setup!()

      for {name, module} <- [{"actor_probe", ActorProbe}, {"context_probe", ContextProbe}] do
        Catalog.register_tool(name, module, probe(name))
        on_exit(fn -> Catalog.unregister_tool(name) end)
      end

      source = AuthorityFixtures.formula_ref()

      graph =
        put_in(AuthorityFixtures.graph_map(), ["nodes", source, "edges", "@ingress", "tools"], [
          "actor_probe.peek",
          "context_probe.peek"
        ])

      {:ok, blob} = Cyfr.Authority.Blob.parse(graph)

      {:ok, authority} =
        Cyfr.Authority.root(AuthorityFixtures.profile(), blob,
          ceiling: AuthorityFixtures.ceiling()
        )

      {:ok, ctx: Sanctum.TestContext.local(), authority: authority}
    end

    test "an :actor handler is given the actor alone, on the external plane", %{ctx: ctx} do
      ctx = %{ctx | session_token_hash: "hash-that-must-not-leak"}

      for runner <- [:inline, :supervised] do
        assert {:ok, %{input: input}} =
                 Catalog.call_external("actor_probe", ctx, %{"action" => "peek"}, runner: runner)

        actor_only!(input, ctx, :external)
        refute inspect(input) =~ "hash-that-must-not-leak"
      end

      # A :context provider is still given the context the gate decided with.
      assert {:ok, %{input: %Sanctum.Context{session_token_hash: "hash-that-must-not-leak"}}} =
               Catalog.call_external("context_probe", ctx, %{"action" => "peek"})
    end

    test "an :actor handler is given the actor alone, in a chain", %{
      ctx: ctx,
      authority: authority
    } do
      assert {:ok, %{input: input}} = chain("actor_probe", ctx, authority)
      actor_only!(input, ctx, :guest)

      assert {:ok, %{input: %Sanctum.Context{plane: :guest}}} =
               chain("context_probe", ctx, authority)
    end

    test "the projection follows the gate: a refused call reaches no handler", %{ctx: ctx} do
      anonymous = %{ctx | authenticated: false}

      assert {:error, {:tool_auth_required, "actor_probe"}} =
               Catalog.call_external("actor_probe", anonymous, %{"action" => "peek"})

      assert {:error, {:guest_plane_call, "actor_probe"}} =
               Catalog.call_external(
                 "actor_probe",
                 Sanctum.Context.enter_guest(ctx),
                 %{"action" => "peek"}
               )
    end
  end

  test "thread consent restarts accept committed integer revisions and absent result metadata" do
    tool = Emissary.MCP.ThreadTool.definition()

    for metadata <- [
          %{},
          %{"profile_id" => nil, "revision" => nil},
          %{"profile_id" => "profile", "revision" => 2}
        ] do
      args = Map.merge(%{"action" => "restart_for_consent", "thread" => "thread"}, metadata)
      assert {:ok, ^args} = Operation.cast(tool, args)
    end

    assert {:error, {:invalid_argument, _}} =
             Operation.cast(tool, %{
               "action" => "restart_for_consent",
               "thread" => "thread",
               "revision" => "2"
             })
  end
end
