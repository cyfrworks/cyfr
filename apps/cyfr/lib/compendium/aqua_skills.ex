# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaSkills do
  @moduledoc """
  The athanor's scrolls — procedures kept as Agent Skills under
  `aqua/skills/<name>/SKILL.md` (`Compendium.AquaPath`), served through the
  seed overlay like the soul and the crew. A skill is how a job is done,
  for whichever agent does it: the soul and every crew member read the
  same index.

  Shared by the `aqua` tool's `skill_list` and the turn's prompt index.
  Reads the scroll index and individual scroll manifests.

  ## A scroll's bound

  A manifest holds at most `max_bytes/0` bytes, so that one line of the
  brain wire holds it encoded, every byte escaped to at most six; its
  description at most `max_description/0` characters, the most every
  program lists whole. The writer refuses past it
  (`Compendium.Providers.Aqua`), and a scroll stored past it, shipped or
  written before, is carried by no harness (`carried?/2`): a turn's index,
  a chain's read and a job's scrolls leave it out, and the Aqua page says
  why on it.
  """

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Sanctum.Context

  @type entry :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          carried: boolean()
        }

  @typedoc """
  One scroll as a read by name answers it: its name, its description, its
  body as written and its other files' names, and whether a harness
  carries it (`carried?/2`).
  """
  @type scroll :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          body: String.t(),
          files: [String.t()],
          carried: boolean()
        }

  @max_bytes 131_072
  @max_description 1_024

  # The index a turn's prompt carries is bounded — so is the work that
  # builds it: the first N names are read, the rest are counted. The same
  # shape as the notes index (`Aqua.Notes.index/1`).
  @index_limit 40

  @doc "How many scrolls the prompt's index names before it counts the rest."
  @spec index_limit() :: pos_integer()
  def index_limit, do: @index_limit

  @doc "The most bytes a scroll's manifest holds."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most characters a scroll's description holds, counted as code points."
  @spec max_description() :: pos_integer()
  def max_description, do: @max_description

  @doc """
  Whether a manifest of `bytes` bytes describing its scroll as
  `description` is within the bound every harness carries.
  """
  @spec carried?(non_neg_integer(), String.t()) :: boolean()
  def carried?(bytes, description) when is_integer(bytes) and is_binary(description),
    do: bytes <= @max_bytes and length(String.to_charlist(description)) <= @max_description

  @doc """
  One scroll by name, read under the caller's actor: the name's grammar,
  then its manifest, then its other files' names. A name of another
  grammar, or one this athanor has no scroll of, is `{:error,
  :not_found}`, so another athanor's scroll is never found.
  """
  @spec skill(Context.t(), term()) :: {:ok, scroll()} | {:error, term()}
  def skill(%Context{} = ctx, name) do
    with true <- (is_binary(name) and AquaPath.valid_name?(name)) or {:error, :not_found},
         {:ok, binary} <- Arca.get(Sanctum.Context.actor(ctx), AquaPath.skill_manifest(name)),
         {:ok, meta, body} <- AquaAgent.parse_frontmatter(binary) do
      description = string(meta["description"])

      {:ok,
       %{
         name: name,
         title: string(meta["name"]) |> then(&if(&1 == "", do: name, else: &1)),
         description: description,
         body: body,
         files: files(ctx, name),
         carried: carried?(byte_size(binary), description)
       }}
    end
  end

  # The scroll's files beside its manifest, by their paths inside its
  # directory; a listing that cannot be read names none.
  defp files(ctx, name) do
    case Arca.list_recursive(Sanctum.Context.actor(ctx), AquaPath.skill_dir(name)) do
      {:ok, leaves} ->
        leaves
        |> Enum.map(&Enum.drop(&1, length(AquaPath.skill_dir(name))))
        |> Enum.reject(&(&1 == [AquaPath.skill_manifest_name()]))
        |> Enum.map(&Enum.join(&1, "/"))
        |> Enum.sort()

      _unread ->
        []
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  @doc """
  Every scroll as name, title and the one line its manifest describes it
  with, sorted by name, and whether a harness carries it (`carried?/2`). Only a valid-named directory whose `SKILL.md`
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
    with {:ok, entries} <- Arca.list_typed(Sanctum.Context.actor(ctx), AquaPath.skills_root()) do
      names =
        for {name, :dir} <- entries, AquaPath.valid_name?(name), do: name

      {named, rest} =
        case limit do
          :all -> {Enum.sort(names), []}
          n when is_integer(n) -> names |> Enum.sort() |> Enum.split(n)
        end

      scrolls =
        for name <- named,
            {:ok, binary} <- [Arca.get(Sanctum.Context.actor(ctx), AquaPath.skill_manifest(name))],
            {:ok, meta, _body} <- [AquaAgent.parse_frontmatter(binary)] do
          description = string(meta["description"])

          %{
            name: name,
            title: meta["name"] || name,
            description: description,
            carried: carried?(byte_size(binary), description)
          }
        end

      {:ok, %{entries: scrolls, more: length(rest)}}
    end
  end
end
