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
  (`Cyfr.ComponentPath.version_dir/4`, five segments) with a sentinel
  that marks a completed copy; an aqua role is a file unit and an aqua
  skill a directory unit. A path that names neither sits above any unit.
  A refusal the real grammar would make — a malformed name, an unknown
  type — is the domain's to make and is not this double's business.
  """

  defmodule Components do
    @moduledoc "Stands in for `Compendium.ComponentPath` (`components/`)."

    @behaviour Arca.Storage.UnitLocator

    # The version directory is the shadow unit, and the contracts spell it.
    @depth length(Cyfr.ComponentPath.version_dir("catalyst", "local", "n", "1.0.0"))
    @sentinel "cyfr-manifest.json"

    @impl Arca.Storage.UnitLocator
    def locate([_root, type_plural | _rest] = path) when length(path) >= @depth do
      # A unit's second segment is a type's plural, which is what keeps
      # `.staging` — laid beside the units, never inside one — above every
      # unit. The pluralisation is the contracts', read rather than
      # respelled.
      if Cyfr.ComponentPath.type_plural(Cyfr.ComponentPath.singular(type_plural)) ==
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

    # The soul's reserved name is the contracts' (`Cyfr.AgentRef`), which
    # is the same name the real locator reads it from.
    @root "aqua"
    @soul Cyfr.AgentRef.soul_name() <> ".md"
    @skill_manifest "SKILL.md"

    @impl Arca.Storage.UnitLocator
    def locate([@root, @soul | _rest]), do: {:file, [@root, @soul]}

    def locate([@root, "roles", file | _rest]) do
      if String.ends_with?(file, ".md"),
        do: {:file, [@root, "roles", file]},
        else: :above_unit
    end

    def locate([@root, "skills", name | _rest]),
      do: {:dir, [@root, "skills", name], @skill_manifest}

    def locate(_path), do: :above_unit
  end

  @doc "The map `Arca.Storage.install_locators!/0` reads."
  @spec locators() :: %{String.t() => module()}
  def locators, do: %{"components" => Components, "aqua" => Aqua}
end
