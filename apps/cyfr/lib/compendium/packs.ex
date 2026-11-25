# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Packs do
  @moduledoc """
  The athanor's packs of scrolls. A pack is a folder of files kept as its
  author made them, at `aqua/scrolls/<pack>/` (`Compendium.AquaPath`), with
  CYFR's record of it at the folder's root (`.cyfr-pack.json`). A scroll is
  a folder of the pack's `skills/` that holds a `SKILL.md`, the Agent
  Skills layout, named `<pack>:<scroll>` wherever CYFR names it.

  ## Where a pack comes from

    * `cyfr`, the scrolls that ship with CYFR, refreshed to the seed's at
      each boot (`settle/2`) and kept as shipped;
    * a pack brought in from an archive the person uploaded, after one
      sheet that says what its scripts reach (`sheet/4`, `bring_in/4`),
      kept exactly as it was taken until an update the person takes;
    * a pack of the person's own, made by the write of its first file
      (`admit_edit/4`): `mine`, which today's scrolls moved into, and any
      other the person names.

  ## One door

  Every change to a pack is a write under `aqua/scrolls/` through the
  overlay's one owner (`Arca.Overlay.edit_unit/4`), a new revision of the
  whole pack. An ordinary write, `Arca.Files`' among them, asks
  `admit_edit/4`: it lands only in a pack of the person's own, within the
  bounds, and a write under a new folder makes a pack of the person's own
  with its record minted. What an ordinary write cannot say, since it
  writes the record or a tree in one commit, is this module's: bringing a
  pack in or updating it, the switch and copying a scroll. Download reads
  the folder. No turn reaches any of it: a turn proposes a scroll, and the
  person's Save writes it (`Compendium.Providers.Aqua`).

  ## The record

  `.cyfr-pack.json` holds the origin (`cyfr`, `brought` or `own`), the
  source (an upload's file name, or none), the folder chosen inside the
  archive, the author's version, whether the pack is switched on, the time
  and the digest the person agreed to, and, for a brought pack and `cyfr`,
  the paths whose executable bit its archive set. No ordinary write reaches
  it, and no archive may carry it at the pack's root. In a pack of the
  person's own a file is executable exactly when its bytes begin with
  `#!`, reckoned from the committed bytes.

  ## The reading T5c consumes

  `pack_digest/2` is the SHA-256 of every pack's name and revision digest
  (the journal's `content_identity`, `Arca.Overlay.content_identity/1`),
  switched off ones included, in name order, read from the rows alone.
  `pack_view/3` answers the packs that digest names and the archive a
  keeper's copy of them is put by (see its doc), or `{:moved, current}`
  when the store has moved on.

  ## A scroll's bound

  A manifest holds at most `max_bytes/0` bytes and a description at most
  `max_description/0` characters. What a scroll's frame delivers, its
  name, its body and its other files' names (`delivered_bytes/3`), is
  held to `max_bytes/0` too. A scroll past either, or a pack past its own
  bounds, is carried by no harness and its card says why.
  """

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Compendium.PackArchive
  alias Sanctum.Context

  @max_bytes 131_072
  @max_description 1_024
  @index_limit 40

  @pack_files 2_048
  @pack_bytes 32 * 1024 * 1024
  @set_files 8_192
  @set_bytes 128 * 1024 * 1024
  @path_bytes 255

  @cyfr "cyfr"
  @mine "mine"
  # What a proposal of a file not there yet is made against.
  @against_none "none"
  # The first entry of a view's `archive`, named as the keeper reads it
  # (its `internal/packview`).
  @archive_manifest ".cyfr-packs.json"
  @origins ~w(cyfr brought own)
  @manifests [
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    ".cursor-plugin/plugin.json"
  ]

  @path_format ~r/\A[A-Za-z0-9_.\-\/]+\z/

  # Every `SKILL.md` the seed shipped under `aqua/skills/<name>/` up to this
  # release, by the name it shipped under, as SHA-256 hex: the migration
  # drops an athanor's scroll only when its name is a shipped name and its
  # bytes are one of the manifests the seed shipped under that name, since
  # `cyfr` carries it; any other, a person's copy under a name of their
  # own among them, moves into `mine`. Generated with
  # `git log --format=%H -- seed/aqua/skills/<name>/SKILL.md` and
  # `git show <commit>:<path> | sha256sum` for every name.
  @shipped_scrolls %{
    "artisan" => MapSet.new(~w(
      13bec2d71f36e43367b53d4c43faf98132850d946767ba7a8b1c0d7bc195e865
      3899ab0ab9af3eefe7c380899d19649eb271cfa39d66186f9f8260d1246514cd
      435b1d3d6e437c75038b3c22e19ae51c7daa84d4fd9cb9c95297b6c61153c415
      57febc03844dde59626b7a544cc9945698f0b9518a360015301cb9d6c1729b4c
      615f1469f10ba71b899142328f51ae28fb9a5ad99e5724316b21d466e070291f
      6b0a6f9e3567add2405eab364f4eb3d906df81bb1b1484fbc505c28ed84416d3
      7eed37ee4ade44549569e06b132aae5ea0dfc7891d396fcc851cd223242ad661
      922bb1be5df5f317b5219a9fc2deadc9cc944c8bcda3106a8803b8051015e2e8
      ad776325c6d5807f506ba4eb8c4fc79fdaa5972a1b99a1c32b3edd8162d9091c
    )),
    "browser" => MapSet.new(~w(
      07a1f3de6b73d936fbc01421edb579177f00c4824127370ff235348e1a18ce3e
      440d225e68dd9bc2fd744b332c402330d0007bbf330f838197dbfbad41248c0a
      4ee383e09a08e1bf4fe8987a12349715041fc572f1dfac59dd771df58b294838
      6f98d77d68a6524b26933a4755cd15d9cad7dfae81218bfa3dc86f9d22c3e093
      82f3d5ecb8d8dd821850406989d55232b1f50e0637962d18c96286256f55262e
      c105be873bccbfb28721e1c598e190e711dd25ac296fe26efe7f45ae025e49d0
      d4f7f2972811b85cc11a5e8c1ed3f9663aad5a175d659a1b1137834f6df64f0d
      d95789603a21677612397e5e455c915cd1ab50f489497d139d88b4849f100e94
    )),
    "builder" => MapSet.new(~w(
      286664b1846ac31a733f2eae84eea96faa7743c3f89000233cfce7fa7b839fce
    )),
    "canvas" => MapSet.new(~w(
      11bd967493cb10eecd0d2b00b85d4289fa3d35d0babb4046d3aa8d0b3694879b
      1441005f19b7e1d99156eb1c57df078b7f6521da2fa131acd7b8191d9393bffc
      182644dda3bdac220cd09629448b57828f4bbc40688994c006f56600016a88f6
      1e02b029aad74a67985817fe46e72914c141b6602968bb9671d7ff7e92df8780
      26d97a54eea4d1503b16e043a9836529eb8e577eee4f66e13d08e9882d18f2e4
      27923f51cffe3eed6403a6846c1c0bb2bfcc01ac6d9b66a8a764f1893da067c3
      358ef5b0f64ccb584940fecf2d162c18175ecec76e30ab640b3c53800b001468
      3e965988630c06df65d8922424acaca8055db728e1b8ba1e4751f2d164725164
      4af16e92541408497d60bebe7f599faf1ddaf23fb0be8754c00c2ce6bdf976ac
      4bc03dc8a157acd36026b4f3ef161641125f1cbcc2c6f302e0ae95d010855eaf
      5125f0a1a501b7b6813287bc7200ca99ded1db64f9953d083bb7c70bb6af457d
      5961410d742a02faca6307ef2bd7eb7605ddc217b51a11e44159635dae0657c3
      6666ca3b6e44cafdcb955a17e59421f398e32881048808ec43b7340aae53652c
      6a4b4285c46f020239db0f01e52ee2a3f2e6f4961e8f460ef38b5fe5b7de0da4
      6ee2f596768c40422b8614d1762b1acf5041d44eeea90c20ced34c6590367d33
      748a3c120a7f9134122986058da12aaf90ac82ec2ccd46490bb3a2c8238ad7ec
      76035857187eb05e499ba470e26f98debc0ef8e83fe8068320c684a6e03031a8
      7d3e7b9789f9639918624dbbf88ab63012a85ba65af2f5ab8f7f002592687d64
      7e0c572e88399ff72c62b9e11dd6af448d6d92912c4cf3d0612674c7581c4635
      852424434cf7dcbf757901a39aaae8b627994af44531bf9fd6c67378c6d8cbff
      92c6d01151b9832edcc31e106e3682bef9dc9ca5cbc138ea58c056029fb91ad1
      991398251e348d98e682a8115d9eb4503219a94f1b4d3d387227ffb7f21adc01
      9bde2bce25acbd0968fdedb440a9f89416ae1c2f2e1368e076e179dc90425d66
      9d675400573f96a483376d47197cddcc61bd8e5c90951db9c684c3b5766b2321
      9f5f4e06f665230c1f61d0ed367463073f44a0be9dfe8bacb5943e8b55e52c08
      a8a5d0aa70003e9114584e61b24128931762cccaa16caa5a6a22d7aa643472fa
      ac0f7bdd5ccf0f2d97cc8c8ad986a81e2e09717c7248f95c478d2cb858662da7
      bffd96fb99179010b3c7f06c0a78afe32285382a59d76a80fe849e01b9f2cdea
      ed01fbe81f93ba7e6b241e9174b21e6bb5cace263e4637dae1b21c346da7f930
      edb3b6253df6422c5b35ad4380232608feb0bc9f078276a24e3aad2f47e433c4
      f1a7bf433d429f773d6a054a8de609afff38a78210e840649f5b9b5fe448c06d
      f3c15e223b4b50aacf57404e09f49ee895bbbbcad49abab1832bab7fced38f6c
      fd1e03c0765c78f8039854f0e19fb6385b79484efa73a63c0a37c7342623daeb
    )),
    "capability-acquisition" => MapSet.new(~w(
      0bd13c1e5b5f1fd0a22168ea3e8fb885f5fef642ac720c95ca6ebbe9e16a2d95
      2e97c82ddcb29c2fd5281a970f602e2958b718427557ae3066e0807941dc8d3f
      59a2e5467dd6c5664f1c90f0bb8e2fe50eff2839311a49ef646129bb337fb4ec
      d11c0453300e117604fc504dd5ca8be0776dbaaff0388b9ac845ae0c2491e15d
      d2cdcb8796f35abc4fa211e1ec60ce692ae8aa9d523f06065f268f584590e9b6
    )),
    "planner" => MapSet.new(~w(
      30d5f282e7c56a3f8958a7995781b8ef6ff76eedc9f6babda9c87341d6ca91d2
      3c78fbbe9de3537308b20c7241d35529f70de34c2a08fb9e9dd6e8a4aa556027
    )),
    "research" => MapSet.new(~w(
      72be2748473c3e8a53f451ca5f5a55165cd8923b95bfcb17dcf267b7d56cc605
    )),
    "web" => MapSet.new(~w(
      06a36e0e1e5a7b07bcb90c6af9338b6594a70f3a58f56ca3d62e0e529394cd67
      0cdc120a41d6afc4abcd23587f988bd4d395f057a5b71a6849c46c2bbcc20ea4
      65fbeb2d9a3e1bdc8746fab33cf87d131c438f00d6f10a533bb621324de79801
      caf4c01ed1bca51f53a36aa8b512daa7095cd0dbb3d15628508d33fe2fb93170
    ))
  }

  @typedoc "A pack's record, as `.cyfr-pack.json` holds it."
  @type pack_record :: %{
          origin: String.t(),
          source: String.t() | nil,
          folder: String.t() | nil,
          version: String.t() | nil,
          on: boolean(),
          agreed_at: String.t() | nil,
          agreed: String.t() | nil,
          executable: [String.t()]
        }

  @typedoc "One scroll of a pack, as the index and the card list it."
  @type entry :: %{
          name: String.t(),
          pack: String.t(),
          scroll: String.t(),
          folder: String.t(),
          title: String.t(),
          description: String.t(),
          carried: boolean(),
          kept: boolean(),
          shadowed: boolean()
        }

  @typedoc "One scroll as a read by name answers it."
  @type scroll :: %{
          name: String.t(),
          pack: String.t(),
          scroll: String.t(),
          folder: String.t(),
          title: String.t(),
          description: String.t(),
          body: String.t(),
          files: [String.t()],
          delivered: non_neg_integer(),
          carried: boolean(),
          kept: boolean()
        }

  # ---------------------------------------------------------------------------
  # Bounds
  # ---------------------------------------------------------------------------

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
  A pack's bounds and the bounds of the packs switched on together: a
  file's (`Arca.Files.max_write/0`) and a pack's name's, a segment of the
  store's path (`Prima.PathSafety.max_segment_bytes/0`), among them.
  """
  @spec bounds() :: %{
          pack_files: pos_integer(),
          pack_bytes: pos_integer(),
          set_files: pos_integer(),
          set_bytes: pos_integer(),
          path_bytes: pos_integer(),
          file_bytes: pos_integer(),
          name_bytes: pos_integer()
        }
  def bounds,
    do: %{
      pack_files: @pack_files,
      pack_bytes: @pack_bytes,
      set_files: @set_files,
      set_bytes: @set_bytes,
      path_bytes: @path_bytes,
      file_bytes: Arca.Files.max_write(),
      name_bytes: Prima.PathSafety.max_segment_bytes()
    }

  @doc """
  Whether a manifest of `bytes` bytes describing its scroll as
  `description` is one the writer keeps.
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

  # ---------------------------------------------------------------------------
  # Names
  # ---------------------------------------------------------------------------

  @doc "CYFR's own pack's name."
  @spec cyfr() :: String.t()
  def cyfr, do: @cyfr

  @doc "The first pack of the person's own's name."
  @spec mine() :: String.t()
  def mine, do: @mine

  @doc """
  A scroll's full name split into its pack and its name, `{:ok, pack,
  scroll}`; `{:bare, name}` for a name of the grammar with no pack;
  `:error` for anything else.
  """
  @spec split_name(term()) :: {:ok, String.t(), String.t()} | {:bare, String.t()} | :error
  def split_name(name) when is_binary(name) do
    case String.split(name, ":") do
      [pack, scroll] ->
        if AquaPath.valid_name?(pack) and AquaPath.valid_name?(scroll),
          do: {:ok, pack, scroll},
          else: :error

      [bare] ->
        if AquaPath.valid_name?(bare), do: {:bare, bare}, else: :error

      _other ->
        :error
    end
  end

  def split_name(_name), do: :error

  @doc "The full name of a pack's scroll."
  @spec full_name(String.t(), String.t()) :: String.t()
  def full_name(pack, scroll), do: pack <> ":" <> scroll

  # ---------------------------------------------------------------------------
  # The record
  # ---------------------------------------------------------------------------

  @doc "A record as `.cyfr-pack.json` holds it: one JSON object, its keys in order."
  @spec encode_record(pack_record()) :: binary()
  def encode_record(record) do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"origin", record.origin},
        {"source", record.source},
        {"folder", record.folder},
        {"version", record.version},
        {"on", record.on},
        {"agreed_at", record.agreed_at},
        {"agreed", record.agreed},
        {"executable", Enum.sort(record.executable)}
      ]),
      pretty: true
    ) <> "\n"
  end

  @doc "A record read from its bytes, or `{:error, :record_invalid}`."
  @spec decode_record(binary()) :: {:ok, pack_record()} | {:error, :record_invalid}
  def decode_record(bytes) when is_binary(bytes) do
    with {:ok, %{"origin" => origin, "on" => on} = map} when origin in @origins and is_boolean(on) <-
           Jason.decode(bytes),
         executable when is_list(executable) <- Map.get(map, "executable", []),
         true <- Enum.all?(executable, &is_binary/1) do
      {:ok,
       %{
         origin: origin,
         source: string_or_nil(map["source"]),
         folder: string_or_nil(map["folder"]),
         version: string_or_nil(map["version"]),
         on: on,
         agreed_at: string_or_nil(map["agreed_at"]),
         agreed: string_or_nil(map["agreed"]),
         executable: executable
       }}
    else
      _invalid -> {:error, :record_invalid}
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  @doc "The record a pack of the person's own is made with: switched on."
  @spec own_record() :: pack_record()
  def own_record,
    do: %{
      origin: "own",
      source: nil,
      folder: nil,
      version: nil,
      on: true,
      agreed_at: nil,
      agreed: nil,
      executable: []
    }

  @doc """
  Whether a pack's file is executable: for a brought pack and `cyfr`, as
  the record names it; in a pack of the person's own, exactly when its
  bytes begin with `#!`.
  """
  @spec executable?(pack_record(), String.t(), binary()) :: boolean()
  def executable?(%{origin: "own"}, _path, bytes), do: match?(<<"#!", _::binary>>, bytes)
  def executable?(%{executable: paths}, path, _bytes), do: path in paths

  # ---------------------------------------------------------------------------
  # Reading the packs
  # ---------------------------------------------------------------------------

  @doc """
  Every pack the athanor holds, switched on or off, in name order, each
  with its record, its files' count and bytes, its scrolls, the parts a
  harness may carry, and why no harness carries it when one does not
  (`past`). A folder whose record cannot be read is listed with `past`
  saying so.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Context{} = ctx) do
    actor = Context.actor(ctx)

    with {:ok, names} <- pack_names(actor) do
      cards = Enum.flat_map(names, &List.wrap(read_pack(actor, &1, :card)))
      verdicts = standing(Enum.map(cards, &card_measured/1))

      {:ok,
       Enum.map(cards, fn card ->
         case verdicts[card.name] do
           {:past_set, sentence} -> %{card | past: sentence}
           _handed_off_or_past -> card
         end
       end)}
    end
  end

  # A card as the set's standing counts it, from the card's own count and
  # bytes: a pack switched on and within its own bounds may be handed.
  defp card_measured(%{name: name, on: on, past: past, files: files, bytes: bytes}) do
    verdict =
      cond do
        not on -> :off
        is_nil(past) -> :handed
        true -> {:withheld, past}
      end

    {name, verdict, files, bytes}
  end

  @doc "One pack by name, as `list/1` lists it, or `{:error, :not_found}`."
  @spec pack(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def pack(%Context{} = ctx, name) do
    if is_binary(name) and AquaPath.valid_name?(name) do
      case read_pack(Context.actor(ctx), name, :card) do
        nil -> {:error, :not_found}
        pack -> {:ok, pack}
      end
    else
      {:error, :not_found}
    end
  end

  defp pack_names(actor) do
    case Arca.list_typed(actor, AquaPath.scrolls_root()) do
      {:ok, entries} ->
        {:ok, Enum.sort(for {name, :dir} <- entries, AquaPath.valid_name?(name), do: name)}

      {:error, :not_found} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  # One pack read from the store: its record, its leaves and its scrolls.
  # `:card` reads every scroll's manifest; `:index` the same, for a pack
  # switched on only.
  defp read_pack(actor, name, purpose) do
    dir = AquaPath.pack_dir(name)

    with {:ok, [_ | _] = leaves} <- Arca.list_recursive(actor, dir) do
      rels = for leaf <- leaves, do: Enum.join(Enum.drop(leaf, length(dir)), "/")
      files = Enum.reject(rels, &(&1 == AquaPath.record_name()))

      {record, past, record_bytes} =
        case Arca.get(actor, dir ++ [AquaPath.record_name()]) do
          {:ok, raw} ->
            case decode_record(raw) do
              {:ok, record} -> {record, nil, byte_size(raw)}
              {:error, _} -> {nil, "its record cannot be read", byte_size(raw)}
            end

          {:error, _} ->
            {nil, "its record cannot be read", 0}
        end

      # The pack's file content, its record left out, as the bounds count it.
      {bytes, unread} =
        case pack_bytes(actor, dir) do
          {:ok, used} -> {max(used - record_bytes, 0), nil}
          :unread -> {0, "its size cannot be read"}
        end

      past = past || unread || pack_past(length(files), bytes)
      scrolls = scrolls_of(actor, name, files, past)

      %{
        name: name,
        record: record,
        origin: record && record.origin,
        on: (record && record.on) || false,
        version: record && record.version,
        source: record && record.source,
        files: length(files),
        bytes: bytes,
        paths: files,
        scrolls: scrolls,
        parts: if(purpose == :card, do: parts(actor, dir, files), else: nil),
        past: past
      }
    else
      # A folder no pack holds any more, or one that cannot be read.
      _empty_or_unread -> nil
    end
  end

  defp pack_bytes(actor, dir) do
    case Arca.usage(actor, dir) do
      {:ok, %{bytes: bytes}} -> {:ok, bytes}
      _unread -> :unread
    end
  end

  defp pack_past(files, _bytes) when files > @pack_files,
    do: "it holds #{files} files, past a pack's #{@pack_files}"

  defp pack_past(_files, bytes) when bytes > @pack_bytes,
    do: "it holds #{bytes} bytes, past a pack's #{@pack_bytes}"

  defp pack_past(_files, _bytes), do: nil

  # The scrolls of a pack: each `skills/<folder>/SKILL.md`, named by its
  # front matter's `name` where that is of the grammar, else by its folder;
  # two of one name, the first by path is the scroll and the other is
  # shadowed.
  defp scrolls_of(actor, pack, files, past) do
    folders =
      for path <- Enum.sort(files),
          [skills, folder, manifest] <- [String.split(path, "/")],
          skills == AquaPath.skills_dirname() and manifest == AquaPath.skill_manifest_name() and
            AquaPath.valid_name?(folder),
          do: folder

    {entries, _seen} =
      Enum.reduce(folders, {[], MapSet.new()}, fn folder, {acc, seen} ->
        case read_scroll(actor, pack, folder, files) do
          {:ok, scroll} ->
            shadowed = MapSet.member?(seen, scroll.scroll)

            entry =
              scroll
              |> Map.take([:name, :pack, :scroll, :folder, :title, :description, :carried, :kept])
              |> Map.put(:shadowed, shadowed)
              |> Map.update!(:carried, &(&1 and is_nil(past) and not shadowed))

            {[entry | acc], MapSet.put(seen, scroll.scroll)}

          {:error, _unread} ->
            {acc, seen}
        end
      end)

    Enum.sort_by(Enum.reverse(entries), &{&1.scroll, &1.folder})
  end

  defp read_scroll(actor, pack, folder, files) do
    with {:ok, binary} <- Arca.get(actor, AquaPath.scroll_manifest(pack, folder)),
         {:ok, meta, body} <- AquaAgent.parse_frontmatter(binary) do
      fm_name = string(meta["name"])
      scroll = own_name(fm_name, folder)
      name = full_name(pack, scroll)
      description = string(meta["description"])
      prefix = AquaPath.skills_dirname() <> "/" <> folder <> "/"

      others =
        for path <- files,
            String.starts_with?(path, prefix),
            rel = String.replace_prefix(path, prefix, ""),
            rel != AquaPath.skill_manifest_name(),
            do: rel

      others = Enum.sort(others)
      delivered = delivered_bytes(name, body, others)

      {:ok,
       %{
         name: name,
         pack: pack,
         scroll: scroll,
         folder: folder,
         title: if(fm_name == "", do: scroll, else: fm_name),
         description: description,
         body: body,
         files: others,
         delivered: delivered,
         carried: fits?(byte_size(binary), description) and delivered <= @max_bytes,
         kept: meta["disable-model-invocation"] == true
       }}
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  # A scroll's own name: its front matter's `name` where that is of the
  # grammar, else its folder's.
  defp own_name(fm_name, folder), do: if(AquaPath.valid_name?(fm_name), do: fm_name, else: folder)

  # What a harness may carry of a pack beyond its scrolls, read from its
  # paths and its manifests: agents, commands, hooks and MCP servers.
  defp parts(actor, dir, files) do
    read = fn rel ->
      case Arca.get(actor, dir ++ String.split(rel, "/")) do
        {:ok, bytes} -> bytes
        _unread -> nil
      end
    end

    parts_of(files, read)
  end

  # Everything Claude Code would load of a pack beyond the scrolls of its
  # `skills/`, read as its plugin manifest reference allows each component
  # key (`.claude-plugin/plugin.json`, the one manifest it reads): its
  # default places (`agents/`, `commands/`, `hooks/hooks.json`, `.mcp.json`)
  # and every form the manifest may declare instead or beside them, a path,
  # a list of paths, an inline object, a file the manifest names. A
  # declaration of a form this reader does not read (an MCP bundle, a key
  # it does not list, a path outside the pack or not there, a file that is
  # not JSON) is named by its key in `unread`, so the sheet says so and is
  # never silent.
  @unlisted_keys ~w(lspServers outputStyles workflows experimental monitors themes channels)

  defp parts_of(files, read) do
    {manifest, unread} =
      if ".claude-plugin/plugin.json" in files do
        case Jason.decode(read.(".claude-plugin/plugin.json") || "") do
          {:ok, %{} = manifest} -> {manifest, []}
          _unreadable -> {%{}, [".claude-plugin/plugin.json"]}
        end
      else
        {%{}, []}
      end

    ctx = %{files: files, read: read}
    {agents, u1} = agents_of(manifest, ctx)
    {commands, u2} = commands_of(manifest, ctx)
    {hooks, u3} = hooks_of(manifest, ctx)
    {servers, u4} = servers_of(manifest, ctx)
    {skills, u5} = extra_skills_of(manifest, ctx)

    unlisted =
      for(key <- @unlisted_keys, Map.has_key?(manifest, key), do: key) ++
        if(".lsp.json" in files and not Map.has_key?(manifest, "lspServers"),
          do: ["lspServers"],
          else: []
        )

    %{
      agents: agents,
      commands: commands,
      hooks: hooks,
      servers: servers,
      skills: skills,
      unread: Enum.uniq(unread ++ u1 ++ u2 ++ u3 ++ u4 ++ u5 ++ unlisted)
    }
  end

  # A manifest's path, `./`-relative to the pack's root (`.` for the root
  # itself where the key allows it): the path inside the pack, or `:error`
  # for one Claude Code does not load (no `./`, a `..`, absolute).
  defp manifest_path(".", true), do: {:ok, ""}
  defp manifest_path("./", true), do: {:ok, ""}

  defp manifest_path("./" <> rel, _root?) do
    rel = String.trim_trailing(rel, "/")
    segments = String.split(rel, "/")

    if rel != "" and not Enum.any?(segments, &(&1 in ["", ".", ".."])),
      do: {:ok, rel},
      else: :error
  end

  defp manifest_path(_path, _root?), do: :error

  defp under(files, ""), do: files

  defp under(files, dir),
    do:
      for(
        f <- files,
        String.starts_with?(f, dir <> "/"),
        do: String.replace_prefix(f, dir <> "/", "")
      )

  defp dir?(files, dir), do: under(files, dir) != []

  # A key's value as a list of its entries: a path, or a list of them.
  defp entries(value) when is_list(value), do: value
  defp entries(value), do: [value]

  defp md_name(path), do: String.replace_suffix(path, ".md", "")

  # Agents: the manifest's `.md` files, which replace `agents/`; else every
  # `.md` under `agents/`, its subfolders part of the name.
  defp agents_of(%{"agents" => declared}, %{files: files}) do
    Enum.reduce(entries(declared), {[], []}, fn entry, {names, unread} ->
      with true <- is_binary(entry),
           {:ok, rel} <- manifest_path(entry, false),
           true <- String.ends_with?(rel, ".md") and rel in files do
        {names ++ [md_name(Path.basename(rel))], unread}
      else
        _form -> {names, unread ++ ["agents"]}
      end
    end)
    |> sorted()
  end

  defp agents_of(_manifest, %{files: files}) do
    {for(f <- under(files, "agents"), String.ends_with?(f, ".md"), do: md_name(f)), []}
    |> sorted()
  end

  # Commands: the manifest's paths (a flat `.md` file, or a folder of them)
  # or its map of name to `source` or `content`, which replace `commands/`;
  # else the `.md` files directly in `commands/`.
  defp commands_of(%{"commands" => declared}, ctx) when is_map(declared) do
    Enum.reduce(declared, {[], []}, fn
      {name, %{"content" => content}}, {names, unread} when is_binary(content) ->
        {names ++ [name], unread}

      {name, %{"source" => source}}, {names, unread} when is_binary(source) ->
        case manifest_path(source, false) do
          {:ok, rel} ->
            if rel in ctx.files,
              do: {names ++ [name], unread},
              else: {names, unread ++ ["commands"]}

          :error ->
            {names, unread ++ ["commands"]}
        end

      _entry, {names, unread} ->
        {names, unread ++ ["commands"]}
    end)
    |> sorted()
  end

  defp commands_of(%{"commands" => declared}, %{files: files}) do
    Enum.reduce(entries(declared), {[], []}, fn entry, {names, unread} ->
      with true <- is_binary(entry),
           {:ok, rel} <- manifest_path(entry, false) do
        cond do
          String.ends_with?(rel, ".md") and rel in files ->
            {names ++ [md_name(Path.basename(rel))], unread}

          dir?(files, rel) ->
            {names ++ flat_md(under(files, rel)), unread}

          true ->
            {names, unread ++ ["commands"]}
        end
      else
        _form -> {names, unread ++ ["commands"]}
      end
    end)
    |> sorted()
  end

  defp commands_of(_manifest, %{files: files}),
    do: sorted({flat_md(under(files, "commands")), []})

  defp flat_md(rels),
    do:
      for(
        rel <- rels,
        not String.contains?(rel, "/"),
        String.ends_with?(rel, ".md"),
        do: md_name(rel)
      )

  # Hooks, by their events: `hooks/hooks.json` (the event map under a
  # top-level `"hooks"`) merged with the manifest's file paths (the same
  # shape), inline event maps (no wrapper), or a list mixing both.
  defp hooks_of(manifest, %{files: files, read: read}) do
    default =
      if "hooks/hooks.json" in files,
        do: [hooks_file(read.("hooks/hooks.json"))],
        else: []

    declared =
      case manifest do
        %{"hooks" => value} ->
          for entry <- entries(value) do
            cond do
              is_map(entry) ->
                events(entry)

              is_binary(entry) ->
                case manifest_path(entry, false) do
                  {:ok, rel} -> if rel in files, do: hooks_file(read.(rel)), else: :unread
                  :error -> :unread
                end

              true ->
                :unread
            end
          end

        _none ->
          []
      end

    gathered(default ++ declared, "hooks")
  end

  defp hooks_file(bytes) do
    case Jason.decode(bytes || "") do
      {:ok, %{"hooks" => hooks}} when is_map(hooks) -> events(hooks)
      _unread -> :unread
    end
  end

  defp events(map) when is_map(map) do
    if Enum.all?(map, fn {_event, handlers} -> is_list(handlers) end),
      do: {:ok, Map.keys(map)},
      else: :unread
  end

  # MCP servers, by name: `.mcp.json` (a map under `"mcpServers"`) merged
  # with the manifest's `.json` file paths, inline maps of name to config,
  # or a list mixing them. An MCP bundle (`.mcpb`, `.dxt`, a path or an
  # address) is a form this reader does not open.
  defp servers_of(manifest, %{files: files, read: read}) do
    default = if ".mcp.json" in files, do: [servers_file(read.(".mcp.json"))], else: []

    declared =
      case manifest do
        %{"mcpServers" => value} ->
          for entry <- entries(value) do
            cond do
              is_map(entry) ->
                server_map(entry)

              is_binary(entry) ->
                case manifest_path(entry, false) do
                  {:ok, rel} ->
                    if String.ends_with?(rel, ".json") and rel in files,
                      do: servers_file(read.(rel)),
                      else: :unread

                  :error ->
                    :unread
                end

              true ->
                :unread
            end
          end

        _none ->
          []
      end

    gathered(default ++ declared, "mcpServers")
  end

  defp servers_file(bytes) do
    case Jason.decode(bytes || "") do
      {:ok, %{"mcpServers" => servers}} when is_map(servers) -> server_map(servers)
      {:ok, %{} = servers} -> server_map(servers)
      _unread -> :unread
    end
  end

  defp server_map(map) do
    if Enum.all?(map, fn {_name, config} -> is_map(config) end),
      do: {:ok, Map.keys(map)},
      else: :unread
  end

  # Skills beyond `skills/`: each folder the manifest's `skills` names (a
  # folder of `<name>/SKILL.md` folders, or one holding `SKILL.md`), which
  # add to the default scan; a pack with `SKILL.md` at its root and no
  # `skills/` loads as one skill.
  defp extra_skills_of(manifest, %{files: files}) do
    declared =
      case manifest do
        %{"skills" => value} ->
          for entry <- entries(value) do
            with true <- is_binary(entry),
                 {:ok, rel} <- manifest_path(entry, true),
                 true <- rel == "" or dir?(files, rel) do
              {:ok, skills_in(files, rel)}
            else
              _form -> :unread
            end
          end

        _none ->
          []
      end

    lone =
      if "SKILL.md" in files and not dir?(files, "skills") and
           not Map.has_key?(manifest, "skills"),
         do: [{:ok, ["SKILL.md"]}],
         else: []

    gathered(lone ++ declared, "skills")
  end

  defp skills_in(files, rel) do
    prefix = if rel == "", do: "", else: rel <> "/"

    for f <- files,
        String.starts_with?(f, prefix),
        rest = String.replace_prefix(f, prefix, ""),
        rest == "SKILL.md" or match?([_name, "SKILL.md"], String.split(rest, "/")),
        not String.starts_with?(f, "skills/"),
        do: f
  end

  defp gathered(found, key) do
    {names, unread} =
      Enum.reduce(found, {[], []}, fn
        {:ok, names}, {acc, unread} -> {acc ++ names, unread}
        :unread, {acc, _unread} -> {acc, [key]}
      end)

    {Enum.sort(Enum.uniq(names)), unread}
  end

  defp sorted({names, unread}), do: {Enum.sort(Enum.uniq(names)), Enum.uniq(unread)}

  # ---------------------------------------------------------------------------
  # Scrolls by name: the index, a read, a file
  # ---------------------------------------------------------------------------

  @doc """
  Every scroll of the packs switched on, as name, title and description,
  in full-name order, each with whether a harness carries it and whether
  its author kept it from the model.
  """
  @spec index(Context.t()) :: {:ok, [entry()]} | {:error, term()}
  def index(%Context{} = ctx) do
    with {:ok, %{entries: entries}} <- index(ctx, :all), do: {:ok, entries}
  end

  @doc """
  The index cut to `limit` entries with a count of the names not read —
  `%{entries: [...], more: n}`. A cut index is what a model reads: only
  scrolls a harness carries and their authors did not keep from the
  model, read in name order until `limit` of them are found. `:all` lists
  every scroll of the packs switched on, each with its flags.
  """
  @spec index(Context.t(), pos_integer() | :all) ::
          {:ok, %{entries: [entry()], more: non_neg_integer()}} | {:error, term()}
  def index(%Context{} = ctx, limit) do
    with {:ok, entries} <- on_entries(Context.actor(ctx)) do
      case limit do
        :all ->
          {:ok, %{entries: Enum.reject(entries, & &1.shadowed), more: 0}}

        n when is_integer(n) ->
          shown = Enum.filter(entries, &(&1.carried and not &1.kept))
          {:ok, %{entries: Enum.take(shown, n), more: max(length(shown) - n, 0)}}
      end
    end
  end

  defp on_entries(actor) do
    with {:ok, names} <- pack_names(actor) do
      entries =
        for name <- names,
            %{on: true, origin: origin, scrolls: scrolls} <- [read_pack(actor, name, :index)],
            origin != nil,
            entry <- scrolls,
            do: entry

      {:ok, Enum.sort_by(entries, & &1.name)}
    end
  end

  @doc """
  One scroll by its full name, `<pack>:<scroll>`, read under the caller's
  actor from a pack switched on. A bare name is refused with a sentence
  naming the full names that match it (`bare_refusal/2`); a name of no
  grammar, a pack switched off, a shadowed scroll and another athanor's
  are `{:error, :not_found}`.
  """
  @spec skill(Context.t(), term()) :: {:ok, scroll()} | {:error, term()}
  def skill(%Context{} = ctx, name) do
    actor = Context.actor(ctx)

    case split_name(name) do
      {:ok, pack, scroll} -> named(actor, pack, scroll)
      {:bare, bare} -> bare_refusal(actor, bare)
      :error -> {:error, :not_found}
    end
  end

  defp named(actor, pack, scroll) do
    case read_pack(actor, pack, :index) do
      %{on: true, origin: origin, scrolls: entries, paths: files, past: past}
      when origin != nil ->
        case Enum.find(entries, &(&1.scroll == scroll and not &1.shadowed)) do
          nil ->
            {:error, :not_found}

          %{folder: folder} ->
            with {:ok, read} <- read_scroll(actor, pack, folder, files),
                 do: {:ok, %{read | carried: read.carried and is_nil(past)}}
        end

      _off_absent_or_unread ->
        {:error, :not_found}
    end
  end

  @doc """
  One scroll as the Scrolls page shows it, from a pack switched on or off,
  by its pack and its folder: what a read by name answers, the pack's
  origin, and its files beside its manifest each with whether it runs
  (`executable?/3`). `{:error, :not_found}` for no such folder.
  """
  @spec view_scroll(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def view_scroll(%Context{} = ctx, pack, folder) do
    actor = Context.actor(ctx)

    with true <- AquaPath.valid_name?(pack) and AquaPath.valid_name?(folder),
         %{paths: files, record: record, origin: origin} = card <- read_pack(actor, pack, :card),
         {:ok, scroll} <- read_scroll(actor, pack, folder, files),
         {:ok, pairs} <- Arca.read_subtree(actor, AquaPath.scroll_dir(pack, folder)) do
      entry =
        Enum.find(card.scrolls, &(&1.folder == folder)) || %{shadowed: false, carried: false}

      runs =
        for {rel, bytes} <- pairs, rel != [AquaPath.skill_manifest_name()], into: %{} do
          path = Enum.join(rel, "/")
          inside = Enum.join([AquaPath.skills_dirname(), folder, path], "/")
          {path, is_map(record) and executable?(record, inside, bytes)}
        end

      {:ok,
       Map.merge(scroll, %{
         origin: origin,
         on: card.on,
         shadowed: entry.shadowed,
         carried: entry.carried,
         files: Enum.map(scroll.files, &%{path: &1, runs: Map.get(runs, &1, false)})
       })}
    else
      {:error, _} = error -> error
      _absent -> {:error, :not_found}
    end
  end

  @doc """
  The refusal of a bare scroll name: `{:error, {:invalid_argument, s}}`
  whose sentence lists the full names of the packs switched on that match
  it, so the model mends the name in one step.
  """
  @spec bare_refusal(Prima.Actor.t(), String.t()) :: {:error, {:invalid_argument, String.t()}}
  def bare_refusal(actor, bare) do
    matches =
      case on_entries(actor) do
        {:ok, entries} -> for %{scroll: ^bare, shadowed: false, name: n} <- entries, do: n
        _unread -> []
      end

    {:error, {:invalid_argument, bare_sentence(bare, matches)}}
  end

  @doc "The sentence a bare scroll name is refused with."
  @spec bare_sentence(String.t(), [String.t()]) :: String.t()
  def bare_sentence(bare, []),
    do:
      "No scroll is named `#{bare}` alone: a scroll is named by its pack and its name, " <>
        "like `#{@mine}:#{bare}`."

  def bare_sentence(bare, [one]), do: "No scroll is named `#{bare}` alone: `#{one}` is."

  def bare_sentence(bare, many) do
    {init, [last]} = Enum.split(Enum.map(many, &"`#{&1}`"), -1)
    "No scroll is named `#{bare}` alone: #{Enum.join(init, ", ")} and #{last} are."
  end

  @doc """
  One file of a scroll's pack by its path inside the pack, `skill_get`'s
  `path`: a text file whole, or cut at `max_bytes/0` with `cut: true`; a
  binary file by its type and size alone. The record is no file of the
  pack. `{:error, :not_found}` as `skill/2` answers it.
  """
  @spec file(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def file(%Context{} = ctx, name, path) when is_binary(path) do
    actor = Context.actor(ctx)

    with {:ok, scroll} <- skill(ctx, name),
         rel = String.trim_leading(path, "/"),
         :ok <- pack_path(rel),
         false <- rel == AquaPath.record_name(),
         {:ok, bytes} <- Arca.get(actor, AquaPath.pack_dir(scroll.pack) ++ String.split(rel, "/")) do
      {:ok, file_answer(scroll, rel, bytes)}
    else
      true -> {:error, :not_found}
      {:error, {:invalid_argument, _}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp file_answer(scroll, rel, bytes) do
    base = %{name: scroll.name, path: rel, size: byte_size(bytes)}

    if text?(bytes) do
      cut = byte_size(bytes) > @max_bytes

      Map.merge(base, %{
        format: "text",
        content: if(cut, do: valid_prefix(bytes, @max_bytes), else: bytes),
        cut: cut
      })
    else
      Map.merge(base, %{format: "binary", type: MIME.from_path(rel)})
    end
  end

  # A file read as text: valid UTF-8 with no NUL; any other is a binary.
  defp text?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)

  defp valid_prefix(bytes, n) do
    prefix = binary_part(bytes, 0, n)
    if String.valid?(prefix), do: prefix, else: valid_prefix(bytes, n - 1)
  end

  # ---------------------------------------------------------------------------
  # The reading T5c consumes
  # ---------------------------------------------------------------------------

  @doc """
  The set's digest for `athanor`, read from the units' rows alone: the
  SHA-256 (`Prima.Digest.sha256/1`) of each pack's name, a NUL, its
  revision digest and a NUL, in name order, every pack switched on or off.
  A pack's revision digest is the journal row's `content_identity` of the
  revision its pointer names (`Arca.Overlay.content_identity/1`); the
  switch is inside that revision, in the record, so the digest names
  which packs are on. An `athanor` that is not the actor's is never read.
  """
  @spec pack_digest(Context.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def pack_digest(%Context{} = ctx, athanor) do
    with :ok <- own_athanor(ctx, athanor),
         {:ok, revisions} <- revisions(Context.actor(ctx)),
         do: {:ok, set_digest(revisions)}
  end

  @doc """
  The packs a set digest names, read under the actor:
  `{:moved, current}` when the store's set digest is no longer `digest`,
  or when a pack's bytes read do not recompute its revision digest;
  otherwise `{:ok, view}` where `view` is

      %{digest: digest,
        packs: [%{name: name, revision: revision_digest, on: boolean,
                  record: %{path: ".cyfr-pack.json", size: n, sha256: "sha256:…"},
                  files: [%{path: "skills/x/SKILL.md", size: n, sha256: "sha256:…",
                            executable: boolean}],
                  withheld: nil | "the sentence a pack past its bounds is left out with"}],
        archive: binary}

  in name order: every pack's name, revision digest and its record's
  line, and for each pack switched on every other file of it by its path
  inside `aqua/scrolls/<pack>/` (`[]` for a pack switched off). A pack
  switched on but past a pack's bounds (`bounds/0`) is handed with no
  file, and `withheld` says why, the sentence its card says. The
  record's line is what a keeper needs to recompute each revision digest
  (`content_identity` over every path of the unit, the record's among
  them) and the set's; it writes the files alone.

  `archive` is the stream a keeper's copy of the packs is put by
  (`Opus.Programs.Session`), made from the same one reading of each pack:
  a plain ustar archive (`Compendium.PackArchive.tar/1`) whose first entry
  is the manifest `#{@archive_manifest}`, the JSON `{"files": [line, …]}`
  of every file handed, each line as `files` gives it with its path
  `<pack>/<path inside the pack>`, then each of those files under that
  path, in the manifest's order. A set that hands no file is the manifest
  `{"files":[]}` alone. No record is in it.
  """
  @spec pack_view(Context.t(), String.t(), String.t()) ::
          {:ok, map()} | {:moved, String.t()} | {:error, term()}
  def pack_view(%Context{} = ctx, athanor, digest) when is_binary(digest) do
    actor = Context.actor(ctx)

    with :ok <- own_athanor(ctx, athanor),
         {:ok, revisions} <- revisions(actor) do
      current = set_digest(revisions)

      if current != digest do
        {:moved, current}
      else
        view(actor, revisions, digest)
      end
    end
  end

  defp view(actor, revisions, digest) do
    Enum.reduce_while(revisions, {:ok, []}, fn {name, identity}, {:ok, acc} ->
      case Arca.read_subtree(actor, AquaPath.pack_dir(name)) do
        {:ok, pairs} ->
          if recomputed(pairs) == identity,
            do: {:cont, {:ok, [split_pack(name, identity, pairs) | acc]}},
            else: {:halt, :moved}

        {:error, :not_found} ->
          {:halt, :moved}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, read} ->
        read = Enum.reverse(read)
        verdicts = standing(Enum.map(read, &measured(&1.name, &1.record, &1.body)))
        viewed = Enum.map(read, &view_pack(&1, verdicts[&1.name]))

        {:ok,
         %{
           digest: digest,
           packs: Enum.map(viewed, fn {pack, _handed} -> pack end),
           archive: archive(viewed)
         }}

      :moved ->
        case revisions(actor) do
          {:ok, now} -> {:moved, set_digest(now)}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  # One pack as read for the view: its record's bytes and reading, and
  # every other file of it.
  defp split_pack(name, identity, pairs) do
    record_name = [AquaPath.record_name()]
    {[{_rel, raw}], body} = Enum.split_with(pairs, &(elem(&1, 0) == record_name))
    record = with {:ok, r} <- decode_record(raw), do: r
    %{name: name, identity: identity, raw: raw, record: record, body: body}
  end

  defp view_pack(%{name: name, identity: identity, raw: raw, record: record, body: body}, handed) do
    on = handed != :off

    withheld =
      case handed do
        {:withheld, sentence} -> sentence
        {:past_set, sentence} -> capitalized(sentence)
        _handed_or_off -> nil
      end

    files =
      if handed == :handed do
        for {rel, bytes} <- Enum.sort_by(body, &elem(&1, 0)) do
          path = Enum.join(rel, "/")

          {%{
             path: path,
             size: byte_size(bytes),
             sha256: Prima.Digest.sha256(bytes),
             executable: executable?(record, path, bytes)
           }, bytes}
        end
      else
        []
      end

    pack = %{
      name: name,
      revision: identity,
      on: on,
      record: %{
        path: AquaPath.record_name(),
        size: byte_size(raw),
        sha256: Prima.Digest.sha256(raw)
      },
      files: Enum.map(files, fn {line, _bytes} -> line end),
      withheld: withheld
    }

    {pack, files}
  end

  # The view's `archive`: the manifest of every file handed, then those
  # files, each under `<pack>/<path inside the pack>`.
  defp archive(viewed) do
    handed =
      for {%{name: name}, files} <- viewed,
          {line, bytes} <- files,
          do: {%{line | path: name <> "/" <> line.path}, bytes}

    manifest = Jason.encode!(%{files: Enum.map(handed, fn {line, _bytes} -> line end)})

    PackArchive.tar([
      {@archive_manifest, manifest, false}
      | for({line, bytes} <- handed, do: {line.path, bytes, line.executable})
    ])
  end

  # The one rule of what a program is handed of a pack, which `pack_view/3`,
  # `pack_file/4` and the cards all ask: a pack switched off is handed
  # nothing; one switched on but past a pack's bounds (a migrated `mine`
  # that holds more than a pack may, say) stays in the store and is handed
  # nothing either, with the sentence its card says; and of the rest,
  # taken in name order, each is handed while the sum of those handed
  # stays within the set's bound (`standing/1`).
  defp handed(name, record, body) do
    if match?(%{on: true}, record) do
      case bounded(name, body) do
        :ok -> :handed
        {:error, {:invalid_argument, sentence}} -> {:withheld, sentence}
      end
    else
      :off
    end
  end

  defp measured(name, record, body),
    do: {name, handed(name, record, body), length(body), body_bytes(body)}

  defp body_bytes(body), do: Enum.reduce(body, 0, fn {_rel, b}, n -> n + byte_size(b) end)

  # The set's bound, decided where the packs are read: the packs a program
  # may be handed (switched on, within their own bounds), in name order,
  # are handed while their sum stays within the set's 8,192 files and
  # 128 MiB; each past it is withheld with its sentence. It holds under any
  # order of writes on any number of nodes, with no lock and no row: the
  # check at a write (`set_bounded/4`) is the early notice, this is the
  # guard. `packs` are `{name, verdict, files, bytes}` in name order.
  defp standing(packs) do
    {verdicts, _sum} =
      Enum.map_reduce(packs, {0, 0}, fn
        {name, :handed, files, bytes}, {fs, bs} ->
          cond do
            fs + files > @set_files ->
              {{name, {:past_set, set_past(:files, fs + files)}}, {fs, bs}}

            bs + bytes > @set_bytes ->
              {{name, {:past_set, set_past(:bytes, bs + bytes)}}, {fs, bs}}

            true ->
              {{name, :handed}, {fs + files, bs + bytes}}
          end

        {name, verdict, _files, _bytes}, sum ->
          {{name, verdict}, sum}
      end)

    Map.new(verdicts)
  end

  defp set_past(:files, sum),
    do:
      "your packs together are past the #{@set_files} files they may hold, at #{sum} " <>
        "with this one; switch one off"

  defp set_past(:bytes, sum),
    do:
      "your packs together are past the #{@set_bytes} bytes they may hold, at #{sum} " <>
        "with this one; switch one off"

  defp capitalized(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp recomputed(pairs) do
    pairs
    |> Enum.map(fn {rel, bytes} -> {rel, Prima.Digest.sha256(bytes), byte_size(bytes)} end)
    |> Arca.Overlay.content_identity()
  end

  @doc """
  One file of a pack by its path inside the pack, for `athanor` under the
  actor: its bytes, from one reading of the pack. Only a pack a program
  is handed answers (`pack_view/3`'s rule: switched on and within a
  pack's bounds); a pack switched off or withheld answers no file, by any
  path, `{:error, :not_found}`. The record is no file of the pack.
  """
  @spec pack_file(Context.t(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def pack_file(%Context{} = ctx, athanor, pack, path) do
    with :ok <- own_athanor(ctx, athanor),
         true <- AquaPath.valid_name?(pack) and is_binary(path),
         :ok <- pack_path(path),
         false <- path == AquaPath.record_name(),
         actor = Context.actor(ctx),
         {:ok, revisions} <- revisions(actor),
         true <- List.keymember?(revisions, pack, 0),
         {:ok, earlier} <- earlier_measured(actor, revisions, pack),
         {:ok, pairs} <- Arca.read_subtree(actor, AquaPath.pack_dir(pack)) do
      handed_file(earlier, pack, pairs, String.split(path, "/"))
    else
      {:error, {:invalid_argument, _}} -> {:error, :not_found}
      {:error, _} = error -> error
      _not_a_file -> {:error, :not_found}
    end
  end

  # The packs before `pack` in name order, each as the set's standing
  # counts it: read whole when switched on, since its own bounds decide
  # whether it counts; a pack that cannot be read answers its error, never
  # nothing.
  defp earlier_measured(actor, revisions, pack) do
    revisions
    |> Enum.take_while(fn {name, _identity} -> name < pack end)
    |> Enum.reduce_while({:ok, []}, fn {name, _identity}, {:ok, acc} ->
      case Arca.read_subtree(actor, AquaPath.pack_dir(name)) do
        {:ok, pairs} ->
          %{record: record, body: body} = split_any(name, pairs)
          {:cont, {:ok, [measured(name, record, body) | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, measured} -> {:ok, Enum.reverse(measured)}
      {:error, _} = error -> error
    end
  end

  defp split_any(name, pairs) do
    record_name = [AquaPath.record_name()]
    {raw, body} = Enum.split_with(pairs, &(elem(&1, 0) == record_name))

    record =
      case raw do
        [{_rel, bytes}] -> with {:ok, r} <- decode_record(bytes), do: r
        [] -> nil
      end

    %{name: name, record: record, body: body}
  end

  defp handed_file(earlier, pack, pairs, rel) do
    %{record: record, body: body} = split_any(pack, pairs)
    verdicts = standing(earlier ++ [measured(pack, record, body)])

    with :handed <- verdicts[pack],
         {^rel, bytes} <- List.keyfind(body, rel, 0) do
      {:ok, bytes}
    else
      _off_withheld_or_absent -> {:error, :not_found}
    end
  end

  defp own_athanor(%Context{athanor_id: athanor}, athanor) when is_binary(athanor), do: :ok
  defp own_athanor(_ctx, _athanor), do: {:error, :not_found}

  # Every pack's name and revision digest, from the rows, in name order.
  defp revisions(actor) do
    prefix = Enum.join(tl(AquaPath.scrolls_root()), "/") <> "/"

    with {:ok, rows} <- Arca.Overlay.revision_identities(actor, hd(AquaPath.root()), prefix) do
      {:ok,
       rows
       |> Enum.flat_map(fn {key, {_revision, identity}} ->
         case String.split(String.replace_prefix(key, prefix, ""), "/") do
           [name] when is_binary(identity) -> [{name, identity}]
           _other -> []
         end
       end)
       |> Enum.sort()}
    end
  end

  defp set_digest(revisions) do
    revisions
    |> Enum.map(fn {name, identity} -> [name, 0, identity, 0] end)
    |> IO.iodata_to_binary()
    |> Prima.Digest.sha256()
  end

  # ---------------------------------------------------------------------------
  # What an ordinary write may make of a pack
  # ---------------------------------------------------------------------------

  @doc """
  The rule an ordinary write into a pack meets (`Arca.Storage.UnitLocator`,
  through `Compendium.AquaPath`): asked under the pack's draft with its
  committed objects (`nil` when the write would make the pack) and the
  objects the write would leave. A write under a new folder makes a pack
  of the person's own, its record minted, except under `cyfr`; a write
  into a brought pack or `cyfr`, which the record seals, is refused; and
  the pack's bounds and the bound of the packs switched on hold. Every
  refusal is a sentence (`{:invalid_argument, _}`).
  """
  @spec admit_edit(
          Prima.Actor.t(),
          Arca.Storage.path(),
          [{Arca.Storage.path(), binary()}] | nil,
          [{Arca.Storage.path(), binary()}]
        ) :: {:ok, [{Arca.Storage.path(), binary()}]} | {:error, term()}
  def admit_edit(actor, unit, current, next) do
    pack = List.last(unit)

    with {:ok, record, next} <- admitted(pack, current, next),
         :ok <- bounded(pack, next),
         :ok <- set_bounded(actor, pack, record, next),
         do: {:ok, next}
  end

  defp admitted(@cyfr, nil, _next),
    do:
      refuse(
        "`#{@cyfr}` is CYFR's own pack, which ships with CYFR: make a pack of your own " <>
          "under another name"
      )

  # The one rule that makes a pack: the write of its first scroll's
  # manifest, `skills/<scroll>/SKILL.md`, under a folder that holds no pack.
  # Any other first write there names a pack that is not here, so a write
  # meant for a pack that was removed meanwhile, or a stray file, makes
  # nothing.
  defp admitted(pack, nil, next) do
    case next do
      [{[skills, scroll, manifest], _bytes}] ->
        if skills == AquaPath.skills_dirname() and manifest == AquaPath.skill_manifest_name() and
             AquaPath.valid_name?(scroll) do
          record = own_record()
          {:ok, record, next ++ [{[AquaPath.record_name()], encode_record(record)}]}
        else
          no_pack(pack)
        end

      _other ->
        no_pack(pack)
    end
  end

  defp admitted(pack, current, next) do
    case record_of(current) do
      {:ok, %{origin: "own"} = record} ->
        {:ok, record, next}

      {:ok, %{origin: origin}} ->
        {:error, sealed(pack, origin)}

      {:error, _} ->
        refuse("The pack `#{pack}` has a record that cannot be read: nothing was written")
    end
  end

  defp no_pack(pack),
    do:
      refuse(
        "No pack named `#{pack}` is here: a pack is made by writing its first scroll, " <>
          "`#{Enum.join(AquaPath.pack_dir(pack), "/")}/skills/<scroll>/SKILL.md`"
      )

  @doc "The refusal a write into a brought pack or `cyfr` answers."
  @spec sealed(String.t(), String.t()) :: {:invalid_argument, String.t()}
  def sealed(pack, "cyfr"),
    do:
      {:invalid_argument,
       "`#{pack}` is CYFR's own pack and changes only with CYFR's update: " <>
         "copy the scroll into a pack of your own"}

  def sealed(pack, _brought),
    do:
      {:invalid_argument,
       "`#{pack}` was brought in and is kept as its author published it: " <>
         "copy the scroll into a pack of your own"}

  defp record_of(pairs) do
    case List.keyfind(pairs, [AquaPath.record_name()], 0) do
      {_rel, raw} -> decode_record(raw)
      nil -> {:error, :record_invalid}
    end
  end

  # A pack's own bounds over its files, the record left out.
  defp bounded(pack, pairs) do
    body = Enum.reject(pairs, &(elem(&1, 0) == [AquaPath.record_name()]))
    count = length(body)
    bytes = Enum.reduce(body, 0, fn {_rel, b}, n -> n + byte_size(b) end)

    cond do
      count > @pack_files ->
        refuse("The pack `#{pack}` would hold #{count} files, past a pack's #{@pack_files}")

      bytes > @pack_bytes ->
        refuse("The pack `#{pack}` would hold #{bytes} bytes, past a pack's #{@pack_bytes}")

      true ->
        Enum.reduce_while(body, :ok, fn {rel, b}, :ok ->
          path = Enum.join(rel, "/")

          cond do
            byte_size(b) > Arca.Files.max_write() ->
              {:halt, refuse("`#{path}` is past a file's #{Arca.Files.max_write()} bytes")}

            true ->
              case pack_path(path) do
                :ok -> {:cont, :ok}
                refused -> {:halt, refused}
              end
          end
        end)
    end
  end

  @doc """
  Whether a path may stand in a pack: relative, at most 255 bytes, of the
  name grammar's characters with `.` and `/`, with no `.` or `..` segment.
  """
  @spec pack_path(String.t()) :: :ok | {:error, {:invalid_argument, String.t()}}
  def pack_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    cond do
      byte_size(path) > @path_bytes ->
        refuse("`#{path}` is a path past a pack's #{@path_bytes} bytes")

      not Regex.match?(@path_format, path) or Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        refuse(
          "`#{path}` is not a path a pack may hold: letters, digits, `_`, `-`, `.` and `/`, " <>
            "with no `..`"
        )

      true ->
        :ok
    end
  end

  # The packs switched on hold at most the set's bound together: a pack
  # switched on that the write would take past it is refused, naming the
  # sum. A pack switched off is in no set.
  defp set_bounded(_actor, _pack, %{on: false}, _pairs), do: :ok

  defp set_bounded(actor, pack, _record, pairs) do
    body = Enum.reject(pairs, &(elem(&1, 0) == [AquaPath.record_name()]))
    set_check(actor, pack, length(body), Enum.reduce(body, 0, &(&2 + byte_size(elem(&1, 1)))))
  end

  # The early notice of the set's bound (`standing/1` is its guard): the
  # other packs switched on, each measured; one whose size cannot be read
  # refuses the write, never counts as nothing.
  defp set_check(actor, pack, files, bytes) do
    with {:ok, names} <- pack_names(actor),
         {:ok, {others_files, others_bytes}} <- others_on(actor, names, pack) do
      total_files = others_files + files
      total_bytes = others_bytes + bytes

      cond do
        total_files > @set_files ->
          refuse(
            "The packs switched on would hold #{total_files} files together, past the " <>
              "#{@set_files} they may hold: switch one off first"
          )

        total_bytes > @set_bytes ->
          refuse(
            "The packs switched on would hold #{total_bytes} bytes together, past the " <>
              "#{@set_bytes} they may hold: switch one off first"
          )

        true ->
          :ok
      end
    end
  end

  defp others_on(actor, names, pack) do
    Enum.reduce_while(names -- [pack], {:ok, {0, 0}}, fn name, {:ok, {fs, bs}} ->
      case on_size(actor, name) do
        {:ok, {f, b}} ->
          {:cont, {:ok, {fs + f, bs + b}}}

        {:error, _} ->
          {:halt,
           refuse(
             "The size of the pack `#{name}` cannot be read, so whether the packs switched " <>
               "on stay within what they may hold together is not known: try again"
           )}
      end
    end)
  end

  # A pack's file count and bytes when switched on, its record left out;
  # `{0, 0}` for one switched off, gone, or whose record cannot be read,
  # none of which a program is handed.
  defp on_size(actor, name) do
    dir = AquaPath.pack_dir(name)

    case Arca.get(actor, dir ++ [AquaPath.record_name()]) do
      {:ok, raw} ->
        case decode_record(raw) do
          {:ok, %{on: true}} ->
            with {:ok, leaves} <- Arca.list_recursive(actor, dir),
                 {:ok, %{bytes: used}} <- Arca.usage(actor, dir),
                 do: {:ok, {max(length(leaves) - 1, 0), max(used - byte_size(raw), 0)}}

          _off_or_unreadable ->
            {:ok, {0, 0}}
        end

      {:error, :not_found} ->
        {:ok, {0, 0}}

      {:error, _} = error ->
        error
    end
  end

  defp refuse(sentence), do: {:error, {:invalid_argument, sentence}}

  # ---------------------------------------------------------------------------
  # Writes Files cannot say: a scroll's manifest by its name, the switch, a copy
  # ---------------------------------------------------------------------------

  @doc """
  Write a scroll's manifest in a pack of the person's own, as an ordinary
  write meets `admit_edit/4`: `:create` makes `skills/<scroll>/SKILL.md`
  (the pack too, when it has none) and refuses a scroll of that name;
  `:new_pack` makes the pack with that scroll as its first, and refuses,
  under the pack's draft, when a pack of that name is already here;
  `{:update, fun}` rewrites the scroll's manifest, `fun` given its bytes
  and answering the next ones.
  """
  @spec put_scroll(
          Context.t(),
          String.t(),
          binary() | nil,
          :create | :new_pack | {:update, (binary() -> {:ok, binary()} | {:error, term()})}
        ) :: :ok | {:error, term()}
  def put_scroll(%Context{} = ctx, name, manifest, mode) do
    actor = Context.actor(ctx)

    case split_name(name) do
      {:ok, pack, scroll} ->
        unit = AquaPath.pack_dir(pack)

        Arca.Overlay.edit_unit(actor, unit, fn
          current when mode == :new_pack and current != nil ->
            refuse("A pack named `#{pack}` is already here: choose another name")

          current ->
            with {:ok, next} <- scroll_written(actor, pack, scroll, current || [], manifest, mode),
                 do: admit_edit(actor, unit, current, next)
        end)

      {:bare, bare} ->
        bare_refusal(actor, bare)

      :error ->
        refuse("A scroll is named by its pack and its name, like `#{@mine}:research`")
    end
  end

  defp scroll_written(actor, pack, scroll, pairs, manifest, :new_pack),
    do: scroll_written(actor, pack, scroll, pairs, manifest, :create)

  defp scroll_written(actor, pack, scroll, pairs, manifest, :create) do
    folder = [AquaPath.skills_dirname(), scroll]

    taken =
      Enum.any?(pairs, fn {rel, _} -> List.starts_with?(rel, folder) end) or
        Enum.any?(scrolls_in(actor, pack, pairs), &(&1 == scroll))

    if taken,
      do: refuse("Scroll '#{full_name(pack, scroll)}' already exists"),
      else: {:ok, pairs ++ [{folder ++ [AquaPath.skill_manifest_name()], manifest}]}
  end

  defp scroll_written(actor, pack, scroll, pairs, _manifest, {:update, fun}) do
    case folder_of(actor, pack, scroll) do
      {:ok, folder} ->
        rel = [AquaPath.skills_dirname(), folder, AquaPath.skill_manifest_name()]

        case List.keyfind(pairs, rel, 0) do
          {^rel, bytes} ->
            with {:ok, next} <- fun.(bytes), do: {:ok, List.keystore(pairs, rel, 0, {rel, next})}

          nil ->
            {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp scrolls_in(actor, pack, _pairs) do
    case read_pack(actor, pack, :card) do
      %{scrolls: scrolls} -> Enum.map(scrolls, & &1.scroll)
      nil -> []
    end
  end

  defp folder_of(actor, pack, scroll) do
    case read_pack(actor, pack, :card) do
      %{scrolls: scrolls} ->
        case Enum.find(scrolls, &(&1.scroll == scroll and not &1.shadowed)) do
          %{folder: folder} -> {:ok, folder}
          nil -> :error
        end

      nil ->
        :error
    end
  end

  @doc """
  The scroll's manifest bytes and the scroll's folder as the store holds
  them, for a pack of any origin, switched on or off: what an editor and
  a proposal's digest read.
  """
  @spec manifest(Context.t(), String.t()) ::
          {:ok, %{bytes: binary(), folder: String.t(), origin: String.t() | nil}}
          | {:error, term()}
  def manifest(%Context{} = ctx, name) do
    actor = Context.actor(ctx)

    case split_name(name) do
      {:ok, pack, scroll} ->
        with %{origin: origin} <- read_pack(actor, pack, :card),
             {:ok, folder} <- folder_of(actor, pack, scroll),
             {:ok, bytes} <- Arca.get(actor, AquaPath.scroll_manifest(pack, folder)) do
          {:ok, %{bytes: bytes, folder: folder, origin: origin}}
        else
          nil -> {:error, :not_found}
          :error -> {:error, :not_found}
          {:error, _} = error -> error
        end

      {:bare, bare} ->
        bare_refusal(actor, bare)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Switch a pack on or off: one new revision of the pack with its record's
  switch turned and nothing else changed, the agreement kept as it was.
  Switching one on that would take the packs switched on past their
  bound is refused, naming the sum.
  """
  @spec switch(Context.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def switch(%Context{} = ctx, pack, on?) when is_boolean(on?) do
    actor = Context.actor(ctx)

    if AquaPath.valid_name?(pack) do
      Arca.Overlay.edit_unit(actor, AquaPath.pack_dir(pack), fn
        nil ->
          {:error, :not_found}

        current ->
          with {:ok, record} <- record_of(current),
               :ok <- switched(actor, pack, record, on?, current) do
            {:ok,
             List.keystore(
               current,
               [AquaPath.record_name()],
               0,
               {[AquaPath.record_name()], encode_record(%{record | on: on?})}
             )}
          else
            {:error, :record_invalid} ->
              refuse("The pack `#{pack}` has a record that cannot be read")

            {:error, _} = refused ->
              refused
          end
      end)
    else
      {:error, :not_found}
    end
  end

  defp switched(_actor, _pack, _record, false, _pairs), do: :ok
  defp switched(_actor, _pack, %{on: true}, true, _pairs), do: :ok

  defp switched(actor, pack, _record, true, pairs) do
    with :ok <- bounded(pack, pairs), do: set_bounded(actor, pack, %{on: true}, pairs)
  end

  @doc """
  Copy one scroll, its folder whole, from any pack into a pack of the
  person's own (`mine` unless named), as an ordinary write into that pack
  meets `admit_edit/4`. A folder of that name already there refuses.
  """
  @spec copy(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def copy(%Context{} = ctx, name, to \\ @mine) do
    actor = Context.actor(ctx)

    with {:ok, pack, scroll} <- copy_source(name),
         {:ok, folder} <- folder_of(actor, pack, scroll),
         true <- AquaPath.valid_name?(to) || {:error, :not_found},
         {:ok, copied} <- folder_pairs(actor, pack, folder) do
      unit = AquaPath.pack_dir(to)

      # A copy is meant for a pack of the person's own: one that is not
      # here yet is made by it, its record minted, as `mine` is at a fill.
      Arca.Overlay.edit_unit(actor, unit, fn current ->
        base = current || [{[AquaPath.record_name()], encode_record(own_record())}]
        dest = [AquaPath.skills_dirname(), folder]

        cond do
          is_nil(current) and to == @cyfr ->
            admit_edit(actor, unit, nil, copied)

          Enum.any?(base, fn {rel, _} -> List.starts_with?(rel, dest) end) ->
            refuse("`#{to}` already has a scroll folder `#{folder}`: delete it first")

          true ->
            admit_edit(actor, unit, base, base ++ copied)
        end
      end)
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp copy_source(name) do
    case split_name(name) do
      {:ok, pack, scroll} -> {:ok, pack, scroll}
      _other -> :error
    end
  end

  defp folder_pairs(actor, pack, folder) do
    dir = AquaPath.scroll_dir(pack, folder)

    with {:ok, pairs} <- Arca.read_subtree(actor, dir),
         do:
           {:ok,
            for({rel, bytes} <- pairs, do: {[AquaPath.skills_dirname(), folder | rel], bytes})}
  end

  # ---------------------------------------------------------------------------
  # A scroll's file a turn proposes, and the person's Save of it
  # ---------------------------------------------------------------------------

  @doc """
  What a turn's proposal of one file beside a scroll is made against, or
  why it cannot be proposed. `name` is the scroll, `<pack>:<scroll>`, in a
  pack of the person's own or one its scroll's Save would make (never
  `cyfr` or a brought pack); `path` is the file's path inside the pack,
  under the scroll's folder (`skills/<folder>/…`), so no manifest, hook or
  record at the pack's root can be named; no file named `SKILL.md`, which
  only a scroll's own writes make; and no path the pack's manifests name
  (`manifest_named/1`). The bytes hold at most `max_bytes/0`, the most a
  proposal's row carries. Answers `against`, the file's SHA-256 as it is
  now or `none`, whether the file runs (`executable?/3`'s rule for a pack
  of the person's own), whether it is a script as the pack sheet counts
  one, and whether it reads as text.
  """
  @spec file_proposal(Context.t(), String.t(), String.t(), binary()) ::
          {:ok, %{against: String.t(), runs: boolean(), script: boolean(), text: boolean()}}
          | {:error, term()}
  def file_proposal(%Context{} = ctx, name, path, bytes)
      when is_binary(path) and is_binary(bytes) do
    actor = Context.actor(ctx)

    with {:ok, pack, scroll} <- scroll_named(actor, name),
         {:ok, pairs} <- own_pairs(actor, pack),
         {:ok, rel} <- file_admitted(pack, scroll, pairs || [], path, bytes, :proposal) do
      runs = executable?(%{origin: "own"}, path, bytes)

      {:ok,
       %{
         against: file_against(pairs || [], rel),
         runs: runs,
         script: script?(%{path: path, executable: runs}),
         text: text?(bytes)
       }}
    end
  end

  @doc """
  The person's Save of a file a turn proposed: one revision of the pack,
  written as every write into it is (`Arca.Overlay.edit_unit/4`, under
  `admit_edit/4`), and only while, under the pack's draft, the scroll's
  `SKILL.md` is stored and the file is as the proposal read it
  (`against`: its SHA-256, or `none` for one not there), so two
  proposals for one path saved in turn never let the second replace the
  first unseen. Every rule `file_proposal/4` holds is asked again over the
  pack as it is at the write.
  """
  @spec put_file(Context.t(), String.t(), String.t(), binary(), String.t()) ::
          :ok | {:error, term()}
  def put_file(%Context{} = ctx, name, path, bytes, against)
      when is_binary(path) and is_binary(bytes) and is_binary(against) do
    actor = Context.actor(ctx)

    with {:ok, pack, scroll} <- scroll_named(actor, name) do
      unit = AquaPath.pack_dir(pack)

      Arca.Overlay.edit_unit(actor, unit, fn
        nil when pack == @cyfr ->
          {:error, sealed(pack, "cyfr")}

        nil ->
          refuse(scroll_first(name))

        current ->
          with :ok <- own_origin_of(pack, current),
               {:ok, rel} <- file_admitted(pack, scroll, current, path, bytes, :save),
               :ok <- file_unchanged(current, rel, against, path),
               do: admit_edit(actor, unit, current, List.keystore(current, rel, 0, {rel, bytes}))
      end)
    end
  end

  defp scroll_named(actor, name) do
    case split_name(name) do
      {:ok, pack, scroll} -> {:ok, pack, scroll}
      {:bare, bare} -> bare_refusal(actor, bare)
      :error -> refuse("A scroll is named by its pack and its name, like `#{@mine}:research`")
    end
  end

  # The pack's files as stored, from a pack of the person's own; `nil` for
  # a pack not here yet, which its scroll's Save would make, but never
  # `cyfr`'s name.
  defp own_pairs(actor, pack) do
    case Arca.read_subtree(actor, AquaPath.pack_dir(pack)) do
      {:ok, []} ->
        if pack == @cyfr, do: {:error, sealed(pack, "cyfr")}, else: {:ok, nil}

      {:ok, pairs} ->
        with :ok <- own_origin_of(pack, pairs), do: {:ok, pairs}

      {:error, :not_found} ->
        if pack == @cyfr, do: {:error, sealed(pack, "cyfr")}, else: {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  defp own_origin_of(pack, pairs) do
    case record_of(pairs) do
      {:ok, %{origin: "own"}} -> :ok
      {:ok, %{origin: origin}} -> {:error, sealed(pack, origin)}
      {:error, _} -> refuse("The pack `#{pack}` has a record that cannot be read")
    end
  end

  # The rules a proposed file meets, at the proposal and again at its
  # Save: the proposal's bound, the store's path rule, the scroll's folder
  # alone, no `SKILL.md`, and no path the pack's manifests name. At the
  # Save the scroll must be stored; at the proposal a scroll not stored
  # yet is named by its folder, as CYFR's own writes keep it.
  defp file_admitted(pack, scroll, pairs, path, bytes, stage) do
    name = full_name(pack, scroll)
    folder = scroll_folder(pairs, scroll)
    segments = String.split(path, "/")

    cond do
      byte_size(bytes) > @max_bytes ->
        refuse(
          "A file Aqua proposes holds at most #{@max_bytes} bytes and `#{path}` holds " <>
            "#{byte_size(bytes)}: put it in through Files"
        )

      match?({:error, _}, pack_path(path)) ->
        pack_path(path)

      stage == :save and is_nil(folder) ->
        refuse(scroll_first(name))

      not match?([_skills, _folder, _ | _], segments) or
          Enum.take(segments, 2) != [AquaPath.skills_dirname(), folder || scroll] ->
        refuse(
          "`#{path}` is outside the folder of the scroll `#{name}`, " <>
            "`#{AquaPath.skills_dirname()}/#{folder || scroll}/`: a file Aqua proposes " <>
            "stays beside its scroll"
        )

      List.last(segments) == AquaPath.skill_manifest_name() ->
        refuse(
          "A scroll's #{AquaPath.skill_manifest_name()} is written with `aqua.skill_create` " <>
            "or `aqua.skill_update`, never as a file"
        )

      manifest = named_by(manifest_named(pairs), path) ->
        refuse(
          "`#{path}` is named by the pack's own `#{manifest}`, which decides what its " <>
            "programs load and run: change it through Files"
        )

      true ->
        {:ok, segments}
    end
  end

  # The folder of the pack's scroll of that name as `scrolls_of/4` names
  # it, the first by path, or `nil` when the pack holds none.
  defp scroll_folder(pairs, scroll) do
    pairs
    |> Enum.flat_map(fn
      {[skills, folder, manifest], bytes} ->
        if skills == AquaPath.skills_dirname() and manifest == AquaPath.skill_manifest_name() and
             AquaPath.valid_name?(folder),
           do: [{folder, bytes}],
           else: []

      _other ->
        []
    end)
    |> Enum.sort()
    |> Enum.find_value(fn {folder, bytes} ->
      case AquaAgent.parse_frontmatter(bytes) do
        {:ok, meta, _body} -> if own_name(string(meta["name"]), folder) == scroll, do: folder
        _unread -> nil
      end
    end)
  end

  defp scroll_first(name),
    do: "Save the scroll `#{name}` first: this file belongs to it"

  defp file_against(pairs, rel) do
    case List.keyfind(pairs, rel, 0) do
      {^rel, bytes} -> Prima.Digest.sha256(bytes)
      nil -> @against_none
    end
  end

  defp file_unchanged(pairs, rel, against, path) do
    if file_against(pairs, rel) == against,
      do: :ok,
      else:
        {:error,
         {:conflict,
          "The file `#{path}` changed since Aqua proposed this, so nothing was saved: " <>
            "open it in Files to see it as it is now"}}
  end

  # The files whose contents decide what a pack's programs load and run
  # beyond its scrolls (`parts_of/2`), and every path they name, `./…` or
  # `${CLAUDE_PLUGIN_ROOT}/…`, with the files they name read the same way:
  # a hook's or a server's script, an agents or commands folder. A plugin
  # manifest's `skills` names where the scrolls are, which is no such
  # path. `{declaring file, named path}` pairs.
  @declaring [
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    ".cursor-plugin/plugin.json",
    "hooks/hooks.json",
    ".mcp.json"
  ]
  @path_ref ~r/(?:\.\/|\$\{CLAUDE_PLUGIN_ROOT\}\/)([A-Za-z0-9_.\-\/]+)/

  defp manifest_named(pairs) do
    read = fn rel ->
      case List.keyfind(pairs, String.split(rel, "/"), 0) do
        {_rel, bytes} -> bytes
        nil -> nil
      end
    end

    named =
      for rel <- @declaring,
          bytes <- List.wrap(read.(rel)),
          ref <- refs(rel, bytes),
          do: {rel, ref}

    further =
      for {_rel, ref} <- named,
          ref not in @declaring,
          bytes <- List.wrap(read.(ref)),
          ref2 <- refs(ref, bytes),
          do: {ref, ref2}

    named ++ further
  end

  defp refs(rel, bytes) do
    text =
      case Jason.decode(bytes) do
        {:ok, %{} = map} when rel in @manifests -> Jason.encode!(Map.delete(map, "skills"))
        _other -> bytes
      end

    for [_whole, ref] <- Regex.scan(@path_ref, text),
        trimmed = String.trim_trailing(ref, "/"),
        trimmed != "",
        do: trimmed
  end

  defp named_by(named, path) do
    Enum.find_value(named, fn {manifest, ref} ->
      if path == ref or String.starts_with?(path, ref <> "/"), do: manifest
    end)
  end

  # ---------------------------------------------------------------------------
  # Bringing a pack in, and updating it
  # ---------------------------------------------------------------------------

  @doc """
  The sheet for an archive: the packs it holds to choose from, and for the
  one chosen (`opts["folder"]`, else the first) its name (`opts["name"]`,
  else its `.claude-plugin/plugin.json`'s, else its folder's), version,
  scrolls, scripts by count, hooks, agents, commands and MCP servers, the
  digest the person would agree to (`files_digest/1`), what an update
  would change, scripts and hooks first, and the sentence that refuses it
  (`refusal`), if any. Reads the archive alone and writes nothing.
  """
  @spec sheet(Context.t(), binary(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sheet(%Context{} = ctx, archive, filename, opts \\ %{}) when is_binary(archive) do
    with {:ok, entries} <- PackArchive.read(archive) do
      case candidates(entries) do
        [] ->
          refuse(
            "The archive holds no pack: a pack is a folder with a `skills/` of scrolls, a " <>
              "plugin manifest, or a lone `SKILL.md`"
          )

        candidates ->
          folder =
            if opts["folder"] in Enum.map(candidates, & &1.folder),
              do: opts["folder"],
              else: hd(candidates).folder

          {:ok, chosen(ctx, entries, candidates, folder, filename, opts)}
      end
    end
  end

  defp chosen(ctx, entries, candidates, folder, filename, opts) do
    candidate = Enum.find(candidates, &(&1.folder == folder))
    files = pack_files(entries, candidate)
    paths = Enum.map(files, & &1.path)
    by_path = Map.new(files, &{&1.path, &1.bytes})
    read = &Map.get(by_path, &1)

    manifest_name =
      with bytes when is_binary(bytes) <- read.(".claude-plugin/plugin.json"),
           {:ok, %{"name" => name}} when is_binary(name) <- Jason.decode(bytes),
           true <- AquaPath.valid_name?(name) do
        name
      else
        _none -> nil
      end

    default = manifest_name || default_name(folder, filename)

    name =
      case opts["name"] do
        given when is_binary(given) and given != "" and is_nil(manifest_name) -> given
        _default -> default
      end

    scrolls = sheet_scrolls(files)
    held = destination(ctx, name)
    existing = existing_of(held)

    %{
      filename: filename,
      candidates: candidates,
      folder: folder,
      name: name,
      named_by_manifest: manifest_name != nil,
      version: version_of(read),
      scrolls: scrolls,
      scripts: Enum.count(files, &script?/1),
      parts: parts_of(paths, read),
      files: length(files),
      bytes: Enum.reduce(files, 0, &(&2 + byte_size(&1.bytes))),
      agreed: files_digest(files),
      against: pairs_digest(held),
      update: update_of(existing, held, files),
      refusal: sheet_refusal(ctx, name, existing, files)
    }
  end

  # The folder's name, or the archive's for a pack at its top, spelled in
  # the name grammar: any other character becomes `-`.
  defp default_name("", filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/(\.tar\.gz|\.tgz|\.zip)\z/, "")
    |> grammar_name()
  end

  defp default_name(folder, _filename),
    do: folder |> String.split("/") |> List.last() |> grammar_name()

  defp grammar_name(name),
    do:
      name
      |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
      |> String.trim_leading("-")
      |> String.trim_leading("_")

  defp version_of(read) do
    Enum.find_value(@manifests ++ ["plugin.json"], fn manifest ->
      with bytes when is_binary(bytes) <- read.(manifest),
           {:ok, %{"version" => version}} when is_binary(version) <- Jason.decode(bytes) do
        version
      else
        _none -> nil
      end
    end)
  end

  defp script?(%{path: path, executable: executable}),
    do: executable or String.contains?("/" <> path, "/scripts/")

  defp sheet_scrolls(files) do
    for %{path: path, bytes: bytes} <- Enum.sort_by(files, & &1.path),
        [skills, folder, manifest] <- [String.split(path, "/")],
        skills == AquaPath.skills_dirname() and manifest == AquaPath.skill_manifest_name() do
      {scroll, kept} =
        case AquaAgent.parse_frontmatter(bytes) do
          {:ok, meta, _body} ->
            fm = string(meta["name"])

            {if(AquaPath.valid_name?(fm), do: fm, else: folder),
             meta["disable-model-invocation"] == true}

          _unread ->
            {folder, false}
        end

      %{scroll: scroll, folder: folder, kept: kept}
    end
  end

  # What the destination holds, read once: whether a pack is there, and
  # its files, from which the sheet's "this replaces" and the files digest
  # it carries (`against`) are both made, so the two can never describe
  # two different moments. `nil` when no pack of that name is here. The
  # event after the reading is where a test holds the sheet to change the
  # destination meanwhile.
  defp destination(ctx, name) do
    held =
      if AquaPath.valid_name?(name) do
        case Arca.read_subtree(Context.actor(ctx), AquaPath.pack_dir(name)) do
          {:ok, [_ | _] = pairs} -> pairs
          _absent -> nil
        end
      end

    :telemetry.execute([:cyfr, :packs, :sheet, :destination], %{}, %{name: name})
    held
  end

  # The pack the destination holds, as far as the sheet asks: its origin,
  # `nil` for a folder whose record does not read.
  defp existing_of(nil), do: nil

  defp existing_of(pairs) do
    case record_of(pairs) do
      {:ok, %{origin: origin}} -> %{origin: origin}
      _unread -> %{origin: nil}
    end
  end

  defp sheet_refusal(_ctx, name, existing, files) do
    cond do
      not AquaPath.valid_name?(name) ->
        "Give the pack a name of letters, digits, `_` and `-`"

      name == @cyfr ->
        "`#{@cyfr}` is CYFR's own pack: give this one another name"

      match?(%{origin: "own"}, existing) ->
        "You have a pack of your own named `#{name}`: give this one another name"

      existing != nil and existing.origin != "brought" ->
        "A pack named `#{name}` is already here: give this one another name"

      Enum.any?(files, &(&1.path == AquaPath.record_name())) ->
        "The pack carries `#{AquaPath.record_name()}` at its root, a name CYFR keeps for its own " <>
          "record of a pack"

      true ->
        case bounded(name, Enum.map(files, &{String.split(&1.path, "/"), &1.bytes})) do
          :ok -> nil
          {:error, {:invalid_argument, sentence}} -> sentence
        end
    end
  end

  # What an update would change, scripts and hooks first, then the rest,
  # each in path order: `nil` when no brought pack of that name is here.
  defp update_of(%{origin: "brought"}, pairs, files) do
    case pairs do
      [_ | _] ->
        record = with {:ok, r} <- record_of(pairs), do: r

        old =
          for {rel, bytes} <- pairs, rel != [AquaPath.record_name()], into: %{} do
            path = Enum.join(rel, "/")

            {path,
             {Prima.Digest.sha256(bytes), is_map(record) and executable?(record, path, bytes)}}
          end

        new = Map.new(files, &{&1.path, {Prima.Digest.sha256(&1.bytes), &1.executable}})

        changes =
          for path <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
              change = change(Map.get(old, path), Map.get(new, path)),
              change != nil,
              do: %{path: path, change: change, first: first?(path, new, old)}

        changes
        |> Enum.sort_by(&{not &1.first, &1.path})
        |> Enum.map(&Map.delete(&1, :first))

      _unread ->
        []
    end
  end

  defp update_of(_existing, _pairs, _files), do: nil

  defp change(nil, _new), do: :added
  defp change(_old, nil), do: :removed
  defp change(same, same), do: nil
  defp change(_old, _new), do: :changed

  defp first?(path, new, old) do
    executable = match?({_, true}, Map.get(new, path)) or match?({_, true}, Map.get(old, path))

    executable or String.contains?("/" <> path, "/scripts/") or
      String.starts_with?(path, "hooks/")
  end

  @doc """
  The digest a person agrees to on the sheet, bound to a pack's files and
  never to a revision: the SHA-256 over each file but the record, in path
  order, of its path, its size, its SHA-256 and its executable bit, each
  followed by a NUL. Switching the pack on and off leaves it as it is.
  """
  @spec files_digest([%{path: String.t(), bytes: binary(), executable: boolean()}]) :: String.t()
  def files_digest(files) do
    files
    |> Enum.reject(&(&1.path == AquaPath.record_name()))
    |> Enum.sort_by(& &1.path)
    |> Enum.map(fn %{path: path, bytes: bytes, executable: x} ->
      [
        path,
        0,
        Integer.to_string(byte_size(bytes)),
        0,
        Prima.Digest.sha256(bytes),
        0,
        if(x, do: "1", else: "0"),
        0
      ]
    end)
    |> IO.iodata_to_binary()
    |> Prima.Digest.sha256()
  end

  defp pairs_digest(nil), do: nil

  defp pairs_digest(pairs) do
    record =
      case record_of(pairs) do
        {:ok, record} -> record
        {:error, _} -> %{origin: "brought", executable: []}
      end

    pairs
    |> Enum.reject(&(elem(&1, 0) == [AquaPath.record_name()]))
    |> Enum.map(fn {rel, bytes} ->
      path = Enum.join(rel, "/")
      %{path: path, bytes: bytes, executable: executable?(record, path, bytes)}
    end)
    |> files_digest()
  end

  @doc """
  Bring a pack in from an archive, or take an update of a brought pack
  of that name, as the sheet the person read showed it: `params` carries
  the `folder` and `name` the sheet was made with, the digest of the
  files the person agreed to (`agreed`), and the files digest of what the
  destination held when the sheet was made (`against`, absent when it
  held no pack). Both sides are the agreement: under the pack's write
  lock the incoming files must be the ones agreed to and the destination
  must still hold what the sheet showed, nothing or the same files, so a
  pack that appeared or changed since is refused with the sheet made
  again, `{:error, {:changed, sheet}}`, for the person to read again. A
  switch alone changes no files and leaves the agreement good. Answers
  `{:ok, name}`.
  """
  @spec bring_in(Context.t(), binary(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def bring_in(%Context{} = ctx, archive, filename, params) do
    with {:ok, sheet} <- sheet(ctx, archive, filename, params) do
      cond do
        sheet.refusal != nil ->
          refuse(sheet.refusal)

        sheet.agreed != params["agreed"] ->
          {:error, {:changed, sheet}}

        true ->
          case land(ctx, archive, sheet, params["against"]) do
            :changed ->
              with {:ok, again} <- sheet(ctx, archive, filename, params),
                   do: {:error, {:changed, again}}

            answer ->
              answer
          end
      end
    end
  end

  defp land(ctx, archive, sheet, against) do
    actor = Context.actor(ctx)
    {:ok, entries} = PackArchive.read(archive)
    candidate = Enum.find(sheet.candidates, &(&1.folder == sheet.folder))
    files = pack_files(entries, candidate)
    unit = AquaPath.pack_dir(sheet.name)

    Arca.Overlay.edit_unit(actor, unit, fn current ->
      held =
        case current && record_of(current) do
          nil -> nil
          {:ok, record} -> record
          {:error, _} -> :unread
        end

      on =
        case held do
          %{origin: "brought", on: on} -> on
          _new -> true
        end

      record = %{
        origin: "brought",
        source: sheet.filename,
        folder: sheet.folder,
        version: sheet.version,
        on: on,
        agreed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        agreed: sheet.agreed,
        executable: for(%{executable: true, path: p} <- files, do: p)
      }

      pairs =
        Enum.map(files, &{String.split(&1.path, "/"), &1.bytes}) ++
          [{[AquaPath.record_name()], encode_record(record)}]

      cond do
        pairs_digest(current) != against -> {:error, :changed}
        held != nil and not match?(%{origin: "brought"}, held) -> refuse(sheet_clash(sheet.name))
        true -> with :ok <- set_bounded(actor, sheet.name, record, pairs), do: {:ok, pairs}
      end
    end)
    |> case do
      :ok -> {:ok, sheet.name}
      {:error, :changed} -> :changed
      error -> error
    end
  end

  defp sheet_clash(name), do: "A pack named `#{name}` is already here: give this one another name"

  # The packs an archive holds: each folder with a `skills/` of scrolls or
  # a plugin manifest, and each folder of a lone `SKILL.md` that is no
  # scroll of such a pack.
  defp candidates(entries) do
    paths = Enum.map(entries, & &1.path)

    by_skills =
      for path <- paths,
          parts = String.split(path, "/"),
          length(parts) >= 3,
          [_folder, manifest] = Enum.take(parts, -2),
          manifest == AquaPath.skill_manifest_name(),
          Enum.at(parts, -3) == AquaPath.skills_dirname(),
          do: parts |> Enum.drop(-3) |> Enum.join("/")

    by_manifest =
      for path <- paths,
          manifest <- @manifests,
          path == manifest or String.ends_with?(path, "/" <> manifest),
          do: path |> String.replace_suffix(manifest, "") |> String.trim_trailing("/")

    packs = MapSet.new(by_skills ++ by_manifest)

    lone =
      for path <- paths,
          parts = String.split(path, "/"),
          List.last(parts) == AquaPath.skill_manifest_name(),
          folder = parts |> Enum.drop(-1) |> Enum.join("/"),
          not inside_pack?(parts, packs),
          do: folder

    (Enum.map(packs, &%{folder: &1, lone: false}) ++
       Enum.map(Enum.reject(lone, &MapSet.member?(packs, &1)), &%{folder: &1, lone: true}))
    |> Enum.uniq_by(& &1.folder)
    |> Enum.sort_by(& &1.folder)
  end

  defp inside_pack?(parts, packs) do
    length(parts) >= 3 and Enum.at(parts, -3) == AquaPath.skills_dirname() and
      MapSet.member?(packs, parts |> Enum.drop(-3) |> Enum.join("/"))
  end

  # A candidate's files by their paths inside the pack; a lone `SKILL.md`'s
  # folder is put under `skills/<its name>/`.
  defp pack_files(entries, %{folder: folder, lone: lone}) do
    prefix = if folder == "", do: "", else: folder <> "/"

    inside =
      for %{path: path} = entry <- entries,
          String.starts_with?(path, prefix),
          do: %{entry | path: String.replace_prefix(path, prefix, "")}

    if lone do
      name = lone_name(inside, folder)
      for entry <- inside, do: %{entry | path: "skills/" <> name <> "/" <> entry.path}
    else
      inside
    end
  end

  defp lone_name(inside, folder) do
    fallback = if folder == "", do: "scroll", else: folder |> String.split("/") |> List.last()

    with %{bytes: bytes} <- Enum.find(inside, &(&1.path == AquaPath.skill_manifest_name())),
         {:ok, meta, _body} <- AquaAgent.parse_frontmatter(bytes),
         name when is_binary(name) <- meta["name"],
         true <- AquaPath.valid_name?(name) do
      name
    else
      _none -> fallback
    end
  end

  # ---------------------------------------------------------------------------
  # Download
  # ---------------------------------------------------------------------------

  @doc """
  A pack as a `.tar.gz` in the layout it would be brought in by: its
  files under a folder of its name, with their executable bits, without
  CYFR's record. Bounded by the pack's own bounds. Answers
  `{:ok, %{filename: "<pack>.tar.gz", bytes: bytes}}`.
  """
  @spec download(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def download(%Context{} = ctx, pack) do
    actor = Context.actor(ctx)

    with true <- AquaPath.valid_name?(pack) || {:error, :not_found},
         {:ok, pairs} <- Arca.read_subtree(actor, AquaPath.pack_dir(pack)),
         {:ok, record} <- record_of(pairs) |> found(),
         :ok <- bounded(pack, pairs) do
      files =
        for {rel, bytes} <- Enum.sort_by(pairs, &elem(&1, 0)),
            rel != [AquaPath.record_name()] do
          path = Enum.join(rel, "/")
          {pack <> "/" <> path, bytes, executable?(record, path, bytes)}
        end

      {:ok, %{filename: pack <> ".tar.gz", stream: PackArchive.tar_gz_stream(files)}}
    end
  end

  defp found({:ok, _} = ok), do: ok
  defp found({:error, _}), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # The migration, `cyfr`'s refresh and the first pack
  # ---------------------------------------------------------------------------

  @doc """
  Make an athanor's packs whole against the release, under a fill's or
  the boot sync's claim (`claim:`):

    * the scrolls of the layout before packs (`aqua/skills/<name>/`) go:
      one the athanor made, or a shipped one it edited, moves with every
      file beside it into `mine` under `skills/<name>/`; an unedited
      shipped one is dropped, since `cyfr` carries it;
    * `cyfr` is copied in when the athanor lacks it, and made the seed's
      again when its files differ, its switch kept;
    * with `fill: true`, an athanor with no pack of the person's own named
      `mine` gets an empty one.
  """
  @spec settle(Context.t(), keyword()) :: :ok | {:error, term()}
  def settle(%Context{} = ctx, opts \\ []) do
    actor = Context.actor(ctx)
    claim = Keyword.take(opts, [:claim])

    with :ok <- migrate(actor, claim),
         :ok <- refresh_cyfr(actor, claim) do
      if Keyword.get(opts, :fill, false), do: first_pack(actor, claim), else: :ok
    end
  end

  defp migrate(actor, claim) do
    with {:ok, orphans} <- Arca.Overlay.orphan_units(actor, hd(AquaPath.root())) do
      scrolls = for {["aqua", "skills", name], pairs} <- orphans, do: {name, pairs}

      if scrolls == [] do
        :ok
      else
        moved =
          for {name, pairs} <- scrolls,
              not unedited_shipped?(name, pairs),
              {rel, bytes} <- pairs,
              do: {[AquaPath.skills_dirname(), name | rel], bytes}

        with :ok <- into_mine(actor, moved, claim) do
          Arca.Overlay.with_claim(claim[:claim], fn ->
            Enum.reduce_while(scrolls, :ok, fn {name, _pairs}, :ok ->
              case Arca.Overlay.drop_orphan(actor, ["aqua", "skills", name]) do
                :ok -> {:cont, :ok}
                {:error, _} = error -> {:halt, error}
              end
            end)
          end)
        end
      end
    end
  end

  defp unedited_shipped?(name, [{["SKILL.md"], bytes}]),
    do:
      MapSet.member?(
        Map.get(@shipped_scrolls, name, MapSet.new()),
        Prima.Digest.sha256_hex(bytes)
      )

  defp unedited_shipped?(_name, _pairs), do: false

  # What moves lands in `mine` beside what it holds. A scroll `mine`
  # already holds is known by its exact place, `skills/<name>/SKILL.md`
  # (a migration that ran before), and is kept as it is; a folder of the
  # same name elsewhere (`docs/planner/`) is no scroll and holds nothing
  # back. A file `mine` already holds at a moved file's path is kept. The
  # bounds do not refuse it: a migrated `mine` past them stays in the
  # store, in no index, and its card says why.
  defp into_mine(actor, moved, claim) do
    skills = AquaPath.skills_dirname()
    manifest = AquaPath.skill_manifest_name()

    Arca.Overlay.edit_unit(
      actor,
      AquaPath.pack_dir(@mine),
      fn current ->
        base = current || [{[AquaPath.record_name()], encode_record(own_record())}]
        held = MapSet.new(for {[^skills, name, ^manifest], _} <- base, do: name)
        paths = MapSet.new(base, &elem(&1, 0))

        {:ok,
         base ++
           Enum.reject(moved, fn {[_skills, name | _] = rel, _} ->
             MapSet.member?(held, name) or MapSet.member?(paths, rel)
           end)}
      end,
      claim
    )
  end

  defp first_pack(actor, claim) do
    case Arca.get(actor, AquaPath.pack_dir(@mine) ++ [AquaPath.record_name()]) do
      {:ok, _record} -> :ok
      {:error, :not_found} -> into_mine(actor, [], claim)
      {:error, _} = error -> error
    end
  end

  defp refresh_cyfr(actor, claim) do
    unit = AquaPath.pack_dir(@cyfr)
    seed = Arca.Storage.seed_prefix(hd(AquaPath.root())) ++ tl(unit)

    case Arca.Overlay.unit_status(actor, unit) do
      {:ok, :available} ->
        Arca.Overlay.pull_shipped(actor, unit, claim)

      {:ok, :shipped} ->
        with {:ok, shipped} <- Arca.read_subtree(Prima.Actor.system(), seed),
             {:ok, held} <- Arca.read_subtree(actor, unit) do
          if body(shipped) == body(held), do: :ok, else: reship(actor, unit, shipped, claim)
        end

      {:ok, _absent_or_own} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp body(pairs),
    do: pairs |> Enum.reject(&(elem(&1, 0) == [AquaPath.record_name()])) |> Enum.sort()

  defp reship(actor, unit, shipped, claim) do
    Arca.Overlay.edit_unit(
      actor,
      unit,
      fn current ->
        on =
          with pairs when is_list(pairs) <- current,
               {:ok, %{on: on}} <- record_of(pairs) do
            on
          else
            _new -> true
          end

        with {:ok, record} <- record_of(shipped) do
          {:ok, body(shipped) ++ [{[AquaPath.record_name()], encode_record(%{record | on: on})}]}
        end
      end,
      claim
    )
  end
end
