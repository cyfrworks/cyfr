# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProviderTest do
  use ExUnit.Case, async: false

  alias Compendium.Provider
  alias Compendium.Registry
  alias Sanctum.Context

  # Valid minimal WASM with export section
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  # The athanor's own AQUA definitions live under its tenant storage —
  # v3 agent files that shadow the throwaway seed's per-file, so these
  # tests read exactly this fixture whatever the shipped template says.
  # Written through the facade so each shadowing write records its origin
  # — the fixture IS an edit of the shipped template, not the athanor's
  # own work.
  defp setup_aqua_dir do
    write = fn name, attrs, prompt ->
      agent =
        Map.merge(
          %{
            name: name,
            title: name,
            description: "",
            disabled: false,
            catalyst_ref: nil,
            model: nil,
            tool_policy: %{},
            prompt: prompt
          },
          attrs
        )

      :ok =
        Arca.put(
          Sanctum.Context.actor(Sanctum.TestContext.local()),
          Compendium.AquaPath.agent_file(name),
          Compendium.AquaAgent.serialize(agent)
        )
    end

    write.(
      "aqua",
      %{
        title: "A.Q.U.A.",
        catalyst_ref: "catalyst:moonmoon69.claude",
        model: "claude-opus-4-6"
      },
      "# A.Q.U.A.\n\nYou are A.Q.U.A."
    )

    write.(
      "builder",
      %{
        title: "Builder",
        description: "WASM component builder sub-agent prompt",
        tool_policy: %{"component.list" => "auto", "build.compile" => "auto"}
      },
      "# Builder Agent\n\nYou are the Builder."
    )

    write.(
      "artisan",
      %{
        title: "Artisan",
        description: "Tincture app/dashboard sub-agent prompt",
        tool_policy: %{"files.read" => "auto", "storage.get" => "auto"}
      },
      "# Artisan Agent\n\nYou are the Artisan."
    )

    write.(
      "explorer",
      %{
        title: "Explorer",
        description: "Research and web search sub-agent prompt",
        tool_policy: %{"native_search" => "auto"}
      },
      "# Explorer Agent\n\nYou are the Explorer."
    )

    write.(
      "planner",
      %{title: "Planner", description: "Planning and analysis sub-agent prompt"},
      "# Planner Agent\n\nYou are the Planner."
    )

    write.(
      "web",
      %{
        title: "Web",
        description: "HTTP interaction sub-agent prompt",
        tool_policy: %{"http.get" => "auto"}
      },
      "# Web Agent\n\nYou are the Web agent."
    )
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    original_base_path = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    # The estate holds the shipped tree, as a fill leaves it; the fixture
    # then edits every shipped agent.
    :ok = Sanctum.TestContext.shipped!(Sanctum.TestContext.athanor_id())
    setup_aqua_dir()

    # Point API URL at a non-routable address so cyfr.run fallback tests
    # don't hit the real API or timeout waiting.
    # Client.ex prepends "https://", so we set the bare host:port here.
    original_registry_url = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Application.put_env(:arca, :base_path, original_base_path)

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
      resources = Provider.resources()
      assert resources == []
    end
  end

  describe "resource_templates/0" do
    test "returns component and asset resource templates" do
      templates = Provider.resource_templates()
      assert length(templates) == 2

      uris = Enum.map(templates, & &1.uriTemplate)
      assert "compendium://components/{reference}" in uris
      assert "compendium://assets/{reference}/{path}" in uris
    end
  end

  # A resource read is the declared `component.read_resource`, admitted by
  # the gate like any other call.
  defp read(ctx, uri),
    do:
      Grimoire.Catalog.call_external("component", ctx, %{
        "action" => "read_resource",
        "uri" => uri
      })

  describe "component.read_resource" do
    test "reads component metadata resource", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "read-test",
          version: "1.0.0",
          type: "reagent",
          description: "A test component for read"
        })

      {:ok, result} = read(ctx, "compendium://components/r:local.read-test:1.0.0")
      assert result.mimeType == "application/json"

      content = Jason.decode!(result.content)
      assert content["name"] == "read-test"
      assert content["version"] == "1.0.0"
      assert content["publisher"] == "local"
      assert is_binary(content["digest"])
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} = read(ctx, "compendium://components/r:local.nonexistent:1.0.0")
      assert err_msg(msg) =~ "not found"
    end

    test "refuses anonymous reads before tenant resolution", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "anon-read",
          version: "1.0.0",
          type: "reagent",
          description: "must not be readable anonymously"
        })

      # An unauthenticated context carries no athanor and must not read this
      # athanor's data by exact reference. Same shape the Authenticate plug
      # mints for a no-credential request.
      anon =
        Sanctum.Context.build(
          user_id: nil,
          athanor_id: nil,
          permissions: [],
          scope: :athanor,
          auth_method: nil,
          authenticated: false
        )

      # Refused at the gate, before any tenant resolution or read.
      assert {:error, {:tool_auth_required, "component"} = msg} =
               read(anon, "compendium://components/r:local.anon-read:1.0.0")

      assert err_msg(msg) =~ "requires authentication"

      assert {:error, {:tool_auth_required, "component"}} =
               read(anon, "compendium://assets/r:local.anon-read:1.0.0/README.md")
    end

    test "reads asset from component directory", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "asset-test",
          version: "1.0.0",
          type: "reagent"
        })

      # Write an asset file into the component's storage directory
      asset_dir =
        Arca.Adapters.Local.build_path(
          Sanctum.Context.actor(ctx),
          ["components", "reagents", "local", "asset-test", "1.0.0"]
        )

      File.mkdir_p!(asset_dir)
      asset_content = ~s({"key": "value"})
      File.write!(Path.join(asset_dir, "config.json"), asset_content)

      {:ok, result} = read(ctx, "compendium://assets/r:local.asset-test:1.0.0/config.json")
      assert result.mimeType == "application/octet-stream"
      assert Base.decode64!(result.content) == asset_content
    end

    test "returns error for non-existent asset", %{ctx: ctx} do
      {:error, msg} = read(ctx, "compendium://assets/r:local.nocomp:1.0.0/missing.txt")
      assert err_msg(msg) =~ "not found"
    end

    test "a hostile asset path is a typed refusal, never a raise", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "asset-guard",
          version: "1.0.0",
          type: "reagent"
        })

      for hostile <- [
            "..%2F..%2Fetc%2Fpasswd",
            "../../../etc/passwd",
            "%2e%2e/%2e%2e/secret",
            "a\\b",
            String.duplicate("a", 300)
          ] do
        assert {:error, msg} =
                 read(ctx, "compendium://assets/r:local.asset-guard:1.0.0/#{hostile}")

        assert err_msg(msg) =~ "Invalid asset path"
      end

      # A path of only empty segments refuses as empty, not as a read.
      assert {:error, msg} = read(ctx, "compendium://assets/r:local.asset-guard:1.0.0///")
      assert err_msg(msg) =~ "Invalid asset path"
    end

    test "returns error for unknown resource", %{ctx: ctx} do
      {:error, {:invalid_argument, msg}} = read(ctx, "compendium://unknown")
      assert msg =~ "Unknown resource"
    end

    test "requires :component_read, and a storage key does not have it", %{ctx: ctx} do
      {:ok, _component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "perm-read",
          version: "1.0.0",
          type: "reagent"
        })

      uri = "compendium://components/r:local.perm-read:1.0.0"

      key = fn permissions ->
        %{ctx | auth_method: :api_key, permissions: MapSet.new(permissions)}
      end

      assert {:ok, _} = read(key.([:component_read]), uri)

      assert {:error, {:missing_permission, :component_read}} =
               read(key.([:storage_read]), uri)
    end
  end

  # ============================================================================
  # Tool Discovery
  # ============================================================================

  describe "tools/0" do
    test "returns action-based tools: component, aqua, registry" do
      tools = Provider.tools()
      assert length(tools) == 3

      tool_names = Enum.map(tools, & &1.name)
      assert "component" in tool_names
      assert "aqua" in tool_names
      assert "registry" in tool_names
    end

    test "tool has required schema fields" do
      tool = Enum.find(Provider.tools(), &(&1.name == "component"))

      assert is_binary(tool.name)
      assert tool.name == "component"
      assert is_binary(tool.title)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
      assert tool.input_schema["type"] == "object"
      assert "action" in tool.input_schema["required"]
    end

    test "component tool has correct actions" do
      tool = Enum.find(Provider.tools(), &(&1.name == "component"))
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
      tool = Enum.find(Provider.tools(), &(&1.name == "component"))
      type_schema = action_schema(tool, "search")["properties"]["type"]

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
        Provider.handle("component", ctx, %{
          "action" => "search",
          "query" => "data processing"
        })

      assert result.components == []
      assert result.total == 0
    end

    test "accepts filter parameters", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("component", ctx, %{
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
        Provider.handle("component", ctx, %{
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
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "catalyst:local.typed-ref-test:1.0.0"
        })

      assert result["component_ref"] == "catalyst:local.typed-ref-test:1.0.0"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.example-tool:1.0.0"
        })

      assert err_msg(msg) =~ "not found"
    end

    test "inspect returns not-found without cyfr.run fallback", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:cyfr.data-processor:1.0.0"
        })

      assert err_msg(msg) =~ "not found"
      refute err_msg(msg) =~ "cyfr.run"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{"action" => "inspect"})
      assert err_msg(msg) =~ "Missing required"
    end

    test "inspect with version-less ref to nonexistent component returns error", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.nonexistent-component"
        })

      assert err_msg(msg) =~ "nonexistent-component"
    end

    test "inspect with pinned ref to nonexistent component falls through to not-found", %{
      ctx: ctx
    } do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.nonexistent-component:1.0.0"
        })

      assert err_msg(msg) =~ "not found" or err_msg(msg) =~ "Component not found"
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
        Provider.handle("component", ctx, %{
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
    test "rejects pull of a local component the server does not ship", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "c:local.example-tool:1.0.0"
        })

      assert err_msg(msg) =~ "not a version the server ships"
      assert err_msg(msg) =~ "cyfr register"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{"action" => "pull"})
      assert err_msg(msg) =~ "Missing required"
    end

    test "rejects an OCI pull from a non-configured registry host", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

      assert err_msg(msg) =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert err_msg(msg) =~ "ghcr.io"
    end

    test "single-user pull failure returns a binary error with the reference", %{ctx: ctx} do
      # An unreachable registry must return a clean pull error.
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "#{Compendium.RegistryHost.canonical_host()}/cyfr/reagents/test:1.0.0"
        })

      assert is_binary(msg)
    end

    @tag :capture_log
    test "a push token that does not open refuses the pull rather than going anonymous",
         %{ctx: ctx} do
      registry = Compendium.RegistryHost.canonical_host()
      aad = Sanctum.CipherAAD.registry_token(ctx.user_id, registry, "cyfr")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt(~s({"type":"push_token","token":""}), aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: ctx.user_id,
          registry: registry,
          namespace_slug: "cyfr",
          credential_ciphertext: ciphertext
        })

      assert {:error, {:invalid_argument, _} = reason} =
               Provider.handle("component", ctx, %{
                 "action" => "pull",
                 "reference" => "#{registry}/cyfr/reagents/test:1.0.0"
               })

      assert err_msg(reason) ==
               "The push token stored for namespace 'cyfr' could not be opened — " <>
                 "sign in again to re-mint it"
    end

    @tag :capture_log
    test "a credential store that cannot answer refuses the pull rather than going anonymous",
         %{ctx: ctx} do
      Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

      assert {:error, {:unavailable, "Your registry credential"} = reason} =
               Provider.handle("component", ctx, %{
                 "action" => "pull",
                 "reference" =>
                   "#{Compendium.RegistryHost.canonical_host()}/cyfr/reagents/test:1.0.0"
               })

      assert err_msg(reason) == "Your registry credential is unavailable — retry shortly"
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
        Provider.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/alice/reagents/data-processor:1.0.0"
        })

      assert err_msg(msg) =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert err_msg(msg) =~ "ghcr.io"
    end

    test "rejects discover against a non-configured registry host", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "discover",
          "registry" => "ghcr.io"
        })

      assert err_msg(msg) =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert err_msg(msg) =~ "ghcr.io"
    end

    test "discover with no registry argument uses the configured registry", %{ctx: ctx} do
      result =
        Provider.handle("component", ctx, %{
          "action" => "discover"
        })

      case result do
        {:error, msg} -> refute err_msg(msg) =~ "Missing required argument: registry"
        {:ok, _} -> :ok
      end
    end

    test "returns a parse error for a malformed OCI reference in pull", %{ctx: ctx} do
      # "ghcr.io/" has a registry but no repository — triggers parse error
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "ghcr.io/"
        })

      assert err_msg(msg) =~ "Invalid OCI reference"
    end
  end

  # ============================================================================
  # Component Tool - Push Action
  # ============================================================================

  describe "component tool - push action" do
    test "rejects push of a non-local namespace to a registry", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:stripe.stripe:1.0.0"
        })

      assert err_msg(msg) =~ "Only components in the local namespace"
      assert err_msg(msg) =~ "namespace 'stripe'"
    end

    test "returns error when the version is missing", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool"
        })

      assert err_msg(msg) =~ "Version is required"
    end

    test "push of a local component without a claimed namespace asks the user to claim one",
         %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool:1.0.0"
        })

      # A local publish requires a claimed personal namespace; the error must explain that requirement.
      refute err_msg(msg) =~ "No push token for namespace 'local'"
      assert err_msg(msg) =~ "personal namespace"
      assert err_msg(msg) =~ "cyfr login"
    end

    test "push of a local component resolves the caller's claimed personal namespace",
         %{ctx: ctx} do
      # A claimed namespace is on the users row; the push token beside it.
      {ctx, user} = Sanctum.TestContext.person!(ctx, %{email: "testns@example.com"})
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, "testns")

      :ok =
        Registry.CredentialStore.put_push_token(
          ctx,
          Compendium.RegistryHost.canonical_host(),
          "testns",
          "cyfr_pt_test",
          "personal"
        )

      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool:1.0.0"
        })

      # Resolution succeeded (no claim/credential error); the push then fails only
      # because the local component itself was never built in this test.
      refute err_msg(msg) =~ "personal namespace"
      refute err_msg(msg) =~ "No push token"
      assert err_msg(msg) =~ "Component not found locally"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "push"
        })

      assert err_msg(msg) =~ "Missing required" and err_msg(msg) =~ "reference"
    end

    test "rejects a push to a non-cyfr.run registry", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "push",
          "reference" => "c:local.my-tool:1.0.0",
          "registry" => "ghcr.io"
        })

      assert err_msg(msg) =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert err_msg(msg) =~ "ghcr.io"
    end
  end

  # ============================================================================
  # Component Tool - Register Action
  # ============================================================================

  describe "component tool - register action" do
    test "scans and returns summary with no args", %{ctx: _ctx} do
      {:ok, result} =
        Provider.handle(
          "component",
          %Sanctum.Context{
            user_id: "test",
            athanor_id: "ath_test",
            scope: :athanor,
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
      tool = Enum.find(Provider.tools(), &(&1.name == "component"))
      # The schema does not accept a directory property.
      refute Map.has_key?(action_schema(tool, "register")["properties"], "directory")
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

    defp setup_dep_test_dir(_test_dir, type, name, version, manifest) do
      segments = ["components", "#{type}s", "local", name, version]

      comp_dir =
        Arca.Adapters.Local.build_path(
          Sanctum.Context.actor(Sanctum.TestContext.local()),
          segments
        )

      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "#{type}.wasm"), @dep_test_wasm)
      segments
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
        Provider.handle("component", ctx, %{
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

      {:ok, _} = Registry.register_from_arca(ctx, cat_dir)

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

      {:ok, _} = Registry.register_from_arca(ctx, formula_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
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

      {:ok, _} = Registry.register_from_arca(ctx, formula_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
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

      {:ok, _} = Registry.register_from_arca(ctx, formula_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
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
      {:ok, result} = Provider.handle("component", ctx, %{"action" => "categories"})

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
      {:ok, result} = Provider.handle("component", ctx, %{"action" => "categories"})

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
        Provider.handle("component", ctx, %{
          "action" => "get_blob",
          "digest" => "sha256:nonexistent"
        })

      assert err_msg(msg) =~ "not found" or err_msg(msg) =~ "Blob"
    end

    test "returns error for missing digest", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{"action" => "get_blob"})
      assert err_msg(msg) =~ "Missing required" or err_msg(msg) =~ "digest"
    end

    test "has digest property in tool schema" do
      tool = Enum.find(Provider.tools(), &(&1.name == "component"))
      digest_schema = action_schema(tool, "get_blob")["properties"]["digest"]

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

    defp setup_plan_component(_test_dir, type, name, version, manifest) do
      segments = ["components", "#{type}s", "local", name, version]

      comp_dir =
        Arca.Adapters.Local.build_path(
          Sanctum.Context.actor(Sanctum.TestContext.local()),
          segments
        )

      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "#{type}.wasm"), @setup_plan_wasm)
      segments
    end

    test "returns setup plan for a catalyst with declared needs", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "setup-claude", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Claude catalyst for setup plan test",
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:anthropic.com",
              "reason" => "to call the Anthropic API with your key",
              "fields" => ["ANTHROPIC_API_KEY"],
              "required" => true
            }
          }
        })

      {:ok, _} = Registry.register_from_arca(ctx, comp_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.setup-claude:0.2.0"
        })

      assert result.component_ref =~ "setup-claude"
      assert result.type in ["catalyst", :catalyst]

      assert [need] = result.needs
      assert need.name == "api_key"
      assert need.kind == "api_key"
      assert need.qualifier == "anthropic.com"
      assert need.required == true
      assert need.reason =~ "Anthropic"

      # No profile yet: a required need means the consent walk is pending.
      assert result.consent == nil
      assert result.ready == false
      assert is_list(result.dependencies)
    end

    test "a component with no needs and no profile is ready", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "setup-web", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Web catalyst with no needs block"
        })

      {:ok, _} = Registry.register_from_arca(ctx, comp_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.setup-web:0.2.0"
        })

      assert result.component_ref =~ "setup-web"
      assert result.needs == []
      assert result.consent == nil
      assert result.ready == true
    end

    test "returns setup plan for a formula with dependencies", %{ctx: ctx, test_dir: test_dir} do
      # Register the dependency catalyst first
      cat_dir =
        setup_plan_component(test_dir, "catalyst", "dep-for-formula", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Dependency catalyst"
        })

      {:ok, _} = Registry.register_from_arca(ctx, cat_dir)

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

      {:ok, _} = Registry.register_from_arca(ctx, formula_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "formula:local.setup-formula:0.2.0"
        })

      assert result.component_ref =~ "setup-formula"
      assert is_list(result.dependencies)
      assert result.dependencies != []
    end

    test "an optional need leaves the plan ready", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        setup_plan_component(test_dir, "catalyst", "ready-opt", "0.2.0", %{
          "type" => "catalyst",
          "version" => "0.2.0",
          "description" => "Readiness test (optional need)",
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:example.com",
              "reason" => "optional enrichment",
              "required" => false
            }
          }
        })

      {:ok, _} = Registry.register_from_arca(ctx, comp_dir)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.ready-opt:0.2.0"
        })

      assert [%{required: false}] = result.needs
      assert result.ready == true
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{"action" => "setup_plan"})
      assert err_msg(msg) =~ "Missing required argument: reference"
    end

    test "returns error for nonexistent component", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "setup_plan",
          "reference" => "catalyst:local.nonexistent:99.0.0"
        })

      assert err_msg(msg) =~ "not found" or err_msg(msg) =~ "Component"
    end
  end

  # ============================================================================
  # Component Tool - List Action
  # ============================================================================

  describe "component tool - list action" do
    test "list returns empty results for empty registry", %{ctx: ctx} do
      {:ok, result} = Provider.handle("component", ctx, %{"action" => "list"})

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

      {:ok, result} = Provider.handle("component", ctx, %{"action" => "list"})

      assert result.total >= 2
      names = Enum.map(result.components, &(&1[:name] || &1["name"]))
      assert "list-test-a" in names
      assert "list-test-b" in names

      # Every listed row carries its provenance and update facts — the
      # one data path the Components page consumes.
      for comp <- result.components do
        assert comp[:provenance] in ["bundled", "user", "remote"]
        assert is_boolean(comp[:superseded])
        assert is_boolean(comp[:upstream_superseded])
      end
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
        Provider.handle("component", ctx, %{
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

      {:ok, result} = Provider.handle("component", ctx, %{"action" => "list"})

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
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.remove-test:1.0.0"
        })

      # Remove it
      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "r:local.remove-test:1.0.0"
        })

      assert result.status == "deleted"
      assert result.reference == "r:local.remove-test:1.0.0"

      # Verify it's gone
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.remove-test:1.0.0"
        })

      assert err_msg(msg) =~ "not found"
    end

    test "removes a filesystem component", %{ctx: ctx} do
      segments = ["components", "catalysts", "local", "remove-fs-test", "1.0.0"]
      comp_dir = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), segments)

      File.mkdir_p!(comp_dir)

      manifest = %{
        "type" => "catalyst",
        "version" => "1.0.0",
        "description" => "FS component to remove"
      }

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_arca(ctx, segments)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "c:local.remove-fs-test:1.0.0"
        })

      assert result.status == "deleted"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "r:local.nonexistent-remove:1.0.0"
        })

      assert err_msg(msg) =~ "not found"
    end

    test "returns error for missing reference", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{"action" => "delete"})
      assert err_msg(msg) =~ "Missing required argument: reference"
    end

    test "returns error for invalid reference", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "delete",
          "reference" => "!!invalid!!"
        })

      assert err_msg(msg) =~ "not found" or err_msg(msg) =~ "Invalid reference"
    end
  end

  # ============================================================================
  # Invalid/Missing Action
  # ============================================================================

  describe "component tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{"action" => "invalid"})
      assert err_msg(msg) =~ "Invalid component action"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = Provider.handle("component", ctx, %{})
      assert err_msg(msg) =~ "Missing required"
    end
  end

  # ============================================================================
  # Guide Tool
  # ============================================================================

  describe "aqua tool - list action" do
    test "list returns available guides", %{ctx: ctx} do
      {:ok, result} = Provider.handle("aqua", ctx, %{"action" => "list"})

      # the soul + 5 roles + 3 doc guides = 9
      assert result.count == 9
      assert length(result.guides) == 9

      names = Enum.map(result.guides, & &1.name)
      assert "component-guide" in names
      assert "tincture-guide" in names
      assert "integration-guide" in names
      assert "aqua" in names
      assert "builder" in names
      assert "artisan" in names
      assert "explorer" in names
      assert "planner" in names
      assert "web" in names
    end

    test "guides have title and description", %{ctx: ctx} do
      {:ok, result} = Provider.handle("aqua", ctx, %{"action" => "list"})

      for guide <- result.guides do
        assert is_binary(guide.name)
        assert is_binary(guide.title)
        assert is_binary(guide.description)
      end
    end

    test "list types the roles as roles, flat", %{ctx: ctx} do
      {:ok, result} = Provider.handle("aqua", ctx, %{"action" => "list"})
      roles = Enum.filter(result.guides, &(&1.type == "role"))

      assert length(roles) == 5
      refute Enum.any?(roles, &Map.has_key?(&1, :parent))
    end

    test "list puts the soul first", %{ctx: ctx} do
      {:ok, result} = Provider.handle("aqua", ctx, %{"action" => "list"})

      assert [%{name: "aqua", type: "soul"} | _] = result.guides
      assert Enum.count(result.guides, &(&1.type == "soul")) == 1
    end
  end

  describe "aqua tool - get action" do
    test "get component-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "component-guide"})

      assert result.name == "component-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Component Reference"
    end

    test "get tincture-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "tincture-guide"})

      assert result.name == "tincture-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Tincture Reference"
    end

    test "get integration-guide returns markdown content", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "integration-guide"})

      assert result.name == "integration-guide"
      assert result.format == "markdown"
      assert is_binary(result.content)
      assert result.content =~ "Integration Guide"
    end

    test "get aqua returns the soul with metadata", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "aqua"})

      assert result.name == "aqua"
      assert result.type == "soul"
      assert result.format == "markdown"
      assert result.content =~ "You are A.Q.U.A."
      assert result.catalyst_ref == "catalyst:moonmoon69.claude"
      assert result.model == "claude-opus-4-6"
    end

    test "get builder returns a role with metadata", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "builder"})

      assert result.name == "builder"
      assert result.type == "role"
      refute Map.has_key?(result, :parent)
      assert result.format == "markdown"
      assert result.content =~ "Builder Agent"
      assert is_map(result.tool_policy)
    end

    test "get returns the athanor's declared policy — one allowlist for every member", %{
      ctx: ctx
    } do
      {:ok, before} = Provider.handle("aqua", ctx, %{"action" => "get", "name" => "builder"})
      assert before.tool_policy["build.compile"] == "auto"

      # Editing declared policy goes through the tool — the agents page's
      # path. A chat decision does NOT come here; those are
      # `Aqua.ToolGrants` rows composed over this at use time.
      edited =
        before.tool_policy
        |> Map.delete("build.compile")
        |> Map.put("files.write", "auto")

      {:ok, _} =
        Provider.handle("aqua", ctx, %{
          "action" => "update",
          "name" => "builder",
          "tool_policy" => edited
        })

      {:ok, result} = Provider.handle("aqua", ctx, %{"action" => "get", "name" => "builder"})

      refute Map.has_key?(result.tool_policy, "build.compile")
      assert result.tool_policy["files.write"] == "auto"
      assert result.tool_policy["component.list"] == "auto"
      refute Map.has_key?(result, :effective_tool_policy)
    end

    test "update rejects the retired allow/approval/block vocabulary", %{ctx: ctx} do
      assert {:error, msg} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "builder",
                 "tool_policy" => %{"files.delete" => "block"}
               })

      assert err_msg(msg) =~ ~s{use "ask" or "auto"}
    end

    test "update rejects malformed tool_policy keys", %{ctx: ctx} do
      assert {:error, msg} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "builder",
                 "tool_policy" => %{"no-dot-here" => "auto"}
               })

      assert err_msg(msg) =~ "Invalid tool_policy key"
    end

    test "update accepts ask/auto and the bare native_search key", %{ctx: ctx} do
      assert {:ok, _} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "aqua",
                 "tool_policy" => %{
                   "files.read" => "auto",
                   "files.delete" => "ask",
                   "native_search" => "auto"
                 }
               })

      {:ok, result} = Provider.handle("aqua", ctx, %{"action" => "get", "name" => "aqua"})
      assert result.tool_policy["native_search"] == "auto"
      assert result.tool_policy["files.delete"] == "ask"
    end

    test "the door refuses what no agent may hold: destructive auto, ask on a role, a UI event at ask",
         %{ctx: ctx} do
      # Kind always wins — on the soul as on a role.
      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "aqua",
                 "tool_policy" => %{"files.delete" => "auto"}
               })

      assert msg =~ "always asks"

      # A glob at auto that would cover a destructive action names it.
      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "builder",
                 "tool_policy" => %{"files.*" => "auto"}
               })

      assert msg =~ "files.delete"

      # A cloned role has no card to raise.
      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "builder",
                 "tool_policy" => %{"files.write" => "ask"}
               })

      assert msg =~ "no card"

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "create",
                 "name" => "asker",
                 "tool_policy" => %{"component.pull" => "ask"}
               })

      assert msg =~ "no card"

      # A UI event is auto or absent.
      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "aqua",
                 "tool_policy" => %{"request_setup.open" => "ask"}
               })

      assert msg =~ "runs on its own"

      # What a role may hold is written whole.
      assert {:ok, _} =
               Provider.handle("aqua", ctx, %{
                 "action" => "update",
                 "name" => "builder",
                 "tool_policy" => %{"files.write" => "auto", "files.read" => "auto"}
               })
    end

    test "get artisan returns a role prompt", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "artisan"})

      assert result.name == "artisan"
      assert result.type == "role"
      assert result.content =~ "Artisan Agent"
    end

    test "get web returns a role prompt", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "web"})

      assert result.name == "web"
      assert result.type == "role"
      assert result.content =~ "Web Agent"
    end

    test "get planner returns a role prompt", %{ctx: ctx} do
      {:ok, result} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "planner"})

      assert result.name == "planner"
      assert result.type == "role"
      assert result.content =~ "Planner Agent"
    end

    test "get with unknown name returns error", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("aqua", ctx, %{"action" => "get", "name" => "nonexistent"})

      assert err_msg(msg) =~ "role or guide not found"
      assert err_msg(msg) =~ "nonexistent"
    end

    test "get without name returns error", %{ctx: ctx} do
      {:error, msg} = Provider.handle("aqua", ctx, %{"action" => "get"})
      assert err_msg(msg) =~ "Missing required"
    end
  end

  describe "component inspect - include_readme" do
    test "inspect with include_readme returns readme content", %{ctx: ctx} do
      segments = ["components", "catalysts", "local", "readme-test", "1.0.0"]
      comp_dir = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), segments)

      File.mkdir_p!(comp_dir)

      readme_content = "# Readme Test Component\n\nThis is the README."
      manifest = %{"type" => "catalyst", "version" => "1.0.0", "name" => "readme-test"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), readme_content)

      {:ok, _} = Registry.register_from_arca(ctx, segments)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.readme-test:1.0.0",
          "include_readme" => true
        })

      assert result["readme"] == readme_content
    end

    test "inspect without include_readme omits readme", %{ctx: ctx} do
      segments = ["components", "catalysts", "local", "no-readme-flag", "1.0.0"]
      comp_dir = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), segments)

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0", "name" => "no-readme-flag"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), "# Has README")

      {:ok, _} = Registry.register_from_arca(ctx, segments)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "c:local.no-readme-flag:1.0.0"
        })

      refute Map.has_key?(result, "readme")
    end

    test "inspect with include_readme returns nil when no README", %{ctx: ctx} do
      segments = ["components", "reagents", "local", "no-readme-file", "1.0.0"]
      comp_dir = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), segments)

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "1.0.0", "name" => "no-readme-file"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_arca(ctx, segments)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "inspect",
          "reference" => "r:local.no-readme-file:1.0.0",
          "include_readme" => true
        })

      assert result["readme"] == nil
    end
  end

  describe "component tool - status overview" do
    test "status without a reference answers the whole-athanor overview", %{ctx: ctx} do
      segments = ["components", "reagents", "local", "ov-tool", "1.0.0"]
      comp_dir = Arca.Adapters.Local.build_path(Sanctum.Context.actor(ctx), segments)
      File.mkdir_p!(comp_dir)

      File.write!(
        Path.join(comp_dir, "cyfr-manifest.json"),
        Jason.encode!(%{"type" => "reagent", "version" => "1.0.0", "name" => "ov-tool"})
      )

      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)
      {:ok, _} = Registry.register_from_arca(ctx, segments)

      {:ok, %{components: components, counts: counts}} =
        Provider.handle("component", ctx, %{"action" => "status"})

      entry = Enum.find(components, &(&1.reference =~ "ov-tool"))
      assert entry.provenance == "user"
      assert entry.shipped_versions == []
      assert entry.superseded == false
      assert counts.user >= 1
    end
  end

  describe "aqua tool - status, skills, delete semantics" do
    test "status speaks the one provenance vocabulary", %{ctx: ctx} do
      # The fixture materialized every shipped agent (they shadow the seed);
      # the shipped scroll is read in place.
      {:ok, %{files: files}} = Provider.handle("aqua", ctx, %{"action" => "status"})

      assert %{state: "bundled_modified"} =
               Enum.find(files, &(&1.path == "aqua/aqua.md"))

      assert %{state: "bundled"} =
               Enum.find(files, &(&1.path == "aqua/skills/capability-acquisition"))
    end

    test "reset keeps member-created agents and scrolls unless all=true", %{ctx: ctx} do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          ["aqua", "roles", "keeper.md"],
          "---\ntitle: Keeper\n---\n\nkeeper\n"
        )

      {:ok, %{created: "pdf"}} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_create",
          "name" => "pdf",
          "description" => "fills PDF forms",
          "content" => "Use the reference."
        })

      {:ok, %{reset: true, reverted: reverted, kept: kept}} =
        Provider.handle("aqua", ctx, %{"action" => "reset"})

      assert "aqua/roles/keeper.md" in kept
      assert "aqua/skills/pdf" in kept
      assert "aqua/roles/web.md" in reverted
      assert Arca.exists?(Sanctum.Context.actor(ctx), ["aqua", "roles", "keeper.md"])

      {:ok, %{reset: true, kept: []}} =
        Provider.handle("aqua", ctx, %{"action" => "reset", "all" => true})

      refute Arca.exists?(Sanctum.Context.actor(ctx), ["aqua", "roles", "keeper.md"])
      refute Arca.exists?(Sanctum.Context.actor(ctx), ["aqua", "skills", "pdf", "SKILL.md"])
    end

    test "skill_list and skill_get serve the scrolls, shipped and the estate's own", %{ctx: ctx} do
      # The shipped scroll is read in place from the seed.
      {:ok, shipped} = Provider.handle("aqua", ctx, %{"action" => "skill_list"})
      assert [%{name: "capability-acquisition", description: line}] = shipped.skills
      assert line =~ "registry"
      refute Map.has_key?(shipped, :hint)

      {:ok, %{created: "pdf"}} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_create",
          "name" => "pdf",
          "description" => "fills PDF forms",
          "content" => "Use the reference."
        })

      # A resource beside the manifest, as a member adds one by hand.
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          ["aqua", "skills", "pdf", "reference.md"],
          "field tables"
        )

      {:ok, listing} = Provider.handle("aqua", ctx, %{"action" => "skill_list"})
      assert Enum.map(listing.skills, & &1.name) == ["capability-acquisition", "pdf"]

      {:ok, skill} = Provider.handle("aqua", ctx, %{"action" => "skill_get", "name" => "pdf"})
      assert skill.description == "fills PDF forms"
      assert skill.content =~ "Use the reference."
      assert skill.resources == ["reference.md"]
    end

    test "a scroll is updated in place and keeps its files", %{ctx: ctx} do
      {:ok, _} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_create",
          "name" => "pdf",
          "description" => "fills PDF forms",
          "content" => "Use the reference."
        })

      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          ["aqua", "skills", "pdf", "reference.md"],
          "field tables"
        )

      {:ok, %{updated: "pdf"}} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_update",
          "name" => "pdf",
          "content" => "Read it twice."
        })

      {:ok, skill} = Provider.handle("aqua", ctx, %{"action" => "skill_get", "name" => "pdf"})
      assert skill.content == "Read it twice."
      assert skill.description == "fills PDF forms"
      assert skill.resources == ["reference.md"]

      assert {:error, {:not_found, "Scroll", "nope"}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "skill_update",
                 "name" => "nope",
                 "content" => "x"
               })
    end

    test "a scroll needs a line and a body, and a name nobody holds", %{ctx: ctx} do
      base = %{"action" => "skill_create", "name" => "pdf", "content" => "Use it."}

      assert {:error, {:invalid_argument, msg}} = Provider.handle("aqua", ctx, base)
      assert msg =~ "description"

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, Map.put(base, "description", "two\nlines"))

      assert msg =~ "one line"

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "skill_create",
                 "name" => "pdf",
                 "description" => "d"
               })

      assert msg =~ "content"

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "skill_create",
                 "name" => "capability-acquisition",
                 "description" => "d",
                 "content" => "c"
               })

      assert msg =~ "already exists"

      assert {:error, {:invalid_argument, _}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "skill_create",
                 "name" => "../x",
                 "description" => "d",
                 "content" => "c"
               })
    end

    test "the shipped scroll is never deleted, edited or not; a reset restores it; the estate's own goes",
         %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "skill_delete",
                 "name" => "capability-acquisition"
               })

      assert msg =~ "ships with the server"

      {:ok, %{updated: _}} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_update",
          "name" => "capability-acquisition",
          "content" => "Shortened."
        })

      {:ok, %{files: files}} = Provider.handle("aqua", ctx, %{"action" => "status"})

      assert %{state: "bundled_modified"} =
               Enum.find(files, &(&1.path == "aqua/skills/capability-acquisition"))

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "skill_delete",
                 "name" => "capability-acquisition"
               })

      assert msg =~ "ships with the server"

      {:ok, %{restored: "capability-acquisition"}} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_reset",
          "name" => "capability-acquisition"
        })

      {:ok, back} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_get",
          "name" => "capability-acquisition"
        })

      assert back.content =~ "component(action: \"search\""

      # Restoring again changes nothing and answers the same; the estate's
      # own has nothing to restore to.
      {:ok, %{restored: "capability-acquisition"}} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_reset",
          "name" => "capability-acquisition"
        })

      {:ok, _} =
        Provider.handle("aqua", ctx, %{
          "action" => "skill_create",
          "name" => "pdf",
          "description" => "d",
          "content" => "c"
        })

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{"action" => "skill_reset", "name" => "pdf"})

      assert msg =~ "estate's own"

      {:ok, %{deleted: "pdf"}} =
        Provider.handle("aqua", ctx, %{"action" => "skill_delete", "name" => "pdf"})

      assert {:error, {:not_found, "Scroll", "pdf"}} =
               Provider.handle("aqua", ctx, %{"action" => "skill_get", "name" => "pdf"})

      assert {:error, {:not_found, "Scroll", "pdf"}} =
               Provider.handle("aqua", ctx, %{"action" => "skill_reset", "name" => "pdf"})
    end

    test "a shipped role refuses delete, edited or not, and points at disable", %{ctx: ctx} do
      # The fixture edited the athanor's copy of web: still shipped,
      # still not deletable — disable is the verb, and reset the way back.
      {:error, msg} = Provider.handle("aqua", ctx, %{"action" => "delete", "name" => "web"})
      assert err_msg(msg) =~ "cannot be deleted"
      assert err_msg(msg) =~ "disabled=true"

      {:ok, %{restored: "web"}} =
        Provider.handle("aqua", ctx, %{"action" => "reset", "name" => "web"})

      {:ok, %{files: files}} = Provider.handle("aqua", ctx, %{"action" => "status"})
      assert %{state: "bundled"} = Enum.find(files, &(&1.path == "aqua/roles/web.md"))

      {:ok, %{restored: "web"}} =
        Provider.handle("aqua", ctx, %{"action" => "reset", "name" => "web"})

      {:error, msg} = Provider.handle("aqua", ctx, %{"action" => "delete", "name" => "web"})
      assert err_msg(msg) =~ "cannot be deleted"

      {:ok, _} =
        Provider.handle("aqua", ctx, %{"action" => "update", "name" => "web", "disabled" => true})

      {:ok, listing} = Provider.handle("aqua", ctx, %{"action" => "list"})
      refute Enum.any?(listing.guides, &(&1.name == "web"))

      # get still answers (so it can be re-enabled), flagged.
      {:ok, got} = Provider.handle("aqua", ctx, %{"action" => "get", "name" => "web"})
      assert got.disabled == true
    end

    test "the soul is edited, never created or deleted", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{
                 "action" => "create",
                 "name" => "aqua",
                 "content" => "x"
               })

      assert msg =~ "soul"

      assert {:error, {:invalid_argument, msg}} =
               Provider.handle("aqua", ctx, %{"action" => "delete", "name" => "aqua"})

      assert msg =~ "soul ships with the server"

      {:ok, %{updated: "aqua"}} =
        Provider.handle("aqua", ctx, %{"action" => "update", "name" => "aqua", "title" => "Mine"})

      assert {:ok, %{type: "soul", title: "Mine"}} =
               Provider.handle("aqua", ctx, %{"action" => "get", "name" => "aqua"})
    end

    test "a member-created role deletes outright", %{ctx: ctx} do
      {:ok, _} =
        Provider.handle("aqua", ctx, %{
          "action" => "create",
          "name" => "my_agent",
          "content" => "You are mine."
        })

      {:ok, %{deleted: "my_agent"} = result} =
        Provider.handle("aqua", ctx, %{"action" => "delete", "name" => "my_agent"})

      refute Map.has_key?(result, :restored)

      {:error, msg} = Provider.handle("aqua", ctx, %{"action" => "get", "name" => "my_agent"})
      assert err_msg(msg) =~ "role or guide not found"
    end
  end

  describe "aqua tool - invalid action" do
    test "returns error for invalid action", %{ctx: ctx} do
      {:error, msg} = Provider.handle("aqua", ctx, %{"action" => "invalid"})
      assert err_msg(msg) =~ "Unknown action: aqua.invalid"
    end

    test "returns error for missing action", %{ctx: ctx} do
      {:error, msg} = Provider.handle("aqua", ctx, %{})
      assert err_msg(msg) =~ "Missing required argument: action"
    end
  end

  describe "aqua tool - schema" do
    test "aqua tool has required schema fields" do
      tool = Enum.find(Provider.tools(), &(&1.name == "aqua"))

      assert tool.name == "aqua"
      assert is_binary(tool.title)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
      assert tool.input_schema["type"] == "object"
      assert "action" in tool.input_schema["required"]
    end

    test "aqua tool has correct actions" do
      tool = Enum.find(Provider.tools(), &(&1.name == "aqua"))
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
      for tool <- Provider.tools() do
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

    defp setup_component_dir(_test_dir, type, name, version, manifest) do
      segments = ["components", "#{type}s", "local", name, version]

      comp_dir =
        Arca.Adapters.Local.build_path(
          Sanctum.Context.actor(Sanctum.TestContext.local()),
          segments
        )

      File.mkdir_p!(comp_dir)

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      wasm_filename = "#{type}.wasm"
      File.write!(Path.join(comp_dir, wasm_filename), @auto_pull_wasm)

      segments
    end

    test "rejects pull of a local formula the server does not ship", %{
      ctx: ctx,
      test_dir: test_dir
    } do
      formula_dir =
        setup_component_dir(test_dir, "formula", "test-formula", "0.1.0", %{
          "type" => "formula",
          "version" => "0.1.0",
          "description" => "A test formula"
        })

      {:ok, _} = Registry.register_from_arca(ctx, formula_dir)

      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "pull",
          "reference" => "formula:local.test-formula:0.1.0"
        })

      assert err_msg(msg) =~ "not a version the server ships"
    end
  end

  # ============================================================================
  # Permission Gates
  # ============================================================================

  describe "permission gates" do
    setup do
      restricted_ctx = %Context{
        user_id: "restricted_user",
        athanor_id: "ath_test",
        permissions: MapSet.new([:component_read]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:ok, restricted_ctx: restricted_ctx}
    end

    test "component.create denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      assert {:error, {:missing_permission, :component_manage}} =
               Grimoire.Catalog.call_external("component", restricted_ctx, %{
                 "action" => "create",
                 "name" => "test-comp",
                 "type" => "reagent"
               })
    end

    test "component.push denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      assert {:error, {:missing_permission, :component_manage}} =
               Grimoire.Catalog.call_external("component", restricted_ctx, %{
                 "action" => "push",
                 "reference" => "reagent:local.test:0.1.0"
               })
    end

    test "component.push is a person's act — an API key with every permission is still refused" do
      key_ctx = %Context{
        user_id: "github|https://github.com|keyholder",
        athanor_id: "ath_test",
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: :api_key,
        api_key_type: :application,
        authenticated: true
      }

      {:error, msg} =
        Grimoire.Catalog.call_external("component", key_ctx, %{
          "action" => "push",
          "reference" => "reagent:local.test:0.1.0"
        })

      assert err_msg(msg) =~ "person's act"
    end

    test "component.register denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      assert {:error, {:missing_permission, :component_manage}} =
               Grimoire.Catalog.call_external("component", restricted_ctx, %{
                 "action" => "register"
               })
    end

    test "component.delete denied without :component_manage", %{restricted_ctx: restricted_ctx} do
      assert {:error, {:missing_permission, :component_manage}} =
               Grimoire.Catalog.call_external("component", restricted_ctx, %{
                 "action" => "delete",
                 "reference" => "reagent:local.test:0.1.0"
               })
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "unknown tool" do
    test "returns error for unknown tool", %{ctx: ctx} do
      {:error, msg} = Provider.handle("unknown_tool", ctx, %{})
      assert err_msg(msg) =~ "Unknown tool"
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
      registry_tool = Enum.find(Provider.tools(), &(&1.name == "registry"))
      assert registry_tool, "registry tool missing from Provider.tools/0"

      enum =
        registry_tool
        |> action_schema("report")
        |> get_in(["properties", "category", "enum"])
        |> MapSet.new()

      assert MapSet.equal?(enum, @expected_report_categories),
             "registry.report category enum drifted. Got: " <>
               inspect(MapSet.to_list(enum)) <>
               "; expected: " <> inspect(MapSet.to_list(@expected_report_categories))
    end
  end

  # Registry errors must be readable and policy-acceptance refusals must carry structured data.
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

      assert {:error, msg} = Provider.handle("registry", ctx, %{"action" => "legal_version"})
      assert is_binary(msg)
      # Must NOT be an inspected struct dump.
      refute err_msg(msg) =~ "%Compendium.OCI.Errors{"
      # Must include the canonical "(HTTP 503, registry_unavailable)" suffix
      # produced by Errors.to_string/1.
      assert err_msg(msg) =~ "503"
      assert err_msg(msg) =~ "registry_unavailable"
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
               Provider.handle("registry", ctx, %{
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
               Provider.handle("registry", ctx, %{
                 "action" => "probe",
                 "provider" => "github",
                 "access_token" => "gho_x"
               })

      assert is_binary(msg)
      refute err_msg(msg) =~ "%Compendium.OCI.Errors{"
      assert err_msg(msg) =~ "403"
    end
  end

  # Providers answer typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Grimoire.Error.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end

  # One action's own declaration, as `Prima.Operation.cast/2` applies it;
  # the tool's discovery schema merges every action into one flat object.
  defp action_schema(tool, action) do
    case Enum.find(tool.operations, &(&1.action == action)) do
      nil ->
        flunk("missing schema for #{tool.name}.#{action}")

      operation ->
        operation.args
        |> Prima.Arg.schema()
        |> put_in(["properties", "action"], %{"type" => "string", "const" => action})
        |> Map.update!("required", &["action" | &1])
    end
  end
end
