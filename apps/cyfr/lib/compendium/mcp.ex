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

  @behaviour Emissary.MCP.ToolProvider

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
        case Jason.encode(component) do
          {:ok, json} -> {:ok, %{content: json, mimeType: "application/json"}}
          {:error, _} -> {:error, "Failed to encode component as JSON"}
        end

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
                Logger.error("[Compendium.MCP] Asset not found: #{rest} (#{inspect(reason)})")
                {:error, "Asset not found: #{rest}"}
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

  # Inspect action - delegates to Compendium.Component.inspect_component/2
  def handle("component", %Context{} = ctx, %{"action" => "inspect", "reference" => reference}) do
    Compendium.Component.inspect_component(ctx, reference)
  end

  def handle("component", _ctx, %{"action" => "inspect"}) do
    {:error, "Missing required argument: reference"}
  end

  # Pull action - pull component from registry (local or OCI)
  def handle("component", %Context{} = ctx, %{"action" => "pull"} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
      progress_id = args["progress_id"]
      session_id = ctx.session_id

      case args["reference"] do
        nil ->
          {:error, "Missing required argument: reference"}

        reference ->
          with {:ok, reference} <- Compendium.Resolver.resolve_or_passthrough(ctx, reference) do
          oci_reference =
            if Compendium.OCI.Reference.oci_ref?(reference) do
              {:ok, reference}
            else
              convert_to_oci_ref(reference)
            end

          case oci_reference do
            {:ok, ref} ->
              broadcast_progress(ctx, progress_id, session_id, :pulling, "Pulling #{ref}...")
              result = do_oci_pull(ctx, ref)

              case result do
                {:ok, res} ->
                  broadcast_progress(ctx, progress_id, session_id, :complete, "Pulled #{res[:component_ref] || ref}")
                {:error, reason} ->
                  Logger.error("[Compendium.MCP] Pull failed: #{inspect(reason)}")
                  broadcast_progress(ctx, progress_id, session_id, :error, "Pull failed")
              end

              result

            {:error, reason} -> {:error, reason}
          end
        end
      end
    end
  end

  # Publish action - publish WASM artifact to permanent storage (and optionally push to OCI registry)
  def handle("component", %Context{} = ctx, %{"action" => "publish"} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
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
            {:ok, %{version: nil}} ->
              {:error, "Version is required for publishing. Example: c:local.name:1.0.0"}

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
                    broadcast_progress(ctx, progress_id, session_id, :pushing, "Pushing #{reference} to #{registry}...")

                    case Compendium.OCI.Client.push(ctx, reference, registry) do
                      {:ok, result} ->
                        broadcast_progress(ctx, progress_id, session_id, :complete, "Published #{result[:oci_reference] || reference}")
                        {:ok, result}

                      {:error, reason} ->
                        Logger.error("[Compendium.MCP] Push failed: #{inspect(reason)}")
                        broadcast_progress(ctx, progress_id, session_id, :error, "Push failed")
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
            {:ok, _namespace, _name, nil, _type} ->
              {:error, "Version is required for publishing. Example: c:local.name:1.0.0"}

            {:ok, namespace, name, version, _type} ->
              case resolve_artifact(artifact) do
                {:ok, wasm_bytes} ->
                  broadcast_progress(ctx, progress_id, session_id, :publishing, "Publishing #{name}:#{version}...")

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
                      broadcast_progress(ctx, progress_id, session_id, :complete, "Published #{name}:#{version}")

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
                      {:error, "Publish failed"}
                  end

                {:error, reason} ->
                  Logger.error("[Compendium.MCP] Failed to resolve artifact: #{inspect(reason)}")
                  {:error, "Failed to resolve artifact"}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  # New action - scaffold a new component project
  def handle("component", %Context{} = ctx, %{"action" => "new"} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
      name = args["name"]
      type = args["type"]
      version = args["version"] || "0.1.0"

      Compendium.Scaffold.create(ctx, name, type, version)
    end
  end

  # Register action - scan and register all local components
  def handle("component", %Context{} = ctx, %{"action" => "register"} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
      register_id = args["register_id"]
      session_id = ctx.session_id

      broadcast_register_progress(ctx, register_id, session_id, :scanning, "Scanning component directories...")

      result = Compendium.AutoIndexer.scan(Compendium.AutoIndexer.default_component_dirs(), ctx: ctx)

      # Broadcast per-component status
      Enum.each(result.components, fn comp ->
        status = comp[:status] || comp["status"]
        name = comp[:name] || comp["name"]
        version = comp[:version] || comp["version"]

        case status do
          "registered" ->
            broadcast_register_progress(ctx, register_id, session_id, :registered, "Registered #{name}:#{version}")
          "unchanged" ->
            broadcast_register_progress(ctx, register_id, session_id, :unchanged, "Unchanged #{name}:#{version}")
          _ ->
            :ok
        end
      end)

      if result.pruned > 0 do
        broadcast_register_progress(ctx, register_id, session_id, :pruning, "Pruned #{result.pruned} stale component(s)")
      end

      broadcast_register_progress(ctx, register_id, session_id, :checking_deps, "Checking dependencies...")

      dep_info = check_register_deps(ctx, result.components, register_id, session_id)

      broadcast_register_progress(ctx, register_id, session_id, :complete,
        "Complete — #{result.registered} registered, #{result.unchanged} unchanged, #{result.total} total")

      dep_fields = case dep_info do
        {:error, {:dependency_check_failed, reason}} ->
          %{pulled_dependencies: [], failed_pulls: [], missing_local_deps: [],
            optional_missing: [], dependency_check_error: reason}
        %{} = info ->
          Map.take(info, [:pulled_dependencies, :failed_pulls, :missing_local_deps, :optional_missing])
      end

      {:ok, Map.merge(%{
        status: "scanned",
        components: result.components,
        registered: result.registered,
        unchanged: result.unchanged,
        pruned: result.pruned,
        errors: result.errors,
        total: result.total,
        elapsed_ms: result.elapsed_ms,
        scanned_dirs: result.scanned_dirs
      }, dep_fields)}
    end
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
    with :ok <- require_permission(ctx, :component_manage) do
      case Sanctum.ComponentRef.parse(reference) do
        {:ok, %{version: nil} = cref} ->
          # Check if name is even valid before giving version error
          case Sanctum.ComponentRef.validate_name(cref.name) do
            :ok -> {:error, "Version is required for removal. Example: c:local.name:1.0.0"}
            {:error, reason} -> {:error, "Invalid reference: #{reason}"}
          end

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
    with :ok <- require_permission(ctx, :component_read) do
      case Registry.get_blob(ctx, digest) do
        {:ok, bytes} ->
          {:ok, %{bytes: Base.encode64(bytes), digest: digest}}

        {:error, :blob_not_found} ->
          {:error, "Blob not found for digest: #{digest}"}

        {:error, reason} ->
          Logger.error("[Compendium.MCP] Failed to get blob: #{inspect(reason)}")
          {:error, "Failed to get blob"}
      end
    end
  end

  def handle("component", _ctx, %{"action" => "get_blob"}) do
    {:error, "Missing required argument: digest"}
  end

  # Discover action - list components on a remote registry.
  # Core edition: uses cyfr.run REST API (no _catalog).
  # Arx edition: uses OCI _catalog with their own registry.
  def handle("component", %Context{} = ctx, %{"action" => "discover"} = args) do
    with :ok <- require_permission(ctx, :component_read) do
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
  end

  # ============================================================================
  # Setup Plan Action
  # ============================================================================

  def handle("component", %Context{} = ctx, %{"action" => "setup_plan", "reference" => reference}) do
    Compendium.Component.setup_plan(ctx, reference)
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
  # Registry Default
  # ============================================================================

  defp default_registry do
    case Application.get_env(:cyfr, :registry) do
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
  defp check_register_deps(ctx, components, register_id, session_id) do
    empty = %{pulled_dependencies: [], failed_pulls: [], missing_local_deps: [], optional_missing: []}

    formulas_to_check =
      Enum.filter(components, fn comp ->
        status = comp[:status] || comp["status"]
        type = comp[:type] || comp["type"]
        type == "formula" and status in ["registered", "unchanged"]
      end)

    if formulas_to_check == [] do
      empty
    else
      all_deps =
        Enum.flat_map(formulas_to_check, fn comp ->
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
    e in [Mint.TransportError, Mint.HTTPError, Jason.DecodeError, MatchError, KeyError, Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[Compendium.MCP] Exception in check_register_deps: #{Exception.message(e)}")
      {:error, {:dependency_check_failed, Exception.message(e)}}
  end

  # Look up a freshly registered component and extract its dependencies.
  defp resolve_manifest_for_deps(ctx, comp) do
    name = comp[:name] || comp["name"]
    version = comp[:version] || comp["version"]
    type = comp[:type] || comp["type"]

    publisher = comp[:publisher] || comp["publisher"] || "local"

    case Arca.ComponentStorage.get_component(ctx, name, version, publisher, type) do
      {:ok, component} ->
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
  defp auto_pull_published_deps(ctx, published_missing, register_id, session_id) do
    {pulled, failed, _visited} =
      Enum.reduce(published_missing, {[], [], MapSet.new()}, fn dep, {acc, failed_acc, visited} ->
        ref = dep[:dependency_ref]
        Logger.info("[Compendium.MCP] Auto-pulling dependency after register: #{ref}")
        broadcast_register_progress(ctx, register_id, session_id, :pulling, "Pulling #{ref}...")

        case do_auto_pull(ctx, ref, visited) do
          {:ok, :cycle_skipped} ->
            {acc, failed_acc, visited}

          {:ok, _} ->
            broadcast_register_progress(ctx, register_id, session_id, :pulled, "Pulled #{ref}")
            {[ref | acc], failed_acc, MapSet.put(visited, ref)}

          {:error, reason} ->
            Logger.warning("[Compendium.MCP] Failed to auto-pull #{ref}: #{inspect(reason)}")
            broadcast_register_progress(ctx, register_id, session_id, :pull_failed, "Failed to pull #{ref}")
            {acc, [ref | failed_acc], visited}
        end
      end)

    {Enum.reverse(pulled), Enum.reverse(failed)}
  end

  # Broadcast register progress to both PubSub (Prism) and SSEBuffer (CLI).
  defp broadcast_register_progress(_ctx, nil, _session_id, _phase, _message), do: :ok

  defp broadcast_register_progress(ctx, register_id, session_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    Phoenix.PubSub.broadcast(Emissary.PubSub, Sanctum.PubSub.topic("register:#{register_id}", ctx), {:register_progress, payload})

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
  defp broadcast_progress(_ctx, nil, _session_id, _phase, _message), do: :ok

  defp broadcast_progress(ctx, progress_id, session_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    Phoenix.PubSub.broadcast(Emissary.PubSub, Sanctum.PubSub.topic("progress:#{progress_id}", ctx), {:progress, payload})

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

      {:ok, %Sanctum.ComponentRef{version: nil} = cref} ->
        registry = Compendium.Edition.cyfr_run_registry()

        {:ok, oci_ref} = Compendium.OCI.Reference.from_component_ref(cref, registry)

        case resolve_latest_oci_tag(oci_ref) do
          {:ok, tag} -> {:ok, Compendium.OCI.Reference.to_string(%{oci_ref | tag: tag})}
          {:error, _} -> {:ok, Compendium.OCI.Reference.to_string(oci_ref)}
        end

      {:ok, %Sanctum.ComponentRef{} = cref} ->
        registry = Compendium.Edition.cyfr_run_registry()
        {:ok, oci_ref} = Compendium.OCI.Reference.from_component_ref(cref, registry)
        {:ok, Compendium.OCI.Reference.to_string(oci_ref)}

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  # Resolve the latest semver tag from an OCI repository (for versionless pulls).
  defp resolve_latest_oci_tag(%Compendium.OCI.Reference{} = ref) do
    path = "/v2/#{ref.repository}/tags/list"

    case Compendium.OCI.Transport.request(:get, path, ref) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"tags" => tags}} when is_list(tags) ->
            semver_tags = Enum.filter(tags, &semver_tag?/1) |> Enum.sort(&semver_gte?/2)
            case semver_tags do
              [latest | _] -> {:ok, latest}
              [] -> {:error, :no_semver_tags}
            end
          _ -> {:error, :unexpected_response}
        end
      _ -> {:error, :tags_fetch_failed}
    end
  end

  defp semver_tag?(tag), do: Regex.match?(~r/^\d+\.\d+\.\d+/, tag)

  defp semver_gte?(a, b) do
    parse_semver(a) >= parse_semver(b)
  end

  defp parse_semver(tag) do
    tag |> String.split(".") |> Enum.map(fn p ->
      case Integer.parse(p) do
        {n, _} -> n
        :error -> 0
      end
    end)
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
    e in [Mint.TransportError, Mint.HTTPError, Jason.DecodeError, MatchError, KeyError, Ecto.QueryError, DBConnection.ConnectionError] ->
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

  defdelegate decode_manifest(value), to: Compendium.Manifest, as: :decode

  # ============================================================================
  # Component Resolution
  # ============================================================================

  # Resolves a component reference string into a component map and a ref map
  # with the actual resolved version. When the parsed version is nil
  # (e.g., bare name without version), resolves to the most recent published
  # version via Registry.get_latest/4.
  defp resolve_component(ctx, reference) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        result =
          if version == nil do
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

    # Build lookup of latest remote version per (name, publisher, type)
    remote_by_identity =
      Enum.reduce(remote_components, %{}, fn comp, acc ->
        key = component_identity_key(comp)
        version = comp["version"] || comp[:version]

        case Map.get(acc, key) do
          nil ->
            Map.put(acc, key, {version, comp})

          {existing_version, _existing_comp} ->
            if version_gt?(version, existing_version) do
              Map.put(acc, key, {version, comp})
            else
              acc
            end
        end
      end)

    # Build set of local identity keys
    local_identity_keys = MapSet.new(local_components, &component_identity_key/1)

    # Annotate local components with remote version info
    annotated_local =
      Enum.map(local_components, fn comp ->
        key = component_identity_key(comp)
        local_version = comp["version"] || comp[:version]

        case Map.get(remote_by_identity, key) do
          {remote_version, _remote_comp} ->
            update_available = version_gt?(remote_version, local_version)

            comp
            |> Map.put(:local_version, local_version)
            |> Map.put(:remote_latest, remote_version)
            |> Map.put(:update_available, update_available)

          nil ->
            comp
            |> Map.put(:local_version, local_version)
            |> Map.put(:remote_latest, nil)
            |> Map.put(:update_available, false)
        end
      end)

    # Remote-only components (not installed locally)
    remote_only =
      remote_by_identity
      |> Enum.reject(fn {key, _} -> MapSet.member?(local_identity_keys, key) end)
      |> Enum.map(fn {_key, {version, comp}} ->
        comp
        |> Map.put(:local_version, nil)
        |> Map.put(:remote_latest, version)
        |> Map.put(:update_available, false)
      end)

    merged = annotated_local ++ remote_only

    {:ok, %{
      components: merged,
      total: length(merged),
      local_count: length(annotated_local),
      remote_count: length(remote_only)
    }}
  end

  defp component_identity_key(comp) when is_map(comp) do
    {comp["name"] || comp[:name],
     comp["publisher"] || comp[:publisher] || comp["publisher_name"] || comp[:publisher_name],
     comp["component_type"] || comp[:component_type]}
  end

  defp version_gt?(nil, _), do: false
  defp version_gt?(_, nil), do: true
  defp version_gt?(a, b) when is_binary(a) and is_binary(b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) == :gt
      _ -> a > b
    end
  end

  defp require_permission(ctx, permission), do: Context.require_permission(ctx, permission)
end
