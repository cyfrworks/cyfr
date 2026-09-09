# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaSkills do
  @moduledoc """
  The estate's scrolls — procedures kept as Agent Skills under
  `aqua/skills/<name>/SKILL.md` (`Compendium.AquaPath`), served through the
  seed overlay like the soul and the roles.

  Shared by the `aqua` tool's `skill_list` and the turn's prompt index.
  Reads the scroll index and individual scroll manifests.
  """

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  @type entry :: %{name: String.t(), title: String.t(), description: String.t()}

  # The index a turn's prompt carries is bounded — so is the work that
  # builds it: the first N names are read, the rest are counted. The same
  # shape as the notes index (`Aqua.Notes.index/1`).
  @index_limit 40

  @doc "How many scrolls the prompt's index names before it counts the rest."
  @spec index_limit() :: pos_integer()
  def index_limit, do: @index_limit

  @doc """
  Every scroll as name, title and the one line its manifest describes it
  with, sorted by name. Only a valid-named directory whose `SKILL.md`
  parses is a scroll — the tree's grammar is the roster, so a junk-named
  directory or a half-written manifest is plain storage and stays out.
  """
  @spec index(Context.t()) :: {:ok, [entry()]} | {:error, term()}
  def index(%Context{} = ctx) do
    with {:ok, %{entries: entries}} <- index(ctx, :all), do: {:ok, entries}
  end

  @doc """
  The index cut to `limit` entries with a count of the rest —
  `%{entries: [...], more: n}` — reading only the manifests it names.
  `:all` reads them all.
  """
  @spec index(Context.t(), pos_integer() | :all) ::
          {:ok, %{entries: [entry()], more: non_neg_integer()}} | {:error, term()}
  def index(%Context{} = ctx, limit) do
    with {:ok, entries} <- Arca.list_typed(ctx, AquaPath.skills_root()) do
      names =
        for {name, :dir} <- entries, AquaPath.valid_name?(name), do: name

      {named, rest} =
        case limit do
          :all -> {Enum.sort(names), []}
          n when is_integer(n) -> names |> Enum.sort() |> Enum.split(n)
        end

      scrolls =
        for name <- named, {:ok, meta, _body} <- [read_manifest(ctx, name)] do
          %{name: name, title: meta["name"] || name, description: meta["description"] || ""}
        end

      {:ok, %{entries: scrolls, more: length(rest)}}
    end
  end

  @doc """
  One scroll's manifest, split into its frontmatter and body — the Agent
  Skills shape `Compendium.AquaAgent.parse_frontmatter/1` reads.
  """
  @spec read_manifest(Context.t(), String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def read_manifest(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, binary} <- Arca.get(ctx, AquaPath.skill_manifest(name)) do
      AquaAgent.parse_frontmatter(binary)
    end
  end
end
