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
  `pack_view/3` answers the packs that digest names (see its doc), or
  `{:moved, current}` when the store has moved on.

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
  @origins ~w(cyfr brought own)
  @manifests [".claude-plugin/plugin.json", ".codex-plugin/plugin.json", ".cursor-plugin/plugin.json"]

  @path_format ~r/\A[A-Za-z0-9_.\-\/]+\z/

  # Every `SKILL.md` the seed shipped under `aqua/skills/` up to this
  # release, as SHA-256 hex: the migration drops an athanor's copy of a
  # shipped scroll that still holds one of these bytes alone, since `cyfr`
  # carries it, and moves any other into `mine`. Generated with
  # `git log --format=%H -- seed/aqua/skills/<name>/SKILL.md` and
  # `git show <commit>:<path> | sha256sum` for every name.
  @shipped_scrolls MapSet.new(~w(
    06a36e0e1e5a7b07bcb90c6af9338b6594a70f3a58f56ca3d62e0e529394cd67
    07a1f3de6b73d936fbc01421edb579177f00c4824127370ff235348e1a18ce3e
    0bd13c1e5b5f1fd0a22168ea3e8fb885f5fef642ac720c95ca6ebbe9e16a2d95
    0cdc120a41d6afc4abcd23587f988bd4d395f057a5b71a6849c46c2bbcc20ea4
    11bd967493cb10eecd0d2b00b85d4289fa3d35d0babb4046d3aa8d0b3694879b
    13bec2d71f36e43367b53d4c43faf98132850d946767ba7a8b1c0d7bc195e865
    1441005f19b7e1d99156eb1c57df078b7f6521da2fa131acd7b8191d9393bffc
    182644dda3bdac220cd09629448b57828f4bbc40688994c006f56600016a88f6
    1e02b029aad74a67985817fe46e72914c141b6602968bb9671d7ff7e92df8780
    26d97a54eea4d1503b16e043a9836529eb8e577eee4f66e13d08e9882d18f2e4
    27923f51cffe3eed6403a6846c1c0bb2bfcc01ac6d9b66a8a764f1893da067c3
    286664b1846ac31a733f2eae84eea96faa7743c3f89000233cfce7fa7b839fce
    2e97c82ddcb29c2fd5281a970f602e2958b718427557ae3066e0807941dc8d3f
    30d5f282e7c56a3f8958a7995781b8ef6ff76eedc9f6babda9c87341d6ca91d2
    358ef5b0f64ccb584940fecf2d162c18175ecec76e30ab640b3c53800b001468
    3899ab0ab9af3eefe7c380899d19649eb271cfa39d66186f9f8260d1246514cd
    3c78fbbe9de3537308b20c7241d35529f70de34c2a08fb9e9dd6e8a4aa556027
    3e965988630c06df65d8922424acaca8055db728e1b8ba1e4751f2d164725164
    435b1d3d6e437c75038b3c22e19ae51c7daa84d4fd9cb9c95297b6c61153c415
    440d225e68dd9bc2fd744b332c402330d0007bbf330f838197dbfbad41248c0a
    4af16e92541408497d60bebe7f599faf1ddaf23fb0be8754c00c2ce6bdf976ac
    4bc03dc8a157acd36026b4f3ef161641125f1cbcc2c6f302e0ae95d010855eaf
    4ee383e09a08e1bf4fe8987a12349715041fc572f1dfac59dd771df58b294838
    5125f0a1a501b7b6813287bc7200ca99ded1db64f9953d083bb7c70bb6af457d
    57febc03844dde59626b7a544cc9945698f0b9518a360015301cb9d6c1729b4c
    5961410d742a02faca6307ef2bd7eb7605ddc217b51a11e44159635dae0657c3
    59a2e5467dd6c5664f1c90f0bb8e2fe50eff2839311a49ef646129bb337fb4ec
    615f1469f10ba71b899142328f51ae28fb9a5ad99e5724316b21d466e070291f
    65fbeb2d9a3e1bdc8746fab33cf87d131c438f00d6f10a533bb621324de79801
    6666ca3b6e44cafdcb955a17e59421f398e32881048808ec43b7340aae53652c
    6a4b4285c46f020239db0f01e52ee2a3f2e6f4961e8f460ef38b5fe5b7de0da4
    6b0a6f9e3567add2405eab364f4eb3d906df81bb1b1484fbc505c28ed84416d3
    6ee2f596768c40422b8614d1762b1acf5041d44eeea90c20ced34c6590367d33
    6f98d77d68a6524b26933a4755cd15d9cad7dfae81218bfa3dc86f9d22c3e093
    72be2748473c3e8a53f451ca5f5a55165cd8923b95bfcb17dcf267b7d56cc605
    748a3c120a7f9134122986058da12aaf90ac82ec2ccd46490bb3a2c8238ad7ec
    76035857187eb05e499ba470e26f98debc0ef8e83fe8068320c684a6e03031a8
    7d3e7b9789f9639918624dbbf88ab63012a85ba65af2f5ab8f7f002592687d64
    7e0c572e88399ff72c62b9e11dd6af448d6d92912c4cf3d0612674c7581c4635
    7eed37ee4ade44549569e06b132aae5ea0dfc7891d396fcc851cd223242ad661
    82f3d5ecb8d8dd821850406989d55232b1f50e0637962d18c96286256f55262e
    852424434cf7dcbf757901a39aaae8b627994af44531bf9fd6c67378c6d8cbff
    922bb1be5df5f317b5219a9fc2deadc9cc944c8bcda3106a8803b8051015e2e8
    92c6d01151b9832edcc31e106e3682bef9dc9ca5cbc138ea58c056029fb91ad1
    991398251e348d98e682a8115d9eb4503219a94f1b4d3d387227ffb7f21adc01
    9bde2bce25acbd0968fdedb440a9f89416ae1c2f2e1368e076e179dc90425d66
    9d675400573f96a483376d47197cddcc61bd8e5c90951db9c684c3b5766b2321
    9f5f4e06f665230c1f61d0ed367463073f44a0be9dfe8bacb5943e8b55e52c08
    a8a5d0aa70003e9114584e61b24128931762cccaa16caa5a6a22d7aa643472fa
    ac0f7bdd5ccf0f2d97cc8c8ad986a81e2e09717c7248f95c478d2cb858662da7
    ad776325c6d5807f506ba4eb8c4fc79fdaa5972a1b99a1c32b3edd8162d9091c
    bffd96fb99179010b3c7f06c0a78afe32285382a59d76a80fe849e01b9f2cdea
    c105be873bccbfb28721e1c598e190e711dd25ac296fe26efe7f45ae025e49d0
    caf4c01ed1bca51f53a36aa8b512daa7095cd0dbb3d15628508d33fe2fb93170
    d11c0453300e117604fc504dd5ca8be0776dbaaff0388b9ac845ae0c2491e15d
    d2cdcb8796f35abc4fa211e1ec60ce692ae8aa9d523f06065f268f584590e9b6
    d4f7f2972811b85cc11a5e8c1ed3f9663aad5a175d659a1b1137834f6df64f0d
    d95789603a21677612397e5e455c915cd1ab50f489497d139d88b4849f100e94
    ed01fbe81f93ba7e6b241e9174b21e6bb5cace263e4637dae1b21c346da7f930
    edb3b6253df6422c5b35ad4380232608feb0bc9f078276a24e3aad2f47e433c4
    f1a7bf433d429f773d6a054a8de609afff38a78210e840649f5b9b5fe448c06d
    f3c15e223b4b50aacf57404e09f49ee895bbbbcad49abab1832bab7fced38f6c
    fd1e03c0765c78f8039854f0e19fb6385b79484efa73a63c0a37c7342623daeb
  ))

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

  @doc "A pack's bounds and the bounds of the packs switched on together."
  @spec bounds() :: %{
          pack_files: pos_integer(),
          pack_bytes: pos_integer(),
          set_files: pos_integer(),
          set_bytes: pos_integer(),
          path_bytes: pos_integer()
        }
  def bounds,
    do: %{
      pack_files: @pack_files,
      pack_bytes: @pack_bytes,
      set_files: @set_files,
      set_bytes: @set_bytes,
      path_bytes: @path_bytes
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
      {:ok, Enum.flat_map(names, &List.wrap(read_pack(actor, &1, :card)))}
    end
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

    with {:ok, leaves} <- Arca.list_recursive(actor, dir) do
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
      bytes = max(pack_bytes(actor, dir) - record_bytes, 0)

      past = past || pack_past(length(files), bytes)
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
      {:error, :not_found} -> nil
      {:error, _} -> nil
    end
  end

  defp pack_bytes(actor, dir) do
    case Arca.usage(actor, dir) do
      {:ok, %{bytes: bytes}} -> bytes
      _unread -> 0
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
      scroll = if AquaPath.valid_name?(fm_name), do: fm_name, else: folder
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

  defp parts_of(files, read) do
    %{
      agents: named_under(files, "agents/"),
      commands: named_under(files, "commands/"),
      hooks: hooks_of(files, read),
      servers: servers_of(files, read)
    }
  end

  defp named_under(files, prefix) do
    for path <- files,
        String.starts_with?(path, prefix),
        rest = String.replace_prefix(path, prefix, ""),
        not String.contains?(rest, "/"),
        String.ends_with?(rest, ".md"),
        do: String.replace_suffix(rest, ".md", "")
  end

  defp hooks_of(files, read) do
    if "hooks/hooks.json" in files do
      with bytes when is_binary(bytes) <- read.("hooks/hooks.json"),
           {:ok, %{"hooks" => hooks}} when is_map(hooks) <- Jason.decode(bytes) do
        Enum.sort(Map.keys(hooks))
      else
        _other -> ["hooks/hooks.json"]
      end
    else
      []
    end
  end

  # Every MCP server a pack would start, from the three ways a plugin
  # declares them: a `.mcp.json`, a manifest's inline `mcpServers`, and a
  # file a manifest names there.
  defp servers_of(files, read) do
    from_mcp_json = if ".mcp.json" in files, do: server_names(read.(".mcp.json")), else: []

    from_manifests =
      for manifest <- ["plugin.json" | @manifests], manifest in files, reduce: [] do
        acc ->
          with bytes when is_binary(bytes) <- read.(manifest),
               {:ok, %{"mcpServers" => declared}} <- Jason.decode(bytes) do
            acc ++ declared_servers(declared, files, read)
          else
            _none -> acc
          end
      end

    Enum.uniq(from_mcp_json ++ from_manifests)
  end

  defp declared_servers(declared, _files, _read) when is_map(declared),
    do: Enum.sort(Map.keys(declared))

  defp declared_servers(declared, files, read) when is_binary(declared) do
    rel = declared |> String.trim_leading("./")
    if rel in files, do: server_names(read.(rel)), else: []
  end

  defp declared_servers(_declared, _files, _read), do: []

  defp server_names(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"mcpServers" => servers}} when is_map(servers) -> Enum.sort(Map.keys(servers))
      {:ok, servers} when is_map(servers) -> Enum.sort(Map.keys(servers))
      _unread -> []
    end
  end

  defp server_names(_bytes), do: []

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
      %{on: true, origin: origin, scrolls: entries, paths: files, past: past} when origin != nil ->
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
      entry = Enum.find(card.scrolls, &(&1.folder == folder)) || %{shadowed: false, carried: false}

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

    if String.valid?(bytes) and not String.contains?(bytes, <<0>>) do
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
                            executable: boolean}]}]}

  in name order: every pack's name, revision digest and its record's
  line, and for each pack switched on every other file of it by its path
  inside `aqua/scrolls/<pack>/` (`[]` for a pack switched off). The
  record's line is what a keeper needs to recompute each revision digest
  (`content_identity` over every path of the unit, the record's among
  them) and the set's; it writes the files alone.
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
            do: {:cont, {:ok, [view_pack(name, identity, pairs) | acc]}},
            else: {:halt, :moved}

        {:error, :not_found} ->
          {:halt, :moved}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, packs} ->
        {:ok, %{digest: digest, packs: Enum.reverse(packs)}}

      :moved ->
        case revisions(actor) do
          {:ok, now} -> {:moved, set_digest(now)}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp view_pack(name, identity, pairs) do
    record_name = [AquaPath.record_name()]
    {[{_rel, raw}], body} = Enum.split_with(pairs, &(elem(&1, 0) == record_name))
    record = with {:ok, r} <- decode_record(raw), do: r

    on = match?(%{on: true}, record)

    files =
      if on do
        for {rel, bytes} <- Enum.sort_by(body, &elem(&1, 0)) do
          path = Enum.join(rel, "/")

          %{
            path: path,
            size: byte_size(bytes),
            sha256: Prima.Digest.sha256(bytes),
            executable: executable?(record, path, bytes)
          }
        end
      else
        []
      end

    %{
      name: name,
      revision: identity,
      on: on,
      record: %{path: AquaPath.record_name(), size: byte_size(raw), sha256: Prima.Digest.sha256(raw)},
      files: files
    }
  end

  defp recomputed(pairs) do
    pairs
    |> Enum.map(fn {rel, bytes} -> {rel, Prima.Digest.sha256(bytes), byte_size(bytes)} end)
    |> Arca.Overlay.content_identity()
  end

  @doc """
  One file of a pack by its path inside the pack, for `athanor` under the
  actor: its bytes. The record is no file of the pack.
  """
  @spec pack_file(Context.t(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def pack_file(%Context{} = ctx, athanor, pack, path) do
    with :ok <- own_athanor(ctx, athanor),
         true <- AquaPath.valid_name?(pack) and is_binary(path),
         :ok <- pack_path(path),
         false <- path == AquaPath.record_name() do
      Arca.get(Context.actor(ctx), AquaPath.pack_dir(pack) ++ String.split(path, "/"))
    else
      {:error, {:invalid_argument, _}} -> {:error, :not_found}
      {:error, _} = error -> error
      _not_a_file -> {:error, :not_found}
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

  defp admitted(_pack, nil, next) do
    record = own_record()
    {:ok, record, next ++ [{[AquaPath.record_name()], encode_record(record)}]}
  end

  defp admitted(pack, current, next) do
    case record_of(current) do
      {:ok, %{origin: "own"} = record} -> {:ok, record, next}
      {:ok, %{origin: origin}} -> {:error, sealed(pack, origin)}
      {:error, _} -> refuse("The pack `#{pack}` has a record that cannot be read: nothing was written")
    end
  end

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
              {:halt,
               refuse("`#{path}` is past a file's #{Arca.Files.max_write()} bytes")}

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

  defp set_check(actor, pack, files, bytes) do
    with {:ok, names} <- pack_names(actor) do
      {others_files, others_bytes} =
        for name <- names,
            name != pack,
            %{on: true, files: f, bytes: b} <- [read_pack(actor, name, :index)],
            reduce: {0, 0} do
          {fs, bs} -> {fs + f, bs + b}
        end

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

  defp refuse(sentence), do: {:error, {:invalid_argument, sentence}}

  # ---------------------------------------------------------------------------
  # Writes Files cannot say: a scroll's manifest by its name, the switch, a copy
  # ---------------------------------------------------------------------------

  @doc """
  Write a scroll's manifest in a pack of the person's own, as an ordinary
  write meets `admit_edit/4`: `:create` makes `skills/<scroll>/SKILL.md`
  (the pack too, when it has none) and refuses a scroll of that name;
  `{:update, fun}` rewrites the scroll's manifest, `fun` given its bytes
  and answering the next ones.
  """
  @spec put_scroll(
          Context.t(),
          String.t(),
          binary() | nil,
          :create | {:update, (binary() -> {:ok, binary()} | {:error, term()})}
        ) :: :ok | {:error, term()}
  def put_scroll(%Context{} = ctx, name, manifest, mode) do
    actor = Context.actor(ctx)

    case split_name(name) do
      {:ok, pack, scroll} ->
        unit = AquaPath.pack_dir(pack)

        Arca.Overlay.edit_unit(actor, unit, fn current ->
          with {:ok, next} <- scroll_written(actor, pack, scroll, current || [], manifest, mode),
               do: admit_edit(actor, unit, current, next)
        end)

      {:bare, bare} ->
        bare_refusal(actor, bare)

      :error ->
        refuse("A scroll is named by its pack and its name, like `#{@mine}:research`")
    end
  end

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

      Arca.Overlay.edit_unit(actor, unit, fn current ->
        pairs = current || []
        dest = [AquaPath.skills_dirname(), folder]

        if Enum.any?(pairs, fn {rel, _} -> List.starts_with?(rel, dest) end),
          do: refuse("`#{to}` already has a scroll folder `#{folder}`: delete it first"),
          else: admit_edit(actor, unit, current, pairs ++ copied)
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
         do: {:ok, for({rel, bytes} <- pairs, do: {[AquaPath.skills_dirname(), folder | rel], bytes})}
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
    existing = existing(ctx, name)

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
      update: update_of(ctx, existing, name, files),
      refusal: sheet_refusal(ctx, name, existing, files)
    }
  end

  defp default_name("", filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/(\.tar\.gz|\.tgz|\.zip)\z/, "")
  end

  defp default_name(folder, _filename), do: folder |> String.split("/") |> List.last()

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
            {if(AquaPath.valid_name?(fm), do: fm, else: folder), meta["disable-model-invocation"] == true}

          _unread ->
            {folder, false}
        end

      %{scroll: scroll, folder: folder, kept: kept}
    end
  end

  defp existing(ctx, name) do
    if AquaPath.valid_name?(name) do
      case read_pack(Context.actor(ctx), name, :card) do
        nil -> nil
        pack -> pack
      end
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
  defp update_of(ctx, %{origin: "brought"} = _existing, name, files) do
    actor = Context.actor(ctx)

    case Arca.read_subtree(actor, AquaPath.pack_dir(name)) do
      {:ok, pairs} ->
        record = with {:ok, r} <- record_of(pairs), do: r

        old =
          for {rel, bytes} <- pairs, rel != [AquaPath.record_name()], into: %{} do
            path = Enum.join(rel, "/")
            {path, {Prima.Digest.sha256(bytes), is_map(record) and executable?(record, path, bytes)}}
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

  defp update_of(_ctx, _existing, _name, _files), do: nil

  defp change(nil, _new), do: :added
  defp change(_old, nil), do: :removed
  defp change(same, same), do: nil
  defp change(_old, _new), do: :changed

  defp first?(path, new, old) do
    executable = match?({_, true}, Map.get(new, path)) or match?({_, true}, Map.get(old, path))
    executable or String.contains?("/" <> path, "/scripts/") or String.starts_with?(path, "hooks/")
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
      [path, 0, Integer.to_string(byte_size(bytes)), 0, Prima.Digest.sha256(bytes), 0,
       if(x, do: "1", else: "0"), 0]
    end)
    |> IO.iodata_to_binary()
    |> Prima.Digest.sha256()
  end

  @doc """
  Bring a pack in from an archive, or take an update of a brought pack
  of that name, as the sheet the person read showed it: `params` carries
  the `folder` and `name` the sheet was made with and the digest the
  person agreed to (`agreed`). An archive whose files are no longer the
  ones agreed to is refused with the sheet made again,
  `{:error, {:changed, sheet}}`, so the person is shown it again.
  Answers `{:ok, name}`.
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
          land(ctx, archive, sheet)
      end
    end
  end

  defp land(ctx, archive, sheet) do
    actor = Context.actor(ctx)
    {:ok, entries} = PackArchive.read(archive)
    candidate = Enum.find(sheet.candidates, &(&1.folder == sheet.folder))
    files = pack_files(entries, candidate)
    unit = AquaPath.pack_dir(sheet.name)
    updating? = sheet.update != nil

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
        held == nil and updating? -> {:error, {:changed, sheet}}
        held != nil and not match?(%{origin: "brought"}, held) -> refuse(sheet_clash(sheet.name))
        held != nil and not updating? -> {:error, {:changed, sheet}}
        true -> with :ok <- set_bounded(actor, sheet.name, record, pairs), do: {:ok, pairs}
      end
    end)
    |> case do
      :ok -> {:ok, sheet.name}
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

      {:ok, %{filename: pack <> ".tar.gz", bytes: PackArchive.tar_gz(files)}}
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
              not unedited_shipped?(pairs),
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

  defp unedited_shipped?([{["SKILL.md"], bytes}]),
    do: MapSet.member?(@shipped_scrolls, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))

  defp unedited_shipped?(_pairs), do: false

  # What moves lands in `mine` beside what it holds; a folder `mine`
  # already holds (a migration that ran before) is kept as it is. The
  # bounds do not refuse it: a migrated `mine` past them stays in the
  # store, in no index, and its card says why.
  defp into_mine(actor, moved, claim) do
    Arca.Overlay.edit_unit(
      actor,
      AquaPath.pack_dir(@mine),
      fn current ->
        base = current || [{[AquaPath.record_name()], encode_record(own_record())}]
        held = MapSet.new(for {[_skills, folder | _], _} <- base, do: folder)
        {:ok, base ++ Enum.reject(moved, fn {[_skills, folder | _], _} -> MapSet.member?(held, folder) end)}
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
          {:ok,
           body(shipped) ++ [{[AquaPath.record_name()], encode_record(%{record | on: on})}]}
        end
      end,
      claim
    )
  end
end
