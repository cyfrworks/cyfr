defmodule Compendium.MCPTest do
  use ExUnit.Case, async: false

  alias Compendium.{MCP, Registry}
  alias Sanctum.Context

  # Valid minimal WASM with export section
  @valid_wasm (
    <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
    <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
    <<0x03, 0x02, 0x01, 0x00>> <>
    <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
    <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>
  )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:arca, :base_path, test_dir)

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: ctx, test_dir: test_dir}
  end

  # ============================================================================
  # Resource Discovery
  # ============================================================================

  describe "resources/0" do
    test "returns component and asset resources" do
      resources = MCP.resources()
      assert length(resources) == 2

      uris = Enum.map(resources, & &1.uri)
      assert "compendium://components/{reference}" in uris
      assert "compendium://assets/{reference}/{path}" in uris
    end

    test "resources have required fields" do
      resources = MCP.resources()

      for resource <- resources do
        assert is_binary(resource.uri)
        assert is_binary(resource.name)
        assert is_binary(resource.description)
        assert is_binary(resource.mimeType)
      end
    end
  end

  describe "read/2" do
    test "reads component metadata resource", %{ctx: ctx} do
      {:ok, _component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "read-test",
        version: "1.0.0",
        type: "reagent",
        description: "A test component for read"
      })

      {:ok, result} = MCP.read(ctx, "compendium://components/local.read-test:1.0.0")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert content["name"] == "read-test"
      assert content["version"] == "1.0.0"
      assert content["publisher"] == "local"
      assert is_binary(content["digest"])
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "compendium://components/local.nonexistent:1.0.0")
      assert msg =~ "not found"
    end

    test "reads asset from component directory", %{ctx: ctx, test_dir: test_dir} do
      {:ok, _component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "asset-test",
        version: "1.0.0",
        type: "reagent"
      })

      # Write an asset file into the component's storage directory
      asset_dir = Path.join([test_dir, "components", "reagents", "local", "asset-test", "1.0.0"])
      File.mkdir_p!(asset_dir)
      asset_content = ~s({"key": "value"})
      File.write!(Path.join(asset_dir, "config.json"), asset_content)

      {:ok, result} = MCP.read(ctx, "compendium://assets/r:local.asset-test:1.0.0/config.json")
      assert result.mimeType == "application/octet-stream"
      assert Base.decode64!(result.content) == asset_content
    end

    test "returns error for non-existent asset", %{ctx: ctx} do
      {:error, msg} = MCP.read(ctx, "compendium://assets/r:local.nocomp:1.0.0/missing.txt")
      assert msg =~ "Asset not found"
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
    test "returns 2 action-based tools" do
      tools = MCP.tools()
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1.name)
      assert "component" in tool_names
      assert "guide" in tool_names
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
      assert "publish" in actions
      assert "register" in actions
      assert "resolve" in actions
      assert "categories" in actions
      assert "get_blob" in actions
    end

    test "component tool has type filter enum" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      type_schema = tool.input_schema["properties"]["type"]

      assert type_schema["type"] == "string"
      assert "catalyst" in type_schema["enum"]
      assert "reagent" in type_schema["enum"]
      assert "formula" in type_schema["enum"]
    end

    test "component tool has visibility enum" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      visibility_schema = tool.input_schema["properties"]["visibility"]

      assert visibility_schema["type"] == "string"
      assert "local" in visibility_schema["enum"]
      assert "private" in visibility_schema["enum"]
      assert "public" in visibility_schema["enum"]
    end

    test "component tool has artifact schema" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      artifact_schema = tool.input_schema["properties"]["artifact"]

      assert artifact_schema["type"] == "object"
      assert is_list(artifact_schema["oneOf"])
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
      {:ok, _component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "ref-test",
        version: "1.0.0",
        type: "reagent",
        description: "Test component for ref"
      })

      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "inspect",
        "reference" => "local.ref-test:1.0.0"
      })

      assert result["component_ref"] == "reagent:local.ref-test:1.0.0"
    end

    test "inspect response includes typed component_ref from reference", %{ctx: ctx} do
      {:ok, _component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "typed-ref-test",
        version: "1.0.0",
        type: "catalyst",
        description: "Test component for typed ref"
      })

      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "inspect",
        "reference" => "catalyst:local.typed-ref-test:1.0.0"
      })

      assert result["component_ref"] == "catalyst:local.typed-ref-test:1.0.0"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "local.example-tool:1.0.0"
        })

      assert msg =~ "not found"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "inspect"})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Component Tool - Pull Action
  # ============================================================================

  describe "component tool - pull action" do
    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "local.example-tool:1.0.0"
        })

      assert msg =~ "not found"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "pull"})
      assert msg =~ "Missing required"
    end
  end

  # ============================================================================
  # Component Tool - Publish Action
  # ============================================================================

  describe "component tool - publish action" do
    test "returns error for non-existent artifact file", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "publish",
          "artifact" => %{"path" => "/nonexistent/file.wasm"},
          "reference" => "my-tool:1.0.0"
        })

      assert is_binary(msg)
    end

    test "returns error for invalid version format", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "publish",
          "artifact" => %{"base64" => Base.encode64("fake")},
          "reference" => "my-tool:1.0",
          "type" => "reagent"
        })

      assert msg =~ "Invalid version" or msg =~ "semver"
    end

    test "returns error for missing artifact", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "publish",
          "reference" => "my-tool:1.0.0"
        })

      assert msg =~ "Missing required" and msg =~ "artifact"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "publish",
          "artifact" => %{"base64" => Base.encode64("fake")}
        })

      assert msg =~ "Missing required" and msg =~ "reference"
    end

    test "returns error for missing type", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "publish",
          "artifact" => %{"base64" => Base.encode64("fake")},
          "reference" => "my-tool:1.0.0"
        })

      assert msg =~ "Missing required" and msg =~ "type"
    end
  end

  # ============================================================================
  # Component Tool - Register Action
  # ============================================================================

  describe "component tool - register action" do
    test "returns error for missing directory", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "register"})
      assert msg =~ "Missing required"
    end

    test "returns error for non-existent directory", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{
        "action" => "register",
        "directory" => "/nonexistent/path/to/component"
      })

      assert is_binary(msg)
    end

    test "rejects non-local publisher namespace", %{ctx: ctx} do
      # Create a temp dir that looks like a stripe publisher component
      tmp = Path.join(System.tmp_dir!(), "cyfr_mcp_register_test_#{:rand.uniform(100_000)}")
      comp_dir = Path.join([tmp, "components", "catalysts", "stripe", "pay", "1.0.0"])
      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>)

      {:error, msg} = MCP.handle("component", ctx, %{
        "action" => "register",
        "directory" => comp_dir
      })

      assert msg =~ "rejected" or msg =~ "namespace"
      File.rm_rf!(tmp)
    end

    test "has directory property in tool schema" do
      tool = Enum.find(MCP.tools(), &(&1.name == "component"))
      dir_schema = tool.input_schema["properties"]["directory"]

      assert dir_schema["type"] == "string"
      assert dir_schema["description"] =~ "register"
    end
  end

  # ============================================================================
  # Component Tool - Resolve Action
  # ============================================================================

  describe "component tool - resolve action" do
    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "resolve",
          "reference" => "local.example-tool:1.0.0"
        })

      assert msg =~ "not found"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "resolve"})
      assert msg =~ "Missing required"
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

  describe "guide tool - list action" do
    test "list returns available guides", %{ctx: ctx} do
      {:ok, result} = MCP.handle("guide", ctx, %{"action" => "list"})

      assert result.count == 2
      assert length(result.guides) == 2

      names = Enum.map(result.guides, & &1.name)
      assert "component-guide" in names
      assert "integration-guide" in names
    end

    test "guides have title and description", %{ctx: ctx} do
      {:ok, result} = MCP.handle("guide", ctx, %{"action" => "list"})

      for guide <- result.guides do
        assert is_binary(guide.name)
        assert is_binary(guide.title)
        assert is_binary(guide.description)
      end
    end
  end

  describe "guide tool - get action" do
    test "get component-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("guide", ctx, %{"action" => "get", "name" => "component-guide"})

      assert result.name == "component-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Component Guide"
    end

    test "get integration-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("guide", ctx, %{"action" => "get", "name" => "integration-guide"})

      assert result.name == "integration-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Integration Guide"
    end

    test "get with unknown name returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("guide", ctx, %{"action" => "get", "name" => "nonexistent"})

      assert msg =~ "Unknown guide"
      assert msg =~ "nonexistent"
    end

    test "get without name returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("guide", ctx, %{"action" => "get"})
      assert msg =~ "Missing required"
    end
  end

  describe "guide tool - readme action" do
    test "readme with missing README returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("guide", ctx, %{
          "action" => "readme",
          "reference" => "c:local.nonexistent:1.0.0"
        })

      assert msg =~ "No README.md found" or msg =~ "not found"
    end

    test "readme without reference returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("guide", ctx, %{"action" => "readme"})
      assert msg =~ "Missing required"
    end

    test "readme with invalid reference returns error", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("guide", ctx, %{"action" => "readme", "reference" => ""})

      assert msg =~ "Invalid reference" or msg =~ "empty"
    end
  end

  describe "guide tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("guide", ctx, %{"action" => "invalid"})
      assert msg =~ "Invalid guide action"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = MCP.handle("guide", ctx, %{})
      assert msg =~ "Invalid guide action" or msg =~ "Missing required"
    end
  end

  describe "guide tool - schema" do
    test "guide tool has required schema fields" do
      tool = Enum.find(MCP.tools(), &(&1.name == "guide"))

      assert tool.name == "guide"
      assert is_binary(tool.title)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
      assert tool.input_schema["type"] == "object"
      assert "action" in tool.input_schema["required"]
    end

    test "guide tool has correct actions" do
      tool = Enum.find(MCP.tools(), &(&1.name == "guide"))
      actions = tool.input_schema["properties"]["action"]["enum"]

      assert "list" in actions
      assert "get" in actions
      assert "readme" in actions
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
end
