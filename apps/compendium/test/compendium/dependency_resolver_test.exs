defmodule Compendium.DependencyResolverTest do
  use ExUnit.Case, async: false

  alias Compendium.DependencyResolver
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_dep_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:arca, :base_path, test_dir)
    Application.put_env(:arca, :components_path, Path.join(test_dir, "components"))

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: ctx, test_dir: test_dir}
  end

  # ============================================================================
  # extract_from_manifest/2
  # ============================================================================

  describe "extract_from_manifest/2" do
    test "extracts static dependencies from manifest" do
      manifest = %{
        "dependencies" => %{
          "static" => [
            %{
              "ref" => "catalyst:local.claude:0.1.0",
              "optional" => false,
              "reason" => "Claude API provider"
            },
            %{
              "ref" => "catalyst:local.openai:0.1.0",
              "optional" => true,
              "reason" => "OpenAI API provider"
            }
          ]
        }
      }

      assert {:ok, deps} = DependencyResolver.extract_from_manifest(manifest, "comp_test")
      assert length(deps) == 2

      claude = Enum.find(deps, &(&1.dep_name == "claude"))
      assert claude.dependency_ref == "catalyst:local.claude:0.1.0"
      assert claude.dep_type == "catalyst"
      assert claude.dep_namespace == "local"
      assert claude.dep_version == "0.1.0"
      assert claude.optional == 0
      assert claude.reason == "Claude API provider"

      openai = Enum.find(deps, &(&1.dep_name == "openai"))
      assert openai.optional == 1
    end

    test "returns empty list when no dependencies declared" do
      manifest = %{"type" => "formula", "version" => "1.0.0"}
      assert {:ok, []} = DependencyResolver.extract_from_manifest(manifest, "comp_test")
    end

    test "returns empty list for nil manifest" do
      assert {:ok, []} = DependencyResolver.extract_from_manifest(nil, "comp_test")
    end

    test "returns empty list when static is nil" do
      manifest = %{"dependencies" => %{"dynamic" => %{"discovery" => "component.search"}}}
      assert {:ok, []} = DependencyResolver.extract_from_manifest(manifest, "comp_test")
    end

    test "returns error for invalid ref" do
      manifest = %{
        "dependencies" => %{
          "static" => [
            %{"ref" => "", "optional" => false}
          ]
        }
      }

      assert {:error, _reason} = DependencyResolver.extract_from_manifest(manifest, "comp_test")
    end

    test "returns error for dependency ref without version" do
      manifest = %{
        "dependencies" => %{
          "static" => [
            %{"ref" => "catalyst:local.claude", "optional" => false}
          ]
        }
      }

      assert {:error, reason} = DependencyResolver.extract_from_manifest(manifest, "comp_test")
      assert reason =~ "explicit version"
    end

    test "defaults optional to false when not specified" do
      manifest = %{
        "dependencies" => %{
          "static" => [
            %{"ref" => "catalyst:local.claude:0.1.0"}
          ]
        }
      }

      assert {:ok, [dep]} = DependencyResolver.extract_from_manifest(manifest, "comp_test")
      assert dep.optional == 0
    end
  end

  # ============================================================================
  # classify_availability/2
  # ============================================================================

  describe "classify_availability/2" do
    test "classifies present deps as present", %{ctx: ctx} do
      # Register a component that a dep refers to
      register_test_component(ctx, "claude", "0.1.0", "catalyst")

      deps = [
        %{
          dependency_ref: "catalyst:local.claude:0.1.0",
          dep_type: "catalyst",
          dep_namespace: "local",
          dep_name: "claude",
          dep_version: "0.1.0",
          optional: 0
        }
      ]

      result = DependencyResolver.classify_availability(ctx, deps)
      assert length(result.present) == 1
      assert result.missing == []
      assert result.optional_missing == []
      assert result.all_satisfied == true
    end

    test "classifies missing required deps as missing", %{ctx: ctx} do
      deps = [
        %{
          dependency_ref: "catalyst:local.nonexistent:0.1.0",
          dep_type: "catalyst",
          dep_namespace: "local",
          dep_name: "nonexistent",
          dep_version: "0.1.0",
          optional: 0
        }
      ]

      result = DependencyResolver.classify_availability(ctx, deps)
      assert result.present == []
      assert length(result.missing) == 1
      assert result.all_satisfied == false
    end

    test "classifies missing optional deps as optional_missing", %{ctx: ctx} do
      deps = [
        %{
          dependency_ref: "catalyst:local.nonexistent:0.1.0",
          dep_type: "catalyst",
          dep_namespace: "local",
          dep_name: "nonexistent",
          dep_version: "0.1.0",
          optional: 1
        }
      ]

      result = DependencyResolver.classify_availability(ctx, deps)
      assert result.present == []
      assert result.missing == []
      assert length(result.optional_missing) == 1
      assert result.all_satisfied == true
    end

    test "handles empty deps list", %{ctx: ctx} do
      result = DependencyResolver.classify_availability(ctx, [])
      assert result.present == []
      assert result.missing == []
      assert result.optional_missing == []
      assert result.all_satisfied == true
    end
  end

  # ============================================================================
  # has_dynamic_deps?/1
  # ============================================================================

  describe "has_dynamic_deps?/1" do
    test "returns true when dynamic section exists" do
      manifest = %{
        "dependencies" => %{
          "dynamic" => %{
            "discovery" => "component.search",
            "description" => "Discovers providers at runtime"
          }
        }
      }

      assert DependencyResolver.has_dynamic_deps?(manifest) == true
    end

    test "returns false when no dynamic section" do
      manifest = %{
        "dependencies" => %{
          "static" => [%{"ref" => "catalyst:local.claude:0.1.0"}]
        }
      }

      assert DependencyResolver.has_dynamic_deps?(manifest) == false
    end

    test "returns false for nil manifest" do
      assert DependencyResolver.has_dynamic_deps?(nil) == false
    end

    test "returns false when no dependencies at all" do
      assert DependencyResolver.has_dynamic_deps?(%{}) == false
    end
  end

  # ============================================================================
  # resolve_tree/3
  # ============================================================================

  describe "resolve_tree/3" do
    test "returns empty tree when no dependencies", %{ctx: ctx} do
      manifest = %{"type" => "formula"}
      assert {:ok, []} = DependencyResolver.resolve_tree(ctx, "comp_test", manifest)
    end

    test "returns tree with deps", %{ctx: ctx} do
      manifest = %{
        "dependencies" => %{
          "static" => [
            %{"ref" => "catalyst:local.claude:0.1.0", "optional" => false}
          ]
        }
      }

      assert {:ok, tree} = DependencyResolver.resolve_tree(ctx, "comp_test", manifest)
      assert length(tree) == 1

      node = hd(tree)
      assert node.dep_name == "claude"
      assert node.cycle == false
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Valid minimal WASM binary with export section
  @valid_wasm (
    <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
    <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
    <<0x03, 0x02, 0x01, 0x00>> <>
    <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
    <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>
  )

  defp register_test_component(ctx, name, version, type) do
    Compendium.Registry.publish_bytes(ctx, @valid_wasm, %{
      name: name,
      version: version,
      type: type,
      description: "Test #{name}"
    })
  end
end
