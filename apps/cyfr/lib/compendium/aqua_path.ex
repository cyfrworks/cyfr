# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaPath do
  @moduledoc """
  Path construction for the athanor's AQUA tree — the `aqua/` tenant
  scope's one spelling, as `Compendium.ComponentPath` is for `components/`
  and `Arca.ConversationStorage.blob_root/1` for `conversations/`.

  The tree holds two kinds of shadow unit (`locate/1` is the grammar the
  overlay consults, via `Arca.Storage.UnitLocator`):

      aqua/
      ├── agents/<name>.md        # one frontmatter-markdown file per agent
      └── skills/<name>/SKILL.md  # one Agent Skills package per skill

  Layout only — the file format is `Compendium.AquaAgent`'s, the reset and
  drift surfaces `Compendium.AquaTemplate`'s.
  """

  @behaviour Arca.Storage.UnitLocator

  @root ["aqua"]
  @root_name hd(@root)
  @agents "agents"
  @skills "skills"
  @skill_manifest "SKILL.md"

  @doc """
  The scope root, for whole-tree operations.

  ## Examples

      iex> Compendium.AquaPath.root()
      ["aqua"]

  """
  @spec root() :: [String.t()]
  def root, do: @root

  @doc """
  The agents directory — the roster.

  ## Examples

      iex> Compendium.AquaPath.agents_root()
      ["aqua", "agents"]

  """
  @spec agents_root() :: [String.t()]
  def agents_root, do: @root ++ [@agents]

  @doc """
  One agent's file — a shadow unit of its own.

  ## Examples

      iex> Compendium.AquaPath.agent_file("aqua_web")
      ["aqua", "agents", "aqua_web.md"]

  """
  @spec agent_file(String.t()) :: [String.t()]
  def agent_file(name) when is_binary(name), do: @root ++ [@agents, name <> ".md"]

  @doc """
  The skills directory.

  ## Examples

      iex> Compendium.AquaPath.skills_root()
      ["aqua", "skills"]

  """
  @spec skills_root() :: [String.t()]
  def skills_root, do: @root ++ [@skills]

  @doc """
  One skill's directory — a shadow unit of its own.

  ## Examples

      iex> Compendium.AquaPath.skill_dir("pdf-forms")
      ["aqua", "skills", "pdf-forms"]

  """
  @spec skill_dir(String.t()) :: [String.t()]
  def skill_dir(name) when is_binary(name), do: @root ++ [@skills, name]

  @doc "The skill manifest's filename — the overlay sentinel for `aqua/`."
  @spec skill_manifest_name() :: String.t()
  def skill_manifest_name, do: @skill_manifest

  @doc """
  One skill's manifest.

  ## Examples

      iex> Compendium.AquaPath.skill_manifest("pdf-forms")
      ["aqua", "skills", "pdf-forms", "SKILL.md"]

  """
  @spec skill_manifest(String.t()) :: [String.t()]
  def skill_manifest(name) when is_binary(name), do: skill_dir(name) ++ [@skill_manifest]

  @doc """
  The overlay's unit grammar for `aqua/` (`Arca.Storage.UnitLocator`):
  an agent is a file-shaped unit (the `.md` file itself — a single put
  materializes it), a skill a directory unit sentinel'd by `SKILL.md`.
  Paths outside the two unit grammars — the roots themselves, or a stray
  shape — are above the units.

  ## Examples

      iex> Compendium.AquaPath.locate(["aqua", "agents", "aqua_web.md"])
      {:file, ["aqua", "agents", "aqua_web.md"]}

      iex> Compendium.AquaPath.locate(["aqua", "skills", "pdf-forms", "helpers", "fill.md"])
      {:dir, ["aqua", "skills", "pdf-forms"], "SKILL.md"}

      iex> Compendium.AquaPath.locate(["aqua", "agents"])
      :above_unit

  """
  @impl Arca.Storage.UnitLocator
  def locate([@root_name, @agents, file | _rest]), do: {:file, @root ++ [@agents, file]}

  def locate([@root_name, @skills, name | _rest]),
    do: {:dir, @root ++ [@skills, name], @skill_manifest}

  def locate(_path), do: :above_unit
end
