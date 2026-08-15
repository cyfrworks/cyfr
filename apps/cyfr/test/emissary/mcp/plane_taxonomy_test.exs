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
end

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Emissary.MCP.PlaneTaxonomyTest.ProbeProvider do
  @moduledoc false
  # A provider whose tool list is whichever malformed probe the test asked
  # for — the audit reads providers from config, so this is the seam.

  alias Emissary.MCP.PlaneTaxonomyTest.Probes

  def tools do
    apply(Probes, Application.get_env(:cyfr, :plane_taxonomy_probe, :unannotated), [])
  end
end

defmodule Emissary.MCP.PlaneTaxonomyTest do
  # The model §6 "Plane taxonomy" gate, both arms: every registered action
  # is annotated, and the agent's virtual tools — which never reach the tool
  # registry and so are invisible to its audit — are covered too.
  use ExUnit.Case, async: true

  alias Emissary.MCP.ExternalProvider
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
            {:kind_only, :missing_planes},
            {:planes_only, :missing_kind},
            {:invalid_plane, :invalid_planes},
            {:empty_planes, :missing_planes},
            {:unannotated, :missing_annotation}
          ] do
        assert {:error, [%{reason: ^reason}]} = audit_probe(probe),
               "#{probe} was not reported as #{reason}"
      end
    end

    test "the whole surface is covered when every provider is loaded" do
      # Guards the standalone-run hole: if this runs with the full provider
      # set it must see the whole taxonomy.
      if length(loaded_providers()) == 8 do
        assert length(annotated_actions()) == 115
      else
        assert length(loaded_providers()) >= 5
      end
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

  describe "public actions" do
    test "every unauthenticated action is annotated external" do
      # The public maps name the unauthenticated HTTP surface, so every
      # entry is by definition external-plane. A drifted entry here would
      # mean an action is publicly reachable without the taxonomy saying so.
      by_tool =
        annotated_actions()
        |> Enum.group_by(fn {tool, _, _} -> tool end, fn {_, verb, ann} -> {verb, ann} end)

      for {tool, verbs} <- public_tool_actions(),
          {verb, %{planes: planes}} <- Map.get(by_tool, tool, []),
          verbs == :all or verb in verbs do
        assert :external in planes, "public action #{tool}.#{verb} is not external-plane"
      end
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

  # Run the audit over a single deliberately-malformed probe tool.
  defp audit_probe(fun) do
    module = Emissary.MCP.PlaneTaxonomyTest.ProbeProvider

    original = Application.get_env(:cyfr, :tool_providers)
    Application.put_env(:cyfr, :tool_providers, [module])
    Application.put_env(:cyfr, :plane_taxonomy_probe, fun)

    try do
      ToolRegistry.audit_action_kinds()
    after
      Application.put_env(:cyfr, :tool_providers, original)
      Application.delete_env(:cyfr, :plane_taxonomy_probe)
    end
  end

  # The router keeps its public maps private; mirrored here rather than
  # reached into. These are the actions documented as reachable without
  # authentication — every one must be external-plane.
  defp public_tool_actions do
    %{
      "session" => :all,
      "aqua" => ~w(list get),
      "component" => ~w(search inspect categories setup_plan list),
      "registry" => ~w(probe claim_personal get_namespace),
      "system" => ~w(status)
    }
  end
end
