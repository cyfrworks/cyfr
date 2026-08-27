# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Fork do
  @moduledoc """
  Fork a published component into the local namespace — how a remote
  component becomes a user-owned local line.

  Copies the source code, manifest, compiled artifact, and README from a
  published component into `components/{type}s/local/{name}/{version}/`,
  making it fully editable, and stamps `forked_from` into the manifest so
  the fork's upstream line stays queryable
  (`Compendium.Provenance.upstream_status/2`).

  The first guard REFUSES a `local` source (`Compendium.NamespacePolicy`
  — a local component has nothing to cross; use scaffold for a fresh
  one). Requires source code (`src/` directory) to be present in the
  source component's storage — components must be pulled locally first.
  """

  require Logger

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
        ComponentPath.default_publisher(),
        target_name,
        target_version
      )

    source_ref_str = ComponentRef.to_string(source_ref)

    target_ref_str =
      ComponentRef.to_string(%ComponentRef{
        type: source_ref.type,
        namespace: ComponentPath.default_publisher(),
        name: target_name,
        version: target_version
      })

    with :ok <- refuse_local_source(source_ref),
         :ok <- validate_name(target_name),
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
          # Clean up the partial copy. A cleanup failure must not mask the
          # fork failure — but it must not vanish either.
          case Arca.delete_tree(ctx, target_base) do
            :ok ->
              :ok

            {:error, cleanup_reason} ->
              Logger.warning(
                "[Compendium.Fork] partial-copy cleanup of #{target_ref_str} failed: " <>
                  inspect(cleanup_reason)
              )
          end

          {:error, "Fork failed: #{inspect(reason)}"}
      end
    end
  end

  # The guard lives here, not in the MCP caller, so a direct call cannot
  # fork what the tool refuses; the rule and its message are
  # `Compendium.NamespacePolicy`'s.
  defp refuse_local_source(%ComponentRef{namespace: namespace}),
    do: Compendium.NamespacePolicy.refuse_local_fork_source(namespace)

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
    case Arca.get(ctx, source_base ++ [ComponentPath.manifest_name()]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error,
         "Component not found locally: #{source_ref_str}. Pull it first: cyfr pull #{source_ref_str}"}
    end
  end

  defp check_target_not_exists(ctx, target_base, target_ref_str) do
    case Arca.get(ctx, target_base ++ [ComponentPath.manifest_name()]) do
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

  # One streaming pass through `Arca.copy_tree/4` — one file in memory at
  # a time, build droppings excluded (a pulled tree can carry them; the
  # seed never does). The manifest — the unit's completion sentinel — is
  # excluded from the copy, re-stamped, and lands LAST (the
  # `Arca.put_files/2` discipline): a fork that dies mid-copy never
  # leaves a unit that reads as complete.
  defp do_fork(ctx, source_base, target_base, target_name, target_version, source_ref_str) do
    manifest = [ComponentPath.manifest_name()]

    copy =
      Arca.copy_tree(ctx, source_base, target_base,
        exclude: &(Arca.Storage.build_dropping?(&1) or &1 == manifest)
      )

    with {:ok, _copied} <- copy,
         {:ok, source_manifest} <- Arca.get(ctx, source_base ++ manifest),
         :ok <-
           Arca.put(
             ctx,
             target_base ++ manifest,
             rewrite_manifest(source_manifest, target_name, target_version, source_ref_str)
           ),
         {:ok, leaves} <- Arca.list_recursive(ctx, target_base) do
      {:ok, leaves |> Enum.map(&Path.join/1) |> Enum.sort()}
    end
  end

  # ============================================================================
  # Manifest Rewrite
  # ============================================================================

  defp rewrite_manifest(manifest_json, name, version, forked_from) do
    case Jason.decode(manifest_json) do
      {:ok, manifest} ->
        manifest
        |> Map.put("publisher", ComponentPath.default_publisher())
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
