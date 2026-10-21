# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentRow do
  @moduledoc """
  The component row as both sides read it: the shape the component domain
  writes and the identity domain consents over.

  A row reaches consent either as a stored map with atom keys or as a
  decoded one with string keys, so `field/2` is the one accessor; the
  activation graph keys a row by its **name-level ref**
  (`type:namespace.name`, no version), because code identity lives in the
  digest and never in the key; and a name's versions are ordered by the
  one comparator (`Prima.Semver`), `inserted_at` as the tiebreak.

  Nothing here reads state. `Compendium.Activation.node_key/1` and
  `Compendium.Registry.latest_of/1` are the component domain's spellings
  and delegate here.
  """

  @doc """
  A row field by name, whether the row carries atom or string keys.

  ## Examples

      iex> Prima.ComponentRow.field(%{name: "widget"}, :name)
      "widget"

      iex> Prima.ComponentRow.field(%{"name" => "widget"}, :name)
      "widget"

      iex> Prima.ComponentRow.field(%{}, :name)
      nil

  """
  @spec field(map(), atom()) :: term()
  def field(row, key) when is_map(row) and is_atom(key) do
    case Map.fetch(row, key) do
      {:ok, value} -> value
      :error -> Map.get(row, Atom.to_string(key))
    end
  end

  @doc """
  The name-level key a component row occupies in an activation graph:
  `type:publisher.name`, the publisher normalized.

  ## Examples

      iex> Prima.ComponentRow.node_key(%{component_type: "catalyst", publisher: nil, name: "files"})
      "catalyst:local.files"

  """
  @spec node_key(map()) :: String.t()
  def node_key(row) when is_map(row) do
    Prima.ComponentRef.build(
      to_string(field(row, :component_type)),
      Prima.ComponentPath.normalize_publisher(field(row, :publisher)),
      field(row, :name)
    )
  end

  @doc """
  The semver-latest of a list of rows, `inserted_at` as the tiebreak —
  the one place ROWS (not bare strings) are ordered. Registered versions
  are validated semver; the comparator (`Prima.Semver`) is total
  regardless.
  """
  @spec latest_of([map()]) :: map() | nil
  def latest_of(rows) when is_list(rows) do
    rows
    |> Enum.sort(fn a, b ->
      case Prima.Semver.compare(a.version, b.version) do
        :gt -> true
        :lt -> false
        :eq -> DateTime.compare(a.inserted_at, b.inserted_at) == :gt
      end
    end)
    |> List.first()
  end
end
