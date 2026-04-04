defmodule Compendium.TinctureValidator do
  @moduledoc """
  Validate tincture bundles and compute content digests.

  Unlike `Compendium.WasmValidator` (which validates WASM binaries),
  this validates HTML/JS/CSS tincture packages and their manifest schema.
  """

  alias Arca.TinctureData.Schema

  @doc """
  Validate a tincture directory.

  Checks:
  1. cyfr-manifest.json exists and type == "tincture"
  2. Entry file exists (manifest tincture.entry or default index.html)
  3. Schema SQL is valid (if schema present)
  4. Computes digest from all shipped files (sorted, deterministic), excluding data.db

  Returns `{:ok, %{digest: sha256_hex, size: total_bytes, exports: []}}`.
  """
  @spec validate(String.t()) :: {:ok, map()} | {:error, String.t()}
  def validate(directory_path) do
    manifest_path = Path.join(directory_path, "cyfr-manifest.json")

    with {:ok, raw} <- read_file(manifest_path),
         {:ok, manifest} <- decode_json(raw),
         :ok <- check_type(manifest),
         :ok <- check_entry(directory_path, manifest),
         :ok <- check_schema(manifest) do
      {digest, size} = compute_digest(directory_path)
      # exports always [] — tinctures have no WASM exports; kept for return-shape
      # compatibility with WasmValidator so Registry can use either validator uniformly
      {:ok, %{digest: digest, size: size, exports: []}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "cyfr-manifest.json not found"}
      {:error, reason} -> {:error, "cannot read manifest: #{inspect(reason)}"}
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, err} -> {:error, "invalid manifest JSON: #{Exception.message(err)}"}
    end
  end

  defp check_type(%{"type" => "tincture"}), do: :ok
  defp check_type(%{"type" => other}), do: {:error, "expected type 'tincture', got '#{other}'"}
  defp check_type(_), do: {:error, "manifest missing 'type' field"}

  defp check_entry(dir, manifest) do
    entry = get_in(manifest, ["tincture", "entry"]) || "index.html"

    cond do
      String.contains?(entry, "..") ->
        {:error, "entry must not contain '..'"}

      String.contains?(entry, "\0") ->
        {:error, "entry must not contain null bytes"}

      String.starts_with?(entry, "/") ->
        {:error, "entry must be a relative path"}

      true ->
        path = Path.join(dir, entry)
        resolved = Path.expand(path)
        base = Path.expand(dir)

        cond do
          not String.starts_with?(resolved, base <> "/") ->
            {:error, "entry escapes tincture directory"}

          not File.regular?(resolved) ->
            {:error, "entry file '#{entry}' not found"}

          true ->
            :ok
        end
    end
  end

  defp check_schema(%{"schema" => schema}) when map_size(schema) > 0 do
    case Schema.parse_manifest_schema(%{"schema" => schema}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "schema validation failed: #{reason}"}
    end
  end

  defp check_schema(_), do: :ok

  @excluded_files ~w(data.db)

  defp compute_digest(directory_path) do
    files =
      directory_path
      |> list_files_recursive()
      |> Enum.reject(fn path ->
        basename = Path.basename(path)
        basename in @excluded_files
      end)
      |> Enum.sort()

    {hash_state, total_size} =
      Enum.reduce(files, {:crypto.hash_init(:sha256), 0}, fn file, {state, size} ->
        relative = Path.relative_to(file, directory_path)
        {:ok, content} = File.read(file)
        file_size = byte_size(content)

        new_state =
          state
          |> :crypto.hash_update(relative)
          |> :crypto.hash_update(content)

        {new_state, size + file_size}
      end)

    digest = :crypto.hash_final(hash_state) |> Base.encode16(case: :lower)
    {digest, total_size}
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      if File.dir?(path) do
        list_files_recursive(path)
      else
        [path]
      end
    end)
  end
end
