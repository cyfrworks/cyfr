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

  A manifest holds at most `max_bytes/0` bytes, and a description at most
  `max_description/0` characters, the most every program lists whole; the
  writer refuses past either (`fits?/2`, `Compendium.Providers.Aqua`).
  What a scroll's frame delivers, its name, its body and its other files'
  names (`delivered_bytes/3`), is held to `max_bytes/0` too, so that one
  line of the brain wire holds it encoded, every byte escaped to at most
  six. A scroll past either bound, stored so before or replaced through
  Files, is carried by no harness (`carried` on its read and its index
  entry): a turn's index, a chain's read and a job's scrolls leave it out,
  and the Aqua page says why on it.
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
  body as written and its other files' names, the bytes its frame
  delivers (`delivered_bytes/3`), and whether a harness carries it.
  """
  @type scroll :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          body: String.t(),
          files: [String.t()],
          delivered: non_neg_integer(),
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
  `description` is one the writer keeps: within `max_bytes/0` and
  `max_description/0` characters, counted as code points.
  """
  @spec fits?(non_neg_integer(), String.t()) :: boolean()
  def fits?(bytes, description) when is_integer(bytes) and is_binary(description),
    do: bytes <= @max_bytes and length(String.to_charlist(description)) <= @max_description

  @doc """
  The bytes of what a scroll's frame holds: its name, its body and its
  other files' names, each name with the two bytes that part it from the
  next.
  """
  @spec delivered_bytes(String.t(), String.t(), [String.t()]) :: non_neg_integer()
  def delivered_bytes(name, body, files),
    do: Enum.reduce(files, byte_size(name) + byte_size(body), &(&2 + byte_size(&1) + 2))

  @doc """
  One scroll by name, read under the caller's actor: the name's grammar,
  then its manifest, then its other files' names. A name of another
  grammar, or one this athanor has no scroll of, is `{:error,
  :not_found}`, so another athanor's scroll is never found.
  """
  @spec skill(Context.t(), term()) :: {:ok, scroll()} | {:error, term()}
  def skill(%Context{} = ctx, name) do
    if is_binary(name) and AquaPath.valid_name?(name),
      do: read(ctx, name),
      else: {:error, :not_found}
  end

  # A scroll as read now: its manifest, parsed, its files listed, and
  # whether a harness carries what its frame would deliver.
  defp read(ctx, name) do
    with {:ok, binary} <- Arca.get(Sanctum.Context.actor(ctx), AquaPath.skill_manifest(name)),
         {:ok, meta, body} <- AquaAgent.parse_frontmatter(binary) do
      description = string(meta["description"])
      files = files(ctx, name)
      delivered = delivered_bytes(name, body, files)

      {:ok,
       %{
         name: name,
         title: string(meta["name"]) |> then(&if(&1 == "", do: name, else: &1)),
         description: description,
         body: body,
         files: files,
         delivered: delivered,
         carried: fits?(byte_size(binary), description) and delivered <= @max_bytes
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

  # What an index entry holds of a scroll.
  @entry [:name, :title, :description]

  @doc """
  Every scroll as name, title and the one line its manifest describes it
  with, sorted by name, and whether a harness carries it. Only a
  valid-named directory whose `SKILL.md` parses is a scroll — the tree's
  grammar is the roster, so a junk-named directory or a half-written
  manifest is plain storage and stays out.
  """
  @spec index(Context.t()) :: {:ok, [entry()]} | {:error, term()}
  def index(%Context{} = ctx) do
    with {:ok, %{entries: entries}} <- index(ctx, :all), do: {:ok, entries}
  end

  @doc """
  The index cut to `limit` entries with a count of the names not read —
  `%{entries: [...], more: n}`. A cut index holds only scrolls a harness
  carries, read in name order until `limit` of them are found, so one past
  the bound hides no other; `:all` reads every one, each with whether it
  is carried.
  """
  @spec index(Context.t(), pos_integer() | :all) ::
          {:ok, %{entries: [entry()], more: non_neg_integer()}} | {:error, term()}
  def index(%Context{} = ctx, limit) do
    with {:ok, entries} <- Arca.list_typed(Sanctum.Context.actor(ctx), AquaPath.skills_root()) do
      names = Enum.sort(for {name, :dir} <- entries, AquaPath.valid_name?(name), do: name)

      case limit do
        :all ->
          {:ok, %{entries: Enum.flat_map(names, &entry(ctx, &1)), more: 0}}

        n when is_integer(n) ->
          {kept, more} = carried(ctx, names, n, [], @entry)
          {:ok, %{entries: kept, more: more}}
      end
    end
  end

  @doc """
  The scrolls a turn hands its harness (`work.scrolls`): the index as
  `index/2` cuts it to `limit`, each scroll with its body as stored, and
  the count of the names not read.
  """
  @spec set(Context.t(), pos_integer()) ::
          {:ok,
           %{
             entries: [%{name: String.t(), description: String.t(), body: String.t()}],
             more: non_neg_integer()
           }}
          | {:error, term()}
  def set(%Context{} = ctx, limit) when is_integer(limit) and limit > 0 do
    with {:ok, entries} <- Arca.list_typed(Sanctum.Context.actor(ctx), AquaPath.skills_root()) do
      names = Enum.sort(for {name, :dir} <- entries, AquaPath.valid_name?(name), do: name)
      {kept, more} = carried(ctx, names, limit, [], [:name, :description, :body])
      {:ok, %{entries: Enum.map(kept, &Map.delete(&1, :carried)), more: more}}
    end
  end

  defp carried(_ctx, names, 0, kept, _fields), do: {Enum.reverse(kept), length(names)}
  defp carried(_ctx, [], _left, kept, _fields), do: {Enum.reverse(kept), 0}

  defp carried(ctx, [name | names], left, kept, fields) do
    case entry(ctx, name, fields) do
      [%{carried: true} = entry] -> carried(ctx, names, left - 1, [entry | kept], fields)
      _past_or_unread -> carried(ctx, names, left, kept, fields)
    end
  end

  defp entry(ctx, name, fields \\ @entry) do
    case read(ctx, name) do
      {:ok, scroll} -> [Map.take(scroll, [:carried | fields])]
      {:error, _unread} -> []
    end
  end
end
