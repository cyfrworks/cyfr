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

  # One unit commit: the source tree streams over (one file in memory at
  # a time, build droppings excluded — a pulled tree can carry them; the
  # seed never does), and the re-stamped manifest is the commit's
  # sentinel, landing LAST. Rollback on failure is the commit's own — a
  # fork that dies mid-copy leaves nothing behind. Fork moves pulled or
  # operator-shipped bytes into the athanor's own name, so it stays
  # cap-exempt (the `Sanctum.Tenancy.Caps` roster).
  defp do_fork(ctx, source_base, target_base, target_name, target_version, source_ref_str) do
    with {:ok, source_manifest} <- Arca.get(ctx, source_base ++ [ComponentPath.manifest_name()]),
         {:ok, written} <-
           Arca.Overlay.commit_unit(
             ctx,
             target_base,
             {:tree, source_base, exclude: &Arca.Storage.build_dropping?/1},
             cap: :exempt,
             sentinel:
               rewrite_manifest(source_manifest, target_name, target_version, source_ref_str)
           ) do
      {:ok, written |> Enum.map(&Path.join(target_base ++ &1)) |> Enum.sort()}
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
