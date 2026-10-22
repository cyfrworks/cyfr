# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentRow do
  @moduledoc """
  The component row as both sides read it: the shape the component domain
  writes and the identity domain consents over.

  A row is the stored map, atom-keyed (`t:t/0`); the activation graph
  keys a row by its **name-level ref** (`type:namespace.name`, no
  version), because code identity lives in the digest and never in the
  key; and a name's versions are ordered by the one comparator
  (`Prima.Semver`), `inserted_at` as the tiebreak. Nothing here reads
  state.
  """

  @typedoc "A component row as storage answers it: atom keys, the fields consent reads."
  @type t :: %{
          optional(:component_type) => String.t() | atom(),
          optional(:publisher) => String.t() | nil,
          optional(:name) => String.t(),
          optional(:version) => String.t(),
          optional(:manifest) => String.t() | map() | nil,
          optional(:release_digest) => String.t() | nil,
          optional(:inserted_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @doc """
  The name-level key a component row occupies in an activation graph:
  `type:publisher.name`, the publisher normalized.

  ## Examples

      iex> Prima.ComponentRow.node_key(%{component_type: "catalyst", publisher: nil, name: "files"})
      "catalyst:local.files"

  """
  @spec node_key(t()) :: String.t()
  def node_key(row) when is_map(row) do
    Prima.ComponentRef.build(
      to_string(Map.get(row, :component_type)),
      Prima.ComponentPath.normalize_publisher(Map.get(row, :publisher)),
      Map.get(row, :name)
    )
  end

  @doc """
  The semver-latest of a list of rows, `inserted_at` as the tiebreak —
  the one place ROWS (not bare strings) are ordered. Registered versions
  are validated semver; the comparator (`Prima.Semver`) is total
  regardless.
  """
  @spec latest_of([t()]) :: t() | nil
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
