# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
  5. Register via Registry with source: "oci"
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
         :ok <- Compendium.Registry.validate_host(ref.registry),
         # Resolve the component ref before any network I/O so a refused
         # namespace costs nothing and, more importantly, can never be
         # reached by a ref shape that skips an earlier check.
         {:ok, component_ref} <- Reference.to_component_ref(ref),
         :ok <- refuse_local_namespace(component_ref),
         {:ok, manifest_json, manifest_digest, manifest_opts} <- fetch_manifest(ctx, ref),
         {:ok, parsed} <- Manifest.parse(manifest_json),
         {:ok, content_layer} <- Manifest.content_layer(parsed),
         config_digest = parsed.config["digest"],
         content_digest = content_layer["digest"],
         {:ok, config_bytes} <- fetch_blob(ctx, ref, config_digest),
         {:ok, content_bytes} <- fetch_blob(ctx, ref, content_digest),
         {:ok, readme_bytes} <- maybe_fetch_layer(ctx, ref, parsed, &Manifest.readme_layer/1),
         {:ok, source_bytes} <- maybe_fetch_layer(ctx, ref, parsed, &Manifest.source_layer/1),
         {:ok, cyfr_manifest} <- parse_config(config_bytes),
         {:ok, sig_meta} <- verify_signature(oci_ref),
         {:ok, component} <-
           store_component(
             ctx,
             component_ref,
             cyfr_manifest,
             content_bytes,
             parsed,
             config_bytes,
             sig_meta
           ),
         :ok <- maybe_store_manifest(ctx, component_ref, config_bytes),
         :ok <- maybe_store_readme(ctx, component_ref, readme_bytes),
         :ok <- maybe_store_source(ctx, component_ref, source_bytes) do
      # Cache manifest for future use, under the same key fetch_manifest
      # reads (a digest-pinned pull must never overwrite a tag entry).
      tag = ref.tag || ref.digest || "latest"
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
          Map.put(
            result,
            :warning,
            "Registry was unreachable during digest check — cached manifest may be stale"
          )
        else
          result
        end

      {:ok, result}
    else
      {:error, %Errors{} = err} ->
        Logger.error(
          "[Compendium.OCI.Client] Pull failed for #{oci_ref}: #{Errors.to_log_string(err)}"
        )

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

  Returns `{:ok, wasm_bytes}` without registering in the database.
  """
  @spec pull_bytes(String.t()) :: {:ok, binary()} | {:error, term()}
  def pull_bytes(oci_ref) when is_binary(oci_ref) do
    with {:ok, ref} <- Reference.parse(oci_ref),
         :ok <- Compendium.Registry.validate_host(ref.registry),
         {:ok, manifest_json, _manifest_digest, _manifest_opts} <- fetch_manifest(nil, ref),
         {:ok, parsed} <- Manifest.parse(manifest_json),
         {:ok, wasm_layer} <- Manifest.wasm_layer(parsed),
         wasm_digest = wasm_layer["digest"],
         {:ok, wasm_bytes} <- fetch_blob(nil, ref, wasm_digest) do
      {:ok, wasm_bytes}
    else
      {:error, %Errors{} = err} ->
        Logger.error(
          "[Compendium.OCI.Client] Pull bytes failed for #{oci_ref}: #{Errors.to_log_string(err)}"
        )

        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} when is_binary(reason) ->
        Logger.error("[Compendium.OCI.Client] Pull bytes failed for #{oci_ref}: #{reason}")
        {:error, reason}

      {:error, reason} ->
        Logger.error(
          "[Compendium.OCI.Client] Pull bytes failed for #{oci_ref}: #{inspect(reason)}"
        )

        {:error, "OCI operation failed: #{inspect(reason)}"}
    end
  end

  # Pulled code holds zero authority, and `local` is the highest-trust
  # namespace: it is the tree the scanner indexes and the seeder copies into
  # every new athanor. So no remote pull may mint a component there,
  # whatever the ref looks like on the way in — `local/formulas/foo:1.0` and
  # `registry.example/local/formulas/foo:1.0` both resolve to the `local`
  # namespace and both are refused here, at the one point every pull passes
  # through.
  defp refuse_local_namespace(%Sanctum.ComponentRef{namespace: namespace}) do
    if Compendium.ComponentPath.local_publisher?(namespace) do
      {:error,
       "Cannot pull into the local namespace. " <>
         "Local components are registered from the filesystem, never pulled."}
    else
      :ok
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
  def push(%Context{} = ctx, component_ref_str, registry)
      when is_binary(component_ref_str) and is_binary(registry) do
    # Resolve the actual publisher name for "local" namespace so that OCI
    # annotations, config blob, and the returned reference all use the real
    # registry namespace (e.g. "moonmoon69") instead of "local".
    with :ok <- Compendium.Registry.validate_host(registry),
         {:ok, cref} <- Sanctum.ComponentRef.parse(component_ref_str),
         {:ok, publisher} <- resolve_push_publisher(cref, registry, ctx),
         push_cref = %{cref | namespace: publisher},
         {:ok, component} <- get_local_component(ctx, cref),
         {:ok, content_bytes} <- get_component_content(ctx, component),
         {:ok, config_json} <- get_full_config(ctx, publisher, cref),
         {:ok, oci_ref} <- Reference.from_component_ref(push_cref, registry),
         {:ok, _content_digest} <-
           Blob.upload(ctx, oci_ref, content_bytes, Manifest.wasm_media_type(cref.type)),
         {:ok, _config_digest} <-
           Blob.upload(ctx, oci_ref, config_json, Manifest.config_media_type()),
         readme_result = get_readme_bytes(ctx, cref),
         :ok <- maybe_upload_blob(ctx, oci_ref, readme_result, Manifest.readme_media_type()),
         source_result = get_source_tarball(ctx, cref),
         :ok <- maybe_upload_blob(ctx, oci_ref, source_result, Manifest.source_media_type()),
         annotations =
           Manifest.build_annotations(%{
             name: cref.name,
             version: cref.version,
             type: cref.type,
             publisher: publisher,
             description: component[:description],
             license: component[:license],
             category: component[:category]
           }),
         layer_opts = build_layer_opts(readme_result, source_result),
         {:ok, manifest_json, _config_digest, _content_digest} <-
           Manifest.build(config_json, content_bytes, cref.type, annotations, layer_opts),
         {:ok, manifest_digest} <- push_manifest(ctx, oci_ref, manifest_json) do
      {:ok,
       %{
         status: "pushed",
         oci_reference: Reference.to_string(oci_ref),
         component_ref: component_ref_str,
         manifest_digest: manifest_digest,
         registry: registry
       }}
    else
      {:error, %Errors{} = err} ->
        Logger.error(
          "[Compendium.OCI.Client] Push failed for #{component_ref_str} to #{registry}: #{Errors.to_log_string(err)}"
        )

        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} when is_binary(reason) ->
        Logger.error(
          "[Compendium.OCI.Client] Push failed for #{component_ref_str} to #{registry}: #{reason}"
        )

        {:error, reason}

      {:error, reason} ->
        Logger.error(
          "[Compendium.OCI.Client] Push failed for #{component_ref_str} to #{registry}: #{inspect(reason)}"
        )

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
    with :ok <- Compendium.Registry.validate_host(registry) do
      discover_repos(registry, namespace)
    end
  end

  defp discover_repos(registry, namespace) do
    # Build a dummy reference for transport (we only need registry)
    ref = %Reference{registry: registry, repository: "_catalog", tag: nil}

    case list_repositories(nil, ref) do
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

            case list_tags(nil, repo_ref) do
              {:ok, tags} ->
                entries =
                  Enum.map(tags, fn tag ->
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
        Logger.error(
          "[Compendium.OCI.Client] Discover failed for #{registry}: #{Errors.to_log_string(err)}"
        )

        hint = Errors.actionable_hint(err)
        msg = Errors.to_string(err)
        {:error, if(hint != "", do: "#{msg}. #{hint}", else: msg)}

      {:error, reason} ->
        Logger.error(
          "[Compendium.OCI.Client] Discover failed for #{registry}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ============================================================================
  # Private: Manifest Operations
  # ============================================================================

  defp fetch_manifest(ctx, ref) do
    tag = ref.tag || ref.digest || "latest"

    # Check cache first (for tag refs)
    case Cache.get_manifest(ref.registry, ref.repository, tag) do
      {:ok, cached_manifest, cached_digest} ->
        cond do
          # For tag refs, verify digest hasn't changed via HEAD
          ref.tag ->
            case head_manifest(ctx, ref, tag) do
              {:ok, remote_digest} when remote_digest == cached_digest ->
                {:ok, cached_manifest, cached_digest, []}

              {:ok, _remote_digest} ->
                # Digest changed, re-fetch
                fetch_manifest_remote(ctx, ref, tag)

              {:error, _} ->
                Logger.warning(
                  "[Compendium.OCI.Client] Stale cache: registry unreachable for digest check, " <>
                    "serving potentially stale manifest for #{ref.registry}/#{ref.repository}:#{tag}"
                )

                {:ok, cached_manifest, cached_digest, [stale: true]}
            end

          # A digest-pinned ref must serve exactly the pinned bytes even from
          # cache — recompute from the cached body rather than trust the
          # recorded digest. A mismatch means the entry is corrupt or was
          # written outside the verified path; refetch and let the remote
          # verification decide (a genuine pull then overwrites the entry).
          ref.digest ->
            if Blob.compute_digest(cached_manifest) == ref.digest do
              {:ok, cached_manifest, ref.digest, []}
            else
              Logger.warning(
                "[Compendium.OCI.Client] Cached manifest for #{ref.registry}/#{ref.repository}" <>
                  "@#{ref.digest} does not hash to its pin — discarding and refetching"
              )

              fetch_manifest_remote(ctx, ref, tag)
            end

          true ->
            {:ok, cached_manifest, cached_digest, []}
        end

      :miss ->
        fetch_manifest_remote(ctx, ref, tag)
    end
  end

  defp fetch_manifest_remote(ctx, ref, tag) do
    path = "/v2/#{ref.repository}/manifests/#{tag}"

    accept_headers = [
      {"accept", Manifest.manifest_media_type()},
      {"accept", "application/vnd.docker.distribution.manifest.v2+json"}
    ]

    case Transport.request(ctx, :get, path, ref, accept_headers) do
      {:ok, 200, headers, body} ->
        # The manifest digest is the hash of the bytes received — the
        # docker-content-digest header is advisory only; a registry cannot
        # vouch for its own honesty. For a digest-pinned ref the computed
        # hash must equal the pin, or the pull is refused.
        computed = Blob.compute_digest(body)
        claimed = get_header(headers, "docker-content-digest")

        if claimed && claimed != computed do
          Logger.warning(
            "[Compendium.OCI.Client] #{ref.registry} sent docker-content-digest #{claimed} " <>
              "but the body hashes to #{computed} — using the computed digest"
          )
        end

        if ref.digest && computed != ref.digest do
          {:error, Errors.digest_mismatch(ref.digest, computed)}
        else
          {:ok, body, computed, []}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp head_manifest(ctx, ref, tag) do
    path = "/v2/#{ref.repository}/manifests/#{tag}"

    accept_headers = [
      {"accept", Manifest.manifest_media_type()},
      {"accept", "application/vnd.docker.distribution.manifest.v2+json"}
    ]

    case Transport.request(ctx, :head, path, ref, accept_headers) do
      {:ok, 200, headers, _body} ->
        digest = get_header(headers, "docker-content-digest")
        {:ok, digest}

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp push_manifest(ctx, ref, manifest_json) do
    tag = ref.tag || "latest"
    path = "/v2/#{ref.repository}/manifests/#{tag}"

    headers = [
      {"content-type", Manifest.manifest_media_type()}
    ]

    case Transport.request(ctx, :put, path, ref, headers, manifest_json) do
      {:ok, status, resp_headers, _body} when status in [201, 202] ->
        digest =
          get_header(resp_headers, "docker-content-digest") || Blob.compute_digest(manifest_json)

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

  defp fetch_blob(ctx, ref, digest) do
    # Check cache first
    case Cache.get_blob(digest) do
      {:ok, bytes} ->
        {:ok, bytes}

      :miss ->
        case Blob.download(ctx, ref, digest) do
          {:ok, bytes} ->
            case Cache.put_blob(digest, bytes) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[Compendium.OCI.Client] Failed to cache blob #{digest}: #{inspect(reason)}"
                )
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
        Logger.warning(
          "[Compendium.OCI.Client] Signature verification failed for #{oci_ref}: #{reason}. " <>
            "Component will be stored as unverified."
        )

        {:ok, %{verified: false, identity: nil, issuer: nil}}
    end
  end

  defp store_component(
         ctx,
         component_ref,
         cyfr_manifest,
         content_bytes,
         parsed,
         config_bytes,
         sig_meta
       ) do
    metadata = %{
      name: component_ref.name,
      version: component_ref.version,
      type: component_ref.type,
      publisher: component_ref.namespace,
      description:
        cyfr_manifest["description"] || parsed.annotations["org.opencontainers.image.description"],
      tags: cyfr_manifest["tags"] || [],
      category: cyfr_manifest["category"] || parsed.annotations["dev.cyfr.component.category"],
      license:
        cyfr_manifest["license"] || parsed.annotations["org.opencontainers.image.licenses"],
      manifest: config_bytes,
      signature_verified: sig_meta[:verified] || false,
      signer_identity: sig_meta[:identity],
      signer_issuer: sig_meta[:issuer]
    }

    # origin: :remote marks these publishes as carrying registry-sourced
    # content, so Registry refuses the local namespace even if a future ref
    # shape slips past refuse_local_namespace/1.
    case component_ref.type do
      "tincture" ->
        Registry.publish_tincture_archive(ctx, content_bytes, metadata,
          allow_overwrite: true,
          origin: :remote
        )

      _wasm_type ->
        Registry.publish_bytes(ctx, content_bytes, metadata,
          allow_overwrite: true,
          origin: :remote
        )
    end
  end

  defp get_local_component(ctx, cref) do
    case Registry.get(ctx, cref.name, cref.version, cref.namespace, cref.type) do
      {:ok, component} ->
        {:ok, component}

      {:error, :not_found} ->
        {:error, "Component not found locally: #{Sanctum.ComponentRef.to_string(cref)}"}
    end
  end

  defp get_wasm_bytes(ctx, component) do
    digest = component[:digest] || component["digest"]

    case Registry.get_blob(ctx, digest) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, "Failed to read WASM blob for digest: #{digest}"}
    end
  end

  # SQLite runtime artifacts that must never be published (transient files
  # created when something opens a SQLite database). `data.db` itself is a
  # regular shipped asset — devs may include one deliberately.
  @tincture_excluded ~w(data.db-wal data.db-shm)

  defp get_tincture_archive(ctx, component) do
    publisher = Compendium.ComponentPath.normalize_publisher(component[:publisher])

    version_dir =
      Compendium.ComponentPath.version_dir(
        "tincture",
        publisher,
        component[:name],
        component[:version]
      )

    entries =
      collect_arca_files(ctx, version_dir, version_dir)
      |> Enum.reject(fn {rel_path, _} -> Path.basename(rel_path) in @tincture_excluded end)

    case entries do
      [] ->
        {:error, "Tincture directory is empty or not found"}

      _ ->
        tar_entries =
          Enum.map(entries, fn {rel, content} ->
            {String.to_charlist(rel), content}
          end)

        case create_tar_gz(tar_entries) do
          {:ok, archive} -> {:ok, archive}
          :none -> {:error, "Failed to create tincture archive"}
        end
    end
  end

  defp get_component_content(ctx, component) do
    case component[:component_type] do
      "tincture" -> get_tincture_archive(ctx, component)
      _wasm_type -> get_wasm_bytes(ctx, component)
    end
  end

  # Read the full cyfr-manifest.json from the component's filesystem
  # directory. Every creation path writes it (scaffold, register, pull,
  # tincture publish, fork), so a missing or unreadable manifest fails the
  # push — synthesizing a config from the DB row would publish a second
  # identity for the same artifact, and a transient storage error would do
  # so silently.
  defp get_full_config(ctx, publisher, cref) do
    manifest_path =
      Compendium.ComponentPath.file_path(
        cref.type,
        cref.namespace,
        cref.name,
        cref.version,
        "cyfr-manifest.json"
      )

    with {:ok, content} <- Arca.get(ctx, manifest_path),
         {:ok, manifest} <- Jason.decode(content),
         updated =
           manifest
           |> Map.delete("id")
           |> Map.put("publisher", publisher)
           |> Map.put("name", cref.name),
         {:ok, json} <- Jason.encode(updated) do
      {:ok, json}
    else
      {:error, reason} ->
        {:error,
         "cannot read cyfr-manifest.json for #{cref.name}@#{cref.version}: #{inspect(reason)}"}
    end
  end

  # Read README.md from the component's filesystem directory.
  defp get_readme_bytes(ctx, cref) do
    readme_path =
      Compendium.ComponentPath.file_path(
        cref.type,
        cref.namespace,
        cref.name,
        cref.version,
        "README.md"
      )

    case Arca.get(ctx, readme_path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> :none
    end
  end

  # Create a gzipped tarball of the src/ directory from the component's filesystem.
  defp get_source_tarball(ctx, cref) do
    src_dir =
      Compendium.ComponentPath.version_dir(
        cref.type,
        cref.namespace,
        cref.name,
        cref.version
      ) ++ ["src"]

    case collect_arca_files(ctx, src_dir, src_dir) do
      [] ->
        :none

      entries ->
        tar_entries =
          Enum.map(entries, fn {rel_path, content} ->
            {String.to_charlist(rel_path), content}
          end)

        create_tar_gz(tar_entries)
    end
  end

  # Create a gzipped tarball from a list of {charlist_name, binary_content} entries.
  # arca:bypass-ok=D — `:erl_tar.create/3` :memory option is unreliable on
  # OTP 28, so we round-trip through System.tmp_dir!. The tar bytes are
  # produced and consumed entirely in this function; no Arca-tracked content
  # touches the local FS.
  defp create_tar_gz(tar_entries) do
    tmp = Path.join(System.tmp_dir!(), "cyfr_tar_#{:rand.uniform(1_000_000)}.tar")

    try do
      case :erl_tar.create(String.to_charlist(tmp), tar_entries) do
        :ok ->
          # arca:bypass-ok=D — read back the tar scratch file.
          case File.read(tmp) do
            {:ok, tar_binary} -> {:ok, :zlib.gzip(tar_binary)}
            {:error, _} -> :none
          end

        {:error, _} ->
          :none
      end
    after
      # arca:bypass-ok=D — remove the tar scratch file.
      File.rm(tmp)
    end
  end

  # Recursively collect all files from an Arca directory as {relative_path, content} tuples.
  defp collect_arca_files(ctx, base_path, current_path) do
    case Arca.list(ctx, current_path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          entry_path = current_path ++ [entry]
          rel_segments = entry_path -- base_path

          case Arca.get(ctx, entry_path) do
            {:ok, content} ->
              [{Path.join(rel_segments), content}]

            {:error, _} ->
              # Likely a directory — recurse into it
              collect_arca_files(ctx, base_path, entry_path)
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Upload a blob only if the data is present (not :none).
  defp maybe_upload_blob(_ctx, _oci_ref, :none, _media_type), do: :ok

  defp maybe_upload_blob(ctx, oci_ref, {:ok, bytes}, media_type) do
    case Blob.upload(ctx, oci_ref, bytes, media_type) do
      {:ok, _digest} -> :ok
      {:error, _} = err -> err
    end
  end

  # Build layer opts for Manifest.build/5 from README and source results.
  defp build_layer_opts(readme_result, source_result) do
    opts = []

    opts =
      case readme_result do
        {:ok, bytes} -> Keyword.put(opts, :readme_bytes, bytes)
        :none -> opts
      end

    case source_result do
      {:ok, bytes} -> Keyword.put(opts, :source_bytes, bytes)
      :none -> opts
    end
  end

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
  defp maybe_fetch_layer(ctx, ref, parsed, extractor_fn) do
    case extractor_fn.(parsed) do
      {:ok, layer} ->
        case fetch_blob(ctx, ref, layer["digest"]) do
          {:ok, bytes} ->
            {:ok, bytes}

          {:error, reason} ->
            Logger.warning(
              "[Compendium.OCI.Client] Failed to fetch optional layer: #{inspect(reason)}"
            )

            {:ok, nil}
        end

      :none ->
        {:ok, nil}
    end
  end

  # Store cyfr-manifest.json to Arca for a pulled component.
  defp maybe_store_manifest(_ctx, _component_ref, nil), do: :ok

  defp maybe_store_manifest(ctx, component_ref, config_bytes) do
    path =
      Compendium.ComponentPath.file_path(
        component_ref.type,
        component_ref.namespace,
        component_ref.name,
        component_ref.version,
        "cyfr-manifest.json"
      )

    case Arca.put(ctx, path, config_bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest_store_failed, reason}}
    end
  end

  # Store README.md to Arca for a pulled component.
  defp maybe_store_readme(_ctx, _component_ref, nil), do: :ok

  defp maybe_store_readme(ctx, component_ref, readme_bytes) do
    path =
      Compendium.ComponentPath.file_path(
        component_ref.type,
        component_ref.namespace,
        component_ref.name,
        component_ref.version,
        "README.md"
      )

    case Arca.put(ctx, path, readme_bytes) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Compendium.OCI.Client] Failed to store README: #{inspect(reason)}")
        :ok
    end
  end

  # Extract and store src/ files from a gzipped tarball to Arca.
  defp maybe_store_source(_ctx, _component_ref, nil), do: :ok

  defp maybe_store_source(ctx, component_ref, source_bytes) do
    base =
      Compendium.ComponentPath.version_dir(
        component_ref.type,
        component_ref.namespace,
        component_ref.name,
        component_ref.version
      )

    try do
      tar_binary = :zlib.gunzip(source_bytes)

      case :erl_tar.extract({:binary, tar_binary}, [:memory]) do
        {:ok, entries} ->
          Enum.each(entries, fn {filename, content} ->
            # filename is a charlist from :erl_tar
            rel_path = to_string(filename)
            path_segments = base ++ ["src" | String.split(rel_path, "/")]

            case Arca.put(ctx, path_segments, content) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[Compendium.OCI.Client] Failed to store source file #{rel_path}: #{inspect(reason)}"
                )
            end
          end)

        {:error, reason} ->
          Logger.warning(
            "[Compendium.OCI.Client] Failed to extract source tarball: #{inspect(reason)}"
          )
      end
    rescue
      e ->
        Logger.warning(
          "[Compendium.OCI.Client] Failed to decompress source tarball: #{inspect(e)}"
        )
    end

    :ok
  end

  # ============================================================================
  # Private: Discovery
  # ============================================================================

  defp list_repositories(ctx, ref) do
    path = "/v2/_catalog"

    case Transport.request(ctx, :get, path, ref) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"repositories" => repos}} ->
            {:ok, repos}

          other ->
            Logger.error(
              "[Compendium.OCI.Client] Unexpected catalog response format from #{ref.registry}: #{inspect(other)}"
            )

            {:error, "Unexpected catalog response format from #{ref.registry}"}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_response(status, body, ref.registry)}

      {:error, _} = error ->
        error
    end
  end

  defp list_tags(ctx, ref) do
    path = "/v2/#{ref.repository}/tags/list"

    case Transport.request(ctx, :get, path, ref) do
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
    # CYFR convention: publisher/<type plural>/name. The plurals are derived
    # from the canonical type list rather than written out again, so a new
    # component type is recognized here without a second edit.
    parts = String.split(repo, "/")
    length(parts) == 3 and Enum.at(parts, 1) in Compendium.ComponentPath.type_plurals()
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

  # Push tokens are opaque (no embedded publisher name), so the destination
  # namespace is resolved before pushing. A component developed under the
  # reserved `local` namespace is published under the caller's claimed personal
  # namespace (`c:local.foo:0.1.0` -> `c:alice.foo:0.1.0`). An explicit,
  # non-local namespace in the ref (a publisher membership) is used as-is.
  defp resolve_push_publisher(cref, registry, %Context{} = ctx) do
    case cref.namespace do
      "local" ->
        case Sanctum.Namespace.lookup_status(ctx.user_id) do
          {:ok, slug} ->
            {:ok, slug}

          :not_claimed ->
            {:error,
             "You haven't claimed a personal namespace yet. Run `cyfr login` to " <>
               "authenticate and claim one before publishing to #{registry}."}

          {:error, _reason} ->
            {:error,
             "Could not resolve your personal namespace for #{registry} " <>
               "(your account could not be read just now). Please retry."}
        end

      slug when is_binary(slug) and slug != "" ->
        {:ok, slug}

      _ ->
        {:error, "Cannot resolve push target namespace for #{registry}"}
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
