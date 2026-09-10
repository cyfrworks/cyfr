# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaPath do
  @moduledoc """
  Path construction for the athanor's AQUA tree — the `aqua/` tenant
  scope's one spelling, as `Compendium.ComponentPath` is for `components/`
  and `Arca.ConversationStorage.blob_root/1` for `conversations/`.

  The tree holds one soul, a flat closet of roles, and the scrolls
  (`locate/1` is the grammar the overlay consults, via
  `Arca.Storage.UnitLocator`):

      aqua/
      ├── aqua.md                 # the soul — the one assistant an estate has
      ├── roles/<name>.md         # one frontmatter-markdown file per role
      └── skills/<name>/SKILL.md  # one Agent Skills package per scroll

  The soul's name is reserved: `aqua` is the file at the root and never a
  role, so `agent_file/1` is the one router from a name to its file.
  Layout only — the file format is `Compendium.AquaAgent`'s, the reset and
  drift surfaces `Compendium.AquaTemplate`'s.
  """

  @behaviour Arca.Storage.UnitLocator

  @root ["aqua"]
  @root_name hd(@root)
  @soul "aqua"
  @soul_file @soul <> ".md"
  @roles "roles"
  @skills "skills"
  @skill_manifest "SKILL.md"
  # The directory an earlier tree shape kept its agents in. Nothing reads
  # it; it is recognised as a unit so `reset all` can drop a stale shadow
  # an estate wrote there before the shape changed.
  @legacy_agents "agents"

  # The one grammar for role and scroll names — the tool boundary
  # (`Compendium.MCP.AquaTool.validate_name`) and the unit locator both
  # speak it, so a name the tools refuse can never mint a unit.
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

  @doc """
  Whether `name` is a valid role or scroll name.

  ## Examples

      iex> Compendium.AquaPath.valid_name?("aqua_web")
      true

      iex> Compendium.AquaPath.valid_name?("../escape")
      false

  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and name =~ @name_format

  @doc """
  The scope root, for whole-tree operations.

  ## Examples

      iex> Compendium.AquaPath.root()
      ["aqua"]

  """
  @spec root() :: [String.t()]
  def root, do: @root

  @doc "The soul's reserved name."
  @spec soul_name() :: String.t()
  def soul_name, do: @soul

  @doc """
  Whether `name` is the soul's — reserved, never a role.

  ## Examples

      iex> Compendium.AquaPath.soul?("aqua")
      true

      iex> Compendium.AquaPath.soul?("aqua_web")
      false

  """
  @spec soul?(term()) :: boolean()
  def soul?(name), do: name == @soul

  @doc """
  The soul file — a shadow unit of its own, at the root of the tree.

  ## Examples

      iex> Compendium.AquaPath.soul_file()
      ["aqua", "aqua.md"]

  """
  @spec soul_file() :: [String.t()]
  def soul_file, do: @root ++ [@soul_file]

  @doc """
  The roles directory — the closet.

  ## Examples

      iex> Compendium.AquaPath.roles_root()
      ["aqua", "roles"]

  """
  @spec roles_root() :: [String.t()]
  def roles_root, do: @root ++ [@roles]

  @doc """
  The bare roles directory name — for consumers rooted elsewhere (the
  seed side reads `seed_prefix("aqua") ++ [roles_dirname()]`).

  ## Examples

      iex> Compendium.AquaPath.roles_dirname()
      "roles"

  """
  @spec roles_dirname() :: String.t()
  def roles_dirname, do: @roles

  @doc """
  The directory an earlier tree shape kept its agents in. Nothing reads
  it; `locate/1` still recognises a file there as a unit so `reset all`
  can drop a stale shadow, and the seed side uses the name to keep such a
  directory out of what the template is said to ship.

  ## Examples

      iex> Compendium.AquaPath.legacy_agents_dirname()
      "agents"

  """
  @spec legacy_agents_dirname() :: String.t()
  def legacy_agents_dirname, do: @legacy_agents

  @doc """
  One role's file — a shadow unit of its own.

  ## Examples

      iex> Compendium.AquaPath.role_file("aqua_web")
      ["aqua", "roles", "aqua_web.md"]

  """
  @spec role_file(String.t()) :: [String.t()]
  def role_file(name) when is_binary(name), do: @root ++ [@roles, name <> ".md"]

  @doc """
  The file an agent name lives in: the soul at the root for `aqua`, a
  role under `roles/` for any other name. One router, so a read of the
  soul cannot miss it by looking in the closet.

  ## Examples

      iex> Compendium.AquaPath.agent_file("aqua")
      ["aqua", "aqua.md"]

      iex> Compendium.AquaPath.agent_file("aqua_web")
      ["aqua", "roles", "aqua_web.md"]

  """
  @spec agent_file(String.t()) :: [String.t()]
  def agent_file(@soul), do: soul_file()
  def agent_file(name) when is_binary(name), do: role_file(name)

  @doc """
  The skills directory — the scrolls.

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
  the soul and each role are file-shaped units (a valid-named `.md`
  file), a skill a valid-named directory unit sentinel'd by `SKILL.md`. A
  unit is a claim the storage layer acts on — the shipped copy, origin
  and edit marks, status — so only the grammar mints one: a
  stray `roles/notes.txt` or a junk-named skill dir stays plain storage,
  outside the roster and the reset bookkeeping.

  ## Examples

      iex> Compendium.AquaPath.locate(["aqua", "aqua.md"])
      {:file, ["aqua", "aqua.md"]}

      iex> Compendium.AquaPath.locate(["aqua", "roles", "aqua_web.md"])
      {:file, ["aqua", "roles", "aqua_web.md"]}

      iex> Compendium.AquaPath.locate(["aqua", "skills", "pdf-forms", "helpers", "fill.md"])
      {:dir, ["aqua", "skills", "pdf-forms"], "SKILL.md"}

      iex> Compendium.AquaPath.locate(["aqua", "roles"])
      :above_unit

      iex> Compendium.AquaPath.locate(["aqua", "roles", "notes.txt"])
      :above_unit

  """
  @impl Arca.Storage.UnitLocator
  def locate([@root_name, @soul_file | _rest]), do: {:file, soul_file()}

  def locate([@root_name, dir, file | _rest]) when dir in [@roles, @legacy_agents] do
    if String.ends_with?(file, ".md") and valid_name?(Path.basename(file, ".md")) do
      {:file, @root ++ [dir, file]}
    else
      :above_unit
    end
  end

  def locate([@root_name, @skills, name | _rest]) do
    if valid_name?(name) do
      {:dir, @root ++ [@skills, name], @skill_manifest}
    else
      :above_unit
    end
  end

  def locate(_path), do: :above_unit
end
