# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaPath do
  @moduledoc """
  Path construction for the athanor's Aqua tree — the `aqua/` tenant
  scope's one spelling, as `Compendium.ComponentPath` is for `components/`
  and `Arca.ThreadStorage.blob_root/1` for `threads/`.

  The tree holds one soul, the athanor's rules file, the crew, and the
  packs of scrolls (`locate/1` is the grammar the overlay consults, via
  `Arca.Storage.UnitLocator`):

      aqua/
      ├── aqua.md                    # the soul — the one assistant an athanor has
      ├── rules.md                   # the rules every brain's instructions carry
      ├── crew/<name>.md             # one frontmatter-markdown file per crew member
      └── scrolls/<pack>/            # one pack, as its author published it
          ├── .cyfr-pack.json        # CYFR's record of the pack (`Compendium.Packs`)
          └── skills/<folder>/SKILL.md   # one Agent Skills package per scroll

  A pack is one directory unit committed whole (`commits_whole?/1`): every
  write inside it is a new revision of the pack, and its record, the
  unit's sentinel, is written by `Compendium.Packs` alone, which also
  answers what an ordinary write may make of a pack (`admit_edit/4`).

  The soul's name is reserved: `aqua` is the file at the root and never a
  crew member, so `agent_file/1` is the one router from a name to its
  file.
  Layout only — the file format is `Compendium.AquaAgent`'s, the reset and
  drift surfaces `Compendium.AquaTemplate`'s.
  """

  @behaviour Arca.Storage.UnitLocator

  @root ["aqua"]
  @root_name hd(@root)
  # The soul's reserved name is `Prima.AgentRef`'s: the consent source ref
  # `agent:local.aqua` and the file at the root of the tree are one name.
  @soul Prima.AgentRef.soul_name()
  @soul_file @soul <> ".md"
  @rules_file "rules.md"
  @crew "crew"
  @scrolls "scrolls"
  @skills "skills"
  @skill_manifest "SKILL.md"
  @record ".cyfr-pack.json"
  # The one grammar for crew, pack and scroll names — the tool boundary
  # (`Compendium.Providers.Aqua.validate_name`) and the unit locator both
  # speak it, so a name the tools refuse can never mint a unit.
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

  @doc """
  Whether `name` is a valid crew member or scroll name.

  ## Examples

      iex> Compendium.AquaPath.valid_name?("web")
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
  defdelegate soul_name(), to: Prima.AgentRef

  @doc """
  Whether `name` is the soul's — reserved, never a crew member.

  ## Examples

      iex> Compendium.AquaPath.soul?("aqua")
      true

      iex> Compendium.AquaPath.soul?("web")
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
  The athanor's rules file — a shadow unit of its own beside the soul,
  plain text that every brain's instructions carry (`Aqua.Prompt`).

  ## Examples

      iex> Compendium.AquaPath.rules_file()
      ["aqua", "rules.md"]

  """
  @spec rules_file() :: [String.t()]
  def rules_file, do: @root ++ [@rules_file]

  @doc """
  The crew directory.

  ## Examples

      iex> Compendium.AquaPath.crew_root()
      ["aqua", "crew"]

  """
  @spec crew_root() :: [String.t()]
  def crew_root, do: @root ++ [@crew]

  @doc """
  The bare crew directory name — for consumers rooted elsewhere (the
  seed side reads `seed_prefix("aqua") ++ [crew_dirname()]`).

  ## Examples

      iex> Compendium.AquaPath.crew_dirname()
      "crew"

  """
  @spec crew_dirname() :: String.t()
  def crew_dirname, do: @crew

  @doc """
  One crew member's file — a shadow unit of its own.

  ## Examples

      iex> Compendium.AquaPath.crew_file("explorer")
      ["aqua", "crew", "explorer.md"]

  """
  @spec crew_file(String.t()) :: [String.t()]
  def crew_file(name) when is_binary(name), do: @root ++ [@crew, name <> ".md"]

  @doc """
  The file an agent name lives in: the soul at the root for `aqua`, a
  crew member under `crew/` for any other name. One router, so a read of
  the soul cannot miss it by looking in the crew.

  ## Examples

      iex> Compendium.AquaPath.agent_file("aqua")
      ["aqua", "aqua.md"]

      iex> Compendium.AquaPath.agent_file("explorer")
      ["aqua", "crew", "explorer.md"]

  """
  @spec agent_file(String.t()) :: [String.t()]
  def agent_file(@soul), do: soul_file()
  def agent_file(name) when is_binary(name), do: crew_file(name)

  @doc """
  The packs' directory.

  ## Examples

      iex> Compendium.AquaPath.scrolls_root()
      ["aqua", "scrolls"]

  """
  @spec scrolls_root() :: [String.t()]
  def scrolls_root, do: @root ++ [@scrolls]

  @doc """
  One pack's directory — a unit of its own, committed whole.

  ## Examples

      iex> Compendium.AquaPath.pack_dir("mine")
      ["aqua", "scrolls", "mine"]

  """
  @spec pack_dir(String.t()) :: [String.t()]
  def pack_dir(pack) when is_binary(pack), do: @root ++ [@scrolls, pack]

  @doc "The pack record's reserved name, the unit's sentinel, at a pack's root."
  @spec record_name() :: String.t()
  def record_name, do: @record

  @doc "The folder inside a pack that holds its scrolls, as Agent Skills lays them out."
  @spec skills_dirname() :: String.t()
  def skills_dirname, do: @skills

  @doc "A scroll's manifest filename."
  @spec skill_manifest_name() :: String.t()
  def skill_manifest_name, do: @skill_manifest

  @doc """
  One scroll's folder inside its pack.

  ## Examples

      iex> Compendium.AquaPath.scroll_dir("mine", "research")
      ["aqua", "scrolls", "mine", "skills", "research"]

  """
  @spec scroll_dir(String.t(), String.t()) :: [String.t()]
  def scroll_dir(pack, folder) when is_binary(pack) and is_binary(folder),
    do: pack_dir(pack) ++ [@skills, folder]

  @doc """
  One scroll's manifest.

  ## Examples

      iex> Compendium.AquaPath.scroll_manifest("mine", "research")
      ["aqua", "scrolls", "mine", "skills", "research", "SKILL.md"]

  """
  @spec scroll_manifest(String.t(), String.t()) :: [String.t()]
  def scroll_manifest(pack, folder), do: scroll_dir(pack, folder) ++ [@skill_manifest]

  @doc """
  The overlay's unit grammar for `aqua/` (`Arca.Storage.UnitLocator`):
  the soul, the rules file and each crew member are file-shaped units (a
  valid-named `.md` file), a pack a valid-named directory unit sentinel'd
  by its record. A unit is a claim the storage layer acts on — the shipped
  copy, the lock, status — so only the grammar mints one: a stray
  `crew/notes.txt` or a junk-named pack folder stays plain storage, outside
  the roster and the reset bookkeeping.

  ## Examples

      iex> Compendium.AquaPath.locate(["aqua", "aqua.md"])
      {:file, ["aqua", "aqua.md"]}

      iex> Compendium.AquaPath.locate(["aqua", "rules.md"])
      {:file, ["aqua", "rules.md"]}

      iex> Compendium.AquaPath.locate(["aqua", "crew", "explorer.md"])
      {:file, ["aqua", "crew", "explorer.md"]}

      iex> Compendium.AquaPath.locate(["aqua", "scrolls", "mine", "skills", "pdf", "SKILL.md"])
      {:dir, ["aqua", "scrolls", "mine"], ".cyfr-pack.json"}

      iex> Compendium.AquaPath.locate(["aqua", "crew"])
      :above_unit

      iex> Compendium.AquaPath.locate(["aqua", "crew", "notes.txt"])
      :above_unit

  """
  @impl Arca.Storage.UnitLocator
  def locate([@root_name, @soul_file | _rest]), do: {:file, soul_file()}
  def locate([@root_name, @rules_file | _rest]), do: {:file, rules_file()}

  def locate([@root_name, @crew, file | _rest]) do
    if String.ends_with?(file, ".md") and valid_name?(Path.basename(file, ".md")) do
      {:file, @root ++ [@crew, file]}
    else
      :above_unit
    end
  end

  def locate([@root_name, @scrolls, pack | _rest]) do
    if valid_name?(pack) do
      {:dir, pack_dir(pack), @record}
    else
      :above_unit
    end
  end

  def locate(_path), do: :above_unit

  # A crew member, the soul or the rules file is created by writing its own
  # file: the write of the unit's one file is its commit. A pack is made by the write of
  # any file under its folder, through `admit_edit/4`.
  @impl Arca.Storage.UnitLocator
  def creates_by_write?(_unit), do: true

  # A pack is committed whole by every write; the soul, the rules file and
  # a crew member are one file each.
  @impl Arca.Storage.UnitLocator
  def commits_whole?([@root_name, @scrolls, _pack]), do: true
  def commits_whole?(_unit), do: false

  # What an ordinary write may make of a pack is the pack's own rule.
  @impl Arca.Storage.UnitLocator
  def admit_edit(actor, unit, current, next),
    do: Compendium.Packs.admit_edit(actor, unit, current, next)
end
