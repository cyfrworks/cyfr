# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DependencyStorageTest do
  use ExUnit.Case, async: false

  alias Arca.DependencyStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    # Create a component to reference
    component_id = "comp_test_#{:rand.uniform(100_000)}"

    Arca.Repo.insert_all("components", [
      %{
        id: component_id,
        name: "test-component",
        version: "1.0.0",
        component_type: "formula",
        description: "Test component",
        tags: "[]",
        digest: "sha256:abc123",
        size: 1024,
        exports: "[]",
        publisher: "local",
        publisher_id: "test-user",
        org_id: Arca.QueryHelpers.normalize_org_id(ctx.org_id),
        project_id: ctx.project_id || "default",
        source: "test",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    {:ok, component_id: component_id, ctx: ctx}
  end

  defp sample_deps do
    [
      %{
        dependency_ref: "catalyst:local.claude:0.1.0",
        dep_type: "catalyst",
        dep_namespace: "local",
        dep_name: "claude",
        dep_version: "0.1.0",
        optional: 0,
        reason: "Claude API provider"
      },
      %{
        dependency_ref: "catalyst:local.openai:0.1.0",
        dep_type: "catalyst",
        dep_namespace: "local",
        dep_name: "openai",
        dep_version: "0.1.0",
        optional: 1,
        reason: "OpenAI API provider"
      }
    ]
  end

  describe "put_dependencies/3 and get_dependencies/2" do
    test "stores and retrieves dependencies", %{component_id: component_id, ctx: ctx} do
      deps = sample_deps()

      assert {:ok, 2} = DependencyStorage.put_dependencies(ctx, component_id, deps)
      assert {:ok, stored} = DependencyStorage.get_dependencies(ctx, component_id)
      assert length(stored) == 2

      refs = Enum.map(stored, & &1.dependency_ref)
      assert "catalyst:local.claude:0.1.0" in refs
      assert "catalyst:local.openai:0.1.0" in refs
    end

    test "replaces existing dependencies on re-put", %{component_id: component_id, ctx: ctx} do
      deps = sample_deps()
      {:ok, 2} = DependencyStorage.put_dependencies(ctx, component_id, deps)

      # Replace with a single dep
      new_deps = [
        %{
          dependency_ref: "reagent:local.parser:1.0.0",
          dep_type: "reagent",
          dep_namespace: "local",
          dep_name: "parser",
          dep_version: "1.0.0",
          optional: 0,
          reason: "Data parser"
        }
      ]

      assert {:ok, 1} = DependencyStorage.put_dependencies(ctx, component_id, new_deps)
      assert {:ok, stored} = DependencyStorage.get_dependencies(ctx, component_id)
      assert length(stored) == 1
      assert hd(stored).dependency_ref == "reagent:local.parser:1.0.0"
    end

    test "handles empty dependency list", %{component_id: component_id, ctx: ctx} do
      assert {:ok, 0} = DependencyStorage.put_dependencies(ctx, component_id, [])
      assert {:ok, []} = DependencyStorage.get_dependencies(ctx, component_id)
    end

    test "returns empty list for unknown component", %{ctx: ctx} do
      assert {:ok, []} = DependencyStorage.get_dependencies(ctx, "comp_nonexistent")
    end

    test "stores optional flag correctly", %{component_id: component_id, ctx: ctx} do
      deps = sample_deps()
      {:ok, 2} = DependencyStorage.put_dependencies(ctx, component_id, deps)
      {:ok, stored} = DependencyStorage.get_dependencies(ctx, component_id)

      claude = Enum.find(stored, &(&1.dependency_ref == "catalyst:local.claude:0.1.0"))
      openai = Enum.find(stored, &(&1.dependency_ref == "catalyst:local.openai:0.1.0"))

      assert claude.optional == 0
      assert openai.optional == 1
    end

    test "stores reason field", %{component_id: component_id, ctx: ctx} do
      deps = sample_deps()
      {:ok, 2} = DependencyStorage.put_dependencies(ctx, component_id, deps)
      {:ok, stored} = DependencyStorage.get_dependencies(ctx, component_id)

      claude = Enum.find(stored, &(&1.dependency_ref == "catalyst:local.claude:0.1.0"))
      assert claude.reason == "Claude API provider"
    end
  end

  describe "get_reverse_dependencies/3" do
    test "finds components that depend on a given name/version", %{
      component_id: component_id,
      ctx: ctx
    } do
      deps = sample_deps()
      {:ok, 2} = DependencyStorage.put_dependencies(ctx, component_id, deps)

      {:ok, reverse} = DependencyStorage.get_reverse_dependencies(ctx, "claude", "0.1.0")
      assert length(reverse) == 1
      assert hd(reverse).component_id == component_id
    end

    test "returns empty list when no dependents exist", %{ctx: ctx} do
      {:ok, reverse} = DependencyStorage.get_reverse_dependencies(ctx, "nonexistent", "1.0.0")
      assert reverse == []
    end
  end

  describe "delete_dependencies/2" do
    test "deletes all dependencies for a component", %{component_id: component_id, ctx: ctx} do
      deps = sample_deps()
      {:ok, 2} = DependencyStorage.put_dependencies(ctx, component_id, deps)

      assert :ok = DependencyStorage.delete_dependencies(ctx, component_id)
      assert {:ok, []} = DependencyStorage.get_dependencies(ctx, component_id)
    end

    test "succeeds for component with no dependencies", %{ctx: ctx} do
      assert :ok = DependencyStorage.delete_dependencies(ctx, "comp_no_deps")
    end
  end
end
