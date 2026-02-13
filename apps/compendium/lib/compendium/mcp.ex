defmodule Compendium.MCP do
  @moduledoc """
  MCP tool provider for Compendium component registry.

  Provides tools with action-based dispatch:
  - `component` - Component discovery and registry operations
    - `search` - Search components by type, category, tags
    - `inspect` - Get component metadata and schema
    - `pull` - Pull component from OCI registry
    - `publish` - Publish WASM artifact to permanent storage
    - `resolve` - Get full dependency tree
    - `categories` - List available categories
  - `guide` - Documentation guides (list, get, readme)

  ## Architecture Note

  This module lives in the `compendium` app, keeping tool definitions
  close to their implementation.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  require Logger

  alias Sanctum.Context
  alias Compendium.Registry

  # Embed top-level guides at compile time
  @guide_root Path.join([__DIR__, "..", "..", "..", ".."]) |> Path.expand()
  @external_resource Path.join(@guide_root, "component-guide.md")
  @external_resource Path.join(@guide_root, "integration-guide.md")
  @component_guide File.read!(Path.join(@guide_root, "component-guide.md"))
  @integration_guide File.read!(Path.join(@guide_root, "integration-guide.md"))

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Compendium resources.
  """
  def resources do
    [
      %{
        uri: "compendium://components/{reference}",
        name: "Component Metadata",
        description: "Component metadata by OCI reference",
        mimeType: "application/json"
      },
      %{
        uri: "compendium://assets/{reference}/{path}",
        name: "Component Assets",
        description: "Static assets from components",
        mimeType: "application/octet-stream"
      }
    ]
  end

  @doc """
  Read a resource by URI.
  """
  def read(%Context{} = _ctx, "compendium://components/" <> reference) do
    {:ok,
     %{
       content:
         Jason.encode!(%{
           reference: reference,
           status: "stub",
           message: "Component registry not yet implemented"
         }),
       mimeType: "application/json"
     }}
  end

  def read(%Context{} = _ctx, "compendium://assets/" <> _rest) do
    {:error, "Asset retrieval not yet implemented"}
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
              "enum" => ["search", "inspect", "pull", "publish", "register", "resolve", "categories", "get_blob"],
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
            "license" => %{
              "type" => "string",
              "description" => "Filter by license, SPDX identifier (search action)"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 20,
              "description" => "Maximum results to return (search action)"
            },
            # inspect/pull/resolve action params
            "reference" => %{
              "type" => "string",
              "description" => "Component reference, OCI or local (inspect/pull/resolve actions)"
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
            "source" => %{
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
            # register action params
            "directory" => %{
              "type" => "string",
              "description" => "Path to component directory containing cyfr-manifest.json and .wasm (register action)"
            }
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
              "enum" => ["component-guide", "integration-guide"],
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

  # Search action - search for components
  def handle("component", %Context{} = ctx, %{"action" => "search"} = args) do
    filters = %{
      query: args["query"],
      type: args["type"],
      category: args["category"],
      tags: args["tags"],
      license: args["license"],
      limit: args["limit"] || 20
    }

    case Registry.search(ctx, filters) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Logger.warning("[Compendium.MCP] Search failed: #{inspect(reason)}")
        {:error, "Search failed: #{inspect(reason)}"}
    end
  end

  # Inspect action - get component metadata
  def handle("component", %Context{} = ctx, %{"action" => "inspect", "reference" => reference}) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        case Registry.get(ctx, name, version, namespace, type) do
          {:ok, component} ->
            {:ok, component}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle("component", _ctx, %{"action" => "inspect"}) do
    {:error, "Missing required argument: reference"}
  end

  # Pull action - pull component from registry (OCI not implemented, local only)
  def handle("component", %Context{} = ctx, %{"action" => "pull"} = args) do
    case args["reference"] do
      nil ->
        {:error, "Missing required argument: reference"}

      reference ->
        case parse_reference(reference) do
          {:ok, namespace, name, version, type} ->
            case Registry.get(ctx, name, version, namespace, type) do
              {:ok, component} ->
                # For local registry, "pull" just returns the component metadata
                # The executor will fetch the blob when running
                {:ok,
                 %{
                   status: "ready",
                   reference: reference,
                   digest: component["digest"],
                   size: component["size"],
                   type: component["type"],
                   source: "local"
                 }}

              {:error, :not_found} ->
                # TODO: Implement OCI pull for remote registries
                {:error, "Component not found in local registry: #{reference}. OCI pull not yet implemented."}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Publish action - publish WASM artifact to permanent storage
  def handle("component", %Context{} = ctx, %{"action" => "publish"} = args) do
    artifact = args["artifact"]
    reference = args["reference"]

    cond do
      is_nil(artifact) ->
        {:error, "Missing required argument: artifact (provide path, base64, or url)"}

      is_nil(reference) ->
        {:error, "Missing required argument: reference (format: name:version)"}

      true ->
        case parse_reference(reference) do
          {:ok, namespace, name, version, _type} ->
            case resolve_artifact(artifact) do
              {:ok, wasm_bytes} ->
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

  # Register action - register a local/agent component from directory
  def handle("component", %Context{} = ctx, %{"action" => "register", "directory" => directory}) do
    expanded = Path.expand(directory)

    case Registry.register_from_directory(ctx, expanded) do
      {:ok, :unchanged} ->
        {:ok, %{status: "unchanged", directory: expanded, message: "Component already registered with same digest"}}

      {:ok, component} ->
        {:ok, %{
          status: "registered",
          name: component.name,
          version: component.version,
          type: component.component_type,
          source: "filesystem",
          digest: component.digest
        }}

      {:error, {:namespace_rejected, msg}} ->
        {:error, "Registration rejected: #{msg}"}

      {:error, {:missing_manifest, msg}} ->
        {:error, msg}

      {:error, {:missing_wasm, msg}} ->
        {:error, msg}

      {:error, {:invalid_path, msg}} ->
        {:error, "Invalid component path: #{msg}"}

      {:error, reason} ->
        Logger.warning("[Compendium.MCP] Register failed: #{inspect(reason)}")
        {:error, "Registration failed: #{inspect(reason)}"}
    end
  end

  def handle("component", _ctx, %{"action" => "register"}) do
    {:error, "Missing required argument: directory"}
  end

  # Resolve action - get dependency tree
  def handle("component", %Context{} = ctx, %{"action" => "resolve", "reference" => reference}) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        case Registry.get(ctx, name, version, namespace, type) do
          {:ok, component} ->
            # TODO: Implement dependency resolution when dependencies are added
            {:ok,
             %{
               reference: reference,
               component: component,
               dependencies: [],
               note: "Dependency resolution not yet implemented"
             }}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle("component", _ctx, %{"action" => "resolve"}) do
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
         }
       ],
       count: 2
     }}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => "component-guide"}) do
    {:ok, %{name: "component-guide", format: "markdown", content: @component_guide}}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => "integration-guide"}) do
    {:ok, %{name: "integration-guide", format: "markdown", content: @integration_guide}}
  end

  def handle("guide", _ctx, %{"action" => "get", "name" => name}) do
    {:error, "Unknown guide: #{name}. Available: component-guide, integration-guide"}
  end

  def handle("guide", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("guide", _ctx, %{"action" => "readme", "reference" => reference}) do
    case parse_reference(reference) do
      {:ok, namespace, name, version, type} ->
        readme_path =
          Path.join(["components", "#{type}s", namespace, name, version, "README.md"])

        expanded = Path.expand(readme_path)

        case File.read(expanded) do
          {:ok, content} ->
            {:ok, %{reference: reference, format: "markdown", content: content}}

          {:error, :enoent} ->
            {:error, "No README.md found for #{reference}"}

          {:error, reason} ->
            {:error, "Failed to read README for #{reference}: #{inspect(reason)}"}
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
end
