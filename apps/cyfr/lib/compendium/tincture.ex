# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture do
  @moduledoc """
  The tincture rules the component domain owns: which file a tincture
  serves as its entry, where its media live and how they are found, which
  extensions an asset may have and which files are never served.

  Publish, index and serve read the same rules. Inside this domain the
  validators and the scaffolder call the functions here and keep their
  sentences; outside it, the `Compendium` facade answers
  `tincture_entry/1` as a typed refusal and `tincture_asset_rules/0` as one
  immutable map, and the HTTP adapter (`CyfrWeb.Ingress.TinctureAssets`)
  serves by that map.
  """

  alias Sanctum.Context

  @reserved_files ["data.db", Compendium.ComponentPath.manifest_name(), "schema.sql"]
  @allowed_extensions ~w(.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map)

  # The raster set the CSAM launch constraint blocks in the two DISCOVERY
  # slots (icon/preview): a tincture whose discovered media names one of
  # these is dropped from the listing until hash matching (PhotoDNA)
  # ships. Deliberately narrower than the serve gate above — a directly
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
      blocked_raster_extensions: blocked_raster_extensions(),
      allowed_extensions: allowed_extensions(),
      reserved_files: reserved_files()
    }
  end

  @doc "Extensions the asset serve gate honors — the one spelling."
  @spec allowed_extensions() :: [String.t()]
  def allowed_extensions, do: @allowed_extensions

  @doc "The files a tincture never serves, as an entry or as an asset."
  @spec reserved_files() :: [String.t()]
  def reserved_files, do: @reserved_files

  @doc "The raster set the listing's CSAM launch constraint blocks."
  @spec blocked_raster_extensions() :: [String.t()]
  def blocked_raster_extensions, do: @blocked_raster_extensions

  @doc """
  Image extensions a console page may build an asset URL for: vector plus
  every servable raster — derived from the serve gate, so the client-side
  fast reject and the server-side gate cannot drift.
  """
  @spec image_extensions() :: [String.t()]
  def image_extensions do
    [".svg" | @blocked_raster_extensions] |> Enum.filter(&(&1 in @allowed_extensions))
  end

  @doc """
  Whether a `tincture.connect` entry is a bare domain with an optional
  `*.` prefix — the grammar the manifest validator holds entries to and
  the served page's CSP is built from, owned by `Cyfr.Manifest`.
  """
  @spec valid_connect_domain?(term()) :: boolean()
  defdelegate valid_connect_domain?(domain), to: Cyfr.Manifest

  @doc "What a tincture serves when its manifest names no entry."
  @spec default_entry() :: String.t()
  def default_entry, do: "index.html"

  @doc """
  The entry a tincture serves, for a caller outside the domain: the
  manifest's `tincture.entry` or the default, held to the same rule
  publish and index use. Takes a tincture row (its `manifest`) or a
  manifest map. `{:error, :no_entry}` when there is no manifest to read,
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
  def entry_of(manifest) when is_map(manifest) do
    manifest |> get_in(["tincture", "entry"]) |> validate_entry()
  end

  @doc "An entry held to the rule: path-safe, not reserved, not a dotfile."
  @spec validate_entry(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_entry(nil), do: {:ok, default_entry()}
  def validate_entry(""), do: {:ok, default_entry()}

  # Path safety answers first: it covers traversal, absolute paths and null
  # bytes, and its refusals name what is actually wrong. A `../escape.html`
  # begins with a dot, so a dotfile check placed above would refuse it for
  # the least useful of its several reasons.
  def validate_entry(entry) when is_binary(entry) do
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

  def validate_entry(_other), do: {:error, "entry must be a string"}

  # Branch on the typed refusal, independently of message wording.
  defp path_safe(entry) do
    case Cyfr.PathSafety.validate_relative_path(entry) do
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

  @doc "The media directory inside a tincture version, as segments."
  @spec media_dir() :: [String.t()]
  def media_dir, do: ["public", "media"]

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
