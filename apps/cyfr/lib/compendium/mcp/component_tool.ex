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

  def handle(_ctx, %{"action" => "ping"}), do: {:ok, %{status: "ok"}}

  # Search action - search for components. Searches the local registry and,
  # unless the caller restricts to source: "local", augments with the
  # configured registry's REST API (cyfr.run by default), merging results.
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
    with :ok <- Shared.require_permission(ctx, :component_manage) do
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
  end

  # Push action — upload an already-registered local component to an OCI registry.
  def handle(%Context{} = ctx, %{"action" => "push"} = args) do
    with :ok <- Shared.require_permission(ctx, :component_manage) do
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

            {:ok, cref} when cref.namespace != "local" ->
              {:error,
               "Only components in the local namespace can be pushed to a registry. " <>
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
  end

  # Create action - scaffold a new component project
  def handle(%Context{} = ctx, %{"action" => "create"} = args) do
    with :ok <- Shared.require_permission(ctx, :component_manage) do
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
  def handle(%Context{} = ctx, %{"action" => "register"} = args) do
    with :ok <- Shared.require_permission(ctx, :component_manage) do
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
  def handle(%Context{} = ctx, %{"action" => "list"} = args) do
    filters = %{
      type: args["type"],
      limit: min(args["limit"] || 1000, 1000)
    }

    {:ok, result} = Registry.search(ctx, filters)
    {:ok, enrich_tincture_media(ctx, result)}
  end

  # Delete action - delete a component from the registry
  def handle(%Context{} = ctx, %{"action" => "delete", "reference" => reference}) do
    with :ok <- Shared.require_permission(ctx, :component_manage) do
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

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: reference"}
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
    with :ok <- Shared.require_permission(ctx, :component_read) do
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

  def handle(_ctx, %{"action" => "get_blob"}) do
    {:error, "Missing required argument: digest"}
  end

  # Discover action - list components on the configured registry (cyfr.run
  # REST API). The registry host is set via CYFR_REGISTRY_URL.
  def handle(%Context{} = ctx, %{"action" => "discover"} = args) do
    with :ok <- Shared.require_permission(ctx, :component_read) do
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
    with :ok <- Shared.require_permission(ctx, :component_manage) do
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

  defp default_registry, do: Compendium.Registry.canonical_host()

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

  # Namespaces that represent local/on-disk components (not pullable from OCI).
  @local_dep_namespaces ["local"]

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
            ns in @local_dep_namespaces
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

  # Auto-pull published (non-local) missing dependencies via OCI.
  defp auto_pull_published_deps(ctx, published_missing, register_id) do
    {pulled, failed, _visited} =
      Enum.reduce(published_missing, {[], [], MapSet.new()}, fn dep, {acc, failed_acc, visited} ->
        ref = dep[:dependency_ref]
        Logger.info("[Compendium.MCP] Auto-pulling dependency after register: #{ref}")
        broadcast_register_progress(ctx, register_id, :pulling, "Pulling #{ref}...")

        case do_auto_pull(ctx, ref, visited) do
          {:ok, :cycle_skipped} ->
            {acc, failed_acc, visited}

          {:ok, _} ->
            broadcast_register_progress(ctx, register_id, :pulled, "Pulled #{ref}")
            {[ref | acc], failed_acc, MapSet.put(visited, ref)}

          {:error, reason} ->
            Logger.warning("[Compendium.MCP] Failed to auto-pull #{ref}: #{inspect(reason)}")

            broadcast_register_progress(
              ctx,
              register_id,
              :pull_failed,
              "Failed to pull #{ref}"
            )

            {acc, [ref | failed_acc], visited}
        end
      end)

    {Enum.reverse(pulled), Enum.reverse(failed)}
  end

  # Broadcast register progress to both PubSub (the console) and the MCP
  # response stream (the CLI).
  defp broadcast_register_progress(_ctx, nil, _phase, _message), do: :ok

  defp broadcast_register_progress(ctx, register_id, phase, message) do
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

    Emissary.MCP.Progress.emit(ctx, %{
      "register_id" => register_id,
      "phase" => phase,
      "message" => message
    })

    :ok
  end

  # Broadcast to all Prism LiveViews subscribed to prism:components.
  # Fires after any state-changing component operation (pull, register, delete, new, publish).
  defp broadcast_components_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:components", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :components_changed)
  end

  # Broadcast generic progress to both PubSub (the console) and the MCP response
  # stream (the CLI). Used by pull and publish handlers.
  defp broadcast_progress(_ctx, nil, _phase, _message), do: :ok

  defp broadcast_progress(ctx, progress_id, phase, message) do
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
  defp convert_to_oci_ref(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %Sanctum.ComponentRef{namespace: ns}} = parsed ->
        if Compendium.ComponentPath.local_publisher?(ns) do
          {:error, "Cannot pull local components. Use `cyfr register` to index local components."}
        else
          to_oci_ref(parsed)
        end

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  defp to_oci_ref({:ok, %Sanctum.ComponentRef{version: nil} = cref}) do
    registry = Compendium.Registry.canonical_host()
    {:ok, oci_ref} = Compendium.OCI.Reference.from_component_ref(cref, registry)

    case resolve_latest_oci_tag(oci_ref) do
      {:ok, tag} -> {:ok, Compendium.OCI.Reference.to_string(%{oci_ref | tag: tag})}
      {:error, _} -> {:ok, Compendium.OCI.Reference.to_string(oci_ref)}
    end
  end

  defp to_oci_ref({:ok, %Sanctum.ComponentRef{} = cref}) do
    registry = Compendium.Registry.canonical_host()
    {:ok, oci_ref} = Compendium.OCI.Reference.from_component_ref(cref, registry)
    {:ok, Compendium.OCI.Reference.to_string(oci_ref)}
  end

  # Resolve the latest semver tag from an OCI repository (for versionless pulls).
  # Public `/tags/list` read (anonymous on cyfr.run) — passes `nil` ctx.
  defp resolve_latest_oci_tag(%Compendium.OCI.Reference{} = ref) do
    path = "/v2/#{ref.repository}/tags/list"

    case Compendium.OCI.Transport.request(nil, :get, path, ref) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"tags" => tags}} when is_list(tags) ->
            # Descending Version-aware sort (prereleases order correctly:
            # 1.0.0-rc1 < 1.0.0), so the head is the latest release.
            semver_tags =
              tags
              |> Enum.filter(&semver_tag?/1)
              |> Enum.sort(fn a, b -> not version_gt?(b, a) end)

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
      case handle(ctx, %{"action" => "pull", "reference" => ref}) do
        {:ok, _result} -> {:ok, :pulled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defdelegate decode_manifest(value), to: Compendium.Manifest, as: :decode

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
