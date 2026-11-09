# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Appearance do
  @moduledoc """
  How Prism's screen looks, as a desktop is told it and as a desktop's
  chrome changes it.

  ## What a desktop is told

  A desktop's handshake carries the screen's appearance (`block/1`): its
  `mode`, Prism's one theme, `dark`; its `accent`, the console's own
  accent colour (`--color-accent-primary` in `assets/css/app.css`, which a
  test holds to `accent/0`); and the `locale`, `time_zone` and
  `safe_areas` the person's browser reports when the view connects
  (`assets/js/app.js`), each held to the wire's grammar
  (`Prima.TinctureWire`) and its default where the report holds none
  that reads. It carries the person by their display name alone
  (`person_name/1`), never an email, a handle or an id.

  ## The chrome

  A desktop's chrome declaration is read at publish into tokens
  (`Prima.Manifest.Chrome`), which the listing keeps on the version's
  card. While that desktop is the visible canvas the shell has the canvas
  hook apply them (`chrome/2`) as Prism's own variables on the page's
  root, and Prism's default theme stands otherwise. The colours applied
  are the dark set where the desktop declares one, Prism's mode, and its
  light set where it declares only that. A texture or a font is named by
  its path in the version, served under the frame's asset credential;
  nothing of the file itself, and no CSS the version wrote, reaches the
  page. The system layer's prompts take none of it.
  """

  alias Prima.TinctureWire

  @mode "dark"
  @accent "#6366f1"
  @locale "en"
  @time_zone "UTC"
  @sides ~w(top right bottom left)

  @typedoc "The screen's appearance, as a desktop's handshake carries it."
  @type block :: %{String.t() => term()}

  @typedoc "A desktop's chrome as the canvas hook applies it, or nil for Prism's default."
  @type chrome :: %{String.t() => term()} | nil

  @doc "Prism's theme: the mode its screen and its system layer wear."
  @spec mode() :: String.t()
  def mode, do: @mode

  @doc "Prism's accent colour, `#rrggbb`."
  @spec accent() :: String.t()
  def accent, do: @accent

  @doc """
  The appearance block from what the person's browser reported when the
  view connected (`report`, the connect parameters, string-keyed):
  `locale`, `time_zone` and `safe_areas` (`top`, `right`, `bottom`,
  `left`, whole CSS pixels), each its default (`en`, `UTC`, 0) where the
  report holds none the wire takes.
  """
  @spec block(map()) :: block()
  def block(report) when is_map(report) do
    locale = Map.get(report, "locale")
    zone = Map.get(report, "time_zone")

    %{
      "mode" => @mode,
      "accent" => @accent,
      "locale" => if(TinctureWire.locale?(locale), do: locale, else: @locale),
      "time_zone" => if(TinctureWire.time_zone?(zone), do: zone, else: @time_zone),
      "safe_areas" => safe_areas(Map.get(report, "safe_areas"))
    }
  end

  defp safe_areas(%{} = areas) do
    Map.new(@sides, fn side ->
      case Map.get(areas, side) do
        inset when is_integer(inset) and inset >= 0 ->
          {side, min(inset, TinctureWire.max_safe_area())}

        inset when is_float(inset) and inset >= 0 ->
          {side, min(round(inset), TinctureWire.max_safe_area())}

        _none ->
          {side, 0}
      end
    end)
  end

  defp safe_areas(_report), do: Map.new(@sides, &{&1, 0})

  @doc """
  The person's display name as a desktop is told it, or nil: never their
  email, handle or id, and nil for a name outside the wire's bound.
  """
  @spec person_name(String.t() | nil) :: String.t() | nil
  def person_name(user_id) when is_binary(user_id) do
    with {:ok, %{display_name: name}} when is_binary(name) <- Sanctum.Tenancy.Users.get(user_id),
         name = String.trim(name),
         true <- name != "" and length(String.codepoints(name)) <= TinctureWire.max_person_name(),
         true <- String.valid?(name) and not String.match?(name, ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u) do
      name
    else
      _none -> nil
    end
  end

  def person_name(_user_id), do: nil

  @doc """
  The chrome `tokens` (`Prima.Manifest.Chrome.tokens/0`, as the version's
  card holds them) as the canvas hook applies them, `url` turning a path
  in the version into the address it is served at: `colours` (`ground`,
  `surface`, `ink`, `accent`) for Prism's mode, `lengths` (`radius`,
  `border`, `edge`, `title-height`, whole pixels), `keywords`
  (`controls`, `title-align`, `glyphs`), `font` (`family` and `src`, or
  absent for the system font) and `textures` (`title`, `shelf`), each
  only where the declaration holds it. Tokens that declare nothing apply
  nothing: nil.
  """
  @spec chrome(map() | nil, (String.t() -> String.t())) :: chrome()
  def chrome(nil, _url), do: nil

  def chrome(%{} = tokens, url) when is_function(url, 1) do
    applied =
      %{}
      |> present("colours", tokens["dark"] || tokens["light"])
      |> present("lengths", Map.take(tokens, ~w(radius border edge title-height)))
      |> present("keywords", Map.take(tokens, ~w(controls title-align glyphs)))
      |> present("font", font(tokens, url))
      |> present("textures", textures(tokens, url))

    if applied == %{}, do: nil, else: applied
  end

  defp font(%{"font" => family, "fonts" => fonts}, url)
       when is_binary(family) and family != "system" do
    case Enum.find(fonts, &(&1["family"] == family)) do
      %{"src" => src} -> %{"family" => family, "src" => url.(src)}
      nil -> nil
    end
  end

  defp font(_tokens, _url), do: nil

  defp textures(tokens, url) do
    for {key, side} <- [{"texture-title", "title"}, {"texture-shelf", "shelf"}],
        path = tokens[key],
        is_binary(path),
        into: %{},
        do: {side, url.(path)}
  end

  defp present(map, _key, nil), do: map
  defp present(map, _key, empty) when empty == %{}, do: map
  defp present(map, key, value), do: Map.put(map, key, value)
end
