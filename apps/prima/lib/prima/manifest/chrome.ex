# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Chrome do
  @moduledoc """
  A desktop's chrome declaration (`tincture.desktop.chrome`), read as a
  strict grammar into tokens, never as a stylesheet: the file is at most
  #{16 * 1024} bytes of ASCII text, and holds at most one `:root` rule and
  any number of `@font-face` rules, and nothing else.

      :root {
        --chrome-ground: #f4f1ea;
        --chrome-radius: 8px;
      }

      @font-face {
        font-family: "Inter";
        src: url("fonts/inter.woff2") format("woff2");
      }

  `:root` declares custom properties, each once, each ended by `;`:

    * `--chrome-ground`, `--chrome-surface`, `--chrome-ink` and
      `--chrome-accent`, and the same four with a `-dark` suffix: colour
      literals `#rgb` or `#rrggbb`. A mode's four are declared together
      or not at all; its ink against its ground is at least 4.5 to 1 and
      its accent against its ground at least 3 to 1 (WCAG contrast).
    * `--chrome-radius` 0 to 24px, `--chrome-border` 0 to 4px,
      `--chrome-edge` 4 to 16px, `--chrome-title-height` 28 to 56px: whole
      numbers of `px`.
    * `--chrome-controls` `left` or `right`, `--chrome-title-align` `left`
      or `center`, `--chrome-glyphs` `plain`, `round`, `square` or
      `pixel`.
    * `--chrome-font`: `system`, or the quoted family a `@font-face` of
      the same file declares.
    * `--chrome-texture-title` and `--chrome-texture-shelf`: `url()` of a
      file in the version, quoted or not.

  `@font-face` declares exactly `font-family`, a quoted family of letters,
  digits, spaces, `_` and `-`, and `src`, `url()` of a `.woff2` file in
  the version, optionally followed by `format("woff2")`.

  A `url()` names a path relative to the chrome file's directory, of plain
  segments (`[A-Za-z0-9_-][A-Za-z0-9_.-]*`), so never `..`, an absolute
  path or another origin. Selectors, properties and at-rules beyond these,
  comments, escapes, `!important`, uppercase names and values outside
  their bounds are refused, each naming its line. `parse/1` answers the
  tokens or the first refusal, and a refusal applies nothing.

  What the paths name, a texture's type, size and dimensions and a font's
  type, size and licence, is held against the version's files by the
  component domain (`Compendium.Tincture.Rules.check_chrome/3`); the
  file's caps are `file_caps/0`.
  """

  @max_bytes 16 * 1024

  @modes %{"light" => "", "dark" => "-dark"}
  @roles ~w(ground surface ink accent)
  @lengths %{
    "--chrome-radius" => 0..24,
    "--chrome-border" => 0..4,
    "--chrome-edge" => 4..16,
    "--chrome-title-height" => 28..56
  }
  @keywords %{
    "--chrome-controls" => ~w(left right),
    "--chrome-title-align" => ~w(left center),
    "--chrome-glyphs" => ~w(plain round square pixel)
  }
  @textures ~w(--chrome-texture-title --chrome-texture-shelf)
  @font "--chrome-font"
  @system_font "system"

  # The contrast floors: a mode's ink and accent against its ground.
  @floors %{"ink" => 4.5, "accent" => 3.0}

  # A texture or a font: its extensions, at most this many bytes, a
  # texture at most this many pixels a side.
  @texture_extensions ~w(.png .svg)
  @font_extension ".woff2"
  @asset_bytes 512 * 1024
  @texture_pixels 2048

  @colour ~r/\A#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/
  @length ~r/\A(0|[1-9][0-9]{0,2})px\z/
  @family ~r/\A"([A-Za-z0-9][A-Za-z0-9 _-]{0,63})"\z/
  @url ~r/\Aurl\((?:"([^"]*)"|([^"\s()]*))\)\z/
  @src ~r/\A(url\([^)]*\))(?:\s+format\("woff2"\))?\z/
  @segment ~r/\A[A-Za-z0-9_-][A-Za-z0-9_.-]{0,127}\z/
  @property ~r/\A--?[a-z][a-z0-9-]*\z|\A[a-z][a-z0-9-]*\z/
  @text ~r/\A[\x20-\x7E\t\r\n]*\z/

  @typedoc """
  The accepted tokens: each mode's colours, lowercase `#rrggbb`, under
  `light` and `dark` when declared; the lengths as whole pixels and the
  keywords, each under its property's name without `--chrome-`; `font`,
  `system` or a declared family; the textures' paths under
  `texture-title` and `texture-shelf`; and `fonts`, each declared family
  with its `src`. Every path is relative to the version's root.
  """
  @type tokens :: %{optional(String.t()) => term()}

  @typedoc "A refusal: the line it names (1 for the whole file) and a sentence."
  @type refusal :: {pos_integer(), String.t()}

  @doc "The most bytes the file may take."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  What the files a chrome declaration names may be: the texture
  extensions, the font extension, the most bytes either may take, and the
  most pixels a texture may take a side.
  """
  @spec file_caps() :: %{
          texture_extensions: [String.t()],
          font_extension: String.t(),
          bytes: pos_integer(),
          texture_pixels: pos_integer()
        }
  def file_caps,
    do: %{
      texture_extensions: @texture_extensions,
      font_extension: @font_extension,
      bytes: @asset_bytes,
      texture_pixels: @texture_pixels
    }

  @doc "The contrast floors, each role's ratio against its mode's ground."
  @spec floors() :: %{String.t() => float()}
  def floors, do: @floors

  @doc """
  The WCAG contrast ratio of two colour literals (`#rgb` or `#rrggbb`),
  the lighter's relative luminance plus 0.05 over the darker's.
  """
  @spec contrast(String.t(), String.t()) :: float()
  def contrast(one, other) do
    [high, low] = Enum.sort([luminance(one), luminance(other)], :desc)
    (high + 0.05) / (low + 0.05)
  end

  @doc """
  Read the chrome file `css`, whose path in the version is `path`, into
  its tokens, or the first refusal with the line it names.
  """
  @spec parse(binary(), String.t()) :: {:ok, tokens()} | {:error, refusal()}
  def parse(css, path) when is_binary(css) and is_binary(path) do
    base = path |> Path.dirname() |> then(&if(&1 == ".", do: [], else: String.split(&1, "/")))

    with :ok <- size(css),
         :ok <- text(css),
         {:ok, rules} <- rules(css, 0, []),
         {:ok, tokens} <- read_rules(css, rules, base) do
      modes(tokens)
    end
  end

  # ---- the file --------------------------------------------------------------

  defp size(css) when byte_size(css) > @max_bytes,
    do:
      {:error, {1, "the file is #{byte_size(css)} bytes; a chrome file is at most #{@max_bytes}"}}

  defp size(_css), do: :ok

  # The characters the grammar reads: printable ASCII, tabs and line
  # breaks. Each that is refused names what it would have been.
  defp text(css) do
    cond do
      not Regex.match?(@text, css) ->
        {:error,
         {line_of(css, first_offset(css, &(not printable?(&1)))), "only ASCII text is read"}}

      (at = match_offset(css, "/*")) != nil ->
        {:error, {line_of(css, at), "comments are not part of the chrome grammar"}}

      (at = match_offset(css, "\\")) != nil ->
        {:error, {line_of(css, at), "escapes are not part of the chrome grammar"}}

      (at = match_offset(css, "!")) != nil ->
        {:error, {line_of(css, at), "!important is not part of the chrome grammar"}}

      true ->
        :ok
    end
  end

  defp printable?(byte), do: byte in 0x20..0x7E or byte in [?\t, ?\r, ?\n]

  defp first_offset(css, refused?) do
    css
    |> :binary.bin_to_list()
    |> Enum.find_index(refused?)
  end

  defp match_offset(css, pattern) do
    case :binary.match(css, pattern) do
      {at, _length} -> at
      :nomatch -> nil
    end
  end

  defp line_of(css, offset), do: 1 + (css |> binary_part(0, offset) |> count_lines())

  defp count_lines(text), do: text |> :binary.matches("\n") |> length()

  # ---- the rules -------------------------------------------------------------

  # Each rule as `{kind, line, body, body_offset}`, in file order: a
  # prelude, `{`, a body holding no brace, `}`.
  defp rules(css, offset, acc) do
    rest = binary_part(css, offset, byte_size(css) - offset)
    trimmed = String.trim_leading(rest)
    offset = offset + byte_size(rest) - byte_size(trimmed)

    if trimmed == "" do
      {:ok, Enum.reverse(acc)}
    else
      with {:ok, kind, open} <- prelude(css, offset),
           {:ok, close} <- body_end(css, open + 1) do
        body = binary_part(css, open + 1, close - open - 1)
        rules(css, close + 1, [{kind, line_of(css, offset), body, open + 1} | acc])
      end
    end
  end

  defp prelude(css, offset) do
    rest = binary_part(css, offset, byte_size(css) - offset)
    line = line_of(css, offset)

    case :binary.match(rest, "{") do
      :nomatch ->
        {:error, {line, "a rule opens with { after :root or @font-face"}}

      {at, _} ->
        case String.trim(binary_part(rest, 0, at)) do
          ":root" -> {:ok, :root, offset + at}
          "@font-face" -> {:ok, :font_face, offset + at}
          "@" <> _ -> {:error, {line, "an at-rule other than @font-face is refused"}}
          _ -> {:error, {line, "a selector other than :root is refused"}}
        end
    end
  end

  defp body_end(css, offset) do
    rest = binary_part(css, offset, byte_size(css) - offset)

    case {:binary.match(rest, "}"), :binary.match(rest, "{")} do
      {:nomatch, _} ->
        {:error, {line_of(css, offset), "the rule is not closed with }"}}

      {{close, _}, {open, _}} when open < close ->
        {:error, {line_of(css, offset + open), "a rule holds no rule inside it"}}

      {{close, _}, _} ->
        {:ok, offset + close}
    end
  end

  # ---- the declarations ------------------------------------------------------

  defp read_rules(css, rules, base) do
    Enum.reduce_while(rules, {:ok, %{"fonts" => []}, false}, fn
      {:root, line, _body, _offset}, {:ok, _tokens, true} ->
        {:halt, {:error, {line, ":root is declared once"}}}

      {kind, line, body, offset}, {:ok, tokens, root?} ->
        with {:ok, declarations} <- declarations(css, body, offset),
             {:ok, tokens} <- read(kind, line, declarations, tokens, base) do
          {:cont, {:ok, tokens, root? or kind == :root}}
        else
          {:error, _} = refusal -> {:halt, refusal}
        end
    end)
    |> case do
      {:ok, tokens, _root?} -> {:ok, tokens}
      refusal -> refusal
    end
  end

  # The body's declarations as `{line, name, value}`: each ended by `;`,
  # with nothing but whitespace after the last.
  defp declarations(css, body, offset) do
    {complete, [tail]} = body |> String.split(";") |> Enum.split(-1)

    if String.trim(tail) != "" do
      at = offset + byte_size(body) - byte_size(tail) + leading(tail)
      {:error, {line_of(css, at), "a declaration ends with ;"}}
    else
      complete
      |> Enum.map_reduce(offset, fn piece, at ->
        {{line_of(css, at + leading(piece)), String.trim(piece)}, at + byte_size(piece) + 1}
      end)
      |> elem(0)
      |> Enum.reduce_while({:ok, []}, fn {line, text}, {:ok, acc} ->
        case declaration(text, line) do
          {:ok, declared} -> {:cont, {:ok, [declared | acc]}}
          {:error, _} = refusal -> {:halt, refusal}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        refusal -> refusal
      end
    end
  end

  defp leading(text), do: byte_size(text) - byte_size(String.trim_leading(text))

  defp declaration("", line), do: {:error, {line, "an empty declaration is refused"}}

  defp declaration(text, line) do
    case String.split(text, ":", parts: 2) do
      [name, value] ->
        name = String.trim(name)
        value = String.trim(value)

        if Regex.match?(@property, name),
          do: {:ok, {line, name, value}},
          else: {:error, {line, "#{show(name)} is not a property the chrome grammar reads"}}

      [_alone] ->
        {:error, {line, "a declaration is a property, :, and its value"}}
    end
  end

  # ---- :root -----------------------------------------------------------------

  defp read(:root, _line, declarations, tokens, base) do
    Enum.reduce_while(declarations, {:ok, tokens, MapSet.new()}, fn {line, name, value},
                                                                    {:ok, tokens, seen} ->
      cond do
        MapSet.member?(seen, name) ->
          {:halt, {:error, {line, "#{name} is declared twice"}}}

        true ->
          case property(name, value, line, base) do
            {:ok, key, token} ->
              tokens = tokens |> put_token(key, token) |> put_line(name, line)
              {:cont, {:ok, tokens, MapSet.put(seen, name)}}

            {:error, _} = refusal ->
              {:halt, refusal}
          end
      end
    end)
    |> case do
      {:ok, tokens, _seen} -> {:ok, tokens}
      refusal -> refusal
    end
  end

  defp read(:font_face, line, declarations, tokens, base) do
    with {:ok, face} <- font_face(declarations, line, %{}),
         {:ok, family} <- Map.fetch(face, "font-family") |> required(line, "font-family"),
         {:ok, src} <- Map.fetch(face, "src") |> required(line, "src"),
         :ok <- new_family(tokens, family, line),
         {:ok, path} <- font_src(src, base) do
      {:ok, Map.update!(tokens, "fonts", &(&1 ++ [%{"family" => family, "src" => path}]))}
    end
  end

  defp font_face([], _line, face), do: {:ok, face}

  defp font_face([{line, name, value} | rest], rule_line, face) do
    cond do
      name not in ~w(font-family src) ->
        {:error, {line, "@font-face declares font-family and src, and #{show(name)} is neither"}}

      Map.has_key?(face, name) ->
        {:error, {line, "#{name} is declared twice"}}

      name == "font-family" ->
        case Regex.run(@family, value) do
          [_, family] -> font_face(rest, rule_line, Map.put(face, name, family))
          nil -> {:error, {line, family_sentence()}}
        end

      true ->
        font_face(rest, rule_line, Map.put(face, name, {line, value}))
    end
  end

  defp required({:ok, value}, _line, _name), do: {:ok, value}
  defp required(:error, line, name), do: {:error, {line, "@font-face declares its #{name}"}}

  defp new_family(%{"fonts" => fonts}, family, line) do
    if Enum.any?(fonts, &(&1["family"] == family)),
      do: {:error, {line, "the family \"#{family}\" is declared twice"}},
      else: :ok
  end

  defp font_src({line, value}, base) do
    with [_, url] <- Regex.run(@src, value),
         {:ok, path} <- url(url, line, base) do
      if Path.extname(path) == @font_extension,
        do: {:ok, path},
        else: {:error, {line, "a font's src is a #{@font_extension} file in the version"}}
    else
      nil ->
        {:error,
         {line, "src is url() of a #{@font_extension} file, then format(\"woff2\") or nothing"}}

      {:error, _} = refusal ->
        refusal
    end
  end

  defp property(name, value, line, base) do
    cond do
      colour = colour_role(name) ->
        colour(colour, value, line, name)

      range = Map.get(@lengths, name) ->
        length(name, value, range, line)

      words = Map.get(@keywords, name) ->
        if value in words,
          do: {:ok, token_name(name), value},
          else: {:error, {line, "#{name} is #{or_list(words)}"}}

      name in @textures ->
        texture(name, value, line, base)

      name == @font ->
        font(value, line)

      true ->
        {:error, {line, "#{show(name)} is not a property the chrome grammar reads"}}
    end
  end

  defp colour_role(name) do
    Enum.find_value(@modes, fn {mode, suffix} ->
      Enum.find_value(@roles, &(name == "--chrome-#{&1}#{suffix}" && {mode, &1}))
    end)
  end

  defp colour({mode, role}, value, line, name) do
    if Regex.match?(@colour, value),
      do: {:ok, {mode, role}, normalize(value)},
      else: {:error, {line, "#{name} is a colour literal, #rgb or #rrggbb"}}
  end

  defp length(name, value, first..last//_ = range, line) do
    with [_, digits] <- Regex.run(@length, value),
         pixels = String.to_integer(digits),
         true <- pixels in range do
      {:ok, token_name(name), pixels}
    else
      _ -> {:error, {line, "#{name} is a whole number of px from #{first} to #{last}"}}
    end
  end

  defp texture(name, value, line, base) do
    with {:ok, path} <- url(value, line, base) do
      if Path.extname(path) in @texture_extensions,
        do: {:ok, token_name(name), path},
        else:
          {:error,
           {line,
            "#{name} is url() of a #{Enum.join(@texture_extensions, " or ")} file in the version"}}
    end
  end

  # The font a `--chrome-font` names is checked against the families once
  # every rule is read (`modes/1`).
  defp font(@system_font, _line), do: {:ok, "font", {:system, nil}}

  defp font(value, line) do
    case Regex.run(@family, value) do
      [_, family] ->
        {:ok, "font", {:family, family, line}}

      nil ->
        {:error, {line, "#{@font} is #{@system_font} or a quoted family a @font-face declares"}}
    end
  end

  defp url(value, line, base) do
    case Regex.run(@url, value) do
      nil ->
        {:error, {line, "#{show(value)} is not url() of a file in the version"}}

      [_ | captured] ->
        path = Enum.find(captured, "", &(&1 != ""))
        relative(path, line, base)
    end
  end

  defp relative(path, line, base) do
    segments = String.split(path, "/")

    cond do
      String.contains?(path, ":") or String.starts_with?(path, "//") ->
        {:error, {line, "url() names a file in the version, never another origin"}}

      Enum.all?(segments, &Regex.match?(@segment, &1)) ->
        {:ok, Enum.join(base ++ segments, "/")}

      true ->
        {:error,
         {line, "url() names a relative path of plain segments, never .., . or an absolute path"}}
    end
  end

  defp put_token(tokens, {mode, role}, colour),
    do: Map.update(tokens, mode, %{role => colour}, &Map.put(&1, role, colour))

  defp put_token(tokens, key, value), do: Map.put(tokens, key, value)

  # The line each :root property was declared on, for the refusals read
  # once every rule is; dropped from the tokens before they are answered.
  defp put_line(tokens, name, line),
    do: Map.update(tokens, :lines, %{name => line}, &Map.put(&1, name, line))

  # ---- the modes -------------------------------------------------------------

  # Each mode's colours together, held to their floors, and the font a
  # family names declared by a @font-face of the file.
  defp modes(tokens) do
    with :ok <- Enum.reduce_while(Map.keys(@modes) |> Enum.sort(), :ok, &mode(tokens, &1, &2)),
         {:ok, tokens} <- declared_font(tokens) do
      {:ok, Map.delete(tokens, :lines)}
    end
  end

  defp line(tokens, name), do: tokens |> Map.get(:lines, %{}) |> Map.get(name, 1)

  defp mode(tokens, mode, :ok) do
    case Map.get(tokens, mode) do
      nil ->
        {:cont, :ok}

      colours when map_size(colours) < length(@roles) ->
        missing = Enum.reject(@roles, &Map.has_key?(colours, &1))

        declared = Enum.find(@roles, &Map.has_key?(colours, &1))

        {:halt,
         {:error,
          {line(tokens, "--chrome-#{declared}#{@modes[mode]}"),
           "a mode's colours are declared together: the #{mode} mode lacks " <>
             Enum.map_join(missing, ", ", &"--chrome-#{&1}#{@modes[mode]}")}}}

      colours ->
        case Enum.find(Enum.sort(@floors), fn {role, floor} ->
               contrast(colours[role], colours["ground"]) < floor
             end) do
          nil ->
            {:cont, :ok}

          {role, floor} ->
            {:halt,
             {:error,
              {line(tokens, "--chrome-#{role}#{@modes[mode]}"),
               "--chrome-#{role}#{@modes[mode]} against --chrome-ground#{@modes[mode]} is " <>
                 "#{Float.round(contrast(colours[role], colours["ground"]), 2)} to 1, " <>
                 "under the floor of #{floor} to 1"}}}
        end
    end
  end

  defp declared_font(%{"font" => {:system, nil}} = tokens),
    do: {:ok, Map.put(tokens, "font", @system_font)}

  defp declared_font(%{"font" => {:family, family, line}, "fonts" => fonts} = tokens) do
    if Enum.any?(fonts, &(&1["family"] == family)),
      do: {:ok, Map.put(tokens, "font", family)},
      else: {:error, {line, "#{@font} names \"#{family}\", which no @font-face here declares"}}
  end

  defp declared_font(tokens), do: {:ok, tokens}

  # ---- helpers ---------------------------------------------------------------

  defp token_name("--chrome-" <> name), do: name

  defp normalize("#" <> <<r, g, b>>), do: String.downcase(<<?#, r, r, g, g, b, b>>)
  defp normalize(hex), do: String.downcase(hex)

  defp luminance(hex) do
    "#" <> digits = normalize(hex)

    [r, g, b] =
      for <<pair::binary-size(2) <- digits>> do
        channel = String.to_integer(pair, 16) / 255

        if channel <= 0.04045,
          do: channel / 12.92,
          else: :math.pow((channel + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp family_sentence,
    do: "font-family is a quoted family of letters, digits, spaces, _ and -, at most 64"

  defp or_list([one, two]), do: "#{one} or #{two}"
  defp or_list(words), do: Enum.join(Enum.drop(words, -1), ", ") <> " or " <> List.last(words)

  defp show(text) when byte_size(text) <= 64, do: ~s("#{text}")
  defp show(text), do: "a name of #{byte_size(text)} characters"
end
