# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Storage.UnitLocator do
  @moduledoc """
  How an overlaid root's shadow units are shaped — answered from the path
  grammar alone, by the domain module that owns the root's spelling
  (`Compendium.ComponentPath` for `components/`, `Compendium.AquaPath` for
  `aqua/`), wired through the `:overlay_locators` config so `Arca` never
  gains a compile edge on Compendium.

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
  `unit_key/1`. Its objects have two homes, both spelled here and nowhere
  else:

    * the **served location** (`served_path/1`) is the unit's own path,
      where every reader of the tree reads;
    * a **revision prefix** (`revision_prefix/2`) is where one revision's
      objects are staged before the row's commit names it:
      `{root}/.staging/{unit…}/{revision}/`, beside the units and never
      inside one. No locator's grammar claims `.staging`, so the prefix
      locates `:above_unit`: status walks skip it and no unit's listing
      or diff sees it. A revision's first object is its in-progress
      marker (`marker_path/2`), created before any upload.

  After the commit the staged objects are moved to the served location
  and the prefix is removed; a prefix that still holds objects is a
  staging in progress, a loser's remains, or a commit whose move has not
  finished — only the row says which.
  """

  @callback locate(Arca.Storage.path()) ::
              :above_unit
              | {:file, unit :: Arca.Storage.path()}
              | {:dir, unit :: Arca.Storage.path(), sentinel :: String.t()}

  @staging ".staging"
  @marker ".in-progress"

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

  @doc "Where readers read a unit: the unit's own path."
  @spec served_path(Arca.Storage.path()) :: Arca.Storage.path()
  def served_path([_root | [_ | _]] = unit), do: unit

  @doc """
  The prefix every revision of a unit is staged under.

  ## Examples

      iex> Arca.Storage.UnitLocator.staging_prefix(["aqua", "skills", "pdf"])
      ["aqua", ".staging", "skills", "pdf"]
  """
  @spec staging_prefix(Arca.Storage.path()) :: Arca.Storage.path()
  def staging_prefix([root | [_ | _] = rest]), do: [root, @staging | rest]

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
