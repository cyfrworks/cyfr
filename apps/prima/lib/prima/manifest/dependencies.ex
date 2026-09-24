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

  An entry is a ref string, or a map carrying `ref` and optionally
  `optional` and `reason`. A ref that does not parse fails the whole
  block: a dependency nobody can name is not a dependency that is simply
  skipped.
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
  order. A manifest with no block declares none.
  """
  @spec from_manifest(map() | nil) :: {:ok, [dependency()]} | {:error, term()}
  def from_manifest(nil), do: {:ok, []}

  def from_manifest(manifest) when is_map(manifest) do
    case get_in(manifest, ["dependencies", "static"]) ||
           get_in(manifest, [:dependencies, :static]) do
      static when is_list(static) -> parse_entries(static)
      _absent_or_malformed -> {:ok, []}
    end
  end

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

  defp dependency(entry) do
    ref_str = if is_binary(entry), do: entry, else: entry["ref"] || entry[:ref]

    {optional, reason} =
      if is_binary(entry) do
        {false, nil}
      else
        {(entry["optional"] || entry[:optional]) == true, entry["reason"] || entry[:reason]}
      end

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
