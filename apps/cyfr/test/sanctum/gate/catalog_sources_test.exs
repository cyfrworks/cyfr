# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.CatalogSourcesTest.Undeclared do
  @moduledoc false
  # An in-chain read that says nothing of what its answers carry, beside an
  # external-only one: the sources audit's refusal, as a provider.
  def service, do: "undeclared"

  def tools do
    [
      Prima.Operation.tool([
        Prima.Operation.new("undeclared", "peek", "Read", [],
          kind: :read,
          planes: [:external, :in_chain]
        ),
        Prima.Operation.new("undeclared", "show", "Read", [], kind: :read, planes: [:external])
      ])
    ]
  end

  def handle(_name, _ctx, _args), do: {:ok, %{}}
end

defmodule Sanctum.Gate.CatalogSourcesTest.Declared do
  @moduledoc false
  # The same actions, the in-chain one declaring that it carries nothing.
  def service, do: "declared"

  def tools do
    [
      Prima.Operation.tool([
        Prima.Operation.new("declared", "peek", "Read", [],
          kind: :read,
          sources: [],
          planes: [:external, :in_chain]
        ),
        Prima.Operation.new("declared", "show", "Read", [], kind: :read, planes: [:external])
      ])
    ]
  end

  def handle(_name, _ctx, _args), do: {:ok, %{}}
end

defmodule Sanctum.Gate.CatalogSourcesTest do
  @moduledoc """
  Every action a chain or a turn can call declares the sources its
  answers carry, and the catalog refuses to boot with one that declares
  none: the athanor's own records carry nothing, and what reaches outside
  the home, or what a publisher or a tool server wrote, is outside.
  """

  # `with_providers/2` swaps the member's table, so the module runs alone.
  use ExUnit.Case, async: false

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  alias Sanctum.Catalog
  alias Sanctum.Gate.CatalogSourcesTest.{Declared, Undeclared}

  # What reaches the registry or the bytes it served, and an execution's
  # own retained payload, whatever an outside sender wrote into it.
  @outside ~w(component.search component.discover component.get_blob component.pull
              component.deprecate component.yank record.payload) ++
             for(
               action <- ~w(probe claim_personal claim_publisher verify_publisher tokens_list
                            tokens_issue tokens_revoke members_list members_add members_update
                            members_remove whoami get_namespace report list_my_reports
                            legal_page legal_version legal_accept appeal),
               do: "registry.#{action}"
             )

  # The shipped soul's own catalog actions that answer the athanor's own
  # records: its reads and its writes carry nothing.
  @own ~w(aqua.get aqua.list aqua.status aqua.skill_get aqua.skill_list aqua.skill_create
          aqua.skill_update build.compile build.status build.toolchains build.validate
          canvas.catalog canvas.versions canvas.write component.categories component.create
          component.fork component.status execution.cancel layout.edit layout.get
          schedule.get schedule.list system.status tincture_visibility.get webhook.get
          webhook.list)

  # Answers that describe installed components or list tools, read by
  # their providers' readers.
  @read_by_answer ~w(component.inspect component.list component.setup_plan tools.list)

  test "every in-chain action of every configured provider declares the sources its answers carry" do
    undeclared =
      for module <- Catalog.configured_providers(),
          %{operations: operations} <- module.tools(),
          %Prima.Operation{sources: nil} = op <- operations,
          :in_chain in op.planes,
          do: "#{op.tool}.#{op.action}"

    assert undeclared == [],
           "#{length(undeclared)} in-chain actions declare no sources: " <>
             Enum.join(undeclared, ", ")

    assert Catalog.audit_sources(Catalog.configured_providers()) == :ok
  end

  test "what reaches outside is outside; the athanor's own records carry nothing" do
    for name <- @outside,
        do: assert(%Prima.Operation{sources: [:outside]} = operation(name), name)

    for name <- @own, do: assert(%Prima.Operation{sources: []} = operation(name), name)

    for name <- @read_by_answer,
        do:
          assert(
            %Prima.Operation{sources: {:answer, {_, :answer_sources}}} = operation(name),
            name
          )
  end

  describe "an answer describing installed components" do
    test "is outside, named by each pulled component, and the athanor's own carry nothing" do
      read = &Compendium.Providers.Component.answer_sources(nil, &1)
      pulled = Prima.Source.outside("catalyst:acme.weather")

      assert read.(%{"component_ref" => "catalyst:local.claude:1.4.1"}) == []
      assert read.(%{"component_ref" => "catalyst:acme.weather:0.2.0"}) == [pulled]
      assert read.(%{component_ref: "catalyst:acme.weather:0.2.0", needs: []}) == [pulled]

      listing = %{
        components: [
          %{component_ref: "catalyst:local.claude:1.4.1", description: "shipped"},
          %{component_ref: "catalyst:acme.weather:0.2.0", description: "theirs"},
          %{component_ref: "catalyst:acme.weather:0.3.0", description: "theirs again"}
        ],
        total: 3
      }

      assert read.(listing) == [pulled]
      assert read.(%{components: [], total: 0}) == []
    end

    test "carries each pulled dependency whose own manifest supplied entries of its tree" do
      read = &Compendium.Providers.Component.answer_sources(nil, &1)
      acme = Prima.Source.outside("reagent:acme.dep")

      # A local root's tree: the pulled dependency's entries sit under it.
      leaf = %{dependency_ref: "reagent:local.leaf:1.0.0", reason: "from acme", children: []}

      tree = [
        %{dependency_ref: "reagent:acme.dep:1.0.0", reason: "ours", children: [leaf]},
        %{dependency_ref: "reagent:local.own:1.0.0", reason: "ours", children: []}
      ]

      assert read.(%{"component_ref" => "reagent:local.root:1.0.0", "dependencies" => tree}) ==
               [acme]

      # Deeper: a local dependency under the pulled one supplies its own
      # entries, which are the athanor's.
      deeper = [
        %{
          dependency_ref: "reagent:acme.dep:1.0.0",
          children: [%{leaf | children: [%{dependency_ref: "reagent:local.x:1.0.0"}]}]
        }
      ]

      assert read.(%{"component_ref" => "reagent:local.root:1.0.0", "dependencies" => deeper}) ==
               [acme]

      # A pulled leaf with nothing under it carries only the root's entry.
      named_only = [%{dependency_ref: "reagent:acme.dep:1.0.0", reason: "ours", children: []}]

      assert read.(%{"component_ref" => "reagent:local.root:1.0.0", "dependencies" => named_only}) ==
               []

      # A setup plan's dependencies are its own manifest's references.
      assert read.(%{
               component_ref: "reagent:local.root:1.0.0",
               dependencies: ["reagent:acme.dep:1.0.0"]
             }) == []

      # A node whose entries cannot be attributed, or a tree that does not
      # read, is unnamed outside.
      unnamed = [%{reason: "who wrote this", children: [leaf]}]

      for dependencies <- [unnamed, [:junk], "junk"] do
        assert read.(%{
                 "component_ref" => "reagent:local.root:1.0.0",
                 "dependencies" => dependencies
               }) ==
                 [Prima.Source.outside(nil)],
               inspect(dependencies)
      end
    end

    # Sol's T6b review probe (F1): the real handler's answer, read by the
    # loop's policy.
    test "inspecting a local root keeps the pulled dependency's manifest material outside",
         %{ctx: ctx} do
      remote_reason = "REMOTE_PROSE_FROM_ACME"

      component!(ctx, "acme", "sol-reader-dep", %{
        "dependencies" => %{
          "static" => [
            %{
              "ref" => "reagent:local.sol-optional-leaf:1.0.0",
              "optional" => true,
              "reason" => remote_reason
            }
          ]
        }
      })

      component!(ctx, "local", "sol-reader-root", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:acme.sol-reader-dep:1.0.0"}]}
      })

      result =
        Compendium.Providers.Component.handle(ctx, %{
          "action" => "inspect",
          "reference" => "reagent:local.sol-reader-root:1.0.0"
        })

      assert {:ok, answer} = result
      assert answer["component_ref"] == "reagent:local.sol-reader-root:1.0.0"
      assert Jason.encode!(answer) =~ remote_reason

      call = %Aqua.Loop.Binding.Call{
        kind: :catalog,
        tool: "component",
        action: "inspect",
        args: %{}
      }

      assert Aqua.Loop.Policy.sources_of(call, result, ctx) ==
               [Prima.Source.outside("reagent:acme.sol-reader-dep")]
    end

    test "that names no component it describes is an unnamed outside source" do
      read = &Compendium.Providers.Component.answer_sources(nil, &1)

      assert read.(%{"description" => "no reference"}) == [Prima.Source.outside(nil)]
      assert read.(%{components: [%{name: "unnamed"}]}) == [Prima.Source.outside(nil)]
      assert read.(%{"component_ref" => "not a reference"}) == [Prima.Source.outside(nil)]
      assert read.("text") == [Prima.Source.outside(nil)]
    end
  end

  test "a tool listing is outside, named by each external server whose tools it lists" do
    read = &Sanctum.Providers.System.answer_sources(nil, &1)

    assert read.(%{tools: [%{"name" => "notes"}, %{"name" => "system"}]}) == []

    assert read.(%{tools: [%{"name" => "notes"}, %{"name" => "weather:forecast"}]}) ==
             [Prima.Source.outside("weather")]

    assert read.(%{tools: [%{"description" => "no name"}]}) == [Prima.Source.outside(nil)]
    assert read.(:unexpected) == [Prima.Source.outside(nil)]
  end

  describe "the sources audit" do
    test "names an in-chain action that declares none, and passes one served only outside a chain" do
      assert Catalog.audit_sources([Declared]) == :ok

      assert Catalog.audit_sources([Undeclared]) ==
               {:error,
                [
                  %{
                    provider: Undeclared,
                    tool: "undeclared",
                    action: "peek",
                    reason: :undeclared_sources
                  }
                ]}
    end

    test "refuses the boot, and the table stays what it was" do
      before = Catalog.operations()

      assert_raise RuntimeError,
                   ~r/sources audit; refusing to boot:\n  - undeclared\.peek: undeclared_sources/,
                   fn -> Catalog.with_providers([Undeclared], fn -> :booted end) end

      assert Catalog.operations() == before

      assert Catalog.with_providers([Declared], fn ->
               Map.has_key?(Catalog.operations(), "declared")
             end)
    end
  end

  # A component row of `publisher`, pulled unless it is `local`.
  defp component!(ctx, publisher, name, extra) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    manifest = Map.merge(%{"name" => name, "version" => "1.0.0", "type" => "reagent"}, extra)

    attrs = %{
      id: "cs_#{publisher}_#{name}",
      name: name,
      version: "1.0.0",
      component_type: "reagent",
      description: "Test component",
      tags: "[]",
      digest: "sha256:test",
      size: 100,
      exports: "[]",
      manifest: Jason.encode!(manifest),
      publisher: publisher,
      publisher_id: ctx.user_id,
      source:
        if(publisher == "local",
          do: Compendium.Source.filesystem(),
          else: Compendium.Source.oci()
        ),
      signature_verified: publisher != "local",
      inserted_at: now,
      updated_at: now
    }

    assert {:ok, _} = Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), attrs)
  end

  defp operation(name) do
    [tool, action] = String.split(name, ".", parts: 2)
    {:ok, {_module, %{operations: operations}}} = Catalog.lookup(tool)
    Enum.find(operations, &(&1.action == action))
  end
end
