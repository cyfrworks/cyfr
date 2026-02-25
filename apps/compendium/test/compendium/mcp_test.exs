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

    # Point API URL at a non-routable address so cyfr.run fallback tests
    # don't hit the real API or timeout waiting.
    original_api_url = Application.get_env(:compendium, :cyfr_run_api_url)
    Application.put_env(:compendium, :cyfr_run_api_url, "http://127.0.0.1:19")

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
      if original_api_url,
        do: Application.put_env(:compendium, :cyfr_run_api_url, original_api_url),
        else: Application.delete_env(:compendium, :cyfr_run_api_url)
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

    test "Core edition inspect falls back to cyfr.run for missing component", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} = MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:cyfr.data-processor:1.0.0"
        })

        # Both local and cyfr.run fail — error should mention both and include reason detail
        assert msg =~ "not found locally or on cyfr.run"
        assert msg =~ "cyfr.run"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition inspect does not fall back to cyfr.run", %{ctx: ctx} do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        {:error, msg} = MCP.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "local.nonexistent:1.0.0"
        })

        # Arx should just say "not found" without mentioning cyfr.run
        assert msg =~ "not found"
        refute msg =~ "cyfr.run"
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "inspect"})
      assert msg =~ "Missing required"
    end

    test "inspect with latest reference resolves to semantic version", %{ctx: ctx} do
      {:ok, _component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "version-resolve",
        version: "2.3.4",
        type: "catalyst",
        description: "Test component for latest resolution"
      })

      # Reference without version defaults to "latest"
      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "inspect",
        "reference" => "c:local.version-resolve"
      })

      # component_ref must contain the resolved semver, not "latest"
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
          "reference" => "local.example-tool:1.0.0"
        })

      assert msg =~ "Cannot pull local components"
      assert msg =~ "cyfr register"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "pull"})
      assert msg =~ "Missing required"
    end

    test "Core edition rejects OCI pull from non-cyfr.run registry", %{ctx: ctx} do
      # Ensure Core edition (neither config key set to :arx)
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} =
          MCP.handle("component", ctx, %{
            "action" => "pull",
            "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
          })

        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition allows OCI pull from any registry", %{ctx: ctx} do
      # Set Arx edition via :sanctum_arx config (the arx_runtime.exs path)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        # This will fail at the network level, not at the registry check
        result = MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

        # Should NOT get the Core edition registry error
        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Core edition pull failure includes auth hint when anonymous", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        anonymous? = Compendium.OCI.Auth.resolve_credentials(Compendium.Edition.cyfr_run_registry()) == :anonymous

        {:error, msg} = MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "registry.cyfr.run/cyfr/reagents/test:1.0.0"
        })

        if anonymous? do
          # No credentials: error should include auth hint
          assert msg =~ "cyfr login"
          assert msg =~ "No credentials configured"
        else
          # Credentials present: pull fails with registry error (no auth hint appended)
          assert is_binary(msg)
        end
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end
  end

  # ============================================================================
  # Edition Detection
  # ============================================================================

  describe "edition detection" do
    test "detects Arx via :sanctum_arx config (arx_runtime.exs path)", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)

      # Only :sanctum_arx is set to :arx (the arx_runtime.exs path)
      Application.delete_env(:sanctum, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        # Arx user should be allowed to pull from ghcr.io
        result = MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "detects Arx via :sanctum config (CYFR_EDITION env var path)", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)

      # Only :sanctum is set to :arx (the CYFR_EDITION=arx path)
      Application.put_env(:sanctum, :edition, :arx)
      Application.delete_env(:sanctum_arx, :edition)

      try do
        result = MCP.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Core edition rejects discover with non-cyfr.run registry", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} = MCP.handle("component", ctx, %{
          "action" => "discover",
          "registry" => "ghcr.io"
        })

        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition allows discover with custom registry", %{ctx: ctx} do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        result = MCP.handle("component", ctx, %{
          "action" => "discover",
          "registry" => "ghcr.io"
        })

        # Should NOT get a Core edition error — Arx passes through the registry
        case result do
          {:error, msg} -> refute msg =~ "Core edition"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition defaults discover to registry.cyfr.run when no registry specified", %{ctx: ctx} do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        # Arx discover without explicit registry should NOT error with "Missing required argument"
        result = MCP.handle("component", ctx, %{
          "action" => "discover"
        })

        case result do
          {:error, msg} -> refute msg =~ "Missing required argument: registry"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "validate_registry_config! raises when Core edition has custom CYFR_RUN_API_URL" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      original_api_url = Application.get_env(:compendium, :cyfr_run_api_url)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)
      Application.put_env(:compendium, :cyfr_run_api_url, "https://internal.cyfr.local")

      try do
        assert_raise RuntimeError, ~r/API URL misconfiguration/, fn ->
          Compendium.Application.validate_registry_config!()
        end
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
        if original_api_url, do: Application.put_env(:compendium, :cyfr_run_api_url, original_api_url),
          else: Application.delete_env(:compendium, :cyfr_run_api_url)
      end
    end

    test "Core edition returns parse error for malformed OCI reference in pull", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        # "ghcr.io/" has a registry but no repository — triggers parse error
        {:error, msg} =
          MCP.handle("component", ctx, %{
            "action" => "pull",
            "reference" => "ghcr.io/"
          })

        assert msg =~ "Invalid OCI reference"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
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

    test "publishes to default registry when no artifact provided", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "publish",
          "reference" => "my-tool:1.0.0"
        })

      # With default registry, this attempts an OCI push which fails because the
      # component doesn't exist locally or credentials are missing
      assert msg =~ "Component not found locally" or msg =~ "No credentials found"
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

    test "Core edition rejects publish push to non-cyfr.run registry", %{ctx: ctx} do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} =
          MCP.handle("component", ctx, %{
            "action" => "publish",
            "reference" => "local.my-tool:1.0.0",
            "registry" => "ghcr.io"
          })

        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end
  end

  # ============================================================================
  # Component Tool - Register Action
  # ============================================================================

  describe "component tool - register action" do
    test "scans and returns summary with no args", %{ctx: _ctx} do
      {:ok, result} = MCP.handle("component", %Sanctum.Context{user_id: "test", org_id: "test"}, %{"action" => "register"})

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
    @dep_test_wasm (
      <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
      <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
      <<0x03, 0x02, 0x01, 0x00>> <>
      <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
      <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>
    )

    defp setup_dep_test_dir(test_dir, type, name, version, manifest) do
      comp_dir = Path.join([test_dir, "components", "#{type}s", "local", name, version])
      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "#{type}.wasm"), @dep_test_wasm)
      comp_dir
    end

    test "inspect component with no deps has no dependency fields", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "no-dep-reagent",
        version: "1.0.0",
        type: "reagent",
        description: "A reagent with no deps"
      })

      {:ok, result} = MCP.handle("component", ctx, %{
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
      cat_dir = setup_dep_test_dir(test_dir, "catalyst", "inspect-dep-cat", "0.1.0", %{
        "type" => "catalyst",
        "version" => "0.1.0",
        "description" => "A dependency catalyst"
      })
      {:ok, _} = Registry.register_from_directory(ctx, cat_dir)

      # Register a formula that depends on the catalyst
      formula_dir = setup_dep_test_dir(test_dir, "formula", "inspect-dep-formula", "0.1.0", %{
        "type" => "formula",
        "version" => "0.1.0",
        "description" => "A formula with deps",
        "dependencies" => %{
          "static" => [
            %{"ref" => "catalyst:local.inspect-dep-cat:0.1.0", "optional" => false, "reason" => "Required"}
          ]
        }
      })
      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "inspect",
        "reference" => "formula:local.inspect-dep-formula:0.1.0"
      })

      assert result["all_satisfied"] == true
      assert is_list(result["dependencies"])
      assert result["missing"] == []
      assert result["has_dynamic"] == false
    end

    test "inspect formula with missing required deps", %{ctx: ctx, test_dir: test_dir} do
      formula_dir = setup_dep_test_dir(test_dir, "formula", "inspect-missing-dep", "0.1.0", %{
        "type" => "formula",
        "version" => "0.1.0",
        "description" => "Formula with missing dep",
        "dependencies" => %{
          "static" => [
            %{"ref" => "catalyst:local.nonexistent-inspect:0.1.0", "optional" => false, "reason" => "Missing"}
          ]
        }
      })
      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "inspect",
        "reference" => "formula:local.inspect-missing-dep:0.1.0"
      })

      assert result["all_satisfied"] == false
      assert "catalyst:local.nonexistent-inspect:0.1.0" in result["missing"]
    end

    test "inspect formula with dynamic deps", %{ctx: ctx, test_dir: test_dir} do
      formula_dir = setup_dep_test_dir(test_dir, "formula", "inspect-dynamic-dep", "0.1.0", %{
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

      {:ok, result} = MCP.handle("component", ctx, %{
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
    @setup_plan_wasm (
      <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
      <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
      <<0x03, 0x02, 0x01, 0x00>> <>
      <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
      <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>
    )

    defp setup_plan_component(test_dir, type, name, version, manifest) do
      comp_dir = Path.join([test_dir, "components", "#{type}s", "local", name, version])
      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "#{type}.wasm"), @setup_plan_wasm)
      comp_dir
    end

    test "returns setup plan for a catalyst with secrets", %{ctx: ctx, test_dir: test_dir} do
      comp_dir = setup_plan_component(test_dir, "catalyst", "setup-claude", "0.2.0", %{
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

      {:ok, result} = MCP.handle("component", ctx, %{
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
      comp_dir = setup_plan_component(test_dir, "catalyst", "setup-web", "0.2.0", %{
        "type" => "catalyst",
        "version" => "0.2.0",
        "description" => "Web catalyst with no setup block"
      })
      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "setup_plan",
        "reference" => "catalyst:local.setup-web:0.2.0"
      })

      assert result.component_ref =~ "setup-web"
      assert result.secrets == []
    end

    test "returns setup plan for a formula with dependencies", %{ctx: ctx, test_dir: test_dir} do
      # Register the dependency catalyst first
      cat_dir = setup_plan_component(test_dir, "catalyst", "dep-for-formula", "0.2.0", %{
        "type" => "catalyst",
        "version" => "0.2.0",
        "description" => "Dependency catalyst"
      })
      {:ok, _} = Registry.register_from_directory(ctx, cat_dir)

      formula_dir = setup_plan_component(test_dir, "formula", "setup-formula", "0.2.0", %{
        "type" => "formula",
        "version" => "0.2.0",
        "description" => "Formula with dependencies",
        "dependencies" => %{
          "static" => [
            %{"ref" => "catalyst:local.dep-for-formula:0.2.0", "optional" => false, "reason" => "Required"}
          ]
        }
      })
      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:ok, result} = MCP.handle("component", ctx, %{
        "action" => "setup_plan",
        "reference" => "formula:local.setup-formula:0.2.0"
      })

      assert result.component_ref =~ "setup-formula"
      assert is_list(result.dependencies)
      assert length(result.dependencies) > 0
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "setup_plan"})
      assert msg =~ "Missing required argument: reference"
    end

    test "returns error for nonexistent component", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{
        "action" => "setup_plan",
        "reference" => "catalyst:local.nonexistent:99.0.0"
      })
      assert msg =~ "not found" or msg =~ "Component"
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
    test "readme reads from Arca after register", %{ctx: ctx, test_dir: test_dir} do
      # Create a component directory with a README
      comp_dir = Path.join([test_dir, "components", "catalysts", "local", "guide-test", "1.0.0"])
      File.mkdir_p!(comp_dir)

      readme_content = "# Guide Test Component\n\nThis is the guide test README."
      manifest = %{"type" => "catalyst", "version" => "1.0.0", "name" => "guide-test"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), readme_content)

      # Register the component (copies README to Arca)
      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Now the guide readme handler should read from Arca
      {:ok, result} = MCP.handle("guide", ctx, %{
        "action" => "readme",
        "reference" => "c:local.guide-test:1.0.0"
      })

      assert result.format == "markdown"
      assert result.content == readme_content
      assert result.reference == "c:local.guide-test:1.0.0"
    end

    test "readme returns error when component exists but has no README", %{ctx: ctx, test_dir: test_dir} do
      # Create a component without README
      comp_dir = Path.join([test_dir, "components", "reagents", "local", "no-readme", "1.0.0"])
      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "1.0.0", "name" => "no-readme"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:error, msg} = MCP.handle("guide", ctx, %{
        "action" => "readme",
        "reference" => "r:local.no-readme:1.0.0"
      })

      assert msg =~ "No README.md found"
    end

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
  # Auto-pull Dependencies
  # ============================================================================

  describe "component tool - pull with dependency auto-pull" do
    # Valid minimal WASM with export section (same as module attribute)
    @auto_pull_wasm (
      <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
      <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
      <<0x03, 0x02, 0x01, 0x00>> <>
      <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
      <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>
    )

    defp setup_component_dir(test_dir, type, name, version, manifest) do
      comp_dir = Path.join([test_dir, "components", "#{type}s", "local", name, version])
      File.mkdir_p!(comp_dir)

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      wasm_filename = "#{type}.wasm"
      File.write!(Path.join(comp_dir, wasm_filename), @auto_pull_wasm)

      comp_dir
    end

    test "rejects pull of local formula", %{ctx: ctx, test_dir: test_dir} do
      formula_dir = setup_component_dir(test_dir, "formula", "test-formula", "0.1.0", %{
        "type" => "formula",
        "version" => "0.1.0",
        "description" => "A test formula"
      })
      {:ok, _} = Registry.register_from_directory(ctx, formula_dir)

      {:error, msg} = MCP.handle("component", ctx, %{
        "action" => "pull",
        "reference" => "formula:local.test-formula:0.1.0"
      })

      assert msg =~ "Cannot pull local components"
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
