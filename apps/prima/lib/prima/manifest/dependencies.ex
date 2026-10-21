# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Dependencies do
  @moduledoc """
  The manifest `dependencies.static` block: the components a component
  declares it reaches.

  Static dependencies are what an activation walks and what a consent's
  blob carries an edge for, so the component domain writes them to rows
  and the identity domain reads them to name an edge — one parse, read by
  both. Dynamic dispatch is deliberately outside the block: a dynamically
  reached component holds no authority, so there is nothing to declare.

  The manifest is decoded JSON, string-keyed. An entry is a ref string,
  or an object carrying `ref` and optionally `optional` and `reason`. A
  `dependencies` that is not an object, a `static` that is not a list,
  an entry of neither shape and a ref that does not parse each fail the
  whole block: a dependency nobody can name is not a dependency that is
  simply skipped.
  """

  @typedoc "One declared static dependency, as a row and an edge both read it."
  @type dependency :: %{
          dependency_ref: String.t(),
          dep_type: String.t(),
          dep_namespace: String.t(),
          dep_name: String.t(),
          dep_version: String.t() | nil,
          optional: boolean(),
          reason: String.t() | nil
        }

  @doc """
  The declared static dependencies of a decoded manifest, in declaration
  order. A manifest with no block, or a block with no `static`, declares
  none.
  """
  @spec from_manifest(map() | nil) :: {:ok, [dependency()]} | {:error, String.t()}
  def from_manifest(nil), do: {:ok, []}

  def from_manifest(manifest) when is_map(manifest) do
    case Map.fetch(manifest, "dependencies") do
      :error -> {:ok, []}
      {:ok, %{} = block} -> static(Map.fetch(block, "static"))
      {:ok, _other} -> {:error, "Invalid dependencies block: dependencies is not an object"}
    end
  end

  defp static(:error), do: {:ok, []}
  defp static({:ok, entries}) when is_list(entries), do: parse_entries(entries)

  defp static({:ok, _other}),
    do: {:error, "Invalid dependencies block: dependencies.static is not a list"}

  defp parse_entries(static) do
    static
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case dependency(entry) do
        {:ok, dep} -> {:cont, {:ok, [dep | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  defp dependency(ref) when is_binary(ref), do: dependency(ref, false, nil)

  defp dependency(%{"ref" => ref} = entry) when is_binary(ref),
    do: dependency(ref, entry["optional"] == true, entry["reason"])

  defp dependency(_entry),
    do: {:error, "Invalid dependency entry: neither a ref nor an object with a ref"}

  defp dependency(ref_str, optional, reason) do
    case Prima.ComponentRef.parse(ref_str) do
      {:ok, parsed} ->
        {:ok,
         %{
           dependency_ref: ref_str,
           dep_type: parsed.type,
           dep_namespace: parsed.namespace,
           dep_name: parsed.name,
           dep_version: parsed.version,
           optional: optional,
           reason: reason
         }}

      {:error, reason} ->
        {:error, "Invalid dependency ref '#{ref_str}': #{reason}"}
    end
  end
end
