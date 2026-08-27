# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.ComponentTool do
  @moduledoc """
  Component tool handlers for the Compendium MCP provider — component
  discovery and registry operations (search, inspect, pull, push, register,
  create, fork, list, delete, deprecate, yank, etc.).

  Extracted from `Compendium.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context
  alias Compendium.OCI.Errors
  alias Compendium.Registry
  alias Compendium.MCP.Shared

  # ============================================================================
  # Tool Handlers - Action-based dispatch
  # ============================================================================

  # Search action - search for components. Searches the local registry and,
  # unless the caller restricts to source: "local", augments with the
  # configured registry's REST API (cyfr.run by default), merging results.
  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Compendium.MCP assembles its roster from these.
  def definition do
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
          "status" => %{kind: :read, planes: [:external, :in_chain]},
          "delete" => %{kind: :destructive, planes: [:external], permission: :component_manage},
          # Reverts a bundled component's local edits to exactly what the
          # release shipped — destructive to the edits, mirror of aqua.reset.
          "reset" => %{
            kind: :destructive,
            planes: [:external],
            permission: :component_manage
          },
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
              "status",
              "delete",
              "reset",
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
              "Component reference in format type:namespace.name:version (e.g. catalyst:moonmoon69.airtable:0.1.0). Use the component_ref value from search/list results. For status, omit it for a whole-athanor overview (provenance, shipped versions and superseded flags per component)."
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
    }
  end

  def handle(%Context{} = ctx, %{"action" => "search"} = args) do
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

  def handle(_ctx, %{"action" => "inspect"}) do
    {:error, "Missing required argument: reference"}
  end

  # Pull action - pull component from registry (local or OCI)
  def handle(%Context{} = ctx, %{"action" => "pull"} = args) do
    progress_id = args["progress_id"]

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
              broadcast_progress(ctx, progress_id, :pulling, "Pulling #{ref}...")
              result = do_oci_pull(ctx, ref)

              case result do
                {:ok, res} ->
                  broadcast_progress(
                    ctx,
                    progress_id,
                    :complete,
                    "Pulled #{res[:component_ref] || ref}"
                  )

                  broadcast_components_changed(ctx)

                {:error, reason} ->
                  Logger.error("[Compendium.MCP] Pull failed: #{inspect(reason)}")
                  broadcast_progress(ctx, progress_id, :error, "Pull failed")
              end

              result

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  # Push action — upload an already-registered local component to an OCI registry.
  # A push goes out as the person who triggered it, under a namespace they
  # hold; an API key is an athanor's credential and is nobody's publisher.
  def handle(%Context{auth_method: :api_key}, %{"action" => "push"}) do
    {:error, "component.push is a person's act — sign in; an API key cannot publish"}
  end

  def handle(%Context{} = ctx, %{"action" => "push"} = args) do
    reference = args["reference"]
    registry = args["registry"] || default_registry()
    progress_id = args["progress_id"]

    cond do
      is_nil(reference) ->
        {:error, "Missing required argument: reference (format: name:version)"}

      true ->
        case Sanctum.ComponentRef.parse(reference) do
          {:ok, %{version: nil}} ->
            {:error, "Version is required for pushing. Example: c:local.name:1.0.0"}

          {:ok, cref} ->
            with :ok <- refuse_non_local_push(cref),
                 :ok <- Compendium.RegistryHost.validate_host(registry) do
              # `local` refs are remapped to the caller's claimed personal
              # namespace inside `OCI.Client.push` (via resolve_push_publisher),
              # which returns a precise error if no namespace is claimed. No
              # literal-"local" credential pre-check here — there is no push
              # token for "local"; the token belongs to the resolved namespace.
              broadcast_progress(
                ctx,
                progress_id,
                :pushing,
                "Pushing #{reference} to #{registry}..."
              )

              case Compendium.OCI.Client.push(ctx, reference, registry) do
                {:ok, result} ->
                  broadcast_progress(
                    ctx,
                    progress_id,
                    :complete,
                    "Pushed #{result[:oci_reference] || reference}"
                  )

                  record_push(ctx, reference, result)
                  {:ok, result}

                {:error, reason} ->
                  Logger.error("[Compendium.MCP] Push failed: #{inspect(reason)}")
                  broadcast_progress(ctx, progress_id, :error, "Push failed")
                  {:error, reason}
              end
            end

          {:error, reason} ->
            {:error, "Invalid reference: #{reason}"}
        end
    end
  end

  # Create action - scaffold a new component project
  def handle(%Context{} = ctx, %{"action" => "create"} = args) do
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

  # Register action - scan and register all local components
  def handle(%Context{} = ctx, %{"action" => "register"} = args) do
    register_id = args["register_id"]

    broadcast_register_progress(
      ctx,
      register_id,
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
            :registered,
            "Registered #{name}:#{version}"
          )

        "unchanged" ->
          broadcast_register_progress(
            ctx,
            register_id,
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
        :pruning,
        "Pruned #{result.pruned} stale component(s)"
      )
    end

    broadcast_register_progress(
      ctx,
      register_id,
      :checking_deps,
      "Checking dependencies..."
    )

    dep_info = check_register_deps(ctx, result.components, register_id)

    broadcast_register_progress(
      ctx,
      register_id,
      :complete,
      "Complete — #{result.registered} registered, #{result.unchanged} unchanged, #{result.total} total"
    )

    broadcast_components_changed(ctx)

    # A freshly registered local component gets its baseline consent at
    # once — provisioning mints for the seed bundle, this mints for what a
    # person registers later — so it is invocable without a manual step.
    minted = bootstrap_registered(ctx, result.components)

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
         scanned_dirs: result.scanned_dirs,
         bootstrapped: minted
       },
       dep_fields
     )}
  end

  # List action - list all installed components (local-only, no remote search)
  def handle(%Context{} = ctx, %{"action" => "list"} = args) do
    filters = %{
      type: args["type"],
      limit: min(args["limit"] || 1000, 1000)
    }

    # The one data path the Components page consumes: every row carries
    # its provenance and update facts, so the UI needs no second call.
    with {:ok, result} <- Registry.search(ctx, filters),
         {:ok, annotated} <- Compendium.Provenance.annotate(ctx, result.components) do
      components =
        Enum.map(annotated, fn entry ->
          entry.component
          |> Map.put(:provenance, Compendium.Provenance.label(entry.provenance))
          |> Map.put(:superseded, entry.superseded)
          |> Map.put(:shadows_shipped, entry.shadows_shipped)
          |> Map.put(:forked_from, entry.forked_from)
          |> Map.put(:upstream_superseded, entry.upstream_superseded)
        end)

      {:ok, enrich_tincture_media(ctx, %{result | components: components})}
    else
      {:error, reason} ->
        Logger.error("[Compendium.MCP] component.list failed: #{inspect(reason)}")
        {:error, "Failed to list components"}
    end
  end

  # Delete action - delete a component from the registry
  def handle(%Context{} = ctx, %{"action" => "delete", "reference" => reference}) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %{version: nil} = cref} ->
        # Check if name is even valid before giving version error
        case Sanctum.ComponentRef.validate_name(cref.name) do
          :ok -> {:error, "Version is required for deletion. Example: c:local.name:1.0.0"}
          {:error, reason} -> {:error, "Invalid reference: #{reason}"}
        end

      {:ok, cref} ->
        case Registry.delete(ctx, cref.name, cref.version, cref.namespace) do
          {:ok, :deleted} ->
            broadcast_components_changed(ctx)
            {:ok, %{status: "deleted", reference: reference}}

          {:ok, :revealed_shipped} ->
            broadcast_components_changed(ctx)
            # The athanor's copy is gone; the shipped version shows
            # through again — same wording as aqua's delete.
            {:ok, %{status: "deleted", reference: reference, restored: "shipped"}}

          {:error, :not_found} ->
            {:error, "Component not found: #{reference}"}

          {:error, :bundled} ->
            {:error,
             "#{reference} ships with the server and cannot be deleted — " <>
               "it costs your athanor nothing until edited"}

          {:error, :bundled_modified} ->
            {:error,
             "#{reference} is bundled with local edits — use action=reset to " <>
               "revert it to the shipped version"}

          {:error, reason} ->
            Logger.error("[Compendium.MCP] component.delete failed: #{inspect(reason)}")
            {:error, "Failed to delete #{reference}"}
        end

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: reference"}
  end

  # Reset action — revert a bundled component's local edits to exactly what
  # the release shipped ("delete" never means "revert").
  def handle(%Context{} = ctx, %{"action" => "reset", "reference" => reference}) do
    with {:ok, %{version: version} = cref} when is_binary(version) <-
           Sanctum.ComponentRef.parse(reference) do
      case Registry.reset(ctx, cref.name, cref.version, cref.namespace) do
        {:ok, :reset} ->
          broadcast_components_changed(ctx)
          {:ok, %{status: "reset", reference: reference}}

        {:ok, :already_pristine} ->
          {:ok, %{status: "already_pristine", reference: reference}}

        {:error, :not_found} ->
          {:error, "Component not found: #{reference}"}

        {:error, :not_bundled} ->
          {:error, "#{reference} is not a bundled component — nothing shipped to revert to"}

        {:error, reason} ->
          Logger.error("[Compendium.MCP] component.reset failed: #{inspect(reason)}")
          {:error, "Failed to reset #{reference}"}
      end
    else
      {:ok, %{version: nil}} ->
        {:error, "Version is required for reset. Example: c:local.name:1.0.0"}

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  def handle(_ctx, %{"action" => "reset"}) do
    {:error, "Missing required argument: reference"}
  end

  # Status action — provenance and drift for one component: whose bytes
  # answer (bundled / bundled_modified / user / remote), how an edited
  # bundled copy differs from shipped, and what versions this release ships.
  def handle(%Context{} = ctx, %{"action" => "status", "reference" => reference}) do
    with {:ok, %{version: version} = cref} when is_binary(version) <-
           Sanctum.ComponentRef.parse(reference),
         {:ok, component} <-
           Arca.ComponentStorage.get_component(ctx, cref.name, cref.version, cref.namespace, nil),
         {:ok, overlay} <- Compendium.Provenance.status(ctx, component) do
      drift =
        case overlay.drift do
          :pristine -> %{drift: "pristine"}
          {:modified, diff} -> %{drift: "modified", diff: format_diff(diff)}
          nil -> %{}
        end

      shipped =
        if overlay.provenance == :remote,
          do: [],
          else:
            Compendium.Provenance.shipped_versions(
              to_string(Map.get(component, :component_type, "")),
              cref.name
            )

      lineage =
        case Compendium.Provenance.upstream_status(ctx, component) do
          nil ->
            %{}

          upstream ->
            %{
              forked_from: upstream.forked_from,
              upstream_superseded: upstream.upstream_superseded
            }
        end

      {:ok,
       %{
         reference: reference,
         provenance: Compendium.Provenance.label(overlay.provenance),
         shipped_versions: shipped,
         shadows_shipped: overlay.shadows_shipped
       }
       |> Map.merge(drift)
       |> Map.merge(lineage)}
    else
      {:ok, %{version: nil}} ->
        {:error, "Version is required for status. Example: c:local.name:1.0.0"}

      {:error, :not_found} ->
        {:error, "Component not found: #{reference}"}

      {:error, reason} when is_binary(reason) ->
        {:error, "Invalid reference: #{reason}"}

      {:error, reason} ->
        Logger.error("[Compendium.MCP] component.status failed: #{inspect(reason)}")
        {:error, "Failed to read status for #{reference}"}
    end
  end

  # Status overview — no reference: the whole athanor at once, provenance
  # per component with the release catalog and superseded flags. The batch
  # surface an updates view consumes.
  def handle(%Context{} = ctx, %{"action" => "status"}) do
    case Compendium.Provenance.overview(ctx) do
      {:error, reason} ->
        {:error, "Failed to read status: #{inspect(reason)}"}

      {:ok, overview} ->
        components =
          Enum.map(overview, fn entry ->
            row = entry.component

            reference =
              Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
                type: to_string(Map.get(row, :component_type, "")),
                namespace: Compendium.ComponentPath.normalize_publisher(Map.get(row, :publisher)),
                name: row.name,
                version: row.version
              })

            %{
              reference: reference,
              provenance: Compendium.Provenance.label(entry.provenance),
              shipped_versions: entry.shipped_versions,
              superseded: entry.superseded,
              shadows_shipped: entry.shadows_shipped,
              forked_from: entry.forked_from,
              upstream_superseded: entry.upstream_superseded
            }
          end)

        counts =
          Enum.reduce(
            overview,
            %{bundled: 0, bundled_modified: 0, user: 0, remote: 0},
            fn entry, acc -> Map.update!(acc, entry.provenance, &(&1 + 1)) end
          )

        {:ok, %{components: Enum.sort_by(components, & &1.reference), counts: counts}}
    end
  end

  # Categories action - list available categories
  def handle(%Context{} = _ctx, %{"action" => "categories"}) do
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
  def handle(%Context{} = ctx, %{"action" => "get_blob", "digest" => digest}) do
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

  def handle(_ctx, %{"action" => "get_blob"}) do
    {:error, "Missing required argument: digest"}
  end

  # Discover action - list components on the configured registry (cyfr.run
  # REST API). The registry host is set via CYFR_REGISTRY_URL.
  def handle(%Context{} = ctx, %{"action" => "discover"} = args) do
    registry = args["registry"] || default_registry()

    case Compendium.RegistryHost.validate_host(registry) do
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

  # ============================================================================
  # Setup Plan Action
  # ============================================================================

  def handle(%Context{} = ctx, %{"action" => "setup_plan", "reference" => reference}) do
    Compendium.Component.setup_plan(ctx, reference)
  end

  def handle(_ctx, %{"action" => "setup_plan"}) do
    {:error, "Missing required argument: reference"}
  end

  # Fork action - fork a published component to local namespace
  def handle(
        %Context{} = ctx,
        %{"action" => "fork", "reference" => reference} = args
      ) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %{version: nil}} ->
        {:error, "Version is required for fork. Example: c:acme.my-tool:1.0.0"}

      # A local source is refused inside Compendium.Fork — one guard, one
      # message, whether the call comes through this tool or directly.
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

  def handle(_ctx, %{"action" => "fork"}) do
    {:error, "Missing required argument: reference"}
  end

  def handle(
        %Context{} = ctx,
        %{"action" => "deprecate", "reference" => reference} = args
      ) do
    reason = Map.get(args, "reason", "")

    if String.trim(reason) == "" do
      {:error, "component.deprecate requires a non-empty 'reason'"}
    else
      with {:ok, ref} <- Sanctum.ComponentRef.parse(reference),
           :ok <- Shared.ensure_fully_qualified(ref),
           {:ok, bearer} <- Shared.namespace_bearer(ctx, ref.namespace),
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
        {:error, err} -> {:error, Shared.to_error_string(err)}
      end
    end
  end

  def handle(_ctx, %{"action" => "deprecate"}) do
    {:error, "component.deprecate requires 'reference' and 'reason'"}
  end

  # Yank action — reason optional (deprecate requires one; yank does not).
  def handle(
        %Context{} = ctx,
        %{"action" => "yank", "reference" => reference} = args
      ) do
    reason = Map.get(args, "reason", "")

    with {:ok, ref} <- Sanctum.ComponentRef.parse(reference),
         :ok <- Shared.ensure_fully_qualified(ref),
         {:ok, bearer} <- Shared.namespace_bearer(ctx, ref.namespace),
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
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "yank"}) do
    {:error, "component.yank requires 'reference'"}
  end

  # Invalid action
  def handle(_ctx, %{"action" => action}) do
    {:error, "Invalid component action: #{action}"}
  end

  # Missing action
  def handle(_ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  # ============================================================================
  # Registry Default
  # ============================================================================

  defp default_registry, do: Compendium.RegistryHost.canonical_host()

  # Only local-namespace refs may be pushed — the namespace grammar is
  # `Compendium.ComponentPath`'s, one spelling.
  defp refuse_non_local_push(cref) do
    if Compendium.ComponentPath.local_publisher?(cref.namespace) do
      :ok
    else
      {:error,
       "Only components in the local namespace can be pushed to a registry. " <>
         "Got namespace '#{cref.namespace}'. Use the local namespace " <>
         "(e.g., c:#{Compendium.ComponentPath.default_publisher()}.#{cref.name}:#{cref.version})."}
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

  # After registration, check newly registered formulas for missing dependencies.
  # Local deps (local/agent namespaces) produce warnings; published deps are auto-pulled.
  defp check_register_deps(ctx, components, register_id) do
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
            # Local/on-disk namespaces are never pullable from OCI — the
            # grammar is ComponentPath's, one spelling.
            Compendium.ComponentPath.local_publisher?(ns)
          end)

        local_refs = Enum.map(local_missing, & &1[:dependency_ref])

        {pulled_refs, failed_refs} =
          auto_pull_published_deps(ctx, published_missing, register_id)

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

    publisher =
      Compendium.ComponentPath.normalize_publisher(comp[:publisher] || comp["publisher"])

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

  # Auto-pull published (non-local) missing dependencies — the closure walk
  # is `Compendium.Pull`'s, the same one provisioning uses; this only relays
  # its progress to the console and the CLI.
  defp auto_pull_published_deps(ctx, published_missing, register_id) do
    refs = Enum.map(published_missing, & &1[:dependency_ref])

    on_progress = fn
      ref, :pulling ->
        Logger.info("[Compendium.MCP] Auto-pulling dependency after register: #{ref}")
        broadcast_register_progress(ctx, register_id, :pulling, "Pulling #{ref}...")

      ref, :pulled ->
        broadcast_register_progress(ctx, register_id, :pulled, "Pulled #{ref}")

      ref, {:failed, _reason} ->
        broadcast_register_progress(ctx, register_id, :pull_failed, "Failed to pull #{ref}")
    end

    %{pulled: pulled, failed: failed} =
      Compendium.Pull.ensure_published_deps(ctx, refs, on_progress: on_progress)

    {pulled, Enum.map(failed, fn {ref, _reason} -> ref end)}
  end

  # Broadcast register progress to both PubSub (the console) and the MCP
  # response stream (the CLI).
  defp broadcast_register_progress(_ctx, nil, _phase, _message), do: :ok

  defp broadcast_register_progress(ctx, register_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    case Phoenix.PubSub.broadcast(
           Emissary.PubSub,
           Prism.Topics.register(register_id, ctx),
           {:register_progress, payload}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.MCP] PubSub broadcast failed: #{inspect(reason)}")
    end

    Emissary.MCP.Progress.emit(ctx, %{
      "register_id" => register_id,
      "phase" => phase,
      "message" => message
    })

    :ok
  end

  # A push is a person's act from an athanor under a namespace they hold:
  # record all three. The namespace is the one the push resolved to
  # (`local.*` refs are published under the caller's own), so it is read
  # from the result, not the argument.
  defp record_push(ctx, reference, result) do
    oci_reference = result[:oci_reference] || result["oci_reference"]
    namespace = namespace_of(oci_reference)

    Logger.info(
      "[Compendium.MCP] pushed #{reference} as #{inspect(oci_reference)} " <>
        "(athanor=#{ctx.athanor_id} user=#{ctx.user_id} namespace=#{inspect(namespace)})"
    )

    :telemetry.execute([:cyfr, :compendium, :component, :push], %{count: 1}, %{
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id,
      namespace: namespace,
      reference: reference,
      oci_reference: oci_reference
    })
  end

  # `registry.host/<namespace>/<name>:<tag>` → the namespace segment.
  defp namespace_of(oci_reference) when is_binary(oci_reference) do
    case Compendium.OCI.Reference.parse(oci_reference) do
      {:ok, %{repository: repo}} when is_binary(repo) ->
        case String.split(repo, "/", parts: 2) do
          [ns | _] when ns != "" -> ns
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp namespace_of(_), do: nil

  # Broadcast to all Prism LiveViews subscribed to prism:components.
  # Fires after any state-changing component operation (pull, register, delete, new, publish).
  # A diff's relative segment lists, joined for the wire.
  defp format_diff(%{added: added, removed: removed, changed: changed}) do
    %{
      added: Enum.map(added, &Enum.join(&1, "/")),
      removed: Enum.map(removed, &Enum.join(&1, "/")),
      changed: Enum.map(changed, &Enum.join(&1, "/"))
    }
  end

  defp broadcast_components_changed(ctx) do
    topic = Prism.Topics.components(ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :components_changed)
  end

  # Broadcast generic progress to both PubSub (the console) and the MCP response
  # stream (the CLI). Used by pull and publish handlers.
  defp broadcast_progress(_ctx, nil, _phase, _message), do: :ok

  defp broadcast_progress(ctx, progress_id, phase, message) do
    payload = %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}

    case Phoenix.PubSub.broadcast(
           Emissary.PubSub,
           Prism.Topics.progress(progress_id, ctx),
           {:progress, payload}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.MCP] PubSub broadcast failed: #{inspect(reason)}")
    end

    Emissary.MCP.Progress.emit(ctx, %{
      "progress_id" => progress_id,
      "phase" => phase,
      "message" => message
    })

    :ok
  end

  # Convert a component-ref style reference to an OCI reference for pulling.
  # Local components are registered via `cyfr register`, not pulled. This is
  # an early, friendlier message only — a ref carrying a registry host skips
  # this branch entirely, so the binding refusal lives in `OCI.Client.pull/2`.
  defp convert_to_oci_ref(reference), do: Compendium.Pull.oci_reference_for(reference)

  # Shared OCI pull logic used by both explicit OCI refs and converted component refs.
  defp do_oci_pull(ctx, reference) do
    case Compendium.OCI.Reference.parse(reference) do
      {:ok, ref} ->
        case Compendium.RegistryHost.validate_host(ref.registry) do
          :ok ->
            namespace_slug =
              case String.split(ref.repository || "", "/", parts: 2) do
                [slug | _] when slug != "" -> slug
                _ -> ""
              end

            anonymous? =
              Compendium.OCI.Auth.fetch_credential(
                Compendium.RegistryHost.canonical_host(),
                namespace_slug,
                ctx
              ) ==
                :anonymous

            if anonymous? do
              Logger.warning(
                "[Compendium.MCP] No credentials for #{Compendium.RegistryHost.canonical_host()} — " <>
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
                      "You are pulling anonymously from #{Compendium.RegistryHost.canonical_host()}. " <>
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
                     " — No credentials configured for #{Compendium.RegistryHost.canonical_host()}. " <>
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

    case ref && Shared.resolve_component(ctx, ref) do
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

  # Auto-pull the missing dependencies of a just-pulled component, closure
  # and all (`Compendium.Pull` walks transitive deps with one visited set).
  defp auto_pull_deps(ctx, deps, result) do
    availability = Compendium.DependencyResolver.classify_availability(ctx, deps)
    refs = Enum.map(availability.missing, & &1[:dependency_ref])

    %{pulled: pulled, failed: failed} =
      Compendium.Pull.ensure_published_deps(ctx, refs,
        on_progress: fn
          ref, :pulling -> Logger.info("[Compendium.MCP] Auto-pulling dependency: #{ref}")
          _ref, _ -> :ok
        end
      )

    optional_missing = Enum.map(availability.optional_missing, & &1[:dependency_ref])

    result
    |> Map.put(:pulled_dependencies, pulled)
    |> Map.put(:failed_pulls, Enum.map(failed, fn {ref, _reason} -> ref end))
    |> Map.put(:optional_missing, optional_missing)
  end

  defdelegate decode_manifest(value), to: Compendium.Manifest, as: :decode

  defp bootstrap_registered(ctx, components) do
    refs =
      for comp <- components,
          (comp[:status] || comp["status"]) == "registered",
          type = comp[:type] || comp["type"] || comp[:component_type] || comp["component_type"],
          name = comp[:name] || comp["name"],
          is_binary(type) and is_binary(name),
          do: "#{type}:#{Compendium.ComponentPath.default_publisher()}.#{name}"

    case refs do
      [] ->
        []

      _ ->
        {:ok, %{minted: minted}} = Sanctum.Consent.Bootstrap.run_for(ctx, refs)
        minted
    end
  end

  # ============================================================================
  # Component Resolution
  # ============================================================================

  defp read_component_readme(ctx, reference) do
    case Shared.resolve_component(ctx, reference) do
      {:ok, _component, ref} ->
        path =
          Compendium.ComponentPath.file_path(
            ref.type,
            ref.namespace,
            ref.name,
            ref.version,
            "README.md"
          )

        case Arca.get(ctx, path) do
          {:ok, content} -> content
          _ -> nil
        end

      _ ->
        nil
    end
  end

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
            if Compendium.Semver.gt?(version, existing_version) do
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
            update_available = Compendium.Semver.gt?(remote_version, local_version)

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

    if publisher && name && version do
      Compendium.ComponentPath.version_dir("tincture", publisher, name, version)
    end
  end
end
