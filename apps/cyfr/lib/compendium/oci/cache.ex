# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.Cache do
  @moduledoc """
  Content-addressable cache for OCI blobs and manifests.

  Routes all I/O through `Arca.Storage` (the default `Arca.Adapters.Local`,
  or a configured object-store adapter) under the global `cache/oci/` prefix:

  - `cache/oci/blobs/sha256/<hex>` — raw blob content
  - `cache/oci/manifests/<registry>/<repo>/<tag>.json` — cached manifest envelopes
  - `cache/oci/index.json` — ref-to-digest mapping with timestamps

  Tag refs re-check digest via HEAD; digest refs are immutable.
  """

  require Logger

  alias Compendium.OCI.Blob, as: BlobUtil

  # All cache operations run under a single global storage context.
  # The `cache/` prefix is in `Arca.Storage.global_prefixes/0`, so the
  # adapter writes to root rather than user-scoping by `user_id`.
  defp ctx, do: Sanctum.system_context()

  @doc """
  Returns the cache root directory.

  Only meaningful when `Arca.Adapters.Local` is the configured storage
  adapter — used by tests that tamper with on-disk entries to verify
  integrity checks. For non-filesystem adapters, returns the conceptual
  Local path; callers must not rely on it pointing at real bytes.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    Arca.Adapters.Local.build_path(ctx(), ["cache", "oci"])
  end

  @doc """
  Get a cached blob by digest.

  Returns `{:ok, bytes}` if cached, `:miss` if not.
  """
  @spec get_blob(String.t()) :: {:ok, binary()} | :miss
  def get_blob("sha256:" <> hex = digest) do
    case Arca.get(ctx(), blob_segments(hex)) do
      {:ok, bytes} ->
        if BlobUtil.compute_digest(bytes) == digest do
          {:ok, bytes}
        else
          Logger.warning("[OCI.Cache.get_blob] Corrupt cache entry for #{digest}, removing")
          Arca.delete(ctx(), blob_segments(hex))
          :miss
        end

      {:error, :not_found} ->
        :miss

      {:error, _reason} ->
        :miss
    end
  end

  def get_blob(_), do: :miss

  @doc """
  Store a blob in the cache by digest.
  """
  @spec put_blob(String.t(), binary()) :: :ok | {:error, term()}
  def put_blob("sha256:" <> hex, content) do
    case Arca.put(ctx(), blob_segments(hex), content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[OCI.Cache.put_blob] Failed to write blob cache: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def put_blob(_, _), do: {:error, :invalid_digest_format}

  @doc """
  Get a cached manifest for a registry/repo/tag.

  Returns `{:ok, manifest_json, digest}` if cached, `:miss` if not.
  """
  @spec get_manifest(String.t(), String.t(), String.t()) :: {:ok, String.t(), String.t()} | :miss
  def get_manifest(registry, repository, tag) do
    case Arca.get(ctx(), manifest_segments(registry, repository, tag)) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"manifest" => manifest, "digest" => digest}} ->
            {:ok, manifest, digest}

          _ ->
            :miss
        end

      {:error, _} ->
        :miss
    end
  end

  @doc """
  Store a manifest in the cache.
  """
  @spec put_manifest(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def put_manifest(registry, repository, tag, manifest_json, digest) do
    payload = %{
      "manifest" => manifest_json,
      "digest" => digest,
      "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, entry} <- Jason.encode(payload),
         :ok <- Arca.put(ctx(), manifest_segments(registry, repository, tag), entry) do
      update_index(registry, repository, tag, digest)
    else
      {:error, %Jason.EncodeError{} = err} ->
        Logger.warning("[OCI.Cache.put_manifest] Failed to encode entry: #{inspect(err)}")
        {:error, {:json_encode, err}}

      {:error, reason} ->
        Logger.warning(
          "[OCI.Cache.put_manifest] Failed to write manifest cache: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Check if all blobs for a manifest are cached.
  """
  @spec all_blobs_cached?(list(String.t())) :: boolean()
  def all_blobs_cached?(digests) when is_list(digests) do
    Enum.all?(digests, fn digest ->
      case get_blob(digest) do
        {:ok, _} -> true
        :miss -> false
      end
    end)
  end

  @doc """
  Get the cached digest for a tag reference from the index.
  """
  @spec get_tag_digest(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :miss
  def get_tag_digest(registry, repository, tag) do
    case read_index() do
      {:ok, index} ->
        key = index_key(registry, repository, tag)

        case Map.get(index, key) do
          %{"digest" => digest} -> {:ok, digest}
          _ -> :miss
        end
    end
  end

  @doc """
  Clear the entire cache.
  """
  @spec clear() :: :ok | {:error, term()}
  def clear do
    case Arca.delete_tree(ctx(), ["cache", "oci"]) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("[OCI.Cache.clear] Failed to clear cache: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Private — path segments
  # ============================================================================

  defp blob_segments(hex), do: ["cache", "oci", "blobs", "sha256", hex]

  defp manifest_segments(registry, repository, tag) do
    safe_repo = String.replace(repository, "/", "_")
    ["cache", "oci", "manifests", registry, safe_repo, "#{tag}.json"]
  end

  defp index_segments, do: ["cache", "oci", "index.json"]

  defp index_key(registry, repository, tag), do: "#{registry}/#{repository}:#{tag}"

  defp read_index do
    case Arca.get(ctx(), index_segments()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, index} when is_map(index) -> {:ok, index}
          _ -> {:ok, %{}}
        end

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp update_index(registry, repository, tag, digest) do
    {:ok, index} = read_index()
    key = index_key(registry, repository, tag)

    updated =
      Map.put(index, key, %{
        "digest" => digest,
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    case Jason.encode(updated, pretty: true) do
      {:ok, json} ->
        case Arca.put(ctx(), index_segments(), json) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[OCI.Cache.update_index] Failed to update index: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[OCI.Cache.update_index] Failed to encode index: #{inspect(reason)}")
        {:error, {:json_encode, reason}}
    end
  end
end
