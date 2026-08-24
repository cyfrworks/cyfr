# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Emissary.MCP.PlaneTaxonomyTest.Probes do
  @moduledoc false
  # Deliberately malformed annotations, one per failure mode, so the audit
  # is shown to report *which* thing is wrong rather than only that
  # something is.

  defp tool(annotation) do
    %{
      name: "probe",
      description: "probe",
      input_schema: %{"properties" => %{"action" => %{"enum" => ["act"]}}},
      annotations: %{actions: %{"act" => annotation}}
    }
  end

  def kind_only, do: [tool(%{kind: :read})]
  def planes_only, do: [tool(%{planes: [:external]})]
  def invalid_plane, do: [tool(%{kind: :read, planes: [:sideways]})]
  def empty_planes, do: [tool(%{kind: :read, planes: []})]
  def unannotated, do: [tool(nil)]

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

  defmodule Unannotated do
    @moduledoc false
    def tools, do: Emissary.MCP.PlaneTaxonomyTest.Probes.unannotated()
  end
end

defmodule Emissary.MCP.PlaneTaxonomyTest do
  # The model §6 "Plane taxonomy" gate, both arms: every registered action
  # is annotated, and the agent's virtual tools — which never reach the tool
  # registry and so are invisible to its audit — are covered too.
  use ExUnit.Case, async: true

  alias Emissary.MCP.ExternalProvider
  alias Emissary.MCP.PlaneTaxonomyTest.Probes
  alias Emissary.MCP.ToolRegistry
  alias Prism.AquaVirtualTools

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
      assert ToolRegistry.audit_action_kinds() == :ok
    end

    test "every action declares a kind and at least one valid plane" do
      for {tool, verb, annotation} <- annotated_actions() do
        assert %{kind: kind, planes: planes} = annotation, "#{tool}.#{verb} is unannotated"
        assert is_atom(kind) and not is_nil(kind), "#{tool}.#{verb} has no kind"
        assert planes != [], "#{tool}.#{verb} has no plane"

        assert Enum.all?(planes, &(&1 in ToolRegistry.valid_planes())),
               "#{tool}.#{verb} has an invalid plane: #{inspect(planes)}"
      end
    end

    test "the audit reports what is wrong, not merely that something is" do
      # A missing plane must be as loud as a missing kind — otherwise a
      # half-annotated action passes the gate it exists to fail.
      for {probe, reason} <- [
            {Probes.KindOnly, :missing_planes},
            {Probes.PlanesOnly, :missing_kind},
            {Probes.InvalidPlane, :invalid_planes},
            {Probes.EmptyPlanes, :missing_planes},
            {Probes.Unannotated, :missing_annotation}
          ] do
        assert {:error, [%{reason: ^reason}]} = ToolRegistry.audit_action_kinds([probe]),
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
          for tool_def <- ToolRegistry.list_tools(),
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
    test "every registered action is externally reachable" do
      # Every registered tool is served over the MCP HTTP surface; nothing
      # here is in-chain-only today.
      for {tool, verb, %{planes: planes}} <- annotated_actions() do
        assert :external in planes, "#{tool}.#{verb} is not externally reachable"
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
      assert AquaVirtualTools.audit_planes() == :ok
    end

    test "every virtual action is in-chain only" do
      for {tool, %{actions: actions}} <- AquaVirtualTools.catalog(),
          {action, %{planes: planes}} <- actions do
        assert planes == [:in_chain], "#{tool}.#{action} claims #{inspect(planes)}"
      end
    end

    test "virtual tools are not registered tools" do
      registered = annotated_actions() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      for tool <- Map.keys(AquaVirtualTools.catalog()) do
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
      # The bucket default is a description of the wiring, not a policy
      # choice: the router rejects any name the registered-tool cache does
      # not hold, and proxied `server:tool` names are never cached.
      assert {:error, :not_found} = ToolRegistry.get_tool("someserver:sometool")
      refute Enum.any?(ToolRegistry.list_tools(), &String.contains?(&1["name"], ":"))
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================
end
