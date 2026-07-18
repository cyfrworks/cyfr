# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.TinctureValidator do
  @moduledoc """
  Validate tincture bundles and compute content digests.

  Unlike `Compendium.WasmValidator` (which validates WASM binaries),
  this validates HTML/JS/CSS tincture packages.

  ## Two entry points

    * `validate/1` — operates on a local filesystem directory. Used by
      the OCI publish flow which extracts the tar archive to a tmp dir
      before validation (Group D in the storage refactor).

    * `validate_from_pairs/1` — operates on a list of
      `{relative_segments, content}` pairs (the shape returned by
      `Arca.read_subtree/2`). Adapter-agnostic — same validator runs
      whether content was read from Local or S3.
  """

  @doc """
  Validate a tincture directory.

  Checks:
  1. cyfr-manifest.json exists and type == "tincture"
  2. Entry file exists (manifest tincture.entry or default index.html)
  3. Computes digest from all shipped files (sorted, deterministic).

  Returns `{:ok, %{digest: sha256_hex, size: total_bytes, exports: []}}`.
  """
  @spec validate(String.t()) :: {:ok, map()} | {:error, String.t()}
  def validate(directory_path) do
    manifest_path = Path.join(directory_path, "cyfr-manifest.json")

    with {:ok, raw} <- read_file(manifest_path),
         {:ok, manifest} <- decode_json(raw),
         :ok <- check_type(manifest),
         :ok <- check_entry(directory_path, manifest),
         :ok <- check_reserved_dirs(directory_path) do
      {digest, size} = compute_digest(directory_path)
      # exports always [] — tinctures have no WASM exports; kept for return-shape
      # compatibility with WasmValidator so Registry can use either validator uniformly
      {:ok, %{digest: digest, size: size, exports: []}}
    end
  end

  @doc """
  Validate a tincture from `{relative_segments, content}` pairs.

  Same checks as `validate/1` but operates entirely in memory — used by
  the Arca-based indexer where content was fetched via `Arca.read_subtree/2`.
  """
  @spec validate_from_pairs([{[String.t()], binary()}]) ::
          {:ok, map()} | {:error, String.t()}
  def validate_from_pairs(pairs) when is_list(pairs) do
    files = Map.new(pairs, fn {segs, content} -> {Enum.join(segs, "/"), content} end)

    with {:ok, raw} <- fetch_pair(files, "cyfr-manifest.json"),
         {:ok, manifest} <- decode_json(raw),
         :ok <- check_type(manifest),
         :ok <- check_entry_in_pairs(files, manifest),
         :ok <- check_reserved_dirs_in_pairs(files) do
      {digest, size} = compute_digest_from_pairs(files)
      {:ok, %{digest: digest, size: size, exports: []}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # arca:bypass-ok=D — operates on the tar-extract tmp dir set up by
  # `Compendium.Registry.extract_and_store_tincture/5`. Validation completes
  # before content is written back through Arca. The pair-based variant
  # (`validate_from_pairs/1`) is the adapter-agnostic path used by indexers.
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

  # arca:bypass-ok=D — operates on the tar-extract tmp dir (Group D); see
  # the module-level note above. The Arca-routed validator (used by the
  # indexer) is `validate_from_pairs/1`.
  defp check_entry(dir, manifest) do
    entry = get_in(manifest, ["tincture", "entry"]) || "index.html"

    with :ok <- validate_entry_path(entry) do
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

  # Traversal rules come from Cyfr.PathSafety (the repo-wide SSOT); keep the
  # user-facing messages this validator has always produced.
  defp validate_entry_path(entry) do
    case Cyfr.PathSafety.validate_relative_path(entry) do
      :ok ->
        :ok

      {:error, message} ->
        cond do
          message =~ "null bytes" -> {:error, "entry must not contain null bytes"}
          message =~ "Absolute paths" -> {:error, "entry must be a relative path"}
          true -> {:error, "entry must not contain '..'"}
        end
    end
  end

  # _s is reserved by the tincture asset router for signed-token path prefixes.
  @reserved_dirs ~w(_s)

  # arca:bypass-ok=D — tar-extract tmp dir scan; see module note.
  defp check_reserved_dirs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        conflict =
          Enum.find(entries, fn e -> e in @reserved_dirs and File.dir?(Path.join(dir, e)) end)

        if conflict, do: {:error, "'#{conflict}' is a reserved directory name"}, else: :ok

      {:error, _} ->
        :ok
    end
  end

  # arca:bypass-ok=D — tar-extract tmp dir; see module note.
  defp compute_digest(directory_path) do
    files =
      directory_path
      |> list_files_recursive()
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

  # arca:bypass-ok=D — tar-extract tmp dir walk; see module note.
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

  # ---------------------------------------------------------------------------
  # Pair-based variants (used by `validate_from_pairs/1`)
  # ---------------------------------------------------------------------------

  defp fetch_pair(files, key) do
    case Map.fetch(files, key) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "cyfr-manifest.json not found"}
    end
  end

  defp check_entry_in_pairs(files, manifest) do
    entry = get_in(manifest, ["tincture", "entry"]) || "index.html"

    with :ok <- validate_entry_path(entry) do
      if Map.has_key?(files, entry) do
        :ok
      else
        {:error, "entry file '#{entry}' not found"}
      end
    end
  end

  defp check_reserved_dirs_in_pairs(files) do
    conflict =
      files
      |> Map.keys()
      |> Enum.find(fn k ->
        case String.split(k, "/", parts: 2) do
          [head | _] -> head in @reserved_dirs
          _ -> false
        end
      end)

    case conflict do
      nil -> :ok
      key -> {:error, "'#{String.split(key, "/") |> List.first()}' is a reserved directory name"}
    end
  end

  defp compute_digest_from_pairs(files) do
    sorted = files |> Map.to_list() |> Enum.sort_by(fn {k, _} -> k end)

    {hash_state, total_size} =
      Enum.reduce(sorted, {:crypto.hash_init(:sha256), 0}, fn {relative, content},
                                                              {state, size} ->
        new_state =
          state
          |> :crypto.hash_update(relative)
          |> :crypto.hash_update(content)

        {new_state, size + byte_size(content)}
      end)

    digest = :crypto.hash_final(hash_state) |> Base.encode16(case: :lower)
    {digest, total_size}
  end
end
