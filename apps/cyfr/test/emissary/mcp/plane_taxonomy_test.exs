# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Emissary.MCP.PlaneTaxonomyTest.Probes do
  @moduledoc false
  # Start from valid declarations, then corrupt one field to exercise the
  # catalog's refusal of malformed provider output independently of constructors.
  defp tool(changes) do
    op = Prima.Operation.new("probe", "act", "Probe", [], kind: :read, planes: [:external])
    %{name: "probe", operations: [struct!(op, changes)]}
  end

  def kind_only, do: [tool(planes: nil)]
  def planes_only, do: [tool(kind: nil)]
  def invalid_plane, do: [tool(planes: [:sideways])]
  def empty_planes, do: [tool(planes: [])]
  def invalid_standing, do: [tool(standing: :thred)]
  def unannotated, do: [%{name: "probe"}]

  # One provider module per probe: the audit takes its roster as an
  # argument, so no test touches global provider config.
  defmodule KindOnly do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.kind_only()
  end

  defmodule PlanesOnly do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.planes_only()
  end

  defmodule InvalidPlane do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.invalid_plane()
  end

  defmodule EmptyPlanes do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.empty_planes()
  end

  defmodule InvalidStanding do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.invalid_standing()
  end

  defmodule Unannotated do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.unannotated()
  end
end

defmodule Emissary.MCP.PlaneTaxonomyTest do
  # Require annotations on registered actions and agent virtual tools.
  use ExUnit.Case, async: true

  alias Emissary.MCP.ExternalProvider
  alias Emissary.MCP.PlaneTaxonomyTest.Probes
  alias Grimoire.Catalog
  alias Aqua.Hands

  # Sibling-app providers are unavailable when this app's suite runs alone.
  # The root suite loads all eight; assert the count so a standalone run
  # cannot quietly pass with three providers unaudited.
  defp loaded_providers do
    :cyfr
    |> Application.get_env(:tool_providers, [])
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  defp annotated_actions do
    Enum.flat_map(loaded_providers(), fn module ->
      Enum.flat_map(module.tools(), fn tool ->
        enum =
          get_in(tool, [Access.key(:input_schema, %{}), "properties", "action", "enum"]) || []

        actions = get_in(tool, [Access.key(:annotations, %{}), :actions]) || %{}

        Enum.map(enum, fn verb -> {tool.name, verb, Map.get(actions, verb)} end)
      end)
    end)
  end

  # ============================================================================
  # Arm 1: registered tools
  # ============================================================================

  describe "registered tools" do
    test "the audit passes" do
      assert Catalog.audit_action_kinds() == :ok
    end

    test "every action declares a kind and at least one valid plane" do
      for {tool, verb, annotation} <- annotated_actions() do
        assert %{kind: kind, planes: planes} = annotation, "#{tool}.#{verb} is unannotated"
        assert is_atom(kind) and not is_nil(kind), "#{tool}.#{verb} has no kind"
        assert planes != [], "#{tool}.#{verb} has no plane"

        assert Enum.all?(planes, &(&1 in Catalog.valid_planes())),
               "#{tool}.#{verb} has an invalid plane: #{inspect(planes)}"
      end
    end

    test "the audit refuses malformed declarations and absent operations" do
      # A missing plane must be as loud as a missing kind — otherwise a
      # half-annotated action passes the gate it exists to fail.
      for {probe, reason} <- [
            {Probes.KindOnly, :invalid_operation},
            {Probes.PlanesOnly, :invalid_operation},
            {Probes.InvalidPlane, :invalid_operation},
            {Probes.EmptyPlanes, :invalid_operation},
            # A misspelt standing rule would otherwise ship as "any scope".
            {Probes.InvalidStanding, :invalid_operation},
            {Probes.Unannotated, :missing_operations}
          ] do
        assert {:error, [%{reason: ^reason}]} = Catalog.audit_action_kinds([probe]),
               "#{inspect(probe)} was not reported as #{reason}"
      end
    end

    test "the walked surface equals the registry's served surface" do
      # Guards the standalone-run hole: a run must audit exactly what the
      # registry serves — a cross-source check in place of a hand-kept
      # count that broke on every added action.
      walked = MapSet.new(annotated_actions(), fn {tool, verb, _ann} -> {tool, verb} end)

      served =
        MapSet.new(
          for tool_def <- Catalog.list_tools(),
              verb <- get_in(tool_def, ["inputSchema", "properties", "action", "enum"]) || [],
              do: {tool_def["name"], verb}
        )

      assert MapSet.equal?(walked, served)
      assert length(loaded_providers()) >= 5
    end
  end

  # ============================================================================
  # The derivation invariant
  # ============================================================================

  describe "derivation" do
    test "the in-chain-only set is pinned, and the wire neither lists nor serves it" do
      in_chain_only =
        MapSet.new(
          for {tool, verb, %{planes: planes}} <- annotated_actions(),
              :external not in planes,
              do: "#{tool}.#{verb}"
        )

      assert in_chain_only == MapSet.new(~w(source.tree source.read source.grep
                                            source.write source.edit source.delete))

      external = MapSet.new(Catalog.external_tool_actions())
      assert MapSet.disjoint?(in_chain_only, external)

      ctx = Sanctum.TestContext.local()

      listed =
        for tool_def <- Grimoire.Visibility.filter_for_context(Catalog.list_tools(), ctx),
            verb <- get_in(tool_def, ["inputSchema", "properties", "action", "enum"]) || [],
            do: "#{tool_def["name"]}.#{verb}"

      assert MapSet.disjoint?(in_chain_only, MapSet.new(listed))

      for pair <- in_chain_only do
        [tool, verb] = String.split(pair, ".")
        {:ok, {_module, meta}} = Catalog.lookup(tool)

        assert {:error, {:unknown_action, ^pair}} =
                 Catalog.authorize_annotated_action(tool, meta, ctx, %{"action" => verb})

        assert :ok =
                 Catalog.authorize_annotated_action(tool, meta, ctx, %{"action" => verb}, true)
      end
    end
  end

  # ============================================================================
  # Public actions
  # ============================================================================

  describe "the anonymous surface" do
    test "every auth: :anonymous action is external-plane, and the set is pinned" do
      anonymous =
        MapSet.new(
          for {tool, verb, %{auth: :anonymous} = annotation} <- annotated_actions() do
            assert :external in annotation.planes,
                   "anonymous action #{tool}.#{verb} is not external-plane"

            {tool, verb}
          end
        )

      # The pin is the point: widening the unauthenticated surface must
      # fail a test loudly, never slip through as a derived fact.
      assert MapSet.equal?(
               anonymous,
               MapSet.new([
                 {"session", "login"},
                 {"session", "logout"},
                 {"session", "whoami"},
                 {"session", "device_init"},
                 {"session", "device_poll"},
                 # The caller's own self-description, from its context alone.
                 {"session", "read_resource"},
                 {"system", "status"}
               ])
             )
    end
  end

  # ============================================================================
  # Arm 2: AQUA virtual tools
  # ============================================================================

  describe "agent virtual tools" do
    test "the second audit arm passes" do
      assert Hands.audit_planes() == :ok
    end

    test "every virtual action is in-chain only" do
      for {tool, %{actions: actions}} <- Hands.catalog(),
          {action, %{planes: planes}} <- actions do
        assert planes == [:in_chain], "#{tool}.#{action} claims #{inspect(planes)}"
      end
    end

    test "virtual tools are not registered tools" do
      registered = annotated_actions() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      for tool <- Map.keys(Hands.catalog()) do
        refute MapSet.member?(registered, tool),
               "#{tool} is both a virtual tool and a registered tool — one taxonomy would hide the other"
      end
    end
  end

  # ============================================================================
  # The external bucket
  # ============================================================================

  describe "upstream external tools" do
    test "the bucket default is in-chain" do
      assert ExternalProvider.default_planes() == [:in_chain]
    end

    test "external tool names remain unreachable over HTTP" do
      # The wiring backstop still holds alongside the per-call gate: the
      # router rejects any name the registered-tool cache does not hold,
      # and proxied `server:tool` names are never cached.
      assert {:error, :not_found} = Catalog.get_tool("someserver:sometool")
      refute Enum.any?(Catalog.list_tools(), &String.contains?(&1["name"], ":"))
    end

    # The bucket default is also enforced at dispatch, not left to the
    # wiring: an external-plane call of a `server:tool` name is refused
    # unless the server row opts in with "console": true. That needs DB
    # rows, so it is pinned in `Emissary.MCP.ExternalProviderTest`
    # ("call_external refuses a proxied name on the external plane").
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # A formula's host intercepts exactly the actions its assignment names,
  # and an assignment names the actions the catalog annotates
  # `host: :intercepted` (`Cyfr.Execution.Assignments`).
  test "the intercept set an assignment carries is the catalog's annotation" do
    intercepted = Catalog.host_intercepted_actions()

    assert "execution.run" in intercepted
    assert "execution.run_stream" in intercepted
    refute "execution.cancel" in intercepted
    refute "execution.list" in intercepted
    refute "system.status" in intercepted

    for name <- intercepted do
      [tool, action] = String.split(name, ".", parts: 2)
      assert Catalog.host_intercepted?(tool, action)
    end
  end
end
