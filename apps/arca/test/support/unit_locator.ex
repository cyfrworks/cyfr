# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.UnitLocator do
  @moduledoc """
  The unit locators this suite installs, standing in for the domain
  modules that own the two overlaid roots' spellings.

  `Arca.Storage.UnitLocator` is a port: the storage layer must know where
  a unit's bytes begin and end, and cannot know what a component or an
  aqua tree is. `Compendium.ComponentPath` and `Compendium.AquaPath`
  answer it in a deployment; neither exists in a build that holds the
  contracts and Arca alone, so a suite of that build brings its own.

  What it has to be faithful about is the SHAPE the storage layer
  branches on, not the grammar the domain enforces: a components path is
  a directory unit at the version directory the contracts spell
  (`Prima.ComponentPath.version_dir/4`, five segments) with a sentinel
  that marks a completed copy; an aqua crew member is a file unit and an aqua
  pack of scrolls a directory unit committed whole. A path that names
  neither sits above any unit.
  A refusal the real grammar would make — a malformed name, an unknown
  type — is the domain's to make and is not this double's business.
  """

  defmodule Components do
    @moduledoc "Stands in for `Compendium.ComponentPath` (`components/`)."

    @behaviour Arca.Storage.UnitLocator

    # The version directory is the shadow unit, and the contracts spell it.
    @depth length(Prima.ComponentPath.version_dir("catalyst", "local", "n", "1.0.0"))
    @sentinel "cyfr-manifest.json"

    @impl Arca.Storage.UnitLocator
    def locate([_root, type_plural | _rest] = path) when length(path) >= @depth do
      # A unit's second segment is a type's plural, which is what keeps
      # `.staging` — laid beside the units, never inside one — above every
      # unit. The pluralisation is the contracts', read rather than
      # respelled.
      if Prima.ComponentPath.type_plural(Prima.ComponentPath.singular(type_plural)) ==
           type_plural do
        {:dir, Enum.take(path, @depth), @sentinel}
      else
        :above_unit
      end
    end

    def locate(_path), do: :above_unit
  end

  defmodule Aqua do
    @moduledoc "Stands in for `Compendium.AquaPath` (`aqua/`)."

    @behaviour Arca.Storage.UnitLocator

    # The soul's reserved name is the contracts' (`Prima.AgentRef`), which
    # is the same name the real locator reads it from.
    @root "aqua"
    @soul Prima.AgentRef.soul_name() <> ".md"
    @record ".cyfr-pack.json"

    @impl Arca.Storage.UnitLocator
    def locate([@root, @soul | _rest]), do: {:file, [@root, @soul]}

    def locate([@root, "crew", file | _rest]) do
      if String.ends_with?(file, ".md"),
        do: {:file, [@root, "crew", file]},
        else: :above_unit
    end

    def locate([@root, "scrolls", pack | _rest]),
      do: {:dir, [@root, "scrolls", pack], @record}

    def locate(_path), do: :above_unit

    # As the real locator answers: an aqua unit is created by writing its
    # own file; a component (the Components locator says nothing) is not.
    @impl Arca.Storage.UnitLocator
    def creates_by_write?(_unit), do: true

    # A pack is committed whole, and the write of its first file makes it,
    # its record minted; its record is the domain's to write.
    @impl Arca.Storage.UnitLocator
    def commits_whole?([@root, "scrolls", _pack]), do: true
    def commits_whole?(_unit), do: false

    @impl Arca.Storage.UnitLocator
    def admit_edit(_actor, _unit, nil, next),
      do: {:ok, next ++ [{[@record], ~s({"origin": "own", "on": true})}]}

    def admit_edit(_actor, _unit, _current, next), do: {:ok, next}
  end

  @doc "The registry the suites install through `Arca.Storage.UnitLocator.install!/1`."
  @spec locators() :: %{String.t() => module()}
  def locators, do: %{"components" => Components, "aqua" => Aqua}
end
