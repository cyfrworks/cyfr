# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture do
  @moduledoc """
  The tincture rules the component domain owns: which file a tincture
  serves as its entry, where its media live and how they are found, which
  extensions an asset may have, which files are never served, and the
  publish check a version passes before it is installed.

  Publish, index and serve read the same rules. Inside this domain the
  validators and the scaffolder call the functions here and keep their
  sentences; outside it, the `Compendium` facade answers
  `tincture_entry/1` as a typed refusal and `tincture_asset_rules/0` as one
  immutable map, and the HTTP adapter (`Emissary.Web.TinctureAssets`)
  serves by that map.

  The served types and the declaration grammar are the frame's rules
  (`Compendium.Tincture.Rules`), read here through the `Compendium` facade,
  so the extensions an asset may have are exactly the types a version
  serves.

  The SDK a tincture's page calls CYFR through (`sdk/0`), the tags that
  hand it to an entry page (`head_tags/3`) and the head a plain page is
  given first (`plain_entry/1`) are here too, so every page CYFR hands
  over, the endpoint's and the one Aqua's browser shows, carries the same
  bytes.
  """

  alias Sanctum.Context

  @sdk_path Path.join(:code.priv_dir(:cyfr), "static/sdk/cyfr.js")
  @external_resource @sdk_path
  # arca:bypass-ok=C — compile-time embed of the SDK source. Runtime never
  # reads from disk for this; mix recompiles the module if the file changes.
  @sdk_source File.read!(@sdk_path)

  # The `<head>` start tag an entry page's injected tags follow.
  @head_re ~r/(<head(?:\s[^>]*)?>)/

  # What a plain page's entry is prefixed with, so the tags always have a
  # head tag to follow.
  @plain_head "<!doctype html><head></head>"

  @reserved_files [Compendium.ComponentPath.manifest_name()]

  # What a version carries beside the files it serves: the registry's
  # readme and source tree (`Compendium.OCI.Client` lays them into the
  # unit), which the publish check does not hold to the served types.
  @readme "README.md"
  @source_dir "src"

  # The raster set the CSAM constraint blocks in the two DISCOVERY slots
  # (icon/preview): a tincture whose discovered media names one of these is
  # dropped from the listing, since no image is hash-matched against known
  # material. Deliberately narrower than the serve gate above — a directly
  # referenced raster asset inside an operator-installed app still serves;
  # the constraint is on what the registry SURFACES, not on what an
  # installed page may contain. `.webp` is blocked here and absent from
  # the serve gate, so it can neither be discovered nor served.
  @blocked_raster_extensions ~w(.png .jpg .jpeg .gif .webp)

  # Tincture media convention: fixed paths only, no globbing. The known
  # slots are probed through `Arca.exists?` so the same logic works against
  # Local FS and S3 (which has no real directories). This module is the
  # convention's one spelling — the scaffolder writes its placeholders
  # through the functions below, so what it writes, discovery finds.
  @media_icon_candidates ~w(public/media/icon.svg public/media/icon.png)
  @media_preview_extensions ~w(svg png)
  @media_preview_count 6

  @typedoc """
  The immutable rules a caller outside the domain reads: the default
  entry, the media directory and default slots (as segments), the preview
  count, the image extensions a page may build an asset URL for, the
  raster extensions discovery blocks, the extensions an asset may be
  served with, and the files never served.
  """
  @type asset_rules :: %{
          default_entry: String.t(),
          media_dir: [String.t()],
          default_icon: [String.t()],
          default_preview: [String.t()],
          preview_count: pos_integer(),
          image_extensions: [String.t()],
          blocked_raster_extensions: [String.t()],
          allowed_extensions: [String.t()],
          reserved_files: [String.t()]
        }

  @doc "The rules as one immutable map (`t:asset_rules/0`)."
  @spec asset_rules() :: asset_rules()
  def asset_rules do
    %{
      default_entry: default_entry(),
      media_dir: media_dir(),
      default_icon: default_icon(),
      default_preview: default_preview(),
      preview_count: preview_count(),
      image_extensions: image_extensions(),
      blocked_raster_extensions: @blocked_raster_extensions,
      allowed_extensions: allowed_extensions(),
      reserved_files: @reserved_files
    }
  end

  # Extensions the asset serve gate honors: the served types'
  # (`Compendium.tincture_served_types/0`).
  defp allowed_extensions, do: Compendium.tincture_served_types() |> Map.keys() |> Enum.sort()

  # Image extensions a console page may build an asset URL for: vector plus
  # every servable raster — derived from the serve gate, so the client-side
  # fast reject and the server-side gate cannot drift.
  defp image_extensions do
    allowed = allowed_extensions()
    [".svg" | @blocked_raster_extensions] |> Enum.filter(&(&1 in allowed))
  end

  @doc """
  The publish check a tincture version passes before it is installed: its
  declaration held to the frame's rules (`Compendium.tincture_declaration/1`),
  each stream it declares one a provider declares, with a subject that
  stream takes (`Compendium.tincture_check_streams/2` against
  `Sanctum.Catalog.streams/0`), every file it serves of a served type
  (`Compendium.tincture_served_types/0`), and its decompressed size within
  the registry's ceiling
  (`Compendium.Registry.tincture_max_decompressed_bytes/0`). `files` are
  the version's files as `{relative_path, byte_count}`, the excluded ones
  already out.

  A desktop (a declaration with the `tincture.desktop` block) is also
  held to what its controls run (`Compendium.tincture_check_desktop/2`)
  and holds its page, its entry
  (`Compendium.tincture_check_canvas_files/2`); its chrome declaration,
  which needs the files' bytes, is `check_chrome/2`'s.

  The files a version serves are all of them but the reserved files,
  dotfiles, its readme and its `src/` tree; for a built tincture (one that
  declares `tincture.build`) only those under the entry's directory and
  the media directory, the rest being the build's input. A file of another
  type is refused by name, and a version over the ceiling with its size.
  Answers the size, stated before anything is installed.
  """
  @spec check_version(map(), [{String.t(), non_neg_integer()}]) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def check_version(manifest, files) when is_map(manifest) and is_list(files) do
    size = Enum.reduce(files, 0, fn {_path, bytes}, acc -> acc + bytes end)

    with :ok <- check_size(size),
         :ok <- check_declaration(manifest, files),
         :ok <- check_types(manifest, files) do
      {:ok, size}
    end
  end

  defp check_size(size) do
    ceiling = Compendium.Registry.tincture_max_decompressed_bytes()

    if size > ceiling,
      do:
        {:error,
         "the version is #{size} bytes decompressed, over the registry's ceiling of " <>
           "#{ceiling} bytes"},
      else: :ok
  end

  defp check_declaration(manifest, files) do
    streams = Sanctum.Catalog.streams()

    with {:ok, declaration} <- Compendium.tincture_declaration(manifest),
         :ok <- Compendium.tincture_check_streams(declaration, streams),
         :ok <- check_canvas(declaration, manifest, streams, files) do
      :ok
    else
      {:error, {:invalid_tincture, sentence}} -> {:error, sentence}
    end
  end

  # A desktop's controls run only what it may offer, and its version holds
  # its page.
  defp check_canvas(%{desktop: %{}} = declaration, manifest, streams, files) do
    with :ok <- Compendium.tincture_check_desktop(declaration, streams) do
      Compendium.tincture_check_canvas_files(manifest, Enum.map(files, &elem(&1, 0)))
    end
  end

  defp check_canvas(_declaration, _manifest, _streams, _files), do: :ok

  @doc """
  The publish check of a desktop's chrome declaration, which reads the
  version's files (`read`, from a relative path to `{:ok, bytes}` or
  `:error`): the file and what it names held to the chrome's grammar and
  caps (`Compendium.tincture_check_chrome/2`). `:ok` for a tincture that
  names no chrome; a refusal names the file and its line. Publish runs it
  once `check_version/2` holds.
  """
  @spec check_chrome(map(), (String.t() -> {:ok, binary()} | :error)) ::
          :ok | {:error, String.t()}
  def check_chrome(manifest, read) when is_map(manifest) and is_function(read, 1) do
    with {:ok, declaration} <- Compendium.tincture_declaration(manifest),
         {:ok, _tokens} <- Compendium.tincture_check_chrome(declaration, read) do
      :ok
    else
      {:error, {:invalid_tincture, sentence}} -> {:error, sentence}
    end
  end

  defp check_types(manifest, files) do
    types = Compendium.tincture_served_types()
    roots = served_roots(manifest)

    refused =
      for {path, _bytes} <- files,
          served?(path, roots),
          not Map.has_key?(types, path |> Path.extname() |> String.downcase()),
          do: path

    case Enum.sort(refused) do
      [] ->
        :ok

      [path | rest] ->
        more = if rest == [], do: "", else: " (and #{length(rest)} more)"

        {:error,
         "#{path} is not a type a tincture serves#{more}; a served file is one of " <>
           (types |> Map.keys() |> Enum.sort() |> Enum.join(" "))}
    end
  end

  # The directories a built tincture serves from: its entry's top directory
  # and the media directory. `:all` for a tincture that is not built, or a
  # built one whose entry sits at the root.
  defp served_roots(manifest) do
    with true <- Compendium.tincture_lockfile_required?(manifest),
         {:ok, entry} <- entry_of(manifest),
         [top, _ | _] <- String.split(entry, "/") do
      [[top], media_dir()]
    else
      _ -> :all
    end
  end

  defp served?(path, roots) do
    segments = String.split(path, "/")
    name = List.last(segments)

    cond do
      name in @reserved_files or String.starts_with?(name, ".") -> false
      roots == :all -> path != @readme and hd(segments) != @source_dir
      true -> Enum.any?(roots, &List.starts_with?(segments, &1))
    end
  end

  # What a tincture serves when its manifest names no entry.
  defp default_entry, do: "index.html"

  @doc """
  The entry a tincture serves, for a caller outside the domain: the
  manifest's `tincture.entry` or the default (`entry_of/1`), held to the
  same rule publish and index use. Takes a tincture row (its `manifest`)
  or a manifest map. `{:error, :no_entry}` when there is no manifest to read,
  `{:error, :invalid_entry}` when the entry is refused.
  """
  @spec entry(term()) :: {:ok, String.t()} | {:error, :no_entry | :invalid_entry}
  def entry(%{manifest: manifest}), do: entry(manifest)

  def entry(manifest) when is_map(manifest) do
    case entry_of(manifest) do
      {:ok, entry} -> {:ok, entry}
      {:error, _message} -> {:error, :invalid_entry}
    end
  end

  def entry(_no_manifest), do: {:error, :no_entry}

  @doc """
  The entry a manifest names, or the default — one reading, for publish,
  for indexing and for serve. A refusal says what is wrong.
  """
  @spec entry_of(map()) :: {:ok, String.t()} | {:error, String.t()}
  def entry_of(manifest) when is_map(manifest),
    do: manifest |> get_in(["tincture", "entry"]) |> validate_entry()

  # An entry held to the rule: path-safe, not reserved, not a dotfile.
  defp validate_entry(nil), do: {:ok, default_entry()}
  defp validate_entry(""), do: {:ok, default_entry()}

  # Path safety answers first: it covers traversal, absolute paths and null
  # bytes, and its refusals name what is actually wrong. A `../escape.html`
  # begins with a dot, so a dotfile check placed above would refuse it for
  # the least useful of its several reasons.
  defp validate_entry(entry) when is_binary(entry) do
    with :ok <- path_safe(entry) do
      cond do
        entry in @reserved_files ->
          {:error, "entry must not be a reserved file (#{Enum.join(@reserved_files, ", ")})"}

        String.starts_with?(entry, ".") ->
          {:error, "entry must not be a dotfile"}

        true ->
          {:ok, entry}
      end
    end
  end

  defp validate_entry(_other), do: {:error, "entry must be a string"}

  # Branch on the typed refusal, independently of message wording.
  defp path_safe(entry) do
    case Prima.PathSafety.validate_relative_path(entry) do
      :ok ->
        :ok

      {:error, {:null_bytes, _}} ->
        {:error, "entry must not contain null bytes"}

      {:error, {:absolute_path, _}} ->
        {:error, "entry must be a relative path"}

      {:error, {reason, _}} when reason in [:dot_segment, :encoded_dots] ->
        {:error, "entry must not contain '..'"}

      {:error, {_reason, message}} ->
        {:error, "entry rejected: #{message}"}
    end
  end

  # ---------------------------------------------------------------------------
  # The pages CYFR hands over
  # ---------------------------------------------------------------------------

  @doc "The SDK's bytes: the bundle every page CYFR hands over holds."
  @spec sdk() :: binary()
  def sdk, do: @sdk_source

  @doc """
  `html` with `<base href="href">` and the SDK, inline under `nonce`,
  after its first `<head>` start tag, one with attributes too; nothing
  else of it moves. A document with no `<head>` tag is answered as it is,
  with neither.
  """
  @spec head_tags(binary(), String.t(), String.t()) :: binary()
  def head_tags(html, href, nonce) do
    escaped_href = href |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    injection =
      "\n<base href=\"#{escaped_href}\">\n<script nonce=\"#{nonce}\">#{@sdk_source}</script>"

    # The tags follow the head tag through a function, never a replacement
    # string: a string's `\\` and `\\N` are escapes, and the SDK's source
    # holds backslashes that must reach the page as they are.
    Regex.replace(@head_re, html, &(&1 <> injection), global: false)
  end

  @doc """
  A plain page's entry, `document` after `<!doctype html><head></head>`,
  so `head_tags/3` finds a head whatever the document's own markup: a
  head of its own, a body alone or no tag at all. Nothing of `document`
  is read. A tincture's entry is never passed through it: a tincture is
  served as it was written.
  """
  @spec plain_entry(binary()) :: binary()
  def plain_entry(document) when is_binary(document), do: @plain_head <> document

  @doc """
  The type a file of a version is served as, the file named by its
  segments inside the version: `{:ok, type}`, or `:error` for no file, a
  reserved file, a segment that is a dotfile, an unsafe path, or an
  extension the served types (`Compendium.tincture_served_types/0`) do
  not name. Every file the endpoint and Aqua's browser are handed of a
  version passes it.
  """
  @spec served_type([String.t()]) :: {:ok, String.t()} | :error
  def served_type(file) when is_list(file) do
    cond do
      file == [] -> :error
      Enum.any?(file, &(&1 in @reserved_files or String.starts_with?(&1, "."))) -> :error
      Prima.PathSafety.validate_relative_path(Enum.join(file, "/")) != :ok -> :error
      true -> type_of(List.last(file))
    end
  end

  defp type_of(name),
    do: Map.fetch(Compendium.tincture_served_types(), name |> Path.extname() |> String.downcase())

  @typedoc "One file of a version as it is handed over: its path inside the version, its type and its bytes."
  @type file :: %{path: String.t(), type: String.t(), bytes: binary()}

  @typedoc "The most files, and bytes of them together, one read of a version's files takes."
  @type bound :: %{files: pos_integer(), bytes: pos_integer()}

  @doc """
  The files of the tincture version `reference` names
  (`tincture:<publisher>.<name>:<version>`) as the endpoint reads them,
  under the caller's context: its entry as `entry/1` gives it, and every
  file of the version `served_type/1` passes, each with its type, in path
  order, its entry among them.

  The version is admitted as `source` admits a path
  (`Compendium.Providers.Source.admit/1`): its directory is one the
  layout's parser reads, of the `local` publisher, and its rows and bytes
  are the caller's athanor's, so another athanor's version is not found,
  as an absent one is. A canvas, or a version whose declaration today's
  rules refuse, holds no page and is refused, as the endpoint serves it
  none. Answers the tincture's name beside its entry and files.

  The files are held to `bound` before a byte of them is read: their
  count from the listing, their bytes from each file's own size as the
  store answers it (`Arca.usage/2`). More files or bytes than it takes
  are refused `:over_bound`.
  """
  @spec files(Context.t(), String.t(), bound()) ::
          {:ok, %{name: String.t(), entry: String.t(), files: [file()]}} | {:error, term()}
  def files(%Context{} = ctx, reference, %{files: _, bytes: _} = bound)
      when is_binary(reference) do
    with {:ok, ref} <- version_ref(reference),
         unit = Prima.ComponentPath.version_dir("tincture", ref.namespace, ref.name, ref.version),
         {:ok, _segments, _parts} <- Compendium.Providers.Source.admit(Enum.join(unit, "/")),
         {:ok, manifest} <- manifest(ctx, reference),
         :ok <- holds_pages(manifest, reference),
         {:ok, entry} <- entry_of(manifest) |> invalid(),
         {:ok, files} <- read_files(ctx, unit, bound) do
      if Enum.any?(files, &(&1.path == entry)),
        do: {:ok, %{name: ref.name, entry: entry, files: files}},
        else: {:error, {:not_found, "entry", entry}}
    end
  end

  defp version_ref(reference) do
    with {:ok, %Prima.ComponentRef{type: "tincture", version: version} = ref}
         when is_binary(version) <- Prima.ComponentRef.parse(reference),
         :ok <- Prima.ComponentRef.validate_version(version) do
      {:ok, ref}
    else
      _other ->
        {:error,
         {:invalid_argument,
          "tincture names a tincture version as tincture:local.<name>:<version>"}}
    end
  end

  # The version's manifest as its row holds it, the one the endpoint
  # serves by. A store that cannot say is unavailable, never not found.
  defp manifest(ctx, reference) do
    case Compendium.inspect_component(ctx, reference) do
      {:ok, %{"manifest" => manifest}} when is_map(manifest) -> {:ok, manifest}
      {:ok, _no_manifest} -> {:error, {:not_found, {:component, reference}}}
      {:error, {:not_found, _what} = reason} -> {:error, reason}
      {:error, {:corrupt, _what} = reason} -> {:error, reason}
      {:error, _unanswered} -> {:error, {:unavailable, "The tincture's version"}}
    end
  end

  # A version holds pages only when the frame's rules read its declaration
  # and it is no canvas, as the endpoint serves it.
  defp holds_pages(manifest, reference) do
    case Compendium.tincture_declaration(manifest) do
      {:ok, declaration} ->
        if Prima.Manifest.Tincture.canvas?(declaration),
          do: {:error, {:invalid_argument, "#{reference} is a canvas, which holds no page"}},
          else: :ok

      {:error, _refused} ->
        {:error,
         {:invalid_argument, "#{reference} declares what today's rules do not read: no page"}}
    end
  end

  defp invalid({:ok, entry}), do: {:ok, entry}
  defp invalid({:error, sentence}), do: {:error, {:invalid_argument, sentence}}

  defp read_files(ctx, unit, bound) do
    actor = Context.actor(ctx)

    with {:ok, leaves} <- Arca.list_recursive(actor, unit),
         served =
           for(
             leaf <- leaves,
             file = Enum.drop(leaf, length(unit)),
             {:ok, type} <- [served_type(file)],
             do: {file, type}
           ),
         :ok <- within(actor, unit, served, bound),
         {:ok, files} <- read_each(actor, unit, Enum.sort(served)) do
      {:ok, files}
    else
      {:error, :over_bound} -> {:error, :over_bound}
      {:error, _unanswered} -> {:error, {:unavailable, "The tincture's files"}}
    end
  end

  # The bound, held before any file is read: the count first, then each
  # file's size as the store answers it, without its bytes.
  defp within(_actor, _unit, served, %{files: files}) when length(served) > files,
    do: {:error, :over_bound}

  defp within(actor, unit, served, %{bytes: bytes}) do
    Enum.reduce_while(served, {:ok, 0}, fn {file, _type}, {:ok, total} ->
      case Arca.usage(actor, unit ++ file) do
        {:ok, %{bytes: size}} when total + size <= bytes -> {:cont, {:ok, total + size}}
        {:ok, _past} -> {:halt, {:error, :over_bound}}
        {:error, _unanswered} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _total} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp read_each(actor, unit, served) do
    served
    |> Enum.reduce_while([], fn {file, type}, acc ->
      case Arca.get(actor, unit ++ file) do
        {:ok, bytes} -> {:cont, [%{path: Enum.join(file, "/"), type: type, bytes: bytes} | acc]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      files -> {:ok, Enum.reverse(files)}
    end
  end

  # The media directory inside a tincture version, as segments.
  defp media_dir, do: ["public", "media"]

  @doc "The default icon slot the scaffolder fills, as segments."
  @spec default_icon() :: [String.t()]
  def default_icon, do: media_dir() ++ ["icon.svg"]

  @doc "The default preview slot the scaffolder fills, as segments."
  @spec default_preview() :: [String.t()]
  def default_preview, do: media_dir() ++ ["preview-1.svg"]

  @doc "How many preview slots the picker card shows."
  @spec preview_count() :: pos_integer()
  def preview_count, do: @media_preview_count

  @doc """
  Discover a tincture version's media through Arca, by the fixed
  `public/media/` convention, under the caller's context.

  Returns relative paths (icon and previews), or nil and an empty list
  when nothing matches. Worst case: ~14 `Arca.exists?` calls per tincture
  (one round-trip each on S3; one stat each on Local).
  """
  @spec media(Context.t(), [String.t()]) :: %{icon: String.t() | nil, previews: [String.t()]}
  def media(%Context{} = ctx, version_segs) when is_list(version_segs) do
    %{
      icon: discover_icon(ctx, version_segs),
      previews: discover_previews(ctx, version_segs)
    }
  end

  defp discover_icon(ctx, version_segs) do
    Enum.find(@media_icon_candidates, fn rel ->
      Arca.exists?(Context.actor(ctx), version_segs ++ String.split(rel, "/"))
    end)
  end

  defp discover_previews(ctx, version_segs) do
    Enum.flat_map(1..@media_preview_count, fn i ->
      Enum.find_value(@media_preview_extensions, [], fn ext ->
        rel = "public/media/preview-#{i}.#{ext}"

        if Arca.exists?(Context.actor(ctx), version_segs ++ String.split(rel, "/")),
          do: [rel]
      end)
    end)
  end
end
