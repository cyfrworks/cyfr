# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
    - `delete` - Delete a component from the registry
  - `aqua` - AQUA agent system and documentation guides (list, get, create, update, delete)

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

  # Project root — used for compile-time doc embedding and aqua/ path default
  @project_root Path.join([__DIR__, "..", "..", "..", ".."]) |> Path.expand()

  # Documentation guides (arca:bypass-ok=C — compile-time embed; runtime never reads).
  @external_resource Path.join(@project_root, "component-guide.md")
  @external_resource Path.join(@project_root, "tincture-guide.md")
  @external_resource Path.join(@project_root, "integration-guide.md")
  @component_guide File.read!(Path.join(@project_root, "component-guide.md"))
  @tincture_guide File.read!(Path.join(@project_root, "tincture-guide.md"))
  @integration_guide File.read!(Path.join(@project_root, "integration-guide.md"))

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
            asset_path =
              Compendium.ComponentPath.version_dir(
                ref.type,
                ref.namespace,
                ref.name,
                ref.version,
                ctx
              ) ++ String.split(path, "/")

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
        description:
          "Component discovery and registry operations. Search/list results include a component_ref field (format: type:publisher.name:version, e.g. catalyst:moonmoon69.airtable:0.1.0) usable directly as the reference argument for pull, inspect, setup_plan, and request_setup.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "search" => %{kind: :read},
            "inspect" => %{kind: :read},
            "pull" => %{kind: :write},
            "publish" => %{kind: :write},
            "register" => %{kind: :write},
            "categories" => %{kind: :read},
            "get_blob" => %{kind: :read},
            "discover" => %{kind: :read},
            "setup_plan" => %{kind: :read},
            "list" => %{kind: :read},
            "delete" => %{kind: :destructive},
            "create" => %{kind: :write},
            "fork" => %{kind: :write},
            "deprecate" => %{kind: :destructive},
            "yank" => %{kind: :destructive}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "search",
                "inspect",
                "pull",
                "publish",
                "register",
                "categories",
                "get_blob",
                "discover",
                "setup_plan",
                "list",
                "delete",
                "create",
                "fork",
                "deprecate",
                "yank"
              ],
              "description" => "Action to perform"
            },
            # deprecate/yank action params
            "reason" => %{
              "type" => "string",
              "description" =>
                "Human-readable explanation surfaced to pullers (deprecate/yank). Required for deprecate; optional for yank. Max 256 chars."
            },
            # search action params
            "query" => %{
              "type" => "string",
              "description" => "Search query (search action)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["catalyst", "reagent", "formula", "tincture"],
              "description" =>
                "Component type (required for create action, optional filter for search/list)"
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
              "description" =>
                "Search scope: 'local' (skip remote), 'remote' (remote only), 'all' (default, both)"
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
              "description" =>
                "Component reference in format type:namespace.name:version (e.g. catalyst:moonmoon69.airtable:0.1.0). Use the component_ref value from search/list results."
            },
            # inspect action params
            "include_readme" => %{
              "type" => "boolean",
              "description" => "Include README.md content in inspect result (default false)"
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
              "description" =>
                "Artifact input: {path: string} | {base64: string} | {url: string} (publish action)",
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
            # create/fork action params
            "name" => %{
              "type" => "string",
              "description" =>
                "Component name, lowercase alphanumeric with hyphens (create/fork action)"
            },
            "version" => %{
              "type" => "string",
              "default" => "0.1.0",
              "description" => "Semver version (create/fork action)"
            },
            "template" => %{
              "type" => "string",
              "enum" => ["react"],
              "description" => "Scaffold template (tincture only). Omit for vanilla HTML/JS/CSS."
            }
            # register action: no additional params (scans all component directories)
          },
          "required" => ["action"]
        }
      },
      %{
        name: "aqua",
        title: "AQUA Agent System",
        description:
          "Manage the AQUA agent system — orchestrators, sub-agents, prompts, and documentation guides. Use 'list' to discover agents and guides, 'get' to retrieve prompts/docs, or 'create'/'update'/'delete' to manage agents (pass type=orchestrator|sub-agent|doc on create).",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "list" => %{kind: :read},
            "get" => %{kind: :read},
            "create" => %{kind: :write},
            "update" => %{kind: :write},
            "delete" => %{kind: :destructive}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "get", "create", "update", "delete"],
              "description" =>
                "Action: list/get agents and guides, or create/update/delete to manage agents. For create, pass type=orchestrator|sub-agent|doc to choose the entry kind."
            },
            "name" => %{
              "type" => "string",
              "description" => "Agent or guide name (for get/update/delete actions)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["doc", "orchestrator", "sub-agent"],
              "description" => "Filter by type (for list action)"
            },
            "parent" => %{
              "type" => "string",
              "description" => "Parent orchestrator name (for create sub-agent action)"
            },
            "title" => %{
              "type" => "string",
              "description" => "Human-readable title (for create/update actions)"
            },
            "description" => %{
              "type" => "string",
              "description" => "Agent description shown to LLM (for create/update actions)"
            },
            "content" => %{
              "type" => "string",
              "description" => "Prompt content in markdown (for create/update actions)"
            },
            "tool_policy" => %{
              "type" => "object",
              "additionalProperties" => %{"type" => "string"},
              "description" =>
                "Per-(tool,action) policy for this agent. Keys are 'tool.action' strings; values are 'allow' (auto-execute), 'approval' (require user click), or 'block' (forbidden). Missing pairs are treated as 'block'. Each action's risk level is derived from its `kind` annotation (read/write/execute/destructive/external) — color/UI treatment uses the kind, not the policy mode."
            },
            "catalyst_ref" => %{
              "type" => "string",
              "description" => "Versionless catalyst reference (for create/update actions)"
            },
            "model" => %{
              "type" => "string",
              "description" => "Model identifier (for create/update actions)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "registry",
        title: "Registry",
        description:
          "cyfr.run registry identity and namespace operations: probe for tokens, claim a personal " <>
            "or publisher namespace, verify DNS ownership, manage additional push tokens and members, " <>
            "and inspect registry-side identity. Separate from `session` (local cyfr identity).",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "probe" => %{kind: :execute},
            "claim_personal" => %{kind: :write},
            "claim_publisher" => %{kind: :write},
            "verify_publisher" => %{kind: :write},
            "tokens_list" => %{kind: :read},
            "tokens_issue" => %{kind: :write},
            "tokens_revoke" => %{kind: :write},
            "members_list" => %{kind: :read},
            "members_add" => %{kind: :write},
            "members_update" => %{kind: :write},
            "members_remove" => %{kind: :write},
            "whoami" => %{kind: :read},
            "get_namespace" => %{kind: :read},
            "report" => %{kind: :write},
            "list_my_reports" => %{kind: :read},
            "legal_page" => %{kind: :read},
            "legal_version" => %{kind: :read},
            "legal_accept" => %{kind: :write},
            "appeal" => %{kind: :write}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "probe",
                "claim_personal",
                "claim_publisher",
                "verify_publisher",
                "tokens_list",
                "tokens_issue",
                "tokens_revoke",
                "members_list",
                "members_add",
                "members_update",
                "members_remove",
                "whoami",
                "get_namespace",
                "report",
                "list_my_reports",
                "legal_page",
                "legal_version",
                "legal_accept",
                "appeal"
              ],
              "description" => "Registry action to perform"
            },
            "provider" => %{
              "type" => "string",
              "enum" => ["github", "google"],
              "description" => "OAuth provider (for probe / claim_personal)"
            },
            "access_token" => %{
              "type" => "string",
              "description" =>
                "IdP access token (for probe / claim_personal). Used once to prove provider identity."
            },
            "label" => %{
              "type" => "string",
              "description" => "Human-readable label for the issued push token"
            },
            "username" => %{
              "type" => "string",
              "description" => "Desired personal-namespace slug (for claim_personal)"
            },
            "slug" => %{
              "type" => "string",
              "description" => "Namespace slug (publisher or personal)"
            },
            "token_id" => %{
              "type" => "string",
              "description" => "Token id (for tokens_revoke)"
            },
            "target_personal_slug" => %{
              "type" => "string",
              "description" => "Target user's personal namespace slug (for members_*)"
            },
            "role" => %{
              "type" => "string",
              "enum" => ["admin", "member"],
              "description" => "Member role (for members_add / members_update)"
            },
            # report action params
            "category" => %{
              "type" => "string",
              "enum" => [
                "impersonation",
                "malware",
                "dmca",
                "spam",
                "other",
                "csam",
                "objectionable",
                "ip_infringement",
                "security",
                "policy_violation",
                "ncii"
              ],
              "description" => "Abuse category (for report action)"
            },
            "target_namespace" => %{
              "type" => "string",
              "description" =>
                "Namespace being reported (for report action; required if no target_component_ref)"
            },
            "target_component_ref" => %{
              "type" => "string",
              "description" =>
                "Component reference being reported (for report action; required if no target_namespace)"
            },
            "details" => %{
              "type" => "string",
              "description" => "Report details (for report action; max 4096 chars)"
            },
            # list_my_reports pagination
            "limit" => %{
              "type" => "integer",
              "description" => "Max rows to return (list_my_reports; default 50, max 200)"
            },
            "offset" => %{
              "type" => "integer",
              "description" => "Starting row offset (list_my_reports; default 0)"
            },
            # legal_page / legal_accept
            "name" => %{
              "type" => "string",
              "description" =>
                "Policy name (for legal_page action: terms / privacy / aup / content-policy / dmca / cookies / transparency)"
            },
            "policy_version" => %{
              "type" => "string",
              "description" =>
                "Policy version string (for legal_accept; obtained via legal_version)"
            },
            "id_token" => %{
              "type" => "string",
              "description" => "OIDC id_token (for legal_accept / appeal when provider=oidcc)"
            },
            "action_type" => %{
              "type" => "string",
              "enum" => ["takedown", "ban"],
              "description" => "Appeal action_type (for appeal action)"
            },
            "action_ref" => %{
              "type" => "string",
              "description" =>
                "Appeal action_ref — component UUID or '<provider>|<subject>' (for appeal action)"
            },
            "argument" => %{
              "type" => "string",
              "description" => "Appeal argument, ≤4000 chars (for appeal action)"
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

  # Search action - search for components. Searches the local registry and,
  # unless the caller restricts to source: "local", augments with the
  # configured registry's REST API (cyfr.run by default), merging results.
  def handle("component", %Context{} = ctx, %{"action" => "search"} = args) do
    filters = %{
      query: args["query"],
      type: args["type"],
      category: args["category"],
      tags: args["tags"],
      license: args["license"],
      limit: min(args["limit"] || 20, 1000)
    }

    source = args["source"] || "all"

    local_result = if source != "remote", do: Registry.search(ctx, filters), else: nil

    if source != "local" do
      case Compendium.Registry.Client.search(ctx, filters) do
        {:ok, remote} ->
          if local_result do
            merge_search_results(local_result, remote)
          else
            {:ok, %{components: remote[:components] || [], total: remote[:total] || 0}}
          end

        {:error, %Errors{} = err} ->
          Logger.error(
            "[Compendium.MCP] CYFR.RUN SEARCH FAILED — #{Errors.to_log_string(err)}. " <>
              "Results are incomplete. Only local components are shown."
          )

          error_msg = format_error(err)

          case local_result do
            {:ok, local} ->
              {:ok,
               local
               |> Map.put(:incomplete, true)
               |> Map.put(:registry_error, error_msg)
               |> Map.put(
                 :note,
                 "INCOMPLETE RESULTS — cyfr.run search failed: #{error_msg}. " <>
                   "Only local components are shown."
               )}

            nil ->
              {:ok,
               %{
                 components: [],
                 total: 0,
                 incomplete: true,
                 registry_error: error_msg,
                 note: "INCOMPLETE RESULTS — cyfr.run search failed: #{error_msg}."
               }}
          end
      end
    else
      local_result || {:ok, %{components: [], total: 0}}
    end
  end

  # Inspect action - delegates to Compendium.Component.inspect_component/2
  def handle(
        "component",
        %Context{} = ctx,
        %{"action" => "inspect", "reference" => reference} = args
      ) do
    case Compendium.Component.inspect_component(ctx, reference) do
      {:ok, result} ->
        result =
          if args["include_readme"] == true do
            readme = read_component_readme(ctx, reference)
            Map.put(result, "readme", readme)
          else
            result
          end

        {:ok, enrich_component_with_media(ctx, result)}

      error ->
        error
    end
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
                    broadcast_progress(
                      ctx,
                      progress_id,
                      session_id,
                      :complete,
                      "Pulled #{res[:component_ref] || ref}"
                    )

                    broadcast_components_changed(ctx)

                  {:error, reason} ->
                    Logger.error("[Compendium.MCP] Pull failed: #{inspect(reason)}")
                    broadcast_progress(ctx, progress_id, session_id, :error, "Pull failed")
                end

                result

              {:error, reason} ->
                {:error, reason}
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
              {:error,
               "Only components in the local namespace can be published to a registry. " <>
                 "Got namespace '#{cref.namespace}'. Use the local namespace (e.g., c:local.#{cref.name}:#{cref.version})."}

            {:ok, _cref} ->
              case Compendium.Registry.validate_host(registry) do
                {:error, msg} ->
                  {:error, msg}

                :ok ->
                  # `local` refs are remapped to the caller's claimed personal
                  # namespace inside `OCI.Client.push` (via resolve_push_publisher),
                  # which returns a precise error if no namespace is claimed. No
                  # literal-"local" credential pre-check here — there is no push
                  # token for "local"; the token belongs to the resolved namespace.
                  broadcast_progress(
                    ctx,
                    progress_id,
                    session_id,
                    :pushing,
                    "Pushing #{reference} to #{registry}..."
                  )

                  case Compendium.OCI.Client.push(ctx, reference, registry) do
                    {:ok, result} ->
                      broadcast_progress(
                        ctx,
                        progress_id,
                        session_id,
                        :complete,
                        "Published #{result[:oci_reference] || reference}"
                      )

                      {:ok, result}

                    {:error, reason} ->
                      Logger.error("[Compendium.MCP] Push failed: #{inspect(reason)}")
                      broadcast_progress(ctx, progress_id, session_id, :error, "Push failed")
                      {:error, reason}
                  end
              end

            {:error, reason} ->
              {:error, "Invalid reference: #{reason}"}
          end

        is_nil(args["type"]) ->
          {:error, "Missing required argument: type (catalyst, reagent, formula, or tincture)"}

        args["type"] == "tincture" ->
          {:error,
           "Tinctures are registered from directories, not published as binary artifacts. " <>
             "Use 'component.new' to scaffold a tincture, then it will be auto-registered."}

        true ->
          case parse_reference(reference) do
            {:ok, _namespace, _name, nil, _type} ->
              {:error, "Version is required for publishing. Example: c:local.name:1.0.0"}

            {:ok, namespace, name, version, _type} ->
              case resolve_artifact(artifact) do
                {:ok, wasm_bytes} ->
                  broadcast_progress(
                    ctx,
                    progress_id,
                    session_id,
                    :publishing,
                    "Publishing #{name}:#{version}..."
                  )

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
                      broadcast_progress(
                        ctx,
                        progress_id,
                        session_id,
                        :complete,
                        "Published #{name}:#{version}"
                      )

                      broadcast_components_changed(ctx)

                      result = %{
                        status: "published",
                        reference: reference,
                        digest: component.digest,
                        size: component.size,
                        type: component.component_type,
                        published_at: component.inserted_at
                      }

                      result =
                        case Map.get(component, :capability_warnings) do
                          nil -> result
                          [] -> result
                          warnings -> Map.put(result, :capability_warnings, warnings)
                        end

                      {:ok, result}

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

  # Create action - scaffold a new component project
  def handle("component", %Context{} = ctx, %{"action" => "create"} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
      name = args["name"]
      type = args["type"]
      version = args["version"] || "0.1.0"
      template = args["template"]

      result = Compendium.Scaffold.create(ctx, name, type, version, template: template)

      case result do
        {:ok, _} -> broadcast_components_changed(ctx)
        _ -> :ok
      end

      result
    end
  end

  # Register action - scan and register all local components
  def handle("component", %Context{} = ctx, %{"action" => "register"} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
      register_id = args["register_id"]
      session_id = ctx.session_id

      broadcast_register_progress(
        ctx,
        register_id,
        session_id,
        :scanning,
        "Scanning component directories..."
      )

      result = Compendium.AutoIndexer.scan(ctx: ctx)

      # Broadcast per-component status
      Enum.each(result.components, fn comp ->
        status = comp[:status] || comp["status"]
        name = comp[:name] || comp["name"]
        version = comp[:version] || comp["version"]

        case status do
          "registered" ->
            broadcast_register_progress(
              ctx,
              register_id,
              session_id,
              :registered,
              "Registered #{name}:#{version}"
            )

          "unchanged" ->
            broadcast_register_progress(
              ctx,
              register_id,
              session_id,
              :unchanged,
              "Unchanged #{name}:#{version}"
            )

          _ ->
            :ok
        end
      end)

      if result.pruned > 0 do
        broadcast_register_progress(
          ctx,
          register_id,
          session_id,
          :pruning,
          "Pruned #{result.pruned} stale component(s)"
        )
      end

      broadcast_register_progress(
        ctx,
        register_id,
        session_id,
        :checking_deps,
        "Checking dependencies..."
      )

      dep_info = check_register_deps(ctx, result.components, register_id, session_id)

      broadcast_register_progress(
        ctx,
        register_id,
        session_id,
        :complete,
        "Complete — #{result.registered} registered, #{result.unchanged} unchanged, #{result.total} total"
      )

      broadcast_components_changed(ctx)

      dep_fields =
        case dep_info do
          {:error, {:dependency_check_failed, reason}} ->
            %{
              pulled_dependencies: [],
              failed_pulls: [],
              missing_local_deps: [],
              optional_missing: [],
              dependency_check_error: reason
            }

          %{} = info ->
            Map.take(info, [
              :pulled_dependencies,
              :failed_pulls,
              :missing_local_deps,
              :optional_missing
            ])
        end

      {:ok,
       Map.merge(
         %{
           status: "scanned",
           components: result.components,
           registered: result.registered,
           unchanged: result.unchanged,
           pruned: result.pruned,
           errors: result.errors,
           total: result.total,
           elapsed_ms: result.elapsed_ms,
           scanned_dirs: result.scanned_dirs
         },
         dep_fields
       )}
    end
  end

  # List action - list all installed components (local-only, no remote search)
  def handle("component", %Context{} = ctx, %{"action" => "list"} = args) do
    filters = %{
      type: args["type"],
      limit: min(args["limit"] || 1000, 1000)
    }

    {:ok, result} = Registry.search(ctx, filters)
    {:ok, enrich_tincture_media(ctx, result)}
  end

  # Delete action - delete a component from the registry
  def handle("component", %Context{} = ctx, %{"action" => "delete", "reference" => reference}) do
    with :ok <- require_permission(ctx, :component_manage) do
      case Sanctum.ComponentRef.parse(reference) do
        {:ok, %{version: nil} = cref} ->
          # Check if name is even valid before giving version error
          case Sanctum.ComponentRef.validate_name(cref.name) do
            :ok -> {:error, "Version is required for deletion. Example: c:local.name:1.0.0"}
            {:error, reason} -> {:error, "Invalid reference: #{reason}"}
          end

        {:ok, cref} ->
          case Registry.delete(ctx, cref.name, cref.version, cref.namespace) do
            :ok ->
              broadcast_components_changed(ctx)
              {:ok, %{status: "deleted", reference: reference}}

            {:error, :not_found} ->
              {:error, "Component not found: #{reference}"}
          end

        {:error, reason} ->
          {:error, "Invalid reference: #{reason}"}
      end
    end
  end

  def handle("component", _ctx, %{"action" => "delete"}) do
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

  # Discover action - list components on the configured registry (cyfr.run
  # REST API). The registry host is set via CYFR_REGISTRY_URL.
  def handle("component", %Context{} = ctx, %{"action" => "discover"} = args) do
    with :ok <- require_permission(ctx, :component_read) do
      registry = args["registry"] || default_registry()

      case Compendium.Registry.validate_host(registry) do
        {:error, msg} ->
          {:error, msg}

        :ok ->
          params = %{namespace: args["namespace"], type: args["type"]}

          case Compendium.Registry.Client.discover(ctx, params) do
            {:ok, result} ->
              {:ok, result}

            {:error, %Errors{} = err} ->
              Logger.error("[Compendium.MCP] DISCOVER FAILED — #{Errors.to_log_string(err)}")

              {:error, format_error(err)}
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

  # Fork action - fork a published component to local namespace
  def handle(
        "component",
        %Context{} = ctx,
        %{"action" => "fork", "reference" => reference} = args
      ) do
    with :ok <- require_permission(ctx, :component_manage) do
      case Sanctum.ComponentRef.parse(reference) do
        {:ok, %{version: nil}} ->
          {:error, "Version is required for fork. Example: c:acme.my-tool:1.0.0"}

        {:ok, %{namespace: "local"}} ->
          {:error, "Cannot fork a local component. Use 'new' to create a fresh component."}

        {:ok, cref} ->
          opts = [
            name: args["name"] || cref.name,
            version: args["version"] || cref.version
          ]

          case Compendium.Fork.fork(ctx, cref, opts) do
            {:ok, result} ->
              broadcast_components_changed(ctx)
              {:ok, result}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, "Invalid reference: #{reason}"}
      end
    end
  end

  def handle("component", _ctx, %{"action" => "fork"}) do
    {:error, "Missing required argument: reference"}
  end

  def handle(
        "component",
        %Context{} = ctx,
        %{"action" => "deprecate", "reference" => reference} = args
      ) do
    reason = Map.get(args, "reason", "")

    if String.trim(reason) == "" do
      {:error, "component.deprecate requires a non-empty 'reason'"}
    else
      with {:ok, ref} <- Sanctum.ComponentRef.parse(reference),
           :ok <- ensure_fully_qualified(ref),
           {:ok, bearer} <- namespace_bearer(ctx, ref.namespace),
           {:ok, body} <-
             Compendium.Registry.Client.deprecate_component(
               ref.namespace,
               ref.type,
               ref.name,
               ref.version,
               reason,
               bearer
             ) do
        {:ok, body}
      else
        {:error, err} -> {:error, to_error_string(err)}
      end
    end
  end

  def handle("component", _ctx, %{"action" => "deprecate"}) do
    {:error, "component.deprecate requires 'reference' and 'reason'"}
  end

  # Yank action — reason optional (deprecate requires one; yank does not).
  def handle(
        "component",
        %Context{} = ctx,
        %{"action" => "yank", "reference" => reference} = args
      ) do
    reason = Map.get(args, "reason", "")

    with {:ok, ref} <- Sanctum.ComponentRef.parse(reference),
         :ok <- ensure_fully_qualified(ref),
         {:ok, bearer} <- namespace_bearer(ctx, ref.namespace),
         {:ok, body} <-
           Compendium.Registry.Client.yank_component(
             ref.namespace,
             ref.type,
             ref.name,
             ref.version,
             reason,
             bearer
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("component", _ctx, %{"action" => "yank"}) do
    {:error, "component.yank requires 'reference'"}
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
  # AQUA Tool — agent system + documentation guides
  # ============================================================================

  # --- list ---

  def handle("aqua", %Context{} = ctx, %{"action" => "list"} = args) do
    type_filter = Map.get(args, "type")

    doc_guides = [
      %{
        name: "component-guide",
        title: "Component Guide",
        type: "doc",
        description: "Building WASM components (catalysts, reagents, formulas) for CYFR"
      },
      %{
        name: "tincture-guide",
        title: "Tincture Guide",
        type: "doc",
        description:
          "Building tinctures (HTML/JS/CSS frontends) — SDK, sandbox constraints, manifest, examples"
      },
      %{
        name: "integration-guide",
        title: "Integration Guide",
        type: "doc",
        description: "How to use CYFR as your application backend"
      }
    ]

    agent_guides =
      case read_agent_manifest(ctx) do
        {:ok, %{"agents" => agents}} ->
          Enum.flat_map(agents, fn {name, config} ->
            orchestrator = %{
              name: name,
              title: config["title"] || name,
              type: "orchestrator",
              description: ""
            }

            sub_agents =
              (config["sub_agents"] || %{})
              |> Enum.map(fn {sa_name, sa_config} ->
                %{
                  name: sa_name,
                  title: sa_config["title"] || sa_name,
                  type: "sub-agent",
                  parent: name,
                  description: sa_config["description"] || ""
                }
              end)

            [orchestrator | sub_agents]
          end)

        _ ->
          []
      end

    all = doc_guides ++ agent_guides

    filtered =
      if type_filter,
        do: Enum.filter(all, &(&1.type == type_filter)),
        else: all

    {:ok, %{guides: filtered, count: length(filtered)}}
  end

  # --- get ---

  def handle("aqua", _ctx, %{"action" => "get", "name" => name})
      when name in ["component-guide", "tincture-guide", "integration-guide"] do
    content =
      case name do
        "component-guide" -> @component_guide
        "tincture-guide" -> @tincture_guide
        "integration-guide" -> @integration_guide
      end

    {:ok, %{name: name, format: "markdown", content: content, type: "doc"}}
  end

  def handle("aqua", %Context{} = ctx, %{"action" => "get", "name" => name}) do
    # Handle "agent-guide" alias for backward compat
    lookup = if name == "agent-guide", do: "aqua", else: name
    lookup_agent_guide(ctx, lookup)
  end

  def handle("aqua", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  # --- create ---
  # Dispatches by the `type` arg (orchestrator | sub-agent). When `type` is
  # absent, infers from presence of `parent`: parent → sub-agent, no parent →
  # orchestrator. Pass `type: "doc"` to create a markdown guide entry.

  def handle("aqua", %Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- require_permission(ctx, :component_manage) do
      type = inferred_aqua_create_type(args)

      case type do
        "sub-agent" -> create_aqua_sub_agent(ctx, name, args)
        "orchestrator" -> create_aqua_orchestrator(ctx, name, args)
        other -> {:error, "Unsupported aqua create type: #{inspect(other)}"}
      end
    end
  end

  def handle("aqua", _ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: name"}
  end

  # --- update ---

  def handle("aqua", %Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    with :ok <- require_permission(ctx, :component_manage),
         {:ok, manifest} <- read_agent_manifest(ctx),
         {:ok, location} <- find_agent_in_manifest(manifest, name) do
      # Update manifest fields if provided
      updated_manifest =
        case location do
          {:orchestrator, _config} ->
            update_agent_fields(manifest, ["agents", name], args)

          {:sub_agent, parent, _config} ->
            update_agent_fields(manifest, ["agents", parent, "sub_agents", name], args)
        end

      # Update prompt content if provided
      prompt_result =
        case args["content"] do
          nil ->
            :ok

          content ->
            {_, config} =
              case location do
                {:orchestrator, c} -> {:orchestrator, c}
                {:sub_agent, _, c} -> {:sub_agent, c}
              end

            filename = config["prompt"] || "#{name}.md"
            Arca.put(ctx, ["aqua", filename], content)
        end

      with :ok <- write_agent_manifest(ctx, updated_manifest),
           :ok <- prompt_result do
        {:ok, %{updated: name}}
      else
        {:error, reason} -> {:error, "Failed to update: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def handle("aqua", _ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: name"}
  end

  # --- delete ---

  def handle("aqua", %Context{} = ctx, %{"action" => "delete", "name" => name}) do
    with :ok <- require_permission(ctx, :component_manage),
         {:ok, manifest} <- read_agent_manifest(ctx),
         {:ok, location} <- find_agent_in_manifest(manifest, name) do
      {updated, prompt_file} =
        case location do
          {:orchestrator, config} ->
            {update_in(manifest, ["agents"], &Map.delete(&1, name)), config["prompt"]}

          {:sub_agent, parent, config} ->
            {update_in(manifest, ["agents", parent, "sub_agents"], &Map.delete(&1, name)),
             config["prompt"]}
        end

      with :ok <- write_agent_manifest(ctx, updated) do
        # Best-effort delete of prompt file
        if prompt_file, do: Arca.delete(ctx, ["aqua", prompt_file])
        {:ok, %{deleted: name}}
      else
        {:error, reason} -> {:error, "Failed to delete: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def handle("aqua", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("aqua", _ctx, _args) do
    {:error, "Invalid aqua action. Use: list, get, create, update, or delete"}
  end

  # ============================================================================
  # Registry Tool — cyfr.run identity/namespace operations
  # ============================================================================

  def handle("registry", %Context{} = ctx, %{"action" => "whoami"}) do
    {:ok, Compendium.Registry.Identity.identity(ctx)}
  end

  def handle(
        "registry",
        ctx,
        %{"action" => "probe", "provider" => provider, "access_token" => access_token} = args
      ) do
    label = Map.get(args, "label")

    case Compendium.Registry.Client.probe_identity(provider, access_token, label) do
      {:ok, body} ->
        # Persist returned push tokens into CredentialStore for authenticated
        # callers. Mirrors what Sanctum.Auth.DeviceFlow.probe_after_session/3
        # does server-side during the device-flow path; for codex/porta
        # post-legal_accept flows that re-call probe directly, this writes
        # the same locally-cached credentials.
        body_with_warnings = maybe_store_probe_credentials(ctx, body)
        {:ok, body_with_warnings}

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required} = err} ->
        # Server bumped the bundled policy version between the user's last
        # acceptance and this re-probe (race on the codex/porta post-accept
        # path). Surface the same structured shape DeviceFlow.probe_after_session/3
        # emits so clients can route back into the clickwrap UI without
        # parsing string errors.
        {:ok,
         %{
           "needs_policy_acceptance" => true,
           "required_policy_version" => required_policy_version(err),
           "needs_personal_namespace" => false
         }}

      {:error, err} ->
        {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "probe"}) do
    {:error, "registry.probe requires 'provider' and 'access_token'"}
  end

  def handle(
        "registry",
        %Context{} = ctx,
        %{
          "action" => "claim_personal",
          "username" => username,
          "provider" => provider,
          "access_token" => access_token
        } = args
      ) do
    label = Map.get(args, "label")

    case Compendium.Registry.Client.claim_personal_namespace(
           username,
           provider,
           access_token,
           label
         ) do
      {:ok, body} ->
        # When the caller reached us with an authenticated cyfr session, persist
        # the returned push token to CredentialStore keyed by the session's
        # user_id. On unauthenticated bootstrap calls (e.g. raw MCP with no
        # Bearer / no hydrated Sanctum session), skip storage — the client
        # must subsequently call /v1/identity/probe after establishing a
        # session to provision the credential locally.
        body_with_warning = maybe_store_personal_credential(ctx, body)
        {:ok, body_with_warning}

      {:error, err} ->
        {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "claim_personal"}) do
    {:error, "registry.claim_personal requires 'username', 'provider', and 'access_token'"}
  end

  def handle("registry", %Context{} = ctx, %{"action" => "claim_publisher", "slug" => slug}) do
    with {:ok, bearer} <- personal_bearer(ctx),
         {:ok, body} <- Compendium.Registry.Client.claim_publisher_namespace(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "claim_publisher"}) do
    {:error, "registry.claim_publisher requires 'slug'"}
  end

  def handle("registry", %Context{} = ctx, %{"action" => "verify_publisher", "slug" => slug}) do
    with {:ok, bearer} <- personal_bearer(ctx),
         {:ok, body} <- Compendium.Registry.Client.verify_publisher_namespace(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "verify_publisher"}) do
    {:error, "registry.verify_publisher requires 'slug'"}
  end

  def handle("registry", _ctx, %{"action" => "get_namespace", "slug" => slug}) do
    case Compendium.Registry.Client.get_namespace(slug) do
      {:ok, body} -> {:ok, body}
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "get_namespace"}) do
    {:error, "registry.get_namespace requires 'slug'"}
  end

  def handle("registry", %Context{} = ctx, %{"action" => "tokens_list", "slug" => slug}) do
    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.list_tokens(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "tokens_list"}) do
    {:error, "registry.tokens_list requires 'slug'"}
  end

  def handle("registry", %Context{} = ctx, %{"action" => "tokens_issue", "slug" => slug} = args) do
    label = Map.get(args, "label")

    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.issue_additional_token(slug, bearer, label) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "tokens_issue"}) do
    {:error, "registry.tokens_issue requires 'slug'"}
  end

  def handle("registry", %Context{} = ctx, %{
        "action" => "tokens_revoke",
        "slug" => slug,
        "token_id" => token_id
      }) do
    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         :ok <- Compendium.Registry.Client.revoke_token(slug, token_id, bearer) do
      {:ok, %{revoked: token_id}}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "tokens_revoke"}) do
    {:error, "registry.tokens_revoke requires 'slug' and 'token_id'"}
  end

  def handle("registry", %Context{} = ctx, %{"action" => "members_list", "slug" => slug}) do
    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.list_members(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "members_list"}) do
    {:error, "registry.members_list requires 'slug'"}
  end

  def handle("registry", %Context{} = ctx, %{
        "action" => "members_add",
        "slug" => slug,
        "target_personal_slug" => target,
        "role" => role
      }) do
    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.add_member(slug, target, role, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "members_add"}) do
    {:error, "registry.members_add requires 'slug', 'target_personal_slug', and 'role'"}
  end

  def handle("registry", %Context{} = ctx, %{
        "action" => "members_update",
        "slug" => slug,
        "target_personal_slug" => target,
        "role" => role
      }) do
    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.update_member(slug, target, role, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "members_update"}) do
    {:error, "registry.members_update requires 'slug', 'target_personal_slug', and 'role'"}
  end

  def handle("registry", %Context{} = ctx, %{
        "action" => "members_remove",
        "slug" => slug,
        "target_personal_slug" => target
      }) do
    with {:ok, bearer} <- namespace_bearer(ctx, slug),
         :ok <- Compendium.Registry.Client.remove_member(slug, target, bearer) do
      {:ok, %{removed: target}}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "members_remove"}) do
    {:error, "registry.members_remove requires 'slug' and 'target_personal_slug'"}
  end

  # User-side abuse report submission. Auth: any push token belonging to the
  # caller — resolved via the same first-push-token heuristic as probe. At
  # least one of target_namespace or target_component_ref must be set.
  def handle("registry", %Context{} = ctx, %{"action" => "report"} = args) do
    category = Map.get(args, "category", "")
    target_namespace = Map.get(args, "target_namespace")
    target_component_ref = Map.get(args, "target_component_ref")
    details = Map.get(args, "details", "")

    with :ok <- ensure_present(category, "category"),
         :ok <- ensure_present(details, "details"),
         :ok <- ensure_target(target_namespace, target_component_ref),
         {:ok, component_id} <- resolve_component_id(target_component_ref),
         {:ok, bearer} <- any_push_token(ctx),
         {:ok, body} <-
           Compendium.Registry.Client.create_abuse_report(
             category,
             target_namespace,
             component_id,
             details,
             bearer
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  # list_my_reports returns the caller's filed abuse reports from cyfr.run.
  # Resolves any available push token (same heuristic as `probe`) and hits
  # GET /v1/abuse-reports/mine. Pagination via optional limit/offset.
  def handle("registry", %Context{} = ctx, %{"action" => "list_my_reports"} = args) do
    opts =
      []
      |> put_if_int(:limit, Map.get(args, "limit"))
      |> put_if_int(:offset, Map.get(args, "offset"))

    with {:ok, bearer} <- any_push_token(ctx),
         {:ok, body} <- Compendium.Registry.Client.list_my_reports(bearer, opts) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "legal_page", "name" => name})
      when is_binary(name) and name != "" do
    case Compendium.Registry.Client.get_legal_page(name) do
      {:ok, body} -> {:ok, body}
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "legal_page"}) do
    {:error,
     "name (one of: terms, privacy, aup, content-policy, dmca, cookies, transparency) is required"}
  end

  def handle("registry", _ctx, %{"action" => "legal_version"}) do
    case Compendium.Registry.Client.get_legal_version() do
      {:ok, body} -> {:ok, body}
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "legal_accept"} = args) do
    provider = Map.get(args, "provider", "")
    access_token = Map.get(args, "access_token", "")
    id_token = Map.get(args, "id_token", "")
    policy_version = Map.get(args, "policy_version", "")

    with :ok <- ensure_present(provider, "provider"),
         :ok <- ensure_present(policy_version, "policy_version"),
         :ok <- ensure_appeal_token(provider, access_token, id_token),
         {:ok, body} <-
           Compendium.Registry.Client.accept_policies(
             provider,
             access_token,
             id_token,
             policy_version
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => "appeal"} = args) do
    provider = Map.get(args, "provider", "")
    access_token = Map.get(args, "access_token", "")
    id_token = Map.get(args, "id_token", "")
    action_type = Map.get(args, "action_type", "")
    action_ref = Map.get(args, "action_ref", "")
    argument = Map.get(args, "argument", "")

    with :ok <- ensure_present(provider, "provider"),
         :ok <- ensure_present(action_type, "action_type"),
         :ok <- ensure_present(action_ref, "action_ref"),
         :ok <- ensure_present(argument, "argument"),
         :ok <- ensure_appeal_token(provider, access_token, id_token),
         {:ok, body} <-
           Compendium.Registry.Client.create_appeal(
             provider,
             access_token,
             id_token,
             action_type,
             action_ref,
             argument
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, to_error_string(err)}
    end
  end

  def handle("registry", _ctx, %{"action" => action}) do
    {:error, "Unknown registry action: #{action}"}
  end

  def handle("registry", _ctx, _args) do
    {:error, "registry action is required"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # --- aqua create helpers ---

  defp inferred_aqua_create_type(%{"type" => type}) when is_binary(type) and type != "", do: type

  defp inferred_aqua_create_type(%{"parent" => parent}) when is_binary(parent) and parent != "",
    do: "sub-agent"

  defp inferred_aqua_create_type(_args), do: "orchestrator"

  defp create_aqua_sub_agent(ctx, name, args) do
    parent = args["parent"]

    if is_nil(parent) or parent == "" do
      {:error, "Missing required argument: parent (required for type=sub-agent)"}
    else
      content = Map.get(args, "content", "")

      with {:ok, manifest} <- read_agent_manifest(ctx),
           true <- Map.has_key?(manifest["agents"] || %{}, parent) do
        sa_config =
          %{
            "prompt" => "#{name}.md",
            "title" => Map.get(args, "title", name),
            "description" => Map.get(args, "description", "")
          }
          |> maybe_put("tool_policy", args["tool_policy"])
          |> maybe_put("catalyst_ref", args["catalyst_ref"])
          |> maybe_put("model", args["model"])

        updated = put_in(manifest, ["agents", parent, "sub_agents", name], sa_config)

        with :ok <- write_agent_manifest(ctx, updated),
             :ok <- Arca.put(ctx, ["aqua", "#{name}.md"], content) do
          {:ok, %{created: name, type: "sub-agent", parent: parent}}
        else
          {:error, reason} -> {:error, "Failed to create agent: #{inspect(reason)}"}
        end
      else
        false -> {:error, "Parent orchestrator '#{parent}' not found"}
        {:error, reason} -> {:error, "Failed to read manifest: #{inspect(reason)}"}
      end
    end
  end

  defp create_aqua_orchestrator(ctx, name, args) do
    content = Map.get(args, "content", "")

    with {:ok, manifest} <- read_agent_manifest(ctx) do
      if Map.has_key?(manifest["agents"] || %{}, name) do
        {:error, "Agent '#{name}' already exists"}
      else
        agent_config =
          %{
            "title" => Map.get(args, "title", name),
            "prompt" => "#{name}.md",
            "sub_agents" => %{}
          }
          |> maybe_put("catalyst_ref", args["catalyst_ref"])
          |> maybe_put("model", args["model"])
          |> maybe_put("tool_policy", args["tool_policy"])

        updated = put_in(manifest, ["agents", name], agent_config)

        with :ok <- write_agent_manifest(ctx, updated),
             :ok <- Arca.put(ctx, ["aqua", "#{name}.md"], content) do
          {:ok, %{created: name, type: "orchestrator"}}
        else
          {:error, reason} -> {:error, "Failed to create agent: #{inspect(reason)}"}
        end
      end
    end
  end

  defp put_if_int(kw, key, n) when is_integer(n) and n >= 0, do: Keyword.put(kw, key, n)

  defp put_if_int(kw, key, s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> Keyword.put(kw, key, n)
      _ -> kw
    end
  end

  defp put_if_int(kw, _key, _), do: kw

  # Find the user's personal-namespace bearer, used for actions that require
  # a user identity proof (claim_publisher, verify_publisher).
  defp personal_bearer(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "" do
    registry = Compendium.Registry.canonical_host()

    case Compendium.Registry.CredentialStore.list_for_user(user_id, registry) do
      [%{type: :push_token, token: token, namespace: slug} | _] when is_binary(token) ->
        if String.contains?(slug, "."),
          do:
            {:error, "no personal-namespace bearer found — claim your personal namespace first"},
          else: {:ok, token}

      _ ->
        {:error, "no push token available — run `cyfr login` to authenticate"}
    end
  end

  defp personal_bearer(_), do: {:error, "authentication required"}

  # Find a bearer scoped to a specific namespace.
  defp namespace_bearer(%Context{user_id: user_id}, slug)
       when is_binary(user_id) and user_id != "" and is_binary(slug) do
    registry = Compendium.Registry.canonical_host()

    case Compendium.Registry.CredentialStore.get(user_id, registry, slug) do
      {:ok, %{type: :push_token, token: token}} when is_binary(token) ->
        {:ok, token}

      _ ->
        {:error, "no push token for namespace '#{slug}' — run `cyfr login`"}
    end
  end

  defp namespace_bearer(_, _), do: {:error, "authentication required"}

  # Persists the push token returned by claim_personal into CredentialStore
  # when the caller is authenticated. Returns the body unchanged on success,
  # or with a `"local_store_failed": true` marker on DB/encrypt failure so
  # the CLI can surface a warning.
  defp maybe_store_personal_credential(%Context{authenticated: true, user_id: user_id}, body)
       when is_binary(user_id) and user_id != "" do
    slug = body["slug"]
    token = body["token"]

    if is_binary(slug) and is_binary(token) do
      registry = Compendium.Registry.canonical_host()

      cred = %{
        type: :push_token,
        token: token,
        namespace: slug,
        role: "personal",
        issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        label: Compendium.Registry.Client.device_label()
      }

      case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
        :ok ->
          body

        {:error, reason} ->
          require Logger

          Logger.warning(
            "[Compendium.MCP] claim_personal CredentialStore.put failed for " <>
              "#{user_id}/#{slug}: #{inspect(reason)} — orphan cyfr.run token " <>
              "will be reaped server-side after 365 days"
          )

          Map.put(body, "local_store_failed", true)
      end
    else
      body
    end
  end

  defp maybe_store_personal_credential(_ctx, body), do: body

  # Persists every push token from a registry.probe response into the
  # caller's local CredentialStore. Used by the post-legal_accept re-probe
  # flow (codex/porta) so the cached credentials are populated without a
  # separate session.* round-trip. Mirrors
  # Sanctum.Auth.DeviceFlow.store_probe_results/4 (the device-flow path
  # that runs at OAuth completion).
  #
  # Annotates the body with `"credential_store_warnings": [slugs]` when any
  # individual put fails — partial failure is non-fatal (each namespace
  # is independent), and surfaces as a soft warning the client can show.
  defp maybe_store_probe_credentials(%Context{authenticated: true, user_id: user_id}, body)
       when is_binary(user_id) and user_id != "" do
    require Logger

    registry = Compendium.Registry.canonical_host()
    label = Compendium.Registry.Client.device_label()

    personal = body["personal_namespace"]
    memberships = body["memberships"] || []

    personal_warning =
      case personal do
        %{"slug" => slug, "token" => token}
        when is_binary(slug) and is_binary(token) ->
          cred = %{
            type: :push_token,
            token: token,
            namespace: slug,
            role: "personal",
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            label: label
          }

          case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
            :ok ->
              nil

            {:error, reason} ->
              Logger.warning(
                "[Compendium.MCP] probe CredentialStore.put failed (personal) " <>
                  "#{user_id}/#{slug}: #{inspect(reason)}"
              )

              slug
          end

        _ ->
          nil
      end

    membership_warnings =
      memberships
      |> Enum.map(fn m ->
        slug = m["slug"]
        token = m["token"]
        role = m["role"] || "member"

        if is_binary(slug) and is_binary(token) do
          cred = %{
            type: :push_token,
            token: token,
            namespace: slug,
            role: role,
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            label: label
          }

          case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
            :ok ->
              nil

            {:error, reason} ->
              Logger.warning(
                "[Compendium.MCP] probe CredentialStore.put failed (member) " <>
                  "#{user_id}/#{slug}: #{inspect(reason)}"
              )

              slug
          end
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    warnings =
      [personal_warning | membership_warnings] |> Enum.reject(&is_nil/1)

    if warnings == [] do
      body
    else
      Map.put(body, "credential_store_warnings", warnings)
    end
  end

  defp maybe_store_probe_credentials(_ctx, body), do: body

  # Lifts `required_version` out of an Errors struct's detail. The detail
  # shape depends on which builder produced the error:
  #   - Errors.from_response/3 puts {required_version: v} directly into detail
  #   - Errors.from_api_response/3 wraps it: %{operation: op, original_detail: %{required_version: v}}
  # Both keying styles (atom + string) are checked. Mirrors the extraction
  # logic in Sanctum.Auth.DeviceFlow.probe_after_session/3.
  defp required_policy_version(%Compendium.OCI.Errors{detail: detail}),
    do: dig_required_version(detail)

  defp required_policy_version(_), do: nil

  defp dig_required_version(%{required_version: v}) when is_binary(v), do: v
  defp dig_required_version(%{"required_version" => v}) when is_binary(v), do: v
  defp dig_required_version(%{original_detail: inner}), do: dig_required_version(inner)
  defp dig_required_version(%{"original_detail" => inner}), do: dig_required_version(inner)
  defp dig_required_version(_), do: nil

  # Canonical formatter shared with Compendium.OCI.Client (oci/client.ex:101-103).
  # Errors.to_string/1 produces "Policy acceptance required on cyfr.run
  # (HTTP 412, policy_acceptance_required)" — readable for TUI / toast surfaces;
  # actionable_hint/1 appends a remediation suffix when one is defined for the
  # reason. Verbose `detail` stays out of user-facing output (it's logged via
  # Errors.to_log_string/1 inside the client).
  defp to_error_string(%Compendium.OCI.Errors{} = err) do
    msg = Compendium.OCI.Errors.to_string(err)
    hint = Compendium.OCI.Errors.actionable_hint(err)
    if hint != "", do: "#{msg}. #{hint}", else: msg
  end

  defp to_error_string(err) when is_binary(err), do: err
  defp to_error_string(err), do: inspect(err)

  # deprecate/yank require a fully-qualified ref (all four fields).
  # Sanctum.ComponentRef.parse/1 can succeed with version=nil for
  # `c:alice.foo` (latest); these actions must target a specific version.
  defp ensure_fully_qualified(%Sanctum.ComponentRef{version: nil}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  defp ensure_fully_qualified(%Sanctum.ComponentRef{version: ""}),
    do: {:error, "deprecate/yank require a pinned version, e.g. c:alice.foo:1.0.0"}

  defp ensure_fully_qualified(%Sanctum.ComponentRef{}), do: :ok

  # ============================================================================
  # Abuse-report + admin helpers
  # ============================================================================

  defp ensure_present(value, _field) when is_binary(value) and value != "", do: :ok
  defp ensure_present(_, field), do: {:error, "'#{field}' is required"}

  # Closed-platform appeals: provider determines which token field carries
  # the credential. github/google use access_token; oidcc uses id_token.
  defp ensure_appeal_token("oidcc", _access, id) when is_binary(id) and id != "", do: :ok

  defp ensure_appeal_token("oidcc", _access, _id),
    do: {:error, "'id_token' is required for oidcc"}

  defp ensure_appeal_token(_provider, access, _id) when is_binary(access) and access != "",
    do: :ok

  defp ensure_appeal_token(_provider, _access, _id),
    do: {:error, "'access_token' is required"}

  defp ensure_target(nil, nil),
    do: {:error, "at least one of target_namespace or target_component_ref required"}

  defp ensure_target("", ""), do: ensure_target(nil, nil)
  defp ensure_target(nil, ""), do: ensure_target(nil, nil)
  defp ensure_target("", nil), do: ensure_target(nil, nil)
  defp ensure_target(_, _), do: :ok

  # MCP report action accepts a component ref (user-friendly). Server wants a
  # UUID. We resolve via the index — GET /v1/components/:type/:slug/:name/:ver.
  # Nil ref is fine (namespace-only report); empty string same.
  defp resolve_component_id(nil), do: {:ok, nil}
  defp resolve_component_id(""), do: {:ok, nil}

  defp resolve_component_id(ref) when is_binary(ref) do
    with {:ok, %Sanctum.ComponentRef{} = r} <- Sanctum.ComponentRef.parse(ref),
         :ok <- ensure_fully_qualified(r),
         {:ok, comp} <-
           Compendium.Registry.Client.get_component(
             Sanctum.system_context(),
             r.type,
             r.namespace,
             r.name,
             r.version
           ) do
      {:ok, comp["id"] || comp[:id]}
    end
  end

  # First push token the caller holds — for non-namespace-scoped actions like
  # abuse-report submission. Same head-of-list heuristic used by probe.
  defp any_push_token(%Sanctum.Context{user_id: user_id})
       when is_binary(user_id) and user_id != "" do
    registry = Compendium.Registry.canonical_host()

    case Compendium.Registry.CredentialStore.list_for_user(user_id, registry) do
      [%{type: :push_token, token: token} | _] when is_binary(token) -> {:ok, token}
      _ -> {:error, "no push token available — run `cyfr login` to authenticate"}
    end
  end

  defp any_push_token(_), do: {:error, "authentication required"}

  # --- AQUA private helpers ---
  #
  # All AQUA reads/writes go through Arca (see Arca.Storage @global_prefixes
  # — `aqua` routes to `:cyfr, :aqua_path`, default `./aqua`). Tests still
  # override the location via `Application.put_env(:cyfr, :aqua_path, tmp)`
  # because the Local adapter resolves `aqua_path/0` from that env key.

  defp read_agent_manifest(%Context{} = ctx) do
    case Arca.get(ctx, ["aqua", "agent.json"]) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} -> {:error, :manifest_not_found}
        end

      {:error, _} ->
        {:error, :manifest_not_found}
    end
  end

  defp write_agent_manifest(%Context{} = ctx, manifest) do
    case Jason.encode(manifest, pretty: true) do
      {:ok, json} -> Arca.put(ctx, ["aqua", "agent.json"], json <> "\n")
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_agent_prompt(%Context{} = ctx, filename) do
    Arca.get(ctx, ["aqua", filename])
  end

  defp lookup_agent_guide(%Context{} = ctx, name) do
    with {:ok, %{"agents" => agents}} <- read_agent_manifest(ctx) do
      case Map.get(agents, name) do
        %{"prompt" => filename} = config ->
          with {:ok, content} <- read_agent_prompt(ctx, filename) do
            {:ok,
             %{
               name: name,
               format: "markdown",
               content: content,
               type: "orchestrator",
               title: config["title"],
               catalyst_ref: config["catalyst_ref"],
               model: config["model"],
               tool_policy: config["tool_policy"]
             }}
          else
            _ -> {:error, "Failed to read prompt for orchestrator: #{name}"}
          end

        nil ->
          find_sub_agent_guide(ctx, agents, name)
      end
    else
      _ -> {:error, "Failed to read agent manifest"}
    end
  end

  defp find_sub_agent_guide(%Context{} = ctx, agents, name) do
    result =
      Enum.find_value(agents, fn {parent, config} ->
        case get_in(config, ["sub_agents", name]) do
          %{"prompt" => filename} = sa ->
            with {:ok, content} <- read_agent_prompt(ctx, filename) do
              {:ok,
               %{
                 name: name,
                 format: "markdown",
                 content: content,
                 type: "sub-agent",
                 parent: parent,
                 title: sa["title"],
                 description: sa["description"],
                 tool_policy: sa["tool_policy"],
                 catalyst_ref: sa["catalyst_ref"],
                 model: sa["model"]
               }}
            end

          _ ->
            nil
        end
      end)

    result || {:error, "Unknown agent or guide: #{name}. Use aqua(list) to see available agents."}
  end

  defp find_agent_in_manifest(manifest, name) do
    agents = manifest["agents"] || %{}

    case Map.get(agents, name) do
      %{} = config ->
        {:ok, {:orchestrator, config}}

      nil ->
        result =
          Enum.find_value(agents, fn {parent, config} ->
            case get_in(config, ["sub_agents", name]) do
              %{} = sa -> {:ok, {:sub_agent, parent, sa}}
              _ -> nil
            end
          end)

        result || {:error, "Agent '#{name}' not found"}
    end
  end

  defp update_agent_fields(manifest, path, args) do
    updatable = ["title", "description", "tool_policy", "catalyst_ref", "model"]

    Enum.reduce(updatable, manifest, fn field, acc ->
      if Map.has_key?(args, field) do
        case Map.get(args, field) do
          nil ->
            # Explicitly set to nil → remove the field from manifest
            update_in(acc, path, fn config -> Map.delete(config, field) end)

          value ->
            put_in(acc, path ++ [field], value)
        end
      else
        acc
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ============================================================================
  # Artifact Resolution
  # ============================================================================

  defp resolve_artifact(%{"path" => path}) when is_binary(path) do
    # `path` lets a publish caller point at any file the cyfr OS process can
    # read. Safe only when no auth is configured — then the operator is the
    # only one who can submit an import and owns the host. Once authentication
    # is configured, any signed-in user could attempt a path import, so reject:
    # they push artifacts via OCI publish or base64, never host filesystem paths.
    if Sanctum.auth_configured?() do
      {:error, :path_artifacts_disabled_when_auth_configured}
    else
      expanded = Path.expand(path)

      # arca:bypass-ok=D — user-supplied filesystem path import boundary
      # (no-auth host-trust). Authorization to invoke this MCP action is
      # enforced by `require_permission(ctx, :component_manage)` at the
      # handler layer.
      case File.read(expanded) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :enoent} -> {:error, :file_not_found}
        {:error, reason} -> {:error, {:file_read_error, reason}}
      end
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
        Keyword.get(config, :url, Compendium.Registry.canonical_host())

      _ ->
        Compendium.Registry.canonical_host()
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
    empty = %{
      pulled_dependencies: [],
      failed_pulls: [],
      missing_local_deps: [],
      optional_missing: []
    }

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

        {pulled_refs, failed_refs} =
          auto_pull_published_deps(ctx, published_missing, register_id, session_id)

        %{
          pulled_dependencies: pulled_refs,
          failed_pulls: failed_refs,
          missing_local_deps: local_refs,
          optional_missing: optional_refs
        }
      end
    end
  rescue
    e in [
      Mint.TransportError,
      Mint.HTTPError,
      Jason.DecodeError,
      MatchError,
      KeyError,
      Ecto.QueryError,
      DBConnection.ConnectionError
    ] ->
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
        manifest = decode_manifest(component.manifest)
        component_id = component.id || ""

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

            broadcast_register_progress(
              ctx,
              register_id,
              session_id,
              :pull_failed,
              "Failed to pull #{ref}"
            )

            {acc, [ref | failed_acc], visited}
        end
      end)

    {Enum.reverse(pulled), Enum.reverse(failed)}
  end

  # Broadcast register progress to both PubSub (Prism) and SSEBuffer (CLI).
  defp broadcast_register_progress(_ctx, nil, _session_id, _phase, _message), do: :ok

  defp broadcast_register_progress(ctx, register_id, session_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    case Phoenix.PubSub.broadcast(
           Emissary.PubSub,
           Sanctum.PubSub.topic("register:#{register_id}", ctx),
           {:register_progress, payload}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.MCP] PubSub broadcast failed: #{inspect(reason)}")
    end

    if session_id do
      notification =
        Emissary.MCP.Message.encode_notification("notifications/progress", %{
          register_id: register_id,
          phase: phase,
          message: message
        })

      Emissary.MCP.SSEBuffer.push(session_id, notification)
    end

    :ok
  end

  # Broadcast to all Prism LiveViews subscribed to prism:components.
  # Fires after any state-changing component operation (pull, register, delete, new, publish).
  defp broadcast_components_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:components", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :components_changed)
  end

  # Broadcast generic progress to both PubSub (Prism) and SSEBuffer (CLI).
  # Used by pull and publish handlers.
  defp broadcast_progress(_ctx, nil, _session_id, _phase, _message), do: :ok

  defp broadcast_progress(ctx, progress_id, session_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    case Phoenix.PubSub.broadcast(
           Emissary.PubSub,
           Sanctum.PubSub.topic("progress:#{progress_id}", ctx),
           {:progress, payload}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.MCP] PubSub broadcast failed: #{inspect(reason)}")
    end

    if session_id do
      notification =
        Emissary.MCP.Message.encode_notification("notifications/progress", %{
          progress_id: progress_id,
          phase: phase,
          message: message
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
        registry = Compendium.Registry.canonical_host()

        {:ok, oci_ref} = Compendium.OCI.Reference.from_component_ref(cref, registry)

        case resolve_latest_oci_tag(oci_ref) do
          {:ok, tag} -> {:ok, Compendium.OCI.Reference.to_string(%{oci_ref | tag: tag})}
          {:error, _} -> {:ok, Compendium.OCI.Reference.to_string(oci_ref)}
        end

      {:ok, %Sanctum.ComponentRef{} = cref} ->
        registry = Compendium.Registry.canonical_host()
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

          _ ->
            {:error, :unexpected_response}
        end

      _ ->
        {:error, :tags_fetch_failed}
    end
  end

  defp semver_tag?(tag), do: Regex.match?(~r/^\d+\.\d+\.\d+/, tag)

  defp semver_gte?(a, b) do
    parse_semver(a) >= parse_semver(b)
  end

  defp parse_semver(tag) do
    tag
    |> String.split(".")
    |> Enum.map(fn p ->
      case Integer.parse(p) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end

  # Shared OCI pull logic used by both explicit OCI refs and converted component refs.
  defp do_oci_pull(ctx, reference) do
    case Compendium.OCI.Reference.parse(reference) do
      {:ok, ref} ->
        case Compendium.Registry.validate_host(ref.registry) do
          :ok ->
            namespace_slug =
              case String.split(ref.repository || "", "/", parts: 2) do
                [slug | _] when slug != "" -> slug
                _ -> ""
              end

            anonymous? =
              Compendium.OCI.Auth.fetch_credential(
                Compendium.Registry.canonical_host(),
                namespace_slug,
                ctx
              ) ==
                :anonymous

            if anonymous? do
              Logger.warning(
                "[Compendium.MCP] No credentials for #{Compendium.Registry.canonical_host()} — " <>
                  "pull may fail for non-public components. Run `cyfr login` to authenticate."
              )
            end

            case Compendium.OCI.Client.pull(ctx, reference) do
              {:ok, result} ->
                if result[:warning], do: Logger.warning("[Compendium.MCP] #{result.warning}")

                result =
                  if anonymous? do
                    Map.put(
                      result,
                      :auth_note,
                      "You are pulling anonymously from #{Compendium.Registry.canonical_host()}. " <>
                        "Private components will not be accessible. Run `cyfr login` to authenticate."
                    )
                  else
                    result
                  end

                result = maybe_auto_pull_oci_deps(ctx, reference, result)
                {:ok, result}

              {:error, reason} ->
                if anonymous? do
                  {:error,
                   reason <>
                     " — No credentials configured for #{Compendium.Registry.canonical_host()}. " <>
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
    e in [
      Mint.TransportError,
      Mint.HTTPError,
      Jason.DecodeError,
      MatchError,
      KeyError,
      Ecto.QueryError,
      DBConnection.ConnectionError
    ] ->
      Logger.warning("[Compendium.MCP] Exception in auto-pull OCI deps: #{Exception.message(e)}")
      result
  end

  # Auto-pull missing dependencies. Uses a visited set for cycle detection.
  defp auto_pull_deps(ctx, deps, result) do
    availability = Compendium.DependencyResolver.classify_availability(ctx, deps)

    {pulled, failed, _visited} =
      Enum.reduce(availability.missing, {[], [], MapSet.new()}, fn dep,
                                                                   {acc, failed_acc, visited} ->
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
  defp read_component_readme(ctx, reference) do
    case resolve_component(ctx, reference) do
      {:ok, _component, ref} ->
        path =
          Compendium.ComponentPath.file_path(
            ref.type,
            ref.namespace,
            ref.name,
            ref.version,
            "README.md",
            ctx
          )

        case Arca.get(ctx, path) do
          {:ok, content} -> content
          _ -> nil
        end

      _ ->
        nil
    end
  end

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

              error ->
                error
            end
          else
            Registry.get(ctx, name, version, namespace, type)
          end

        case result do
          {:ok, component} ->
            resolved_version = component[:version] || version
            resolved_type = type || component[:component_type] || component[:type]

            {:ok, component,
             %{namespace: namespace, name: name, version: resolved_version, type: resolved_type}}

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
  # Search Result Merging (single-user: local + cyfr.run)
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

    # Collect all remote versions per identity for version discovery
    remote_all_versions =
      Enum.reduce(remote_components, %{}, fn comp, acc ->
        key = component_identity_key(comp)
        version = comp["version"] || comp[:version]
        Map.update(acc, key, [version], fn vs -> [version | vs] end)
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
            |> Map.put(:remote_versions, Map.get(remote_all_versions, key, []))

          nil ->
            comp
            |> Map.put(:local_version, local_version)
            |> Map.put(:remote_latest, nil)
            |> Map.put(:update_available, false)
            |> Map.put(:remote_versions, [])
        end
      end)

    # Remote-only components (not installed locally) — latest version only
    remote_only =
      remote_by_identity
      |> Enum.reject(fn {key, _} -> MapSet.member?(local_identity_keys, key) end)
      |> Enum.map(fn {key, {version, comp}} ->
        comp
        |> Map.put(:local_version, nil)
        |> Map.put(:remote_latest, version)
        |> Map.put(:update_available, false)
        |> Map.put(:remote_versions, Map.get(remote_all_versions, key, []))
        |> ensure_component_ref()
      end)

    merged = annotated_local ++ remote_only

    {:ok,
     %{
       components: merged,
       total: length(merged),
       local_count: length(annotated_local),
       remote_count: length(remote_only)
     }}
  end

  defp ensure_component_ref(comp) do
    if comp[:component_ref] || comp["component_ref"] do
      comp
    else
      type = comp["component_type"] || comp[:component_type]

      publisher =
        comp["namespace_slug"] || comp[:namespace_slug] || comp["publisher"] ||
          comp[:publisher]

      name = comp["name"] || comp[:name]
      version = comp["version"] || comp[:version]

      if type && publisher && name do
        ref =
          Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
            type: type,
            namespace: publisher,
            name: name,
            version: version
          })

        Map.put(comp, :component_ref, ref)
      else
        comp
      end
    end
  end

  defp component_identity_key(comp) when is_map(comp) do
    {comp["name"] || comp[:name],
     comp["publisher"] || comp[:publisher] || comp["namespace_slug"] || comp[:namespace_slug],
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

  # ============================================================================
  # Tincture media enrichment (used by `component list` and `component inspect`)
  # ============================================================================

  # Walk a search/list result and enrich tincture rows with media files
  # discovered via the `public/media/` convention (probed through Arca.exists?
  # — works on Local FS and S3 alike). Non-tincture rows pass through
  # unchanged. Manifest values declared in `tincture.media` always win as
  # escape hatch.
  defp enrich_tincture_media(ctx, %{components: components} = result) when is_list(components) do
    %{result | components: Enum.map(components, &enrich_component_with_media(ctx, &1))}
  end

  defp enrich_tincture_media(_ctx, result), do: result

  defp enrich_component_with_media(ctx, %{component_type: "tincture"} = component) do
    enrich_with_discovered_media(ctx, component)
  end

  defp enrich_component_with_media(ctx, %{"component_type" => "tincture"} = component) do
    enrich_with_discovered_media(ctx, component)
  end

  defp enrich_component_with_media(_ctx, component), do: component

  defp enrich_with_discovered_media(ctx, component) do
    raw_manifest = component[:manifest] || component["manifest"]

    case parse_manifest_for_enrichment(raw_manifest) do
      {:ok, parsed} ->
        case compute_tincture_version_segments(component) do
          nil ->
            component

          segments ->
            discovered = Cyfr.TinctureHelpers.discover_media_via_arca(ctx, segments)
            updated = merge_discovered_into_manifest(parsed, discovered)
            put_manifest(component, updated, raw_manifest)
        end

      :error ->
        component
    end
  end

  defp parse_manifest_for_enrichment(nil), do: :error
  defp parse_manifest_for_enrichment(map) when is_map(map), do: {:ok, map}

  defp parse_manifest_for_enrichment(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp parse_manifest_for_enrichment(_), do: :error

  defp merge_discovered_into_manifest(manifest, discovered) do
    tincture_block = manifest["tincture"] || %{}
    declared = tincture_block["media"] || %{}

    icon = declared["icon"] || discovered.icon
    previews = declared["previews"] || discovered.previews

    # Skip the merge entirely if discovery found nothing AND nothing was declared
    # — keeps the manifest free of an empty media block for tinctures with no assets.
    if icon == nil and previews in [nil, []] do
      manifest
    else
      merged_media =
        %{}
        |> put_media_field("icon", icon)
        |> put_media_field("previews", previews || [])

      Map.put(manifest, "tincture", Map.put(tincture_block, "media", merged_media))
    end
  end

  defp put_media_field(map, _key, nil), do: map
  defp put_media_field(map, _key, []), do: map
  defp put_media_field(map, key, value), do: Map.put(map, key, value)

  # Write the enriched manifest back into the component, preserving whichever
  # key shape (atom or string) the original used and whichever value shape
  # (parsed map or JSON string) it came in. Keeps consumers downstream of the
  # post-processor unaffected by the enrichment pass.
  defp put_manifest(component, updated, original) when is_binary(original) do
    encoded = Jason.encode!(updated)

    cond do
      Map.has_key?(component, :manifest) -> Map.put(component, :manifest, encoded)
      Map.has_key?(component, "manifest") -> Map.put(component, "manifest", encoded)
      true -> component
    end
  end

  defp put_manifest(component, updated, _original) do
    cond do
      Map.has_key?(component, :manifest) -> Map.put(component, :manifest, updated)
      Map.has_key?(component, "manifest") -> Map.put(component, "manifest", updated)
      true -> component
    end
  end

  defp compute_tincture_version_segments(component) do
    publisher = component[:publisher] || component["publisher"]
    name = component[:name] || component["name"]
    version = component[:version] || component["version"]
    org_id = component[:org_id] || component["org_id"]
    project_id = component[:project_id] || component["project_id"]

    if publisher && name && version do
      Compendium.ComponentPath.version_dir(
        "tincture",
        publisher,
        name,
        version,
        {org_id, project_id}
      )
    end
  end
end
