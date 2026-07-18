# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCPTest do
  use ExUnit.Case, async: false

  alias Compendium.{MCP, Registry}
  alias Sanctum.Context

  # Valid minimal WASM with export section
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  defp setup_aqua_dir(test_dir) do
    aqua_dir = Path.join(test_dir, "aqua")
    File.mkdir_p!(aqua_dir)

    manifest = %{
      "version" => 1,
      "default" => "aqua",
      "agents" => %{
        "aqua" => %{
          "title" => "A.Q.U.A.",
          "prompt" => "aqua.md",
          "catalyst_ref" => "catalyst:moonmoon69.claude",
          "model" => "claude-opus-4-6",
          "sub_agents" => %{
            "aqua_builder" => %{
              "prompt" => "aqua_builder.md",
              "title" => "Builder",
              "description" => "WASM component builder sub-agent prompt",
              "tool_policy" => %{"component.list" => "allow", "build.compile" => "allow"}
            },
            "aqua_artisan" => %{
              "prompt" => "aqua_artisan.md",
              "title" => "Artisan",
              "description" => "Tincture app/dashboard sub-agent prompt",
              "tool_policy" => %{"files.read" => "allow", "storage.get" => "allow"}
            },
            "aqua_arcade" => %{
              "prompt" => "aqua_arcade.md",
              "title" => "Arcade",
              "description" => "Game tincture sub-agent prompt",
              "tool_policy" => %{"files.read" => "allow", "storage.get" => "allow"}
            },
            "aqua_explorer" => %{
              "prompt" => "aqua_explorer.md",
              "title" => "Explorer",
              "description" => "Research and web search sub-agent prompt",
              "tool_policy" => %{"native_search" => "allow"}
            },
            "aqua_planner" => %{
              "prompt" => "aqua_planner.md",
              "title" => "Planner",
              "description" => "Planning and analysis sub-agent prompt"
            },
            "aqua_web" => %{
              "prompt" => "aqua_web.md",
              "title" => "Web",
              "description" => "HTTP interaction sub-agent prompt",
              "tool_policy" => %{"http.get" => "allow"}
            }
          }
        }
      }
    }

    File.write!(Path.join(aqua_dir, "agent.json"), Jason.encode!(manifest))

    File.write!(
      Path.join(aqua_dir, "aqua.md"),
      "# A.Q.U.A.\n\n## Routing Rules\n\nYou are A.Q.U.A."
    )

    File.write!(Path.join(aqua_dir, "aqua_builder.md"), "# Builder Agent\n\nYou are the Builder.")
    File.write!(Path.join(aqua_dir, "aqua_artisan.md"), "# Artisan Agent\n\nYou are the Artisan.")
    File.write!(Path.join(aqua_dir, "aqua_arcade.md"), "# Arcade Agent\n\nYou are the Arcade.")

    File.write!(
      Path.join(aqua_dir, "aqua_explorer.md"),
      "# Explorer Agent\n\nYou are the Explorer."
    )

    File.write!(Path.join(aqua_dir, "aqua_planner.md"), "# Planner Agent\n\nYou are the Planner.")
    File.write!(Path.join(aqua_dir, "aqua_web.md"), "# Web Agent\n\nYou are the Web agent.")
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, Path.join(test_dir, "components"))

    # Set up aqua/ directory with agent manifest and test prompts
    setup_aqua_dir(test_dir)
    Application.put_env(:cyfr, :aqua_path, Path.join(test_dir, "aqua"))

    # Point API URL at a non-routable address so cyfr.run fallback tests
    # don't hit the real API or timeout waiting.
    # Client.ex prepends "https://", so we set the bare host:port here.
    original_registry_url = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Application.delete_env(:cyfr, :aqua_path)

      if original_registry_url,
        do: Application.put_env(:cyfr, :registry_url, original_registry_url),
        else: Application.delete_env(:cyfr, :registry_url)
    end)

    {:ok, ctx: ctx, test_dir: test_dir}
  end

  # ============================================================================
  # Resource Discovery
  # ============================================================================

  describe "resources/0" do
    test "returns no concrete resources" do
      resources = MCP.resources()
      assert resources == []
    end
  end

  describe "resource_templates/0" do
    test "returns component and asset resource templates" do
      templates = MCP.resource_templates()
      assert length(templates) == 2

      uris = Enum.map(templates, & &1.uriTemplate)
      assert "compendium://components/{reference}" in uris
      assert "compendium://assets/{reference}/{path}" in uris
    end
  end

  describe "read/2" do
    test "reads component metadata resource", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "read-test",
          version: "1.0.0",
          type: "reagent",
          description: "A test component for read"
        })

      {:ok, result} = MCP.read(ctx, "compendium://components/r:local.read-test:1.0.0")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert content["name"] == "read-test"
      assert content["version"] == "1.0.0"
      assert content["publisher"] == "local"
      assert is_binary(content["digest"])
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "compendium://components/r:local.nonexistent:1.0.0")
      assert msg =~ "not found"
    end

    test "reads asset from component directory", %{ctx: ctx, test_dir: test_dir} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "asset-test",
          version: "1.0.0",
          type: "reagent"
        })

      # Write an asset file into the component's storage directory
      asset_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "asset-test",
          "1.0.0"
        ])

      File.mkdir_p!(asset_dir)
      asset_content = ~s({"key": "value"})
      File.write!(Path.join(asset_dir, "config.json"), asset_content)

      {:ok, result} = MCP.read(ctx, "compendium://assets/r:local.asset-test:1.0.0/config.json")
      assert result.mimeType == "application/octet-stream"
      assert Base.decode64!(result.content) == asset_content
    end

    test "returns error for non-existent asset", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "compendium://assets/r:local.nocomp:1.0.0/missing.txt")
      assert msg =~ "not found"
    end

    test "returns error for unknown resource", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "compendium://unknown")
      assert msg =~ "Unknown resource"
    end
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns action-based tools: component, aqua, registry" do
      tools = MCP.tools()
      assert length(tools) == 3

      tool_names = Enum.map(tools, & &1.name)
      assert "component" in tool_names
      assert "aqua" in tool_names
      assert "registry" in tool_names
    end

    test "tool has required schema fields" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))

      assert is_binary(tool.name)
      assert tool.name == "component"
      assert is_binary(tool.title)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
      assert tool.input_schema["type"] == "object"
      assert "action" in tool.input_schema["required"]
    end

    test "component tool has correct actions" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      actions = tool.input_schema["properties"]["action"]["enum"]

      assert "search" in actions
      assert "inspect" in actions
      assert "pull" in actions
      assert "push" in actions
      assert "register" in actions
      assert "categories" in actions
      assert "get_blob" in actions
      assert "list" in actions
      assert "delete" in actions
    end

    test "component tool has type filter enum" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      type_schema = tool.input_schema["properties"]["type"]

      assert type_schema["type"] == "string"
      assert "catalyst" in type_schema["enum"]
      assert "reagent" in type_schema["enum"]
      assert "formula" in type_schema["enum"]
    end
  end

  # ============================================================================
  # Component Tool - Search Action
  # ============================================================================

  describe "component tool - search action" do
    test "search returns empty results for empty registry", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "search",
          "query" => "data processing"
        })

      assert result.components == []
      assert result.total == 0
    end

    test "accepts filter parameters", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "search",
          "query" => "api",
          "type" => "catalyst",
          "category" => "api-integrations",
          "license" => "MIT"
        })

      assert result.components == []
      assert result.total == 0
    end
  end

  # ============================================================================
  # Component Tool - Inspect Action
  # ============================================================================

  describe "component tool - inspect action" do
    test "inspect response includes component_ref", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "ref-test",
          version: "1.0.0",
          type: "reagent",
          description: "Test component for ref"
        })

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.ref-test:1.0.0"
        })

      assert result["component_ref"] == "reagent:local.ref-test:1.0.0"
    end

    test "inspect response includes typed component_ref from reference", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "typed-ref-test",
          version: "1.0.0",
          type: "catalyst",
          description: "Test component for typed ref"
        })

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "catalyst:local.typed-ref-test:1.0.0"
        })

      assert result["component_ref"] == "catalyst:local.typed-ref-test:1.0.0"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.example-tool:1.0.0"
        })

      assert msg =~ "not found"
    end

    test "inspect returns not-found without cyfr.run fallback", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:cyfr.data-processor:1.0.0"
        })

      assert msg =~ "not found"
      refute msg =~ "cyfr.run"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "inspect"})
      assert msg =~ "Missing required"
    end

    test "inspect with version-less ref to nonexistent component returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.nonexistent-component"
        })

      assert msg =~ "nonexistent-component"
    end

    test "inspect with pinned ref to nonexistent component falls through to not-found", %{
      ctx: ctx
    } do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.nonexistent-component:1.0.0"
        })

      assert msg =~ "not found" or msg =~ "Component not found"
    end

    test "inspect with latest reference resolves to semantic version", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "version-resolve",
          version: "2.3.4",
          type: "catalyst",
          description: "Test component for latest resolution"
        })

      # Reference without version defaults to nil (resolve to latest)
      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.version-resolve"
        })

      # component_ref must contain the resolved semver, not be version-less
      assert result["component_ref"] == "catalyst:local.version-resolve:2.3.4"
      refute result["component_ref"] =~ "latest"
    end
  end

  # ============================================================================
  # Component Tool - Pull Action
  # ============================================================================

  describe "component tool - pull action" do
    test "rejects pull of local components", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "c:local.example-tool:1.0.0"
        })

      assert msg =~ "Cannot pull local components"
      assert msg =~ "cyfr register"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "pull"})
      assert msg =~ "Missing required"
    end

    test "rejects an OCI pull from a non-configured registry host", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
    end

    test "single-user pull failure returns a binary error with the reference", %{ctx: ctx} do
      # Post-refactor the anonymous-probe is namespace-scoped and logs a
      # warning rather than appending a hint to the pull error. We just
      # check the pull fails cleanly against an unreachable registry.
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "registry.cyfr.run/cyfr/reagents/test:1.0.0"
        })

      assert is_binary(msg)
    end
  end

  # ============================================================================
  # Registry host validation
  # ============================================================================

  describe "registry host validation" do
    test "rejects a pull from a non-configured registry host", %{ctx: ctx} do
      # The deployment talks to its configured registry only — a foreign OCI
      # host is rejected regardless of who the caller is.
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
    end

    test "rejects discover against a non-configured registry host", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "discover",
          "registry" => "ghcr.io"
        })

      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
    end

    test "discover with no registry argument uses the configured registry", %{ctx: ctx} do
      result =
        MCP.handle("component", ctx, %{
          "action" => "discover"
        })

      case result do
        {:error, msg} -> refute msg =~ "Missing required argument: registry"
        {:ok, _} -> :ok
      end
    end

    test "returns a parse error for a malformed OCI reference in pull", %{ctx: ctx} do
      # "ghcr.io/" has a registry but no repository — triggers parse error
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/"
        })

      assert msg =~ "Invalid OCI reference"
    end
  end

  # ============================================================================
  # Component Tool - Push Action
  # ============================================================================

  describe "component tool - push action" do
    test "rejects push of a non-local namespace to a registry", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:stripe.stripe:1.0.0"
        })

      assert msg =~ "Only components in the local namespace"
      assert msg =~ "namespace 'stripe'"
    end

    test "returns error when the version is missing", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool"
        })

      assert msg =~ "Version is required"
    end

    test "push of a local component without a claimed namespace asks the user to claim one",
         %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool:1.0.0"
        })

      # Regression: a `local` ref is pushed under the caller's claimed personal
      # namespace, not the literal "local". With no namespace claimed the error
      # must guide the user to claim one — never the old, misleading
      # "No push token for namespace 'local'".
      refute msg =~ "No push token for namespace 'local'"
      assert msg =~ "personal namespace"
      assert msg =~ "cyfr login"
    end

    test "push of a local component resolves the caller's claimed personal namespace",
         %{ctx: ctx} do
      # Claiming a namespace stores a personal (bare-slug) push-token credential.
      :ok =
        Registry.CredentialStore.put(ctx.user_id, Registry.canonical_host(), "testns", %{
          type: :push_token,
          token: "cyfr_pt_test",
          namespace: "testns"
        })

      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool:1.0.0"
        })

      # Resolution succeeded (no claim/credential error); the push then fails only
      # because the local component itself was never built in this test.
      refute msg =~ "personal namespace"
      refute msg =~ "No push token"
      assert msg =~ "Component not found locally"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "push"
        })

      assert msg =~ "Missing required" and msg =~ "reference"
    end

    test "rejects a push to a non-cyfr.run registry", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool:1.0.0",
          "registry" => "ghcr.io"
        })

      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
    end
  end

  # ============================================================================
  # Component Tool - Register Action
  # ============================================================================

  describe "component tool - register action" do
    test "scans and returns summary with no args", %{ctx: _ctx} do
      {:ok, result} =
        MCP.handle(
          "component",
          %Sanctum.Context{
            user_id: "test",
            org_id: "test",
            permissions: MapSet.new([:*]),
            authenticated: true
          },
          %{"action" => "register"}
        )

      assert result.status == "scanned"
      assert is_integer(result.registered)
      assert is_integer(result.unchanged)
      assert is_integer(result.pruned)
      assert is_integer(result.errors)
      assert is_integer(result.total)
      assert is_integer(result.elapsed_ms)
    end

    test "register action does not require directory parameter" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      # directory property should no longer exist in schema
      refute Map.has_key?(tool.input_schema["properties"], "directory")
    end
  end

  # ============================================================================
  # Component Tool - Inspect with Dependencies
  # ============================================================================

  describe "component tool - inspect with dependencies" do
    @dep_test_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                     <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                     <<0x03, 0x02, 0x01, 0x00>> <>
                     <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                     <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

    defp setup_dep_test_dir(test_dir, type, name, version, manifest) do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "#{type}s",
          "local",
          name,
          version
        ])

      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "#{type}.wasm"), @dep_test_wasm)
      comp_dir
    end

    test "inspect component with no deps has no dependency fields", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "no-dep-reagent",
          version: "1.0.0",
          type: "reagent",
          description: "A reagent with no deps"
        })

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.no-dep-reagent:1.0.0"
        })

      refute Map.has_key?(result, "dependencies")
      refute Map.has_key?(result, "all_satisfied")
      refute Map.has_key?(result, "missing")
      refute Map.has_key?(result, "has_dynamic")
    end

    test "inspect formula with all deps satisfied", %{ctx: ctx, test_dir: test_dir} do
      # Register the dependency catalyst
      cat_dir =
        setup_dep_test_dir(test_dir, "catalyst", "inspect-dep-cat", "0.1.0", %{
          "type" => "catalyst",
          "version" => "0.1.0",
          "description" => "A dependency catalyst"
        })

      {:ok, _} = Registry.register_from_directory(ctx, cat_dir)

      # Register a formula that depends on the catalyst
      formula_dir =
        setup_dep_test_dir(test_dir, "formula", "inspect-dep-formula", "0.1.0", %{
          "type" => "formula",
          "version" => "0.1.0",
          "description" => "A formula with deps",
          "dependencies" => %{
            "static" => [
              %{
                "ref" => "catalyst:local.inspect-dep-cat:0.1.0",
                "optional" => false,
                "reason" => "Required"
              }
            ]
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "formula:local.inspect-dep-formula:0.1.0"
        })

      assert result["all_satisfied"] == true
      assert is_list(result["dependencies"])
      assert result["missing"] == []
      assert result["has_dynamic"] == false
    end

    test "inspect formula with missing required deps", %{ctx: ctx, test_dir: test_dir} do
      formula_dir =
        setup_dep_test_dir(test_dir, "formula", "inspect-missing-dep", "0.1.0", %{
          "type" => "formula",
          "version" => "0.1.0",
          "description" => "Formula with missing dep",
          "dependencies" => %{
            "static" => [
              %{
                "ref" => "catalyst:local.nonexistent-inspect:0.1.0",
                "optional" => false,
                "reason" => "Missing"
              }
            ]
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "formula:local.inspect-missing-dep:0.1.0"
        })

      assert result["all_satisfied"] == false
      assert "catalyst:local.nonexistent-inspect:0.1.0" in result["missing"]
    end

    test "inspect formula with dynamic deps", %{ctx: ctx, test_dir: test_dir} do
      formula_dir =
        setup_dep_test_dir(test_dir, "formula", "inspect-dynamic-dep", "0.1.0", %{
          "type" => "formula",
          "version" => "0.1.0",
          "description" => "Formula with dynamic deps",
          "dependencies" => %{
            "dynamic" => %{
              "discovery" => "component.search",
              "description" => "Discovers catalysts at runtime",
              "typical_types" => ["catalyst"]
            }
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "formula:local.inspect-dynamic-dep:0.1.0"
        })

      assert result["has_dynamic"] == true
    end
  end

  # ============================================================================
  # Component Tool - Categories Action
  # ============================================================================

  describe "component tool - categories action" do
    test "returns list of categories", %{ctx: ctx} do
      {:ok, result} = MCP.handle("component", ctx, %{"action" => "categories"})

      assert is_list(result.categories)
      assert length(result.categories) == 5

      category_names = Enum.map(result.categories, & &1.name)
      assert "api-integrations" in category_names
      assert "data-processing" in category_names
      assert "ai-ml" in category_names
      assert "security" in category_names
      assert "utilities" in category_names
    end

    test "categories have descriptions", %{ctx: ctx} do
      {:ok, result} = MCP.handle("component", ctx, %{"action" => "categories"})

      for category <- result.categories do
        assert is_binary(category.name)
        assert is_binary(category.description)
      end
    end
  end

  # ============================================================================
  # Component Tool - Get Blob Action
  # ============================================================================

  describe "component tool - get_blob action" do
    test "returns error for non-existent blob", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "get_blob",
          "digest" => "sha256:nonexistent"
        })

      assert msg =~ "not found" or msg =~ "Blob"
    end

    test "returns error for missing digest", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "get_blob"})
      assert msg =~ "Missing required" or msg =~ "digest"
    end

    test "has digest property in tool schema" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      digest_schema = tool.input_schema["properties"]["digest"]

      assert digest_schema["type"] == "string"
      assert digest_schema["description"] =~ "digest"
    end
  end

  # ============================================================================
  # Setup Plan Action
  # ============================================================================

  describe "component tool - setup_plan action" do
    @setup_plan_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                       <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                       <<0x03, 0x02, 0x01, 0x00>> <>
                       <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                       <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

    defp setup_plan_component(test_dir, type, name, version, manifest) do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "#{type}s",
          "local",
          name,
          version
        ])

      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "#{type}.wasm"), @setup_plan_wasm)
      comp_dir
    end

    test "returns setup plan for a catalyst with secrets", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "setup-claude", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Claude catalyst for setup plan test",
          "setup" => %{
            "secrets" => [
              %{"name" => "ANTHROPIC_API_KEY", "description" => "API key", "required" => true}
            ],
            "policy" => %{
              "allowed_domains" => ["api.anthropic.com"],
              "allowed_methods" => ["GET", "POST"],
              "rate_limit" => %{"requests" => 100, "window" => "1m"}
            }
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.setup-claude:0.2.0"
        })

      assert result.component_ref =~ "setup-claude"
      assert result.type in ["catalyst", :catalyst]
      assert is_list(result.secrets)
      assert length(result.secrets) == 1
      assert is_boolean(result.ready)
      assert is_list(result.dependencies)

      # Should have the setup policy recommendation
      assert result.policy_recommended["allowed_domains"] == ["api.anthropic.com"]
    end

    test "returns setup plan for a catalyst without secrets", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "setup-web", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Web catalyst with no setup block"
        })

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.setup-web:0.2.0"
        })

      assert result.component_ref =~ "setup-web"
      assert result.secrets == []
    end

    test "returns setup plan for a formula with dependencies", %{ctx: ctx, test_dir: test_dir} do
      # Register the dependency catalyst first
      cat_dir =
        setup_plan_component(test_dir, "catalyst", "dep-for-formula", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Dependency catalyst"
        })

      {:ok, _} = Registry.register_from_directory(ctx, cat_dir)

      formula_dir =
        setup_plan_component(test_dir, "formula", "setup-formula", "0.2.0", %{
          "type" => "formula",
          "version" => "0.2.0",
          "description" => "Formula with dependencies",
          "dependencies" => %{
            "static" => [
              %{
                "ref" => "catalyst:local.dep-for-formula:0.2.0",
                "optional" => false,
                "reason" => "Required"
              }
            ]
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "formula:local.setup-formula:0.2.0"
        })

      assert result.component_ref =~ "setup-formula"
      assert is_list(result.dependencies)
      assert result.dependencies != []
    end

    test "ready is true when name-level policy exists", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "ready-nl", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Readiness test (name-level policy)",
          "setup" => %{
            "policy" => %{"allowed_domains" => ["example.com"]}
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Store policy at name-level (no version)
      :ok =
        Sanctum.PolicyStore.put(ctx, "catalyst:local.ready-nl", %{
          "allowed_domains" => ["example.com"]
        })

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.ready-nl:0.2.0"
        })

      assert result.ready == true
      assert result.policy_stored == true
    end

    test "ready is false with only hardcoded default policy", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "ready-hc", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Readiness test (no stored policy)",
          "setup" => %{
            "policy" => %{"allowed_domains" => ["example.com"]}
          }
        })

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.ready-hc:0.2.0"
        })

      assert result.ready == false
      assert result.policy_stored == false
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "setup_plan"})
      assert msg =~ "Missing required argument: reference"
    end

    test "returns error for nonexistent component", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.nonexistent:99.0.0"
        })

      assert msg =~ "not found" or msg =~ "Component"
    end
  end

  # ============================================================================
  # Component Tool - List Action
  # ============================================================================

  describe "component tool - list action" do
    test "list returns empty results for empty registry", %{ctx: ctx} do
      {:ok, result} = MCP.handle("component", ctx, %{"action" => "list"})

      assert result.components == []
      assert result.total == 0
    end

    test "list returns all installed components", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "list-test-a",
          version: "1.0.0",
          type: "reagent",
          description: "First test component"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "list-test-b",
          version: "1.0.0",
          type: "catalyst",
          description: "Second test component"
        })

      {:ok, result} = MCP.handle("component", ctx, %{"action" => "list"})

      assert result.total >= 2
      names = Enum.map(result.components, &(&1[:name] || &1["name"]))
      assert "list-test-a" in names
      assert "list-test-b" in names
    end

    test "list filters by type", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "list-type-r",
          version: "1.0.0",
          type: "reagent",
          description: "A reagent"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "list-type-c",
          version: "1.0.0",
          type: "catalyst",
          description: "A catalyst"
        })

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "list",
          "type" => "reagent"
        })

      types = Enum.map(result.components, &(&1[:component_type] || &1["component_type"]))
      assert Enum.all?(types, &(&1 == "reagent"))
    end

    test "list includes source field", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "list-source-test",
          version: "1.0.0",
          type: "reagent",
          description: "Component with source"
        })

      {:ok, result} = MCP.handle("component", ctx, %{"action" => "list"})

      for comp <- result.components do
        source = comp[:source] || comp["source"]
        assert source != nil, "component should have a source field"
      end
    end
  end

  # ============================================================================
  # Component Tool - Remove Action
  # ============================================================================

  describe "component tool - delete action" do
    test "removes a published component", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "remove-test",
          version: "1.0.0",
          type: "reagent",
          description: "Component to remove"
        })

      # Verify it exists
      {:ok, _} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.remove-test:1.0.0"
        })

      # Remove it
      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "r:local.remove-test:1.0.0"
        })

      assert result.status == "deleted"
      assert result.reference == "r:local.remove-test:1.0.0"

      # Verify it's gone
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.remove-test:1.0.0"
        })

      assert msg =~ "not found"
    end

    test "removes a filesystem component", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "remove-fs-test",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{
        "type" => "catalyst",
        "version" => "1.0.0",
        "description" => "FS component to remove"
      }

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "c:local.remove-fs-test:1.0.0"
        })

      assert result.status == "deleted"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "r:local.nonexistent-remove:1.0.0"
        })

      assert msg =~ "not found"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "delete"})
      assert msg =~ "Missing required argument: reference"
    end

    test "returns error for invalid reference", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "!!invalid!!"
        })

      assert msg =~ "not found" or msg =~ "Invalid reference"
    end

    test "verifies cleanup removes associated policies", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "remove-policy-test",
          version: "1.0.0",
          type: "catalyst",
          description: "Component with policy"
        })

      # Set a policy
      Sanctum.MCP.handle("policy", ctx, %{
        "action" => "set",
        "component_ref" => "catalyst:local.remove-policy-test:1.0.0",
        "allowed_domains" => ["example.com"]
      })

      # Remove the component
      {:ok, _} =
        MCP.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "c:local.remove-policy-test:1.0.0"
        })

      # Policy should be gone too — either returns {:error, "not found"} or {:ok, %{policy: nil}}
      result =
        Sanctum.MCP.handle("policy", ctx, %{
          "action" => "get",
          "component_ref" => "catalyst:local.remove-policy-test:1.0.0"
        })

      case result do
        {:error, msg} -> assert msg =~ "not found" or msg =~ "Policy"
        {:ok, %{policy: policy}} -> assert policy == nil or policy == %{}
      end
    end
  end

  # ============================================================================
  # Invalid/Missing Action
  # ============================================================================

  describe "component tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid component action"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Guide Tool
  # ============================================================================

  describe "aqua tool - list action" do
    test "list returns available guides", %{ctx: ctx} do
      {:ok, result} = MCP.handle("aqua", ctx, %{"action" => "list"})

      # 3 doc guides + 1 orchestrator + 6 sub-agents = 10
      assert result.count == 10
      assert length(result.guides) == 10

      names = Enum.map(result.guides, & &1.name)
      assert "component-guide" in names
      assert "tincture-guide" in names
      assert "integration-guide" in names
      assert "aqua" in names
      assert "aqua_builder" in names
      assert "aqua_artisan" in names
      assert "aqua_arcade" in names
      assert "aqua_explorer" in names
      assert "aqua_planner" in names
      assert "aqua_web" in names
    end

    test "guides have title and description", %{ctx: ctx} do
      {:ok, result} = MCP.handle("aqua", ctx, %{"action" => "list"})

      for guide <- result.guides do
        assert is_binary(guide.name)
        assert is_binary(guide.title)
        assert is_binary(guide.description)
      end
    end

    test "list with type filter returns only matching guides", %{ctx: ctx} do
      {:ok, result} = MCP.handle("aqua", ctx, %{"action" => "list", "type" => "sub-agent"})

      assert result.count == 6

      for guide <- result.guides do
        assert guide.type == "sub-agent"
      end
    end

    test "list with orchestrator filter", %{ctx: ctx} do
      {:ok, result} = MCP.handle("aqua", ctx, %{"action" => "list", "type" => "orchestrator"})

      assert result.count == 1
      assert hd(result.guides).name == "aqua"
    end
  end

  describe "aqua tool - get action" do
    test "get component-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "component-guide"})

      assert result.name == "component-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Component Reference"
    end

    test "get tincture-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "tincture-guide"})

      assert result.name == "tincture-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Tincture Reference"
    end

    test "get integration-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "integration-guide"})

      assert result.name == "integration-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Integration Guide"
    end

    test "get agent-guide returns aqua prompt (backward compat)", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "agent-guide"})

      assert result.name == "aqua"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "A.Q.U.A."
    end

    test "get aqua returns orchestrator prompt with metadata", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "aqua"})

      assert result.name == "aqua"
      assert result.type == "orchestrator"
      assert result.format == "markdown"
      assert result.content =~ "Routing Rules"
      assert result.catalyst_ref == "catalyst:moonmoon69.claude"
      assert result.model == "claude-opus-4-6"
    end

    test "get aqua_builder returns sub-agent prompt with metadata", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "aqua_builder"})

      assert result.name == "aqua_builder"
      assert result.type == "sub-agent"
      assert result.parent == "aqua"
      assert result.format == "markdown"
      assert result.content =~ "Builder Agent"
      assert is_map(result.tool_policy)
    end

    test "get aqua_artisan returns sub-agent prompt", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "aqua_artisan"})

      assert result.name == "aqua_artisan"
      assert result.type == "sub-agent"
      assert result.content =~ "Artisan Agent"
    end

    test "get aqua_arcade returns sub-agent prompt", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "aqua_arcade"})

      assert result.name == "aqua_arcade"
      assert result.type == "sub-agent"
      assert result.content =~ "Arcade Agent"
    end

    test "get aqua_web returns sub-agent prompt", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "aqua_web"})

      assert result.name == "aqua_web"
      assert result.type == "sub-agent"
      assert result.content =~ "Web Agent"
    end

    test "get aqua_planner returns sub-agent prompt", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "aqua_planner"})

      assert result.name == "aqua_planner"
      assert result.type == "sub-agent"
      assert result.content =~ "Planner Agent"
    end

    test "get with unknown name returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("aqua", ctx, %{"action" => "get", "name" => "nonexistent"})

      assert msg =~ "Unknown agent or guide"
      assert msg =~ "nonexistent"
    end

    test "get without name returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("aqua", ctx, %{"action" => "get"})
      assert msg =~ "Missing required"
    end
  end

  describe "component inspect - include_readme" do
    test "inspect with include_readme returns readme content", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "readme-test",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      readme_content = "# Readme Test Component\n\nThis is the README."
      manifest = %{"type" => "catalyst", "version" => "1.0.0", "name" => "readme-test"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), readme_content)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.readme-test:1.0.0",
          "include_readme" => true
        })

      assert result["readme"] == readme_content
    end

    test "inspect without include_readme omits readme", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "no-readme-flag",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0", "name" => "no-readme-flag"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), "# Has README")

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.no-readme-flag:1.0.0"
        })

      refute Map.has_key?(result, "readme")
    end

    test "inspect with include_readme returns nil when no README", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "no-readme-file",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "1.0.0", "name" => "no-readme-file"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.no-readme-file:1.0.0",
          "include_readme" => true
        })

      assert result["readme"] == nil
    end
  end

  describe "aqua tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("aqua", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid aqua action"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("aqua", ctx, %{})
      assert msg =~ "Invalid aqua action" or msg =~ "Missing required"
    end
  end

  describe "aqua tool - schema" do
    test "aqua tool has required schema fields" do
      tool = Enum.find(MCP.tools(), &(&1.name == "aqua"))

      assert tool.name == "aqua"
      assert is_binary(tool.title)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
      assert tool.input_schema["type"] == "object"
      assert "action" in tool.input_schema["required"]
    end

    test "aqua tool has correct actions" do
      tool = Enum.find(MCP.tools(), &(&1.name == "aqua"))
      actions = tool.input_schema["properties"]["action"]["enum"]

      assert "list" in actions
      assert "get" in actions
      assert "create" in actions
      assert "update" in actions
      assert "delete" in actions
      refute "readme" in actions
      # `create_agent` was folded into `create` (dispatch by `type` arg).
      refute "create_agent" in actions
    end

    test "all internal tools declare per-action kind annotations" do
      for tool <- MCP.tools() do
        action_enum = get_in(tool.input_schema, ["properties", "action", "enum"]) || []
        actions_meta = get_in(tool, [:annotations, :actions]) || %{}

        for a <- action_enum do
          assert Map.has_key?(actions_meta, a),
                 "#{tool.name}.#{a} is missing from annotations.actions"

          %{kind: kind} = actions_meta[a]

          assert kind in [:read, :write, :execute, :destructive, :external],
                 "#{tool.name}.#{a} has unexpected kind #{inspect(kind)}"
        end
      end
    end
  end

  # ============================================================================
  # Auto-pull Dependencies
  # ============================================================================

  describe "component tool - pull with dependency auto-pull" do
    # Valid minimal WASM with export section (same as module attribute)
    @auto_pull_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                      <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                      <<0x03, 0x02, 0x01, 0x00>> <>
                      <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                      <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

    defp setup_component_dir(test_dir, type, name, version, manifest) do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "#{type}s",
          "local",
          name,
          version
        ])

      File.mkdir_p!(comp_dir)

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      wasm_filename = "#{type}.wasm"
      File.write!(Path.join(comp_dir, wasm_filename), @auto_pull_wasm)

      comp_dir
    end

    test "rejects pull of local formula", %{ctx: ctx, test_dir: test_dir} do
      formula_dir =
        setup_component_dir(test_dir, "formula", "test-formula", "0.1.0", %{
          "type" => "formula",
          "version" => "0.1.0",
          "description" => "A test formula"
        })

      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "formula:local.test-formula:0.1.0"
        })

      assert msg =~ "Cannot pull local components"
    end
  end

  # ============================================================================
  # Permission Gates
  # ============================================================================

  describe "permission gates" do
    setup do
      restricted_ctx = %Context{
        user_id: "restricted_user",
        org_id: nil,
        permissions: MapSet.new([:component_read]),
        scope: :project,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, restricted_ctx: restricted_ctx}
    end

    test "component.create denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      {:error, msg} =
        MCP.handle("component", restricted_ctx, %{
          "action" => "create",
          "name" => "test-comp",
          "type" => "reagent"
        })

      assert msg =~ "Unauthorized"
      assert msg =~ "component_manage"
    end

    test "component.push denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      {:error, msg} =
        MCP.handle("component", restricted_ctx, %{
          "action" => "push",
          "reference" => "reagent:local.test:0.1.0"
        })

      assert msg =~ "Unauthorized"
      assert msg =~ "component_manage"
    end

    test "component.register denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      {:error, msg} = MCP.handle("component", restricted_ctx, %{"action" => "register"})

      assert msg =~ "Unauthorized"
      assert msg =~ "component_manage"
    end

    test "component.delete denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      {:error, msg} =
        MCP.handle("component", restricted_ctx, %{
          "action" => "delete",
          "reference" => "reagent:local.test:0.1.0"
        })

      assert msg =~ "Unauthorized"
      assert msg =~ "component_manage"
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "unknown tool" do
    test "returns error for unknown tool", %{ctx: ctx} do
      {:error, msg} = MCP.handle("unknown_tool", ctx, %{})
      assert msg =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Schema drift guards
  # ============================================================================

  describe "registry.report category enum" do
    # Locked to cyfr.run `abuse_reports.category` CHECK constraint.
    # If this fails, server and client drifted — reconcile both sides before
    # adjusting the expected list.
    @expected_report_categories MapSet.new(~w(
      impersonation
      malware
      dmca
      spam
      other
      csam
      objectionable
      ip_infringement
      security
      policy_violation
      ncii
    ))

    test "MCP schema exposes exactly the 11 cyfr.run-supported categories" do
      registry_tool = Enum.find(MCP.tools(), &(&1.name == "registry"))
      assert registry_tool, "registry tool missing from MCP.tools/0"

      enum =
        registry_tool
        |> get_in([:input_schema, "properties", "category", "enum"])
        |> MapSet.new()

      assert MapSet.equal?(enum, @expected_report_categories),
             "registry.report category enum drifted. Got: " <>
               inspect(MapSet.to_list(enum)) <>
               "; expected: " <> inspect(MapSet.to_list(@expected_report_categories))
    end
  end

  # Bypass-based wire tests for the post-refactor error-formatting fixes:
  # the MCP layer must surface registry errors as readable strings (not
  # inspected struct dumps), and registry.probe must surface 412
  # POLICY_ACCEPTANCE_REQUIRED structurally so codex/porta can route into
  # the clickwrap UI without parsing strings.
  describe "registry MCP — error formatting + structured probe 412 (Bypass)" do
    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")

      on_exit(fn ->
        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_scheme,
          do: Application.put_env(:cyfr, :registry_scheme, original_scheme),
          else: Application.delete_env(:cyfr, :registry_scheme)
      end)

      {:ok, bypass: bypass}
    end

    test "registry.legal-version surfaces 503 errors as readable string (no inspected struct)",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect(bypass, "GET", "/v1/legal/version", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(503, ~s({"errors":[{"code":"UNAVAILABLE","message":"db down"}]}))
      end)

      assert {:error, msg} = MCP.handle("registry", ctx, %{"action" => "legal_version"})
      assert is_binary(msg)
      # Must NOT be an inspected struct dump.
      refute msg =~ "%Compendium.OCI.Errors{"
      # Must include the canonical "(HTTP 503, registry_unavailable)" suffix
      # produced by Errors.to_string/1.
      assert msg =~ "503"
      assert msg =~ "registry_unavailable"
    end

    test "registry.probe returns structured needs_policy_acceptance map on 412",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          412,
          Jason.encode!(%{
            "errors" => [%{"code" => "POLICY_ACCEPTANCE_REQUIRED", "message" => "accept v3"}],
            "required_version" => "v3"
          })
        )
      end)

      assert {:ok, body} =
               MCP.handle("registry", ctx, %{
                 "action" => "probe",
                 "provider" => "github",
                 "access_token" => "gho_x"
               })

      assert body["needs_policy_acceptance"] == true
      assert body["required_policy_version"] == "v3"
      assert body["needs_personal_namespace"] == false
    end

    test "registry.probe still surfaces non-policy 4xx errors as readable string",
         %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(403, ~s({"errors":[{"code":"IDENTITY_BANNED"}]}))
      end)

      assert {:error, msg} =
               MCP.handle("registry", ctx, %{
                 "action" => "probe",
                 "provider" => "github",
                 "access_token" => "gho_x"
               })

      assert is_binary(msg)
      refute msg =~ "%Compendium.OCI.Errors{"
      assert msg =~ "403"
    end
  end
end
