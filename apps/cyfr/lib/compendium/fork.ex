# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Fork do
  @moduledoc """
  Fork a published component into the local namespace.

  Copies the source code, manifest, compiled artifact, and README from a
  published component into `components/{type}s/local/{name}/{version}/`,
  making it fully editable.

  Requires source code (`src/` directory) to be present in the source
  component's storage. Components must be pulled locally first.
  """

  alias Sanctum.{ComponentRef, Context}
  alias Compendium.ComponentPath

  @spec fork(Context.t(), ComponentRef.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def fork(%Context{} = ctx, %ComponentRef{} = source_ref, opts \\ []) do
    target_name = Keyword.get(opts, :name, source_ref.name)
    target_version = Keyword.get(opts, :version, source_ref.version)

    source_base =
      ComponentPath.version_dir(
        source_ref.type,
        source_ref.namespace,
        source_ref.name,
        source_ref.version
      )

    target_base =
      ComponentPath.version_dir(
        source_ref.type,
        "local",
        target_name,
        target_version
      )

    source_ref_str = ComponentRef.to_string(source_ref)
    target_ref_str = "#{source_ref.type}:local.#{target_name}:#{target_version}"

    with :ok <- validate_name(target_name),
         :ok <- validate_version(target_version),
         :ok <- check_source_exists(ctx, source_base, source_ref_str),
         :ok <- check_target_not_exists(ctx, target_base, target_ref_str),
         :ok <- check_source_available(ctx, source_base, source_ref_str) do
      case do_fork(ctx, source_base, target_base, target_name, target_version, source_ref_str) do
        {:ok, files} ->
          {:ok,
           %{
             status: "forked",
             reference: target_ref_str,
             forked_from: source_ref_str,
             files: files,
             next_steps: next_steps(source_ref.type, target_ref_str)
           }}

        {:error, reason} ->
          # Clean up partial copy
          Arca.delete_tree(ctx, target_base)
          {:error, "Fork failed: #{inspect(reason)}"}
      end
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_name(name) do
    case ComponentRef.validate_name(name) do
      :ok -> :ok
      {:error, reason} -> {:error, "Invalid fork target name: #{reason}"}
    end
  end

  defp validate_version(version) do
    case ComponentRef.validate_version(version) do
      :ok -> :ok
      {:error, reason} -> {:error, "Invalid fork target version: #{reason}"}
    end
  end

  defp check_source_exists(ctx, source_base, source_ref_str) do
    case Arca.get(ctx, source_base ++ ["cyfr-manifest.json"]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error,
         "Component not found locally: #{source_ref_str}. Pull it first: cyfr pull #{source_ref_str}"}
    end
  end

  defp check_target_not_exists(ctx, target_base, target_ref_str) do
    case Arca.get(ctx, target_base ++ ["cyfr-manifest.json"]) do
      {:ok, _} -> {:error, "Target already exists: #{target_ref_str}"}
      {:error, _} -> :ok
    end
  end

  defp check_source_available(ctx, source_base, source_ref_str) do
    case Arca.list(ctx, source_base ++ ["src"]) do
      {:ok, entries} when entries != [] ->
        :ok

      _ ->
        {:error,
         "No source code available for #{source_ref_str}. " <>
           "The publisher did not include source when publishing this component."}
    end
  end

  # ============================================================================
  # Copy Logic
  # ============================================================================

  defp do_fork(ctx, source_base, target_base, target_name, target_version, source_ref_str) do
    case collect_files(ctx, source_base, source_base) do
      {:error, reason} ->
        {:error, reason}

      files ->
        write_files(files, ctx, target_base, target_name, target_version, source_ref_str)
    end
  end

  defp collect_files(ctx, base_path, current_path) do
    case Arca.list(ctx, current_path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          entry_path = current_path ++ [entry]
          rel_segments = entry_path -- base_path

          case Arca.get(ctx, entry_path) do
            {:ok, content} ->
              [{rel_segments, content}]

            {:error, _} ->
              # Likely a directory — recurse
              collect_files(ctx, base_path, entry_path)
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp write_files(files, ctx, target_base, target_name, target_version, source_ref_str) do
    result =
      Enum.reduce_while(files, {:ok, []}, fn {rel_segments, content}, {:ok, acc} ->
        content =
          if rel_segments == ["cyfr-manifest.json"] do
            rewrite_manifest(content, target_name, target_version, source_ref_str)
          else
            content
          end

        target_path = target_base ++ rel_segments

        case Arca.put(ctx, target_path, content) do
          :ok -> {:cont, {:ok, [Path.join(target_path) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Manifest Rewrite
  # ============================================================================

  defp rewrite_manifest(manifest_json, name, version, forked_from) do
    case Jason.decode(manifest_json) do
      {:ok, manifest} ->
        manifest
        |> Map.put("publisher", "local")
        |> Map.put("name", name)
        |> Map.put("version", version)
        |> Map.put("forked_from", forked_from)
        |> Jason.encode!(pretty: true)

      {:error, _} ->
        # If manifest is not valid JSON, copy as-is
        manifest_json
    end
  end

  # ============================================================================
  # Next Steps
  # ============================================================================

  defp next_steps("tincture", reference) do
    [
      "Edit the source files to customize the tincture",
      "Register: use component.register with reference '#{reference}'"
    ]
  end

  defp next_steps(type, reference) do
    [
      "Edit src/src/lib.rs to modify the #{type} logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end
end
