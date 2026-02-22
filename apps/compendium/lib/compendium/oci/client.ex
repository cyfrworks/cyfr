defmodule Compendium.OCI.Client do
  @moduledoc """
  High-level OCI Distribution client for Compendium.

  Provides pull, push, and discover operations that integrate with
  the local component registry.
  """

  require Logger

  alias Compendium.OCI.{Blob, Cache, Errors, Manifest, Reference, Transport}
  alias Compendium.Registry
  alias Sanctum.Context

  # ============================================================================
  # Pull
  # ============================================================================

  @doc """
  Pull a component from an OCI registry.

  Flow:
  1. Parse OCI ref → GET manifest → parse descriptors
  2. Check cache (skip download if all blobs cached and digest matches)
  3. Download config blob (cyfr-manifest.json) + WASM layer blob
  4. Extract to local component directory
  5. Register in SQLite via Registry with source: "oci"
  6. Return component metadata

  ## Parameters

  - `ctx` - User context
  - `oci_ref` - OCI reference string (e.g., "registry.cyfr.run/cyfr/reagents/data-processor:1.2.0")

  ## Returns

  - `{:ok, result}` with component metadata and digest
  - `{:error, reason}` on failure
  """
  @spec pull(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def pull(%Context{} = ctx, oci_ref) when is_binary(oci_ref) do
    with {:ok, ref} <- Reference.parse(oci_ref),
         :ok <- Compendium.Edition.validate_registry(ref.registry),
         {:ok, manifest_json, manifest_digest, manifest_opts} <- fetch_manifest(ref),
         {:ok, parsed} <- Manifest.parse(manifest_json),
         {:ok, wasm_layer} <- Manifest.wasm_layer(parsed),
         config_digest = parsed.config["digest"],
         wasm_digest = wasm_layer["digest"],
         {:ok, config_bytes} <- fetch_blob(ref, config_digest),
         {:ok, wasm_bytes} <- fetch_blob(ref, wasm_digest),
         {:ok, cyfr_manifest} <- parse_config(config_bytes),
         {:ok, component_ref} <- Reference.to_component_ref(ref),
         {:ok, component} <- store_component(ctx, component_ref, cyfr_manifest, wasm_bytes, parsed) do
      # Cache manifest for future use
      tag = ref.tag || "latest"
      Cache.put_manifest(ref.registry, ref.repository, tag, manifest_json, manifest_digest)

      result = %{
        status: "pulled",
        reference: oci_ref,
        component_ref: Sanctum.ComponentRef.to_string(component_ref),
        digest: component.digest,
        manifest_digest: manifest_digest,
        size: component.size,
        type: component.component_type,
        source: "oci"
      }

      result =
        if manifest_opts[:stale] do
          Map.put(result, :warning, "Registry was unreachable during digest check — cached manifest may be stale")
        else
          result
        end

      {:ok, result}
    else
      {:error, %Errors{} = err} ->
        Logger.error("[Compendium.OCI.Client] Pull failed for #{oci_ref}: #{Errors.to_log_string(err)}")
        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} when is_binary(reason) ->
        Logger.error("[Compendium.OCI.Client] Pull failed for #{oci_ref}: #{reason}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Compendium.OCI.Client] Pull failed for #{oci_ref}: #{inspect(reason)}")
        {:error, "OCI operation failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Pull and return WASM bytes directly (used by Executor for OCI refs).

  Returns `{:ok, wasm_bytes}` without registering in SQLite.
  """
  @spec pull_bytes(String.t()) :: {:ok, binary()} | {:error, term()}
  def pull_bytes(oci_ref) when is_binary(oci_ref) do
    with {:ok, ref} <- Reference.parse(oci_ref),
         :ok <- Compendium.Edition.validate_registry(ref.registry),
         {:ok, manifest_json, _manifest_digest, _manifest_opts} <- fetch_manifest(ref),
         {:ok, parsed} <- Manifest.parse(manifest_json),
         {:ok, wasm_layer} <- Manifest.wasm_layer(parsed),
         wasm_digest = wasm_layer["digest"],
         {:ok, wasm_bytes} <- fetch_blob(ref, wasm_digest) do
      {:ok, wasm_bytes}
    else
      {:error, %Errors{} = err} ->
        Logger.error("[Compendium.OCI.Client] Pull bytes failed for #{oci_ref}: #{Errors.to_log_string(err)}")
        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} when is_binary(reason) ->
        Logger.error("[Compendium.OCI.Client] Pull bytes failed for #{oci_ref}: #{reason}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Compendium.OCI.Client] Pull bytes failed for #{oci_ref}: #{inspect(reason)}")
        {:error, "OCI operation failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Push
  # ============================================================================

  @doc """
  Push a component to an OCI registry.

  Flow:
  1. Read local component (WASM + cyfr-manifest.json)
  2. Check blob existence (skip upload if present)
  3. Upload WASM blob, then config blob
  4. Build + PUT OCI manifest with tag
  5. Return OCI reference and digest

  ## Parameters

  - `ctx` - User context
  - `component_ref` - CYFR component reference string
  - `registry` - Target registry hostname (e.g., "registry.cyfr.run")

  ## Returns

  - `{:ok, result}` with OCI reference and digest
  - `{:error, reason}` on failure
  """
  @spec push(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def push(%Context{} = ctx, component_ref_str, registry) when is_binary(component_ref_str) and is_binary(registry) do
    with :ok <- Compendium.Edition.validate_registry(registry),
         {:ok, cref} <- Sanctum.ComponentRef.parse(component_ref_str),
         {:ok, component} <- get_local_component(ctx, cref),
         {:ok, wasm_bytes} <- get_wasm_bytes(ctx, component),
         config_json = build_config_json(component),
         {:ok, oci_ref} <- Reference.from_component_ref(cref, registry),
         {:ok, _wasm_digest} <- Blob.upload(oci_ref, wasm_bytes, Manifest.wasm_media_type(cref.type)),
         {:ok, _config_digest} <- Blob.upload(oci_ref, config_json, Manifest.config_media_type()),
         annotations = Manifest.build_annotations(%{
           name: cref.name,
           version: cref.version,
           type: cref.type,
           publisher: cref.namespace,
           description: component[:description],
           license: component[:license],
           category: component[:category]
         }),
         {:ok, manifest_json, _config_digest, _wasm_digest} <- Manifest.build(config_json, wasm_bytes, cref.type, annotations),
         {:ok, manifest_digest} <- push_manifest(oci_ref, manifest_json) do
      {:ok, %{
        status: "pushed",
        oci_reference: Reference.to_string(oci_ref),
        component_ref: component_ref_str,
        manifest_digest: manifest_digest,
        registry: registry
      }}
    else
      {:error, %Errors{} = err} ->
        Logger.error("[Compendium.OCI.Client] Push failed for #{component_ref_str} to #{registry}: #{Errors.to_log_string(err)}")
        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} when is_binary(reason) ->
        Logger.error("[Compendium.OCI.Client] Push failed for #{component_ref_str} to #{registry}: #{reason}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Compendium.OCI.Client] Push failed for #{component_ref_str} to #{registry}: #{inspect(reason)}")
        {:error, "OCI operation failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Discover
  # ============================================================================

  @doc """
  Discover CYFR components on a remote registry.

  Flow:
  1. GET `/v2/_catalog` (paginated) for repository list
  2. Filter by CYFR-convention paths
  3. GET `/v2/<repo>/tags/list` for each
  4. Return structured results

  ## Parameters

  - `registry` - Registry hostname (e.g., "registry.cyfr.run")
  - `namespace` - Optional publisher namespace to filter by

  ## Returns

  - `{:ok, results}` with list of discovered components
  - `{:error, reason}` on failure
  """
  @spec discover(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def discover(registry, namespace \\ nil) when is_binary(registry) do
    with :ok <- Compendium.Edition.validate_registry(registry) do
      discover_repos(registry, namespace)
    end
  end

  defp discover_repos(registry, namespace) do
    # Build a dummy reference for transport (we only need registry)
    ref = %Reference{registry: registry, repository: "_catalog", tag: nil}

    case list_repositories(ref) do
      {:ok, repos} ->
        # Filter to CYFR-convention repos: publisher/types/name
        cyfr_repos =
          repos
          |> Enum.filter(&cyfr_repo?/1)
          |> maybe_filter_namespace(namespace)

        # Get tags for each repo, collecting errors for failed repos
        {results, errors} =
          Enum.reduce(cyfr_repos, {[], []}, fn repo, {comps, errs} ->
            repo_ref = %Reference{registry: registry, repository: repo, tag: nil}

            case list_tags(repo_ref) do
              {:ok, tags} ->
                entries = Enum.map(tags, fn tag ->
                  %{
                    repository: repo,
                    tag: tag,
                    oci_reference: "#{registry}/#{repo}:#{tag}",
                    component: parse_repo_to_component(repo, tag)
                  }
                end)
                {comps ++ entries, errs}

              {:error, reason} ->
                {comps, errs ++ ["Failed to list tags for #{repo}: #{inspect(reason)}"]}
            end
          end)

        result = %{
          registry: registry,
          components: results,
          total: length(results)
        }

        result = if errors != [], do: Map.put(result, :errors, errors), else: result

        {:ok, result}

      {:error, %Errors{} = err} ->
        Logger.error("[Compendium.OCI.Client] Discover failed for #{registry}: #{Errors.to_log_string(err)}")
        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} ->
        Logger.error("[Compendium.OCI.Client] Discover failed for #{registry}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Private: Manifest Operations
  # ============================================================================

  defp fetch_manifest(ref) do
    tag = ref.tag || ref.digest || "latest"

    # Check cache first (for tag refs)
    case Cache.get_manifest(ref.registry, ref.repository, tag) do
      {:ok, cached_manifest, cached_digest} ->
        # For tag refs, verify digest hasn't changed via HEAD
        if ref.tag do
          case head_manifest(ref, tag) do
            {:ok, remote_digest} when remote_digest == cached_digest ->
              {:ok, cached_manifest, cached_digest, []}

            {:ok, _remote_digest} ->
              # Digest changed, re-fetch
              fetch_manifest_remote(ref, tag)

            {:error, _} ->
              Logger.warning("[Compendium.OCI.Client] Stale cache: registry unreachable for digest check, " <>
                             "serving potentially stale manifest for #{ref.registry}/#{ref.repository}:#{tag}")
              {:ok, cached_manifest, cached_digest, [stale: true]}
          end
        else
          {:ok, cached_manifest, cached_digest, []}
        end

      :miss ->
        fetch_manifest_remote(ref, tag)
    end
  end

  defp fetch_manifest_remote(ref, tag) do
    path = "/v2/#{ref.repository}/manifests/#{tag}"

    accept_headers = [
      {"accept", Manifest.manifest_media_type()},
      {"accept", "application/vnd.docker.distribution.manifest.v2+json"}
    ]

    case Transport.request(:get, path, ref, accept_headers) do
      {:ok, 200, headers, body} ->
        digest = get_header(headers, "docker-content-digest") || Blob.compute_digest(body)
        {:ok, body, digest, []}

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp head_manifest(ref, tag) do
    path = "/v2/#{ref.repository}/manifests/#{tag}"

    accept_headers = [
      {"accept", Manifest.manifest_media_type()},
      {"accept", "application/vnd.docker.distribution.manifest.v2+json"}
    ]

    case Transport.request(:head, path, ref, accept_headers) do
      {:ok, 200, headers, _body} ->
        digest = get_header(headers, "docker-content-digest")
        {:ok, digest}

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp push_manifest(ref, manifest_json) do
    tag = ref.tag || "latest"
    path = "/v2/#{ref.repository}/manifests/#{tag}"

    headers = [
      {"content-type", Manifest.manifest_media_type()}
    ]

    case Transport.request(:put, path, ref, headers, manifest_json) do
      {:ok, status, resp_headers, _body} when status in [201, 202] ->
        digest = get_header(resp_headers, "docker-content-digest") || Blob.compute_digest(manifest_json)
        {:ok, digest}

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Private: Blob Operations
  # ============================================================================

  defp fetch_blob(ref, digest) do
    # Check cache first
    case Cache.get_blob(digest) do
      {:ok, bytes} ->
        {:ok, bytes}

      :miss ->
        case Blob.download(ref, digest) do
          {:ok, bytes} ->
            case Cache.put_blob(digest, bytes) do
              :ok -> :ok
              {:error, reason} ->
                Logger.warning("[Compendium.OCI.Client] Failed to cache blob #{digest}: #{inspect(reason)}")
            end

            {:ok, bytes}

          {:error, _} = error ->
            error
        end
    end
  end

  # ============================================================================
  # Private: Component Storage
  # ============================================================================

  defp store_component(ctx, component_ref, cyfr_manifest, wasm_bytes, parsed) do
    metadata = %{
      name: component_ref.name,
      version: component_ref.version,
      type: component_ref.type,
      publisher: component_ref.namespace,
      description: cyfr_manifest["description"] || parsed.annotations["org.opencontainers.image.description"],
      tags: cyfr_manifest["tags"] || [],
      category: cyfr_manifest["category"] || parsed.annotations["dev.cyfr.component.category"],
      license: cyfr_manifest["license"] || parsed.annotations["org.opencontainers.image.licenses"]
    }

    Registry.publish_bytes(ctx, wasm_bytes, metadata)
  end

  defp get_local_component(ctx, cref) do
    case Registry.get(ctx, cref.name, cref.version, cref.namespace, cref.type) do
      {:ok, component} -> {:ok, component}
      {:error, :not_found} -> {:error, "Component not found locally: #{Sanctum.ComponentRef.to_string(cref)}"}
    end
  end

  defp get_wasm_bytes(ctx, component) do
    digest = component[:digest] || component["digest"]

    case Registry.get_blob(ctx, digest) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, "Failed to read WASM blob for digest: #{digest}"}
    end
  end

  defp build_config_json(component) do
    config = %{
      "name" => component[:name],
      "version" => component[:version],
      "type" => component[:component_type],
      "description" => component[:description] || "",
      "tags" => decode_if_string(component[:tags], []),
      "category" => component[:category],
      "license" => component[:license],
      "exports" => decode_if_string(component[:exports], [])
    }

    # Preserve dependencies from manifest if present
    config =
      case extract_manifest_dependencies(component) do
        nil -> config
        deps -> Map.put(config, "dependencies", deps)
      end

    Jason.encode!(config)
  end

  defp extract_manifest_dependencies(component) do
    manifest = component[:manifest]

    manifest =
      case manifest do
        nil -> nil
        m when is_map(m) -> m
        m when is_binary(m) ->
          case Jason.decode(m) do
            {:ok, decoded} -> decoded
            _ -> nil
          end
      end

    case manifest do
      nil -> nil
      m -> m["dependencies"]
    end
  end

  defp decode_if_string(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        decoded

      _ ->
        Logger.debug("[Compendium.OCI.Client] JSON decode failed for value, using default")
        default
    end
  end

  defp decode_if_string(value, _default) when is_list(value), do: value
  defp decode_if_string(_, default), do: default

  defp parse_config(config_bytes) do
    case Jason.decode(config_bytes) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _} -> {:error, "Config blob is not a JSON object"}
      {:error, reason} -> {:error, "Failed to parse config blob: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Private: Discovery
  # ============================================================================

  defp list_repositories(ref) do
    path = "/v2/_catalog"

    case Transport.request(:get, path, ref) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"repositories" => repos}} ->
            {:ok, repos}

          other ->
            Logger.error("[Compendium.OCI.Client] Unexpected catalog response format from #{ref.registry}: #{inspect(other)}")
            {:error, "Unexpected catalog response format from #{ref.registry}"}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp list_tags(ref) do
    path = "/v2/#{ref.repository}/tags/list"

    case Transport.request(:get, path, ref) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"tags" => tags}} when is_list(tags) -> {:ok, tags}
          _ -> {:error, "Unexpected tags response format for #{ref.repository}"}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp cyfr_repo?(repo) do
    # CYFR convention: publisher/types/name where types is catalysts|reagents|formulas
    parts = String.split(repo, "/")
    length(parts) == 3 and Enum.at(parts, 1) in ~w(catalysts reagents formulas)
  end

  defp maybe_filter_namespace(repos, nil), do: repos

  defp maybe_filter_namespace(repos, namespace) do
    Enum.filter(repos, fn repo ->
      String.starts_with?(repo, namespace <> "/")
    end)
  end

  defp parse_repo_to_component(repo, tag) do
    case String.split(repo, "/") do
      [publisher, type_plural, name] ->
        type = String.trim_trailing(type_plural, "s")
        %{type: type, publisher: publisher, name: name, version: tag}

      _ ->
        nil
    end
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: v

      _ ->
        nil
    end)
  end
end
