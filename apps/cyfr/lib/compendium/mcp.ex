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
    - `push` - Push a local component to the OCI registry
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
  alias Compendium.MCP.Shared

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

  Anonymous reads are refused before any tenant resolution: an
  unauthenticated context carries no athanor of its own, so letting it
  through would serve component metadata and asset bytes to anyone who can
  reach `POST /mcp` with an exact reference.
  """
  def read(%Context{authenticated: false}, "compendium://" <> _rest) do
    {:error, "Authentication required to read components"}
  end

  def read(%Context{} = ctx, "compendium://components/" <> reference) do
    case Shared.resolve_component(ctx, reference) do
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
        case Shared.resolve_component(ctx, reference) do
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
            "search" => %{kind: :read, planes: [:external, :in_chain]},
            "inspect" => %{kind: :read, planes: [:external, :in_chain]},
            "pull" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "push" => %{kind: :write, planes: [:external], permission: :component_manage},
            "register" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "categories" => %{kind: :read, planes: [:external, :in_chain]},
            "get_blob" => %{
              kind: :read,
              planes: [:external, :in_chain],
              permission: :component_read
            },
            "discover" => %{
              kind: :read,
              planes: [:external, :in_chain],
              permission: :component_read
            },
            "setup_plan" => %{kind: :read, planes: [:external, :in_chain]},
            "list" => %{kind: :read, planes: [:external, :in_chain]},
            "delete" => %{kind: :destructive, planes: [:external], permission: :component_manage},
            "create" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "fork" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            # deprecate/yank were the one write pair with no permission gate —
            # discovery already advertised :component_manage, and every
            # sibling mutation carries it; the handlers' namespace-bearer
            # check remains as the registry-identity residual.
            "deprecate" => %{
              kind: :destructive,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "yank" => %{
              kind: :destructive,
              planes: [:external, :in_chain],
              permission: :component_manage
            }
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
                "push",
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
              "enum" => Sanctum.ComponentRef.valid_types(),
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
          "Manage the AQUA agent system — orchestrators, sub-agents, prompts, and documentation guides. Use 'list' to discover agents and guides, 'get' to retrieve prompts/docs, or 'create'/'update'/'delete' to manage agents (pass type=orchestrator|sub-agent on create; docs are read-only).",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            # list/get are deliberately open to any authenticated caller,
            # including in-chain: agent definitions are instance-global
            # shared reads (owner decision 2026-08-15).
            "list" => %{kind: :read, planes: [:external, :in_chain]},
            "get" => %{kind: :read, planes: [:external, :in_chain]},
            "create" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "update" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "delete" => %{
              kind: :destructive,
              planes: [:external, :in_chain],
              permission: :component_manage
            }
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "get", "create", "update", "delete"],
              "description" =>
                "Action: list/get agents and guides, or create/update/delete to manage agents. For create, pass type=orchestrator|sub-agent to choose the agent kind (docs are read-only)."
            },
            "name" => %{
              "type" => "string",
              "description" => "Agent or guide name (for get/update/delete actions)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["orchestrator", "sub-agent"],
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
              "additionalProperties" => %{"type" => "string", "enum" => ["ask", "auto"]},
              "description" =>
                "Per-(tool,action) allowlist for this agent. Keys are 'tool.action' or 'tool.*' strings (a bare 'native_search' key grants the provider-native search tool); values are 'auto' (directly callable) or 'ask' (reachable only through user approval). A pair missing from the map is not callable at all. Each action's risk level is derived from its `kind` annotation (read/write/execute/destructive/external) — color/UI treatment uses the kind, not the policy mode. The policy is the athanor's: every member edits the same allowlist."
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
            # Bootstrap/spec reads stay open (they run before a session
            # exists per the cyfr.run spec); identity mutations mirror
            # RegistryTool's gate.
            "probe" => %{kind: :execute, planes: [:external, :in_chain]},
            "claim_personal" => %{kind: :write, planes: [:external, :in_chain]},
            "claim_publisher" => %{
              kind: :write,
              planes: [:external],
              permission: :component_manage
            },
            "verify_publisher" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "tokens_list" => %{kind: :read, planes: [:external, :in_chain]},
            "tokens_issue" => %{kind: :write, planes: [:external], permission: :component_manage},
            "tokens_revoke" => %{
              kind: :write,
              planes: [:external, :in_chain],
              permission: :component_manage
            },
            "members_list" => %{kind: :read, planes: [:external, :in_chain]},
            "members_add" => %{kind: :write, planes: [:external], permission: :component_manage},
            "members_update" => %{
              kind: :write,
              planes: [:external],
              permission: :component_manage
            },
            "members_remove" => %{
              kind: :write,
              planes: [:external],
              permission: :component_manage
            },
            "whoami" => %{kind: :read, planes: [:external, :in_chain]},
            "get_namespace" => %{kind: :read, planes: [:external, :in_chain]},
            "report" => %{kind: :write, planes: [:external, :in_chain]},
            "list_my_reports" => %{kind: :read, planes: [:external, :in_chain]},
            "legal_page" => %{kind: :read, planes: [:external, :in_chain]},
            "legal_version" => %{kind: :read, planes: [:external, :in_chain]},
            "legal_accept" => %{kind: :write, planes: [:external, :in_chain]},
            "appeal" => %{kind: :write, planes: [:external, :in_chain]}
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
  # Tool Handlers — delegated to per-tool modules
  # ============================================================================

  def handle("component", ctx, args), do: Compendium.MCP.ComponentTool.handle(ctx, args)
  def handle("aqua", ctx, args), do: Compendium.MCP.AquaTool.handle(ctx, args)
  def handle("registry", ctx, args), do: Compendium.MCP.RegistryTool.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
