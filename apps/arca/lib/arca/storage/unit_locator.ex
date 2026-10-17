# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage.UnitLocator do
  @moduledoc """
  How an overlaid root's shadow units are shaped — answered from the path
  grammar alone, by the domain module that owns the root's spelling
  (`Compendium.ComponentPath` for `components/`, `Compendium.AquaPath` for
  `aqua/`), so `Arca` never gains a compile edge on Compendium.

  The locators are one installed registry, a map from each overlaid root
  to its locator: `Cyfr.Application` writes it at boot with `install!/1`,
  and `Arca.Storage.locate/1` reads it through `impl!/0` for every leaf a
  batch walk classifies.

  The layout table (`Arca.Storage`) says only WHETHER a root overlays;
  the locator says HOW: given a logical path inside its root, it answers

    * `:above_unit` — the path sits above any shadow unit (listings union
      here; writes and deletes pass untouched);
    * `{:file, unit}` — the path is at or below a file-shaped unit (the
      unit IS one file — an aqua agent);
    * `{:dir, unit, sentinel}` — the path is at or below a directory
      unit whose named sentinel file marks a completed copy (a component
      version directory, an aqua skill).

  Pure — no I/O, no context. The shape must be answerable before any file
  exists (the write gate consults it on the first write), and the batch
  walks stay two listings with no per-unit probes because classifying a
  leaf is a function call, not a round-trip.

  ## Where a unit's bytes live

  A unit is published by its `Arca.Schemas.StorageUnit` row, keyed by
  `unit_key/1`. Its objects have one home, spelled here and nowhere else:
  a **revision prefix** (`revision_prefix/2`), where one revision's
  objects are staged before the row's commit names it and served from
  once it does: `{root}/.staging/{unit…}/{revision}/`, beside the units
  and never inside one. No locator's grammar claims `.staging`, so the
  prefix locates `:above_unit`: status walks skip it and no unit's listing
  or diff sees it as itself. A revision's first object is its in-progress
  marker (`marker_path/2`), created before any upload.

  A reader of a unit path resolves the row and reads the object under the
  committed revision's prefix (`in_revision/3`); a listing of the prefix
  is spelled back as the unit's own paths (`from_revision/3`). Nothing is
  placed at the unit's own path. A prefix the row does not name is a
  staging in progress, a loser's remains or a revision the pointer has
  left — only the row says which, and the collector takes the last two.
  """

  @callback locate(Arca.Storage.path()) ::
              :above_unit
              | {:file, unit :: Arca.Storage.path()}
              | {:dir, unit :: Arca.Storage.path(), sentinel :: String.t()}

  defmodule NotInstalledError do
    @moduledoc """
    Raised by `Arca.Storage.UnitLocator.impl!/0` when nothing has installed
    the overlaid roots' locators.
    """

    defexception message:
                   "Arca.Storage.UnitLocator has no installed locators: nothing called " <>
                     "Arca.Storage.UnitLocator.install!/1. An overlaid path cannot be " <>
                     "located until boot installs them."
  end

  # The port's own term: the verified registry, written once at boot and
  # read per leaf, so a batch walk never re-reads anything to classify.
  @key {__MODULE__, :impl}

  @staging ".staging"
  @marker ".in-progress"

  @typedoc "Each overlaid root, and the locator that shapes its units."
  @type registry :: %{String.t() => module()}

  @doc """
  Assert the locator registry and install it: `locators` must name exactly
  the overlaid roots (`Arca.Storage.overlay_roots/0`), each value a module
  exporting `locate/1`. Called once by `Cyfr.Application` at boot, before
  anything scans the union, so a forgotten root fails there instead of on
  the first touch of it. A refused registry leaves the installed one in
  place.
  """
  @spec install!(registry()) :: registry()
  def install!(locators) when is_map(locators) do
    roots = MapSet.new(Arca.Storage.overlay_roots())
    keys = MapSet.new(Map.keys(locators))

    unless MapSet.equal?(roots, keys) do
      raise ArgumentError, """
      the unit locators must name exactly the overlaid roots.
        overlaid roots (Arca.Storage layout): #{inspect(Enum.sort(roots))}
        installed locators:                   #{inspect(Enum.sort(keys))}
      Remedy: add the missing root's Arca.Storage.UnitLocator to the map
      the boot installs, or add/remove the root's row in the layout
      table — the two must always agree.
      """
    end

    for {root, mod} <- locators,
        not (is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, :locate, 1)) do
      raise ArgumentError,
            "locator for #{inspect(root)} (#{inspect(mod)}) does not implement " <>
              "Arca.Storage.UnitLocator"
    end

    :persistent_term.put(@key, locators)
    locators
  end

  @doc """
  Erase the installed registry, leaving the port as boot found it. The
  inverse of `install!/1`, for a test that installs one of its own.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The installed registry. Raises `Arca.Storage.UnitLocator.NotInstalledError`
  when there is none: a path the storage layer cannot place is not a path
  outside every unit.
  """
  @spec impl!() :: registry()
  def impl! do
    case :persistent_term.get(@key, nil) do
      nil -> raise NotInstalledError
      locators -> locators
    end
  end

  @doc """
  The row key of a unit path: its seeded root, and the rest of the path
  joined with `/`.

  ## Examples

      iex> Arca.Storage.UnitLocator.unit_key(["aqua", "roles", "scribe.md"])
      {"aqua", "roles/scribe.md"}
  """
  @spec unit_key(Arca.Storage.path()) :: {root :: String.t(), unit_key :: String.t()}
  def unit_key([root | [_ | _] = rest]) when is_binary(root), do: {root, Enum.join(rest, "/")}

  @doc """
  The unit path a row key names — the inverse of `unit_key/1`.

  ## Examples

      iex> Arca.Storage.UnitLocator.unit_path("aqua", "roles/scribe.md")
      ["aqua", "roles", "scribe.md"]
  """
  @spec unit_path(String.t(), String.t()) :: Arca.Storage.path()
  def unit_path(root, unit_key) when is_binary(root) and is_binary(unit_key),
    do: [root | String.split(unit_key, "/")]

  @doc """
  The staging area of a whole root: what every unit's staging prefix
  under it starts with.

  ## Examples

      iex> Arca.Storage.UnitLocator.staging_area("aqua")
      ["aqua", ".staging"]
  """
  @spec staging_area(String.t()) :: Arca.Storage.path()
  def staging_area(root) when is_binary(root), do: [root, @staging]

  @doc """
  The prefix every revision of a unit is staged under.

  ## Examples

      iex> Arca.Storage.UnitLocator.staging_prefix(["aqua", "skills", "pdf"])
      ["aqua", ".staging", "skills", "pdf"]
  """
  @spec staging_prefix(Arca.Storage.path()) :: Arca.Storage.path()
  def staging_prefix([root | [_ | _] = rest]), do: [root, @staging | rest]

  @doc """
  Where a reader finds a path at or inside a unit, for the unit's shape
  as `locate/1` answered it and the revision the row names: the object
  under that revision's prefix. A directory unit's own path is the prefix
  itself; a file unit's own path is its one object, and a path below a
  file unit is below that object, where no adapter has anything.

  ## Examples

      iex> Arca.Storage.UnitLocator.in_revision({:dir, ["aqua", "skills", "pdf"], "SKILL.md"}, "rev_1", ["aqua", "skills", "pdf", "SKILL.md"])
      ["aqua", ".staging", "skills", "pdf", "rev_1", "SKILL.md"]
      iex> Arca.Storage.UnitLocator.in_revision({:file, ["aqua", "roles", "a.md"]}, "rev_1", ["aqua", "roles", "a.md"])
      ["aqua", ".staging", "roles", "a.md", "rev_1", "a.md"]
  """
  @spec in_revision(
          {:file, Arca.Storage.path()} | {:dir, Arca.Storage.path(), String.t()},
          String.t(),
          Arca.Storage.path()
        ) :: Arca.Storage.path()
  def in_revision({:file, unit}, revision, path),
    do: staged_object(unit, revision, []) ++ Enum.drop(path, length(unit))

  def in_revision({:dir, unit, _sentinel}, revision, path),
    do: revision_prefix(unit, revision) ++ Enum.drop(path, length(unit))

  @doc """
  The inverse of `in_revision/3`: a key listed under the revision's prefix
  as the unit's own path.

  ## Examples

      iex> Arca.Storage.UnitLocator.from_revision({:dir, ["aqua", "skills", "pdf"], "SKILL.md"}, "rev_1", ["aqua", ".staging", "skills", "pdf", "rev_1", "SKILL.md"])
      ["aqua", "skills", "pdf", "SKILL.md"]
  """
  @spec from_revision(
          {:file, Arca.Storage.path()} | {:dir, Arca.Storage.path(), String.t()},
          String.t(),
          Arca.Storage.path()
        ) :: Arca.Storage.path()
  def from_revision({:file, unit}, _revision, _key), do: unit

  def from_revision({:dir, unit, _sentinel}, revision, key),
    do: unit ++ Enum.drop(key, length(revision_prefix(unit, revision)))

  @doc """
  Where one revision's objects are staged: revision-unique, so a plain
  write under it can never land on another revision's object.

  ## Examples

      iex> Arca.Storage.UnitLocator.revision_prefix(["aqua", "skills", "pdf"], "rev_1")
      ["aqua", ".staging", "skills", "pdf", "rev_1"]
  """
  @spec revision_prefix(Arca.Storage.path(), String.t()) :: Arca.Storage.path()
  def revision_prefix(unit, revision) when is_binary(revision) and revision != "",
    do: staging_prefix(unit) ++ [revision]

  @doc "The name of a revision prefix's in-progress marker."
  @spec marker_name() :: String.t()
  def marker_name, do: @marker

  @doc "The in-progress marker of one revision: the first object under its prefix."
  @spec marker_path(Arca.Storage.path(), String.t()) :: Arca.Storage.path()
  def marker_path(unit, revision), do: revision_prefix(unit, revision) ++ [@marker]

  @doc """
  Where one object of a revision is staged. `relative` is the object's
  path inside a directory unit; a file unit is one object, `[]`, staged
  under the unit's own file name.

  ## Examples

      iex> Arca.Storage.UnitLocator.staged_object(["aqua", "roles", "a.md"], "rev_1", [])
      ["aqua", ".staging", "roles", "a.md", "rev_1", "a.md"]
  """
  @spec staged_object(Arca.Storage.path(), String.t(), Arca.Storage.path()) ::
          Arca.Storage.path()
  def staged_object(unit, revision, []), do: revision_prefix(unit, revision) ++ [List.last(unit)]
  def staged_object(unit, revision, relative), do: revision_prefix(unit, revision) ++ relative

  @doc """
  Whether a path is at or inside a seeded root's staging area. Only a
  seeded root has one: the same name under any other root is content.
  """
  @spec staging?(Arca.Storage.path()) :: boolean()
  def staging?([root, @staging | _rest]), do: root in Arca.Storage.overlay_roots()
  def staging?(_path), do: false
end
