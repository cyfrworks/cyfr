defmodule Compendium.MCP do
  @moduledoc """
  MCP tool provider for Compendium component registry.

  Provides tools with action-based dispatch:
  - `component` - Component discovery and registry operations
    - `search` - Search components by type, category, tags
    - `inspect` - Get component metadata, schema, and dependency tree (when deps declared)
    - `pull` - Pull component from OCI registry
    - `publish` - Publish WASM artifact to permanent storage
    - `categories` - List available categories
    - `list` - List all installed components (local-only)
    - `remove` - Remove a component from the registry
  - `guide` - Documentation guides (list, get, readme)

  ## Architecture Note

  This module lives in the `compendium` app, keeping tool definitions
  close to their implementation.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  require Logger

  alias Sanctum.Context
  alias Compendium.OCI.Errors
  alias Compendium.Registry

  # Embed top-level guides at compile time
  @guide_root Path.join([__DIR__, "..", "..", "..", ".."]) |> Path.expand()
  @external_resource Path.join(@guide_root, "component-guide.md")
  @external_resource Path.join(@guide_root, "integration-guide.md")
  @external_resource Path.join(@guide_root, "agent-guide.md")
  @component_guide File.read!(Path.join(@guide_root, "component-guide.md"))
  @integration_guide File.read!(Path.join(@guide_root, "integration-guide.md"))
  @agent_guide File.read!(Path.join(@guide_root, "agent-guide.md"))

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Compendium resources (concrete URIs only).
  """
  def resources do
    []
  end

  @doc """
  Returns Compendium resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    [
      %{
        uriTemplate: "compendium://components/{reference}",
        name: "Component Metadata",
        description: "Component metadata by OCI reference",
        mimeType: "application/json"
      },
      %{
        uriTemplate: "compendium://assets/{reference}/{path}",
        name: "Component Assets",
        description: "Static assets from components",
        mimeType: "application/octet-stream"
      }
    ]
  end

  @doc """
  Read a resource by URI.
  """
  def read(%Context{} = ctx, "compendium://components/" <> reference) do
    case resolve_component(ctx, reference) do
      {:ok, component, _ref} ->
        {:ok, %{content: Jason.encode!(component), mimeType: "application/json"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read(%Context{} = ctx, "compendium://assets/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [reference, path] when path != "" ->
        case resolve_component(ctx, reference) do
          {:ok, _component, ref} ->
            asset_path = ["components", "#{ref.type}s", ref.namespace, ref.name, ref.version | String.split(path, "/")]

            case Arca.get(ctx, asset_path) do
              {:ok, content} ->
                {:ok, %{content: Base.encode64(content), mimeType: "application/octet-stream"}}

              {:error, reason} ->
                {:error, "Asset not found: #{rest} (#{inspect(reason)})"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "Invalid asset URI: missing path after reference"}
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # ============================================================================
  # ToolProvider Protocol (validated at runtime)
  # ============================================================================

  def tools do
    [
      %{
        name: "component",
        title: "Component",
        description: "Component discovery and registry operations",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["search", "inspect", "pull", "publish", "register", "categories", "get_blob", "discover", "setup_plan", "list", "remove", "new"],
              "description" => "Action to perform"
            },
            # search action params
            "query" => %{
              "type" => "string",
              "description" => "Search query (search action)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["catalyst", "reagent", "formula"],
              "description" => "Filter by component type (search action)"
            },
            "category" => %{
              "type" => "string",
              "description" => "Filter by category (search action)"
            },
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter by tags, AND logic (search action)"
            },
            "has_source" => %{
              "type" => "boolean",
              "description" => "Only show components with source available (search action)"
            },
            "source" => %{
              "type" => "string",
              "enum" => ["local", "remote", "all"],
              "description" => "Search scope: 'local' (skip remote), 'remote' (remote only), 'all' (default, both)"
            },
            "license" => %{
              "type" => "string",
              "description" => "Filter by license, SPDX identifier (search action)"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 20,
              "description" => "Maximum results to return (search action)"
            },
            # inspect/pull action params
            "reference" => %{
              "type" => "string",
              "description" => "Component reference, OCI or local (inspect/pull actions)"
            },
            # pull action params
            "verify" => %{
              "type" => "boolean",
              "default" => true,
              "description" => "Verify signature before pulling (pull action)"
            },
            # publish action params
            "artifact" => %{
              "type" => "object",
              "description" => "Artifact input: {path: string} | {base64: string} | {url: string} (publish action)",
              "oneOf" => [
                %{"properties" => %{"path" => %{"type" => "string"}}},
                %{"properties" => %{"base64" => %{"type" => "string"}}},
                %{"properties" => %{"url" => %{"type" => "string"}}}
              ]
            },
            "visibility" => %{
              "type" => "string",
              "enum" => ["local", "private", "public"],
              "default" => "local",
              "description" => "Visibility level (publish action)"
            },
            "source_availability" => %{
              "type" => "string",
              "enum" => ["none", "include", "external"],
              "default" => "none",
              "description" => "Source availability (publish action)"
            },
            "source_url" => %{
              "type" => "string",
              "description" => "Repository URL, required if source=external (publish action)"
            },
            "digest" => %{
              "type" => "string",
              "description" => "Component digest (get_blob action)"
            },
            "registry" => %{
              "type" => "string",
              "description" => "OCI registry hostname for push/discover (e.g., ghcr.io)"
            },
            "namespace" => %{
              "type" => "string",
              "description" => "Publisher namespace filter (discover action)"
            },
            # new action params
            "name" => %{
              "type" => "string",
              "description" => "Component name, lowercase alphanumeric with hyphens (new action)"
            },
            "version" => %{
              "type" => "string",
              "default" => "0.1.0",
              "description" => "Semver version (new action)"
            },
            # register action: no additional params (scans all component directories)
          },
          "required" => ["action"]
        }
      },
      %{
        name: "guide",
        title: "Documentation Guides",
        description:
          "Access CYFR documentation and component READMEs. Use 'list' to see top-level guides, 'get' to retrieve a guide, or 'readme' to get a component's README.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "get", "readme"],
              "description" => "Action: list guides, get a guide by name, or get a component README"
            },
            "name" => %{
              "type" => "string",
              "enum" => ["component-guide", "integration-guide", "agent-guide"],
              "description" => "Guide name (for get action)"
            },
            "reference" => %{
              "type" => "string",
              "description" =>
                "Component reference, e.g. 'c:local.claude:0.1.0' (for readme action)"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Tool Handlers - Action-based dispatch
  # ============================================================================

  def handle("component", _ctx, %{"action" => "ping"}), do: {:ok, %{status: "ok"}}

  # Search action - search for components
  # Core edition: searches local registry + cyfr.run REST API, merges results.
  # Arx edition: local registry only (Arx has its own registry with its own search).
  def handle("component", %Context{} = ctx, %{"action" => "search"} = args) do
    filters = %{
      query: args["query"],
      type: args["type"],
      category: args["category"],
      tags: args["tags"],
      license: args["license"],
      limit: args["limit"] || 20
    }

    source = args["source"] || "all"

    local_result = if source != "remote", do: Registry.search(ctx, filters), else: nil

    if Compendium.Edition.core_edition?() and source != "local" do
      case Compendium.CyfrRun.Client.search(ctx, filters) do
        {:ok, remote} ->
          if local_result do
            merge_search_results(local_result, remote)
          else
            {:ok, %{components: remote[:components] || [], total: remote[:total] || 0}}
          end

        {:error, %Errors{} = err} ->
          Logger.error("[Compendium.MCP] CYFR.RUN SEARCH FAILED — #{Errors.to_log_string(err)}. " <>
                       "Results are incomplete. Only local components are shown.")

          error_msg = format_error(err)

          case local_result do
            {:ok, local} ->
              {:ok, local
                |> Map.put(:incomplete, true)
                |> Map.put(:registry_error, error_msg)
                |> Map.put(:note, "INCOMPLETE RESULTS — cyfr.run search failed: #{error_msg}. " <>
                                  "Only local components are shown.")}

            nil ->
              {:ok, %{components: [], total: 0, incomplete: true,
                      registry_error: error_msg,
                      note: "INCOMPLETE RESULTS — cyfr.run search failed: #{error_msg}."}}
          end
      end
    else
      local_result || {:ok, %{components: [], total: 0}}
    end
  end

  # Inspect action - get component metadata
  # Core edition: falls back to cyfr.run when component not found locally.
  # Arx edition: local only.
  def handle("component", %Context{} = ctx, %{"action" => "inspect", "reference" => reference}) do
    case resolve_component(ctx, reference) do
      {:ok, component, ref} ->
        # Include canonical component_ref so callers (e.g., Opus Executor)
        # can use it for policy/secret lookup without re-parsing.
        canonical_ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
          type: ref.type,
          namespace: ref.namespace,
          name: ref.name,
          version: ref.version
        })

        result = component |> Map.put("component_ref", canonical_ref) |> Map.put("type", ref.type)
        {:ok, maybe_enrich_with_dependencies(ctx, component, result)}

      {:error, _reason} ->
        if Compendium.Edition.core_edition?() do
          inspect_cyfr_run_fallback(ctx, reference)
        else
          {:error, "Component not found: #{reference}"}
        end
    end
  end

  def handle("component", _ctx, %{"action" => "inspect"}) do
    {:error, "Missing required argument: reference"}
  end

  # Pull action - pull component from registry (local or OCI)
  def handle("component", %Context{} = ctx, %{"action" => "pull"} = args) do
    progress_id = args["progress_id"]
    session_id = ctx.session_id

    case args["reference"] do
      nil ->
        {:error, "Missing required argument: reference"}

      reference ->
        oci_reference =
          if Compendium.OCI.Reference.oci_ref?(reference) do
            {:ok, reference}
          else
            convert_to_oci_ref(reference)
          end

        case oci_reference do
          {:ok, ref} ->
            broadcast_progress(progress_id, session_id, :pulling, "Pulling #{ref}...")
            result = do_oci_pull(ctx, ref)

            case result do
              {:ok, res} ->
                broadcast_progress(progress_id, session_id, :complete, "Pulled #{res[:component_ref] || ref}")
              {:error, reason} ->
                broadcast_progress(progress_id, session_id, :error, "Pull failed: #{inspect(reason)}")
            end

            result

          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Publish action - publish WASM artifact to permanent storage (and optionally push to OCI registry)
  def handle("component", %Context{} = ctx, %{"action" => "publish"} = args) do
    artifact = args["artifact"]
    reference = args["reference"]
    registry = args["registry"] || default_registry()
    progress_id = args["progress_id"]
    session_id = ctx.session_id

    cond do
      is_nil(reference) ->
        {:error, "Missing required argument: reference (format: name:version)"}

      # OCI push: push an already-published local component to a remote registry
      is_binary(registry) and is_nil(artifact) ->
        case Sanctum.ComponentRef.parse(reference) do
          {:ok, cref} when cref.namespace != "local" ->
            {:error, "Only components in the local namespace can be published to a registry. " <>
                     "Got namespace '#{cref.namespace}'. Use the local namespace (e.g., c:local.#{cref.name}:#{cref.version})."}

          {:ok, _cref} ->
            case Compendium.Edition.validate_registry(registry) do
              {:error, msg} ->
                {:error, msg}

              :ok ->
                if registry == Compendium.Edition.cyfr_run_registry() and
                     Compendium.OCI.Auth.resolve_credentials(registry) == :anonymous do
                  {:error, "No credentials found for #{Compendium.Edition.cyfr_run_registry()}. " <>
                           "Run `cyfr login` to authenticate before pushing."}
                else
                  broadcast_progress(progress_id, session_id, :pushing, "Pushing #{reference} to #{registry}...")

                  case Compendium.OCI.Client.push(ctx, reference, registry) do
                    {:ok, result} ->
                      broadcast_progress(progress_id, session_id, :complete, "Published #{result[:oci_reference] || reference}")
                      {:ok, result}

                    {:error, reason} ->
                      broadcast_progress(progress_id, session_id, :error, "Push failed: #{inspect(reason)}")
                      {:error, reason}
                  end
                end
            end

          {:error, reason} ->
            {:error, "Invalid reference: #{reason}"}
        end

      is_nil(args["type"]) ->
        {:error, "Missing required argument: type (catalyst, reagent, or formula)"}

      true ->
        case parse_reference(reference) do
          {:ok, namespace, name, version, _type} ->
            case resolve_artifact(artifact) do
              {:ok, wasm_bytes} ->
                broadcast_progress(progress_id, session_id, :publishing, "Publishing #{name}:#{version}...")

                metadata = %{
                  name: name,
                  version: version,
                  type: args["type"],
                  description: args["description"],
                  tags: args["tags"],
                  category: args["category"],
                  license: args["license"],
                  publisher: namespace
                }

                case Registry.publish_bytes(ctx, wasm_bytes, metadata) do
                  {:ok, component} ->
                    broadcast_progress(progress_id, session_id, :complete, "Published #{name}:#{version}")

                    {:ok,
                     %{
                       status: "published",
                       reference: reference,
                       digest: component.digest,
                       size: component.size,
                       type: component.component_type,
                       published_at: component.inserted_at
                     }}

                  {:error, {:already_exists, name, version}} ->
                    {:error, "Component #{name}:#{version} already exists"}

                  {:error, {:missing_required, field}} ->
                    {:error, "Missing required field: #{field}"}

                  {:error, {:invalid_name, msg}} ->
                    {:error, "Invalid component name: #{msg}"}

                  {:error, {:invalid_version, msg}} ->
                    {:error, "Invalid version: #{msg}"}

                  {:error, reason} ->
                    Logger.warning("[Compendium.MCP] Publish failed: #{inspect(reason)}")
                    {:error, "Publish failed: #{inspect(reason)}"}
                end

              {:error, reason} ->
                {:error, "Failed to resolve artifact: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # New action - scaffold a new component project
  def handle("component", %Context{} = ctx, %{"action" => "new"} = args) do
    name = args["name"]
    type = args["type"]
    version = args["version"] || "0.1.0"

    Compendium.Scaffold.create(ctx, name, type, version)
  end

  # Register action - scan and register all local components
  def handle("component", %Context{} = ctx, %{"action" => "register"} = args) do
    register_id = args["register_id"]
    session_id = ctx.session_id

    broadcast_register_progress(register_id, session_id, :scanning, "Scanning component directories...")

    result = Compendium.AutoIndexer.scan()

    # Broadcast per-component status
    Enum.each(result.components, fn comp ->
      status = comp[:status] || comp["status"]
      name = comp[:name] || comp["name"]
      version = comp[:version] || comp["version"]

      case status do
        "registered" ->
          broadcast_register_progress(register_id, session_id, :registered, "Registered #{name}:#{version}")
        "unchanged" ->
          broadcast_register_progress(register_id, session_id, :unchanged, "Unchanged #{name}:#{version}")
        _ ->
          :ok
      end
    end)

    if result.pruned > 0 do
      broadcast_register_progress(register_id, session_id, :pruning, "Pruned #{result.pruned} stale component(s)")
    end

    broadcast_register_progress(register_id, session_id, :checking_deps, "Checking dependencies...")

    dep_info = check_register_deps(ctx, result.components, register_id, session_id)

    broadcast_register_progress(register_id, session_id, :complete,
      "Complete — #{result.registered} registered, #{result.unchanged} unchanged, #{result.total} total")

    {:ok, %{
      status: "scanned",
      components: result.components,
      registered: result.registered,
      unchanged: result.unchanged,
      pruned: result.pruned,
      errors: result.errors,
      total: result.total,
      elapsed_ms: result.elapsed_ms,
      scanned_dirs: result.scanned_dirs,
      pulled_dependencies: dep_info.pulled_dependencies,
      failed_pulls: dep_info.failed_pulls,
      missing_local_deps: dep_info.missing_local_deps,
      optional_missing: dep_info.optional_missing
    }}
  end

  # List action - list all installed components (local-only, no remote search)
  def handle("component", %Context{} = ctx, %{"action" => "list"} = args) do
    filters = %{
      type: args["type"],
      limit: args["limit"] || 1000
    }

    {:ok, result} = Registry.search(ctx, filters)
    {:ok, result}
  end

  # Remove action - remove a component from the registry
  def handle("component", %Context{} = ctx, %{"action" => "remove", "reference" => reference}) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, cref} ->
        case Registry.delete(ctx, cref.name, cref.version, cref.namespace) do
          :ok ->
            {:ok, %{status: "removed", reference: reference}}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}
        end

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  def handle("component", _ctx, %{"action" => "remove"}) do
    {:error, "Missing required argument: reference"}
  end

  # Categories action - list available categories
  def handle("component", %Context{} = _ctx, %{"action" => "categories"}) do
    {:ok,
     %{
       categories: [
         %{name: "api-integrations", description: "External API connectors"},
         %{name: "data-processing", description: "Data transformation and analysis"},
         %{name: "ai-ml", description: "Machine learning and AI tools"},
         %{name: "security", description: "Security and cryptography"},
         %{name: "utilities", description: "General-purpose utilities"}
       ]
     }}
  end

  # Get blob action - get component WASM binary by digest
  def handle("component", %Context{} = ctx, %{"action" => "get_blob", "digest" => digest}) do
    case Registry.get_blob(ctx, digest) do
      {:ok, bytes} ->
        {:ok, %{bytes: Base.encode64(bytes), digest: digest}}

      {:error, :blob_not_found} ->
        {:error, "Blob not found for digest: #{digest}"}

      {:error, reason} ->
        {:error, "Failed to get blob: #{inspect(reason)}"}
    end
  end

  def handle("component", _ctx, %{"action" => "get_blob"}) do
    {:error, "Missing required argument: digest"}
  end

  # Discover action - list components on a remote registry.
  # Core edition: uses cyfr.run REST API (no _catalog).
  # Arx edition: uses OCI _catalog with their own registry.
  def handle("component", %Context{} = ctx, %{"action" => "discover"} = args) do
    registry = args["registry"] || default_registry()

    case Compendium.Edition.validate_registry(registry) do
      {:error, msg} ->
        {:error, msg}

      :ok ->
        if Compendium.Edition.core_edition?() do
          params = %{namespace: args["namespace"], type: args["type"]}

          case Compendium.CyfrRun.Client.discover(ctx, params) do
            {:ok, result} ->
              {:ok, result}

            {:error, %Errors{} = err} ->
              Logger.error("[Compendium.MCP] CYFR.RUN DISCOVER FAILED — #{Errors.to_log_string(err)}")
              {:error, format_error(err)}
          end
        else
          namespace = args["namespace"]

          case Compendium.OCI.Client.discover(registry, namespace) do
            {:ok, result} ->
              for err <- result[:errors] || [] do
                Logger.warning("[Compendium.MCP] Discover: #{err}")
              end

              {:ok, result}

            {:error, %Errors{} = err} ->
              Logger.error("[Compendium.MCP] DISCOVER FAILED for #{registry} — #{Errors.to_log_string(err)}")
              {:error, format_error(err)}

            {:error, reason} ->
              {:error, format_error(reason)}
          end
        end
    end
  end

  # ============================================================================
  # Setup Plan Action
  # ============================================================================

  def handle("component", %Context{} = ctx, %{"action" => "setup_plan", "reference" => reference}) do
    case resolve_component(ctx, reference) do
      {:ok, component, ref} ->
        canonical_ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
          type: ref.type, namespace: ref.namespace,
          name: ref.name, version: ref.version
        })
        manifest = component[:manifest] || component["manifest"] || %{}
        setup = manifest["setup"] || %{}

        secrets_status = check_secrets_status(ctx, canonical_ref, setup["secrets"] || [])
        policy_status = check_policy_status(ctx, canonical_ref)
        policy_effective = get_effective_policy(ctx, canonical_ref)
        deps = extract_dependency_refs(manifest)
        description = component[:description] || component["description"] || manifest["description"]

        configurable_fields =
          case Sanctum.Policy.FieldSchema.configurable_fields(setup["policy"]) do
            {:ok, fields} -> fields
            {:error, _} -> nil
          end

        {:ok, %{
          component_ref: canonical_ref,
          description: description,
          type: ref.type,
          setup: setup,
          secrets: secrets_status,
          policy_recommended: setup["policy"],
          policy_current: policy_effective || policy_status,
          policy_stored: policy_status != nil,
          configurable_fields: configurable_fields,
          dependencies: deps,
          ready: all_configured?(secrets_status, policy_status)
        }}

      {:error, reason} -> {:error, reason}
    end
  end

  def handle("component", _ctx, %{"action" => "setup_plan"}) do
    {:error, "Missing required argument: reference"}
  end

  # Invalid action
  def handle("component", _ctx, %{"action" => action}) do
    {:error, "Invalid component action: #{action}"}
  end

  # Missing action
  def handle("component", _ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  # ============================================================================
  # Guide Tool
  # ============================================================================

  def handle("guide", _ctx, %{"action" => "list"}) do
    {:ok,
     %{
       guides: [
         %{
           name: "component-guide",
           title: "Component Guide",
           description: "Practical guide to building WASM components for CYFR"
         },
         %{
           name: "integration-guide",
           title: "Integration Guide",
           description: "How to use CYFR as your application backend"
         },
         %{
           name: "agent-guide",
           title: "Agent Guide",
           description: "Reference for AI agents running inside the CYFR sandbox"
         }
       ],
       count: 3
     }}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => "component-guide"}) do
    {:ok, %{name: "component-guide", format: "markdown", content: @component_guide}}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => "integration-guide"}) do
    {:ok, %{name: "integration-guide", format: "markdown", content: @integration_guide}}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => "agent-guide"}) do
    {:ok, %{name: "agent-guide", format: "markdown", content: @agent_guide}}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => name}) do
    {:error, "Unknown guide: #{name}. Available: component-guide, integration-guide, agent-guide"}
  end

  def handle("guide", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("guide", %Context{} = ctx, %{"action" => "readme", "reference" => reference}) do
    case resolve_component(ctx, reference) do
      {:ok, _component, ref} ->
        path = ["components", "#{ref.type}s", ref.namespace, ref.name, ref.version, "README.md"]

        case Arca.get(ctx, path) do
          {:ok, content} ->
            {:ok, %{reference: reference, format: "markdown", content: content}}

          {:error, _} ->
            {:error, "No README.md found for #{reference}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle("guide", _ctx, %{"action" => "readme"}) do
    {:error, "Missing required argument: reference"}
  end

  def handle("guide", _ctx, _args) do
    {:error, "Invalid guide action. Use: list, get, or readme"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Artifact Resolution
  # ============================================================================

  defp resolve_artifact(%{"path" => path}) when is_binary(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp resolve_artifact(%{"base64" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  defp resolve_artifact(%{"url" => _url}) do
    {:error, "URL artifact resolution not yet implemented for publish"}
  end

  defp resolve_artifact(_), do: {:error, :invalid_artifact_type}

  # ============================================================================
  # Inspect Fallback (Core edition → cyfr.run)
  # ============================================================================

  defp inspect_cyfr_run_fallback(ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        component_type = type || (
          Logger.warning("[Compendium.MCP] No component type specified for #{reference}, defaulting to \"reagent\". " <>
                         "Specify type in the reference (e.g., catalyst:#{reference}) for accurate results.")
          "reagent"
        )
        api_version = if version != "latest", do: version, else: nil

        case Compendium.CyfrRun.Client.get_component(ctx, component_type, namespace, name, api_version) do
          {:ok, component} ->
            canonical_ref = Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
              type: component_type,
              namespace: namespace,
              name: name,
              version: component["version"] || version
            })

            {:ok, component
              |> Map.put("component_ref", canonical_ref)
              |> Map.put("type", component_type)
              |> Map.put("source", "cyfr.run")
              |> Map.put("note", "Component found on cyfr.run but not locally. " <>
                                 "Run `component pull #{reference}` to download it.")}

          {:error, %Errors{} = err} ->
            Logger.error("[Compendium.MCP] Inspect fallback to cyfr.run failed for #{reference}: #{Errors.to_log_string(err)}")
            {:error, "Component not found locally or on cyfr.run: #{reference} (#{format_error(err)})"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Registry Default
  # ============================================================================

  defp default_registry do
    case Application.get_env(:compendium, :registry) do
      config when is_list(config) ->
        Keyword.get(config, :url, Compendium.Edition.cyfr_run_registry())

      _ ->
        Compendium.Edition.cyfr_run_registry()
    end
  end

  # ============================================================================
  # Error Formatting
  # ============================================================================

  defp format_error(%Errors{} = err) do
    msg = Errors.to_string(err)
    hint = Errors.actionable_hint(err)
    if hint != "", do: "#{msg}. #{hint}", else: msg
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # ============================================================================
  # Dependency Auto-Pull
  # ============================================================================

  # Enrich a local pull result with auto-pulled dependencies.
  defp enrich_pull_with_deps(ctx, component, result) do
    manifest = decode_manifest(component[:manifest] || component["manifest"])

    case Compendium.DependencyResolver.extract_from_manifest(manifest, component[:id] || "") do
      {:ok, []} ->
        result

      {:ok, deps} ->
        auto_pull_deps(ctx, deps, result)

      {:error, _} ->
        result
    end
  end

  # ============================================================================
  # Register Dependency Checking
  # ============================================================================

  # Namespaces that represent local/on-disk components (not pullable from OCI).
  @local_dep_namespaces ["local"]

  # After registration, check newly registered formulas for missing dependencies.
  # Local deps (local/agent namespaces) produce warnings; published deps are auto-pulled.
  defp check_register_deps(ctx, components, register_id \\ nil, session_id \\ nil) do
    empty = %{pulled_dependencies: [], failed_pulls: [], missing_local_deps: [], optional_missing: []}

    newly_registered_formulas =
      Enum.filter(components, fn comp ->
        status = comp[:status] || comp["status"]
        type = comp[:type] || comp["type"]
        status == "registered" and type == "formula"
      end)

    if newly_registered_formulas == [] do
      empty
    else
      all_deps =
        Enum.flat_map(newly_registered_formulas, fn comp ->
          case resolve_manifest_for_deps(ctx, comp) do
            {:ok, deps} -> deps
            :skip -> []
          end
        end)
        |> Enum.uniq_by(& &1[:dependency_ref])

      if all_deps == [] do
          empty
      else
        availability = Compendium.DependencyResolver.classify_availability(ctx, all_deps)

        optional_refs = Enum.map(availability.optional_missing, & &1[:dependency_ref])

        {local_missing, published_missing} =
          Enum.split_with(availability.missing, fn dep ->
            ns = dep[:dep_namespace] || dep["dep_namespace"]
            ns in @local_dep_namespaces
          end)

        local_refs = Enum.map(local_missing, & &1[:dependency_ref])

        {pulled_refs, failed_refs} = auto_pull_published_deps(ctx, published_missing, register_id, session_id)

        %{
          pulled_dependencies: pulled_refs,
          failed_pulls: failed_refs,
          missing_local_deps: local_refs,
          optional_missing: optional_refs
        }
      end
    end
  rescue
    e ->
      Logger.warning("[Compendium.MCP] Exception in check_register_deps: #{Exception.message(e)}")
      %{pulled_dependencies: [], failed_pulls: [], missing_local_deps: [], optional_missing: []}
  end

  # Look up a freshly registered component and extract its dependencies.
  defp resolve_manifest_for_deps(ctx, comp) do
    name = comp[:name] || comp["name"]
    version = comp[:version] || comp["version"]
    type = comp[:type] || comp["type"]

    case Arca.MCP.handle("component_store", ctx, %{
           "action" => "get",
           "name" => name,
           "version" => version,
           "component_type" => type
         }) do
      {:ok, %{component: component}} ->
        manifest = decode_manifest(component[:manifest] || component["manifest"])
        component_id = component[:id] || ""

        case Compendium.DependencyResolver.extract_from_manifest(manifest, component_id) do
          {:ok, []} -> :skip
          {:ok, deps} -> {:ok, deps}
          {:error, _} -> :skip
        end

      _ ->
        :skip
    end
  end

  # Auto-pull published (non-local) missing dependencies via OCI.
  defp auto_pull_published_deps(ctx, published_missing, register_id \\ nil, session_id \\ nil) do
    {pulled, failed, _visited} =
      Enum.reduce(published_missing, {[], [], MapSet.new()}, fn dep, {acc, failed_acc, visited} ->
        ref = dep[:dependency_ref]
        Logger.info("[Compendium.MCP] Auto-pulling dependency after register: #{ref}")
        broadcast_register_progress(register_id, session_id, :pulling, "Pulling #{ref}...")

        case do_auto_pull(ctx, ref, visited) do
          {:ok, :cycle_skipped} ->
            {acc, failed_acc, visited}

          {:ok, _} ->
            broadcast_register_progress(register_id, session_id, :pulled, "Pulled #{ref}")
            {[ref | acc], failed_acc, MapSet.put(visited, ref)}

          {:error, reason} ->
            Logger.warning("[Compendium.MCP] Failed to auto-pull #{ref}: #{inspect(reason)}")
            broadcast_register_progress(register_id, session_id, :pull_failed, "Failed to pull #{ref}")
            {acc, [ref | failed_acc], visited}
        end
      end)

    {Enum.reverse(pulled), Enum.reverse(failed)}
  end

  # Broadcast register progress to both PubSub (Prism) and SSEBuffer (CLI).
  defp broadcast_register_progress(nil, _session_id, _phase, _message), do: :ok

  defp broadcast_register_progress(register_id, session_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    Phoenix.PubSub.broadcast(Emissary.PubSub, "register:#{register_id}", {:register_progress, payload})

    if session_id do
      notification = Emissary.MCP.Message.encode_notification("notifications/progress", %{
        register_id: register_id, phase: phase, message: message
      })
      Emissary.MCP.SSEBuffer.push(session_id, notification)
    end

    :ok
  end

  # Broadcast generic progress to both PubSub (Prism) and SSEBuffer (CLI).
  # Used by pull and publish handlers.
  defp broadcast_progress(nil, _session_id, _phase, _message), do: :ok

  defp broadcast_progress(progress_id, session_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    Phoenix.PubSub.broadcast(Emissary.PubSub, "progress:#{progress_id}", {:progress, payload})

    if session_id do
      notification = Emissary.MCP.Message.encode_notification("notifications/progress", %{
        progress_id: progress_id, phase: phase, message: message
      })
      Emissary.MCP.SSEBuffer.push(session_id, notification)
    end

    :ok
  end

  # Convert a component-ref style reference to an OCI reference for pulling.
  # Local components are registered via `cyfr register`, not pulled.
  @local_publishers ["local"]
  defp convert_to_oci_ref(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %Sanctum.ComponentRef{namespace: ns}} when ns in @local_publishers ->
        {:error, "Cannot pull local components. Use `cyfr register` to index local components."}

      {:ok, %Sanctum.ComponentRef{} = cref} ->
        registry = Compendium.Edition.cyfr_run_registry()

        case Compendium.OCI.Reference.from_component_ref(cref, registry) do
          {:ok, oci_ref} -> {:ok, Compendium.OCI.Reference.to_string(oci_ref)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  # Shared OCI pull logic used by both explicit OCI refs and converted component refs.
  defp do_oci_pull(ctx, reference) do
    if Compendium.Edition.core_edition?() do
      case Compendium.OCI.Reference.parse(reference) do
        {:ok, ref} ->
          case Compendium.Edition.validate_registry(ref.registry) do
            :ok ->
              anonymous? = Compendium.OCI.Auth.resolve_credentials(Compendium.Edition.cyfr_run_registry()) == :anonymous

              if anonymous? do
                Logger.warning("[Compendium.MCP] No credentials for #{Compendium.Edition.cyfr_run_registry()} — " <>
                               "pull may fail for non-public components. Run `cyfr login` to authenticate.")
              end

              case Compendium.OCI.Client.pull(ctx, reference) do
                {:ok, result} ->
                  if result[:warning], do: Logger.warning("[Compendium.MCP] #{result.warning}")

                  result =
                    if anonymous? do
                      Map.put(result, :auth_note,
                        "You are pulling anonymously from #{Compendium.Edition.cyfr_run_registry()}. " <>
                        "Private components will not be accessible. Run `cyfr login` to authenticate.")
                    else
                      result
                    end

                  result = maybe_auto_pull_oci_deps(ctx, reference, result)
                  {:ok, result}

                {:error, reason} ->
                  if anonymous? do
                    {:error, reason <> " — No credentials configured for #{Compendium.Edition.cyfr_run_registry()}. " <>
                                    "Run `cyfr login` to authenticate."}
                  else
                    {:error, reason}
                  end
              end

            {:error, msg} ->
              {:error, msg}
          end

        {:error, reason} ->
          {:error, "Invalid OCI reference: #{reason}"}
      end
    else
      case Compendium.OCI.Client.pull(ctx, reference) do
        {:ok, result} ->
          if result[:warning], do: Logger.warning("[Compendium.MCP] #{result.warning}")
          result = maybe_auto_pull_oci_deps(ctx, reference, result)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Enrich an OCI pull result with auto-pulled dependencies.
  # After OCI pull, the component should be in the local registry.
  # Uses component_ref from the pull result (not the OCI URL) for lookup.
  defp maybe_auto_pull_oci_deps(ctx, _oci_reference, result) do
    ref = result[:component_ref] || result["component_ref"]

    case ref && resolve_component(ctx, ref) do
      {:ok, component, _ref} ->
        enrich_pull_with_deps(ctx, component, result)

      _ ->
        result
    end
  rescue
    e ->
      Logger.warning("[Compendium.MCP] Exception in auto-pull OCI deps: #{Exception.message(e)}")
      result
  end

  # Auto-pull missing dependencies. Uses a visited set for cycle detection.
  defp auto_pull_deps(ctx, deps, result) do
    availability = Compendium.DependencyResolver.classify_availability(ctx, deps)

    {pulled, failed, _visited} =
      Enum.reduce(availability.missing, {[], [], MapSet.new()}, fn dep, {acc, failed_acc, visited} ->
        ref = dep[:dependency_ref]
        Logger.info("[Compendium.MCP] Auto-pulling dependency: #{ref}")

        case do_auto_pull(ctx, ref, visited) do
          {:ok, :cycle_skipped} ->
            {acc, failed_acc, visited}

          {:ok, _} ->
            {[ref | acc], failed_acc, MapSet.put(visited, ref)}

          {:error, reason} ->
            Logger.warning("[Compendium.MCP] Failed to auto-pull #{ref}: #{inspect(reason)}")
            {acc, [ref | failed_acc], visited}
        end
      end)

    optional_missing = Enum.map(availability.optional_missing, & &1[:dependency_ref])

    result
    |> Map.put(:pulled_dependencies, Enum.reverse(pulled))
    |> Map.put(:failed_pulls, Enum.reverse(failed))
    |> Map.put(:optional_missing, optional_missing)
  end

  # Recursive auto-pull with cycle detection.
  # Calls the pull handler for the dependency, which in turn triggers
  # enrich_pull_with_deps for transitive dependency resolution.
  defp do_auto_pull(ctx, ref, visited) when is_binary(ref) do
    if MapSet.member?(visited, ref) do
      {:ok, :cycle_skipped}
    else
      case handle("component", ctx, %{"action" => "pull", "reference" => ref}) do
        {:ok, _result} -> {:ok, :pulled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ============================================================================
  # Inspect Dependency Enrichment
  # ============================================================================

  # Conditionally enriches an inspect result with dependency resolution info.
  # Only adds dependency fields when the component declares deps (keeps response
  # lean for simple components like reagents with no dependencies).
  defp maybe_enrich_with_dependencies(ctx, component, result) do
    manifest = decode_manifest(component[:manifest] || component["manifest"])

    static_deps = get_in(manifest, ["dependencies", "static"]) || []
    has_dynamic = Compendium.DependencyResolver.has_dynamic_deps?(manifest)

    if static_deps == [] and not has_dynamic do
      result
    else
      component_id = component[:id] || component["id"]

      case Compendium.DependencyResolver.resolve_tree(ctx, component_id, manifest) do
        {:ok, tree} ->
          flat_deps = flatten_dep_tree(tree)
          availability = Compendium.DependencyResolver.classify_availability(ctx, flat_deps)

          result
          |> Map.put("dependencies", tree)
          |> Map.put("has_dynamic", has_dynamic)
          |> Map.put("all_satisfied", availability.all_satisfied)
          |> Map.put("missing", Enum.map(availability.missing, & &1[:dependency_ref]))
          |> Map.put("optional_missing", Enum.map(availability.optional_missing, & &1[:dependency_ref]))

        {:error, _reason} ->
          result
      end
    end
  end

  # Flatten a dependency tree into a flat list for availability classification.
  defp flatten_dep_tree(tree) when is_list(tree) do
    Enum.flat_map(tree, fn node ->
      children = Map.get(node, :children, [])
      base = Map.drop(node, [:children, :cycle])
      [base | flatten_dep_tree(children)]
    end)
  end

  defp decode_manifest(nil), do: %{}
  defp decode_manifest(m) when is_map(m), do: m

  defp decode_manifest(m) when is_binary(m) do
    case Jason.decode(m) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  # ============================================================================
  # Component Resolution
  # ============================================================================

  # Resolves a component reference string into a component map and a ref map
  # with the actual resolved version. When the parsed version is "latest"
  # (e.g., bare name without version), resolves to the most recent published
  # version via Registry.get_latest/4.
  defp resolve_component(ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        result =
          if version == "latest" do
            # get_latest uses list action which omits manifest; resolve version
            # then re-fetch with get to include manifest
            case Registry.get_latest(ctx, name, namespace, type) do
              {:ok, component} ->
                resolved_version = component[:version]
                if resolved_version do
                  Registry.get(ctx, name, resolved_version, namespace, type)
                else
                  {:ok, component}
                end
              error -> error
            end
          else
            Registry.get(ctx, name, version, namespace, type)
          end

        case result do
          {:ok, component} ->
            resolved_version = component[:version] || version
            resolved_type = type || component[:component_type] || component[:type]
            {:ok, component, %{namespace: namespace, name: name, version: resolved_version, type: resolved_type}}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Reference Parsing
  # ============================================================================

  @doc false
  # Parse a component reference using the canonical format (type:namespace.name:version).
  # Returns {:ok, namespace, name, version, type} for database lookup.
  # The namespace is used as the publisher filter for disambiguation.
  # The type may be nil when not specified in the ref.
  defp parse_reference(reference) when is_binary(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %Sanctum.ComponentRef{type: type, namespace: namespace, name: name, version: version}} ->
        {:ok, namespace, name, version, type}

      {:error, reason} ->
        {:error, "Invalid reference format: #{reference}. #{reason}"}
    end
  end

  defp parse_reference(_), do: {:error, "Reference must be a string"}

  # ============================================================================
  # Search Result Merging (Core edition: local + cyfr.run)
  # ============================================================================

  defp merge_search_results({:ok, local}, remote) do
    local_components = local[:components] || []
    remote_components = remote[:components] || []

    # Deduplicate: local takes precedence over remote duplicates
    local_keys = MapSet.new(local_components, &component_dedup_key/1)

    unique_remote =
      Enum.reject(remote_components, fn comp ->
        MapSet.member?(local_keys, component_dedup_key(comp))
      end)

    merged = local_components ++ unique_remote

    {:ok, %{
      components: merged,
      total: length(merged),
      local_count: length(local_components),
      remote_count: length(unique_remote)
    }}
  end

  defp component_dedup_key(comp) when is_map(comp) do
    {comp["name"] || comp[:name],
     comp["publisher"] || comp[:publisher],
     comp["version"] || comp[:version]}
  end

  # ============================================================================
  # Setup Plan Helpers
  # ============================================================================

  # Check which secrets are already set and granted for a component.
  # Returns a list of maps with name, description, required, already_set, already_granted.
  defp check_secrets_status(ctx, canonical_ref, secret_specs) do
    # Get list of existing secrets
    {existing_secrets, secrets_error} = case Sanctum.MCP.handle("secret", ctx, %{"action" => "list"}) do
      {:ok, %{secrets: names}} -> {MapSet.new(names), nil}
      other ->
        Logger.warning("[Compendium.MCP] Failed to list secrets: #{inspect(other)}")
        {MapSet.new(), "Unable to check secret status (Sanctum unavailable)"}
    end

    # Get list of granted secrets for this component
    {granted_secrets, grants_error} = case Sanctum.MCP.handle("secret", ctx, %{
      "action" => "resolve_granted",
      "component_ref" => canonical_ref
    }) do
      {:ok, %{secrets: secrets}} when is_map(secrets) -> {MapSet.new(Map.keys(secrets)), nil}
      other ->
        Logger.warning("[Compendium.MCP] Failed to resolve granted secrets for #{canonical_ref}: #{inspect(other)}")
        {MapSet.new(), "Unable to check grant status (Sanctum unavailable)"}
    end

    warning = secrets_error || grants_error

    specs = Enum.map(secret_specs, fn spec ->
      name = spec["name"]
      entry = %{
        name: name,
        description: spec["description"],
        required: spec["required"] || false,
        already_set: MapSet.member?(existing_secrets, name),
        already_granted: MapSet.member?(granted_secrets, name)
      }
      if warning, do: Map.put(entry, :warning, warning), else: entry
    end)

    specs
  end

  # Check if a policy exists for the component.
  # Returns the current policy map or nil if no policy is set.
  defp check_policy_status(ctx, canonical_ref) do
    case Sanctum.MCP.handle("policy", ctx, %{
      "action" => "get",
      "component_ref" => canonical_ref
    }) do
      {:ok, %{policy: policy}} -> policy
      _ -> nil
    end
  end

  # Returns the effective policy (stored policy or type defaults).
  defp get_effective_policy(ctx, canonical_ref) do
    case Sanctum.Policy.get_effective(ctx, canonical_ref) do
      {:ok, %Sanctum.Policy{} = policy} -> Map.from_struct(policy)
      {:ok, policy} when is_map(policy) -> policy
      _ -> nil
    end
  end

  # Returns true when all required secrets are set+granted and a policy exists.
  defp all_configured?(secrets_status, policy_status) do
    secrets_ready = Enum.all?(secrets_status, fn s ->
      !s.required || (s.already_set && s.already_granted)
    end)

    secrets_ready && policy_status != nil
  end

  # Extract dependency refs from a component manifest for display.
  defp extract_dependency_refs(component) do
    deps = component["dependencies"] || component[:dependencies] || %{}
    static = deps["static"] || deps[:static] || []

    Enum.map(static, fn dep ->
      %{
        ref: dep["ref"] || dep[:ref],
        optional: dep["optional"] || dep[:optional] || false,
        reason: dep["reason"] || dep[:reason]
      }
    end)
  end
end
