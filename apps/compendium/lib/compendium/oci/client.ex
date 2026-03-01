defmodule Compendium.OCI.Client do
  @moduledoc """
  High-level OCI Distribution client for Compendium.

  Provides pull, push, and discover operations that integrate with
  the local component registry.
  """

  require Logger

  alias Compendium.OCI.{Auth, Blob, Cache, Errors, Manifest, Reference, Transport}
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
         {:ok, readme_bytes} <- maybe_fetch_layer(ref, parsed, &Manifest.readme_layer/1),
         {:ok, source_bytes} <- maybe_fetch_layer(ref, parsed, &Manifest.source_layer/1),
         {:ok, cyfr_manifest} <- parse_config(config_bytes),
         {:ok, component_ref} <- Reference.to_component_ref(ref),
         {:ok, sig_meta} <- verify_signature(oci_ref),
         {:ok, component} <- store_component(ctx, component_ref, cyfr_manifest, wasm_bytes, parsed, config_bytes, sig_meta),
         :ok <- maybe_store_manifest(ctx, component_ref, config_bytes),
         :ok <- maybe_store_readme(ctx, component_ref, readme_bytes),
         :ok <- maybe_store_source(ctx, component_ref, source_bytes) do
      # Cache manifest for future use
      tag = ref.tag || "latest"
      Cache.put_manifest(ref.registry, ref.repository, tag, manifest_json, manifest_digest)

      result = %{
        status: "pulled",
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
    # Resolve the actual publisher name for "local" namespace so that OCI
    # annotations, config blob, and the returned reference all use the real
    # registry namespace (e.g. "moonmoon69") instead of "local".
    with :ok <- Compendium.Edition.validate_registry(registry),
         {:ok, cref} <- Sanctum.ComponentRef.parse(component_ref_str),
         {:ok, publisher} <- resolve_push_publisher(cref, registry),
         push_cref = %{cref | namespace: publisher},
         {:ok, component} <- get_local_component(ctx, cref),
         {:ok, wasm_bytes} <- get_wasm_bytes(ctx, component),
         config_json = get_full_config(component, publisher, cref),
         {:ok, oci_ref} <- Reference.from_component_ref(push_cref, registry),
         {:ok, _wasm_digest} <- Blob.upload(oci_ref, wasm_bytes, Manifest.wasm_media_type(cref.type)),
         {:ok, _config_digest} <- Blob.upload(oci_ref, config_json, Manifest.config_media_type()),
         readme_result = get_readme_bytes(cref),
         :ok <- maybe_upload_blob(oci_ref, readme_result, Manifest.readme_media_type()),
         source_result = get_source_tarball(cref),
         :ok <- maybe_upload_blob(oci_ref, source_result, Manifest.source_media_type()),
         annotations = Manifest.build_annotations(%{
           name: cref.name,
           version: cref.version,
           type: cref.type,
           publisher: publisher,
           description: component[:description],
           license: component[:license],
           category: component[:category]
         }),
         layer_opts = build_layer_opts(readme_result, source_result),
         {:ok, manifest_json, _config_digest, _wasm_digest} <- Manifest.build(config_json, wasm_bytes, cref.type, annotations, layer_opts),
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

  # Verify OCI image signature via cosign. Returns {:ok, sig_meta} always —
  # verification failure is not fatal (component is stored as unverified).
  defp verify_signature(oci_ref) do
    case Compendium.Cosign.verify(oci_ref) do
      {:ok, %{identity: identity, issuer: issuer}} ->
        {:ok, %{verified: true, identity: identity, issuer: issuer}}

      {:error, reason} ->
        Logger.warning("[Compendium.OCI.Client] Signature verification failed for #{oci_ref}: #{reason}. " <>
                       "Component will be stored as unverified.")
        {:ok, %{verified: false, identity: nil, issuer: nil}}
    end
  end

  defp store_component(ctx, component_ref, cyfr_manifest, wasm_bytes, parsed, config_bytes, sig_meta) do
    metadata = %{
      name: component_ref.name,
      version: component_ref.version,
      type: component_ref.type,
      publisher: component_ref.namespace,
      description: cyfr_manifest["description"] || parsed.annotations["org.opencontainers.image.description"],
      tags: cyfr_manifest["tags"] || [],
      category: cyfr_manifest["category"] || parsed.annotations["dev.cyfr.component.category"],
      license: cyfr_manifest["license"] || parsed.annotations["org.opencontainers.image.licenses"],
      manifest: config_bytes,
      signature_verified: sig_meta[:verified] || false,
      signer_identity: sig_meta[:identity],
      signer_issuer: sig_meta[:issuer]
    }

    Registry.publish_bytes(ctx, wasm_bytes, metadata, allow_overwrite: true)
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

  defp build_config_json(component, publisher) do
    config = %{
      "name" => component[:name],
      "version" => component[:version],
      "type" => component[:component_type],
      "publisher" => publisher,
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

  # Read full cyfr-manifest.json from the component's filesystem directory.
  # Falls back to build_config_json if the manifest file doesn't exist (legacy).
  defp get_full_config(component, publisher, cref) do
    dir = component_fs_dir(cref)
    manifest_path = Path.join(dir, "cyfr-manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} ->
            manifest
            |> Map.delete("id")
            |> Map.put("publisher", publisher)
            |> Map.put("name", cref.name)
            |> Jason.encode!()

          {:error, _} ->
            build_config_json(component, publisher)
        end

      {:error, _} ->
        build_config_json(component, publisher)
    end
  end

  # Read README.md from the component's filesystem directory.
  defp get_readme_bytes(cref) do
    dir = component_fs_dir(cref)
    readme_path = Path.join(dir, "README.md")

    case File.read(readme_path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> :none
    end
  end

  # Create a gzipped tarball of the src/ directory from the component's filesystem.
  defp get_source_tarball(cref) do
    dir = component_fs_dir(cref)
    src_dir = Path.join(dir, "src")

    if File.dir?(src_dir) do
      files = collect_files(src_dir, "")

      case files do
        [] ->
          :none

        entries ->
          tar_entries = Enum.map(entries, fn {rel_path, content} ->
            {String.to_charlist(rel_path), content}
          end)

          create_tar_gz(tar_entries)
      end
    else
      :none
    end
  end

  # Create a gzipped tarball from a list of {charlist_name, binary_content} entries.
  # Uses a temp file because :erl_tar.create/3 :memory option is unreliable on OTP 28.
  defp create_tar_gz(tar_entries) do
    tmp = Path.join(System.tmp_dir!(), "cyfr_tar_#{:rand.uniform(1_000_000)}.tar")

    try do
      case :erl_tar.create(String.to_charlist(tmp), tar_entries) do
        :ok ->
          case File.read(tmp) do
            {:ok, tar_binary} -> {:ok, :zlib.gzip(tar_binary)}
            {:error, _} -> :none
          end

        {:error, _} ->
          :none
      end
    after
      File.rm(tmp)
    end
  end

  # Recursively collect all files from a directory as {relative_path, content} tuples.
  defp collect_files(base_dir, prefix) do
    case File.ls(base_dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(base_dir, entry)
          rel_path = if prefix == "", do: entry, else: Path.join(prefix, entry)

          if File.dir?(full_path) do
            collect_files(full_path, rel_path)
          else
            case File.read(full_path) do
              {:ok, content} -> [{rel_path, content}]
              {:error, _} -> []
            end
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Upload a blob only if the data is present (not :none).
  defp maybe_upload_blob(_oci_ref, :none, _media_type), do: :ok
  defp maybe_upload_blob(oci_ref, {:ok, bytes}, media_type) do
    case Blob.upload(oci_ref, bytes, media_type) do
      {:ok, _digest} -> :ok
      {:error, _} = err -> err
    end
  end

  # Build layer opts for Manifest.build/5 from README and source results.
  defp build_layer_opts(readme_result, source_result) do
    opts = []
    opts = case readme_result do
      {:ok, bytes} -> Keyword.put(opts, :readme_bytes, bytes)
      :none -> opts
    end
    case source_result do
      {:ok, bytes} -> Keyword.put(opts, :source_bytes, bytes)
      :none -> opts
    end
  end

  # Get the filesystem directory for a locally-registered component.
  defp component_fs_dir(cref) do
    Path.join(["components", "#{cref.type}s", cref.namespace, cref.name, cref.version])
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
  # Private: Optional Layer Fetch + Store
  # ============================================================================

  # Fetch an optional layer if present in the manifest.
  # extractor_fn is a function like &Manifest.readme_layer/1 that returns {:ok, layer} | :none
  defp maybe_fetch_layer(ref, parsed, extractor_fn) do
    case extractor_fn.(parsed) do
      {:ok, layer} ->
        case fetch_blob(ref, layer["digest"]) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} ->
            Logger.warning("[Compendium.OCI.Client] Failed to fetch optional layer: #{inspect(reason)}")
            {:ok, nil}
        end

      :none ->
        {:ok, nil}
    end
  end

  # Store cyfr-manifest.json to Arca for a pulled component.
  defp maybe_store_manifest(_ctx, _component_ref, nil), do: :ok
  defp maybe_store_manifest(ctx, component_ref, config_bytes) do
    path = ["components", "#{component_ref.type}s", component_ref.namespace,
            component_ref.name, component_ref.version, "cyfr-manifest.json"]
    Arca.MCP.handle("storage", ctx, %{
      "action" => "write", "path" => path,
      "content" => Base.encode64(config_bytes)
    })
    :ok
  end

  # Store README.md to Arca for a pulled component.
  defp maybe_store_readme(_ctx, _component_ref, nil), do: :ok
  defp maybe_store_readme(ctx, component_ref, readme_bytes) do
    path = ["components", "#{component_ref.type}s", component_ref.namespace,
            component_ref.name, component_ref.version, "README.md"]
    Arca.MCP.handle("storage", ctx, %{
      "action" => "write", "path" => path,
      "content" => Base.encode64(readme_bytes)
    })
    :ok
  end

  # Extract and store src/ files from a gzipped tarball to Arca.
  defp maybe_store_source(_ctx, _component_ref, nil), do: :ok
  defp maybe_store_source(ctx, component_ref, source_bytes) do
    base = ["components", "#{component_ref.type}s", component_ref.namespace,
            component_ref.name, component_ref.version]
    try do
      tar_binary = :zlib.gunzip(source_bytes)

      case :erl_tar.extract({:binary, tar_binary}, [:memory]) do
        {:ok, entries} ->
          Enum.each(entries, fn {filename, content} ->
            # filename is a charlist from :erl_tar
            rel_path = to_string(filename)
            path_segments = base ++ ["src" | String.split(rel_path, "/")]
            Arca.MCP.handle("storage", ctx, %{
              "action" => "write", "path" => path_segments,
              "content" => Base.encode64(content)
            })
          end)

        {:error, reason} ->
          Logger.warning("[Compendium.OCI.Client] Failed to extract source tarball: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning("[Compendium.OCI.Client] Failed to decompress source tarball: #{inspect(e)}")
    end
    :ok
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

  defp resolve_push_publisher(cref, registry) do
    if cref.namespace == "local" do
      case resolve_publisher_name(registry) do
        {:ok, name} ->
          {:ok, name}

        :unknown ->
          Logger.error("[Compendium.OCI.Client] Cannot resolve publisher name for #{registry} — " <>
                       "credentials may be missing or JWT lacks publisher_name claim")
          {:error, "Cannot push to #{registry}: publisher name could not be resolved. " <>
                   "Run `cyfr login` to authenticate, or push with an explicit publisher namespace."}
      end
    else
      {:ok, cref.namespace}
    end
  end

  defp resolve_publisher_name(registry) do
    case Auth.resolve_credentials(registry) do
      {:ok, %{password: jwt}} -> decode_jwt_publisher(jwt)
      _ -> :unknown
    end
  end

  defp decode_jwt_publisher(jwt) do
    with [_header, payload, _sig] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"publisher_name" => name}} when is_binary(name) and name != "" <- Jason.decode(json) do
      {:ok, name}
    else
      _ -> :unknown
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
