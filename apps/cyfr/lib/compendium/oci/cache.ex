defmodule Compendium.OCI.Cache do
  @moduledoc """
  Content-addressable local cache for OCI blobs and manifests.

  Layout at `~/.cyfr/oci-cache/`:
  - `blobs/sha256/<hex>` — raw blob content
  - `manifests/<registry>/<repo>/<tag>.json` — cached manifests
  - `index.json` — ref-to-digest mapping with timestamps

  Tag refs re-check digest via HEAD; digest refs are immutable.
  """

  require Logger

  alias Compendium.OCI.Blob, as: BlobUtil

  @doc """
  Returns the cache root directory.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    Application.get_env(:cyfr, :oci_cache_dir) ||
      Path.join([System.user_home!(), ".cyfr", "oci-cache"])
  end

  @doc """
  Get a cached blob by digest.

  Returns `{:ok, bytes}` if cached, `:miss` if not.
  """
  @spec get_blob(String.t()) :: {:ok, binary()} | :miss
  def get_blob("sha256:" <> hex = digest) do
    path = blob_path(hex)

    case File.read(path) do
      {:ok, bytes} ->
        # Verify integrity
        if BlobUtil.compute_digest(bytes) == digest do
          {:ok, bytes}
        else
          Logger.warning("[OCI.Cache] Corrupt cache entry for #{digest}, removing")
          File.rm(path)
          :miss
        end

      {:error, _} ->
        :miss
    end
  end

  def get_blob(_), do: :miss

  @doc """
  Store a blob in the cache by digest.
  """
  @spec put_blob(String.t(), binary()) :: :ok | {:error, term()}
  def put_blob("sha256:" <> hex, content) do
    path = blob_path(hex)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[OCI.Cache] Failed to write blob cache: #{inspect(reason)}")
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
    path = manifest_path(registry, repository, tag)

    case File.read(path) do
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
  @spec put_manifest(String.t(), String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def put_manifest(registry, repository, tag, manifest_json, digest) do
    path = manifest_path(registry, repository, tag)
    dir = Path.dirname(path)

    case Jason.encode(%{
           "manifest" => manifest_json,
           "digest" => digest,
           "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }) do
      {:ok, entry} ->
        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(path, entry) do
          update_index(registry, repository, tag, digest)
        else
          {:error, reason} ->
            Logger.warning("[OCI.Cache] Failed to write manifest cache: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[OCI.Cache] Failed to encode manifest cache entry: #{inspect(reason)}")
        {:error, {:json_encode, reason}}
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

      _ ->
        :miss
    end
  end

  @doc """
  Clear the entire cache.
  """
  @spec clear() :: :ok | {:error, term()}
  def clear do
    dir = cache_dir()

    if File.exists?(dir) do
      case File.rm_rf(dir) do
        {:ok, _} -> :ok
        {:error, reason, _path} ->
          Logger.warning("[OCI.Cache] Failed to clear cache: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp blob_path(hex) do
    Path.join([cache_dir(), "blobs", "sha256", hex])
  end

  defp manifest_path(registry, repository, tag) do
    safe_repo = String.replace(repository, "/", "_")
    Path.join([cache_dir(), "manifests", registry, safe_repo, "#{tag}.json"])
  end

  defp index_path do
    Path.join(cache_dir(), "index.json")
  end

  defp index_key(registry, repository, tag) do
    "#{registry}/#{repository}:#{tag}"
  end

  defp read_index do
    case File.read(index_path()) do
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

    updated = Map.put(index, key, %{
      "digest" => digest,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    path = index_path()

    case Jason.encode(updated, pretty: true) do
      {:ok, json} ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, json) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("[OCI.Cache] Failed to update index: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[OCI.Cache] Failed to encode cache index: #{inspect(reason)}")
        {:error, {:json_encode, reason}}
    end
  end
end
