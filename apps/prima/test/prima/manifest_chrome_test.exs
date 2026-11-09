# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestChromeTest do
  @moduledoc """
  A desktop's chrome declaration read as a strict grammar: every property,
  value and bound it reads, the contrast floors at their boundary, and
  the refusal, naming its line, of everything else: comments, escapes,
  non-ASCII text, uppercase, nested and other at-rules, other selectors,
  `!important`, duplicates, external URLs, `..` paths and a file over its
  size.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest.Chrome

  @light """
  --chrome-ground: #ffffff;
  --chrome-surface: #f4f1ea;
  --chrome-ink: #1d1b16;
  --chrome-accent: #2f6f6a;
  """

  defp root(body), do: ":root {\n" <> body <> "}\n"

  defp refusal(css, path \\ "chrome.css") do
    assert {:error, {line, sentence}} = Chrome.parse(css, path)
    {line, sentence}
  end

  test "reads every property it knows into tokens" do
    css = """
    :root {
      --chrome-ground: #FFF;
      --chrome-surface: #f4f1ea;
      --chrome-ink: #1d1b16;
      --chrome-accent: #2f6f6a;
      --chrome-ground-dark: #101010;
      --chrome-surface-dark: #1a1a1a;
      --chrome-ink-dark: #eeeeee;
      --chrome-accent-dark: #4fb3a9;
      --chrome-radius: 0px;
      --chrome-border: 4px;
      --chrome-edge: 16px;
      --chrome-title-height: 28px;
      --chrome-controls: left;
      --chrome-title-align: center;
      --chrome-glyphs: pixel;
      --chrome-font: "Iosevka Term";
      --chrome-texture-title: url("textures/title.png");
      --chrome-texture-shelf: url(textures/shelf.svg);
    }

    @font-face {
      font-family: "Iosevka Term";
      src: url("fonts/iosevka.woff2") format("woff2");
    }
    """

    assert {:ok, tokens} = Chrome.parse(css, "chrome/chrome.css")

    assert tokens == %{
             "light" => %{
               "ground" => "#ffffff",
               "surface" => "#f4f1ea",
               "ink" => "#1d1b16",
               "accent" => "#2f6f6a"
             },
             "dark" => %{
               "ground" => "#101010",
               "surface" => "#1a1a1a",
               "ink" => "#eeeeee",
               "accent" => "#4fb3a9"
             },
             "radius" => 0,
             "border" => 4,
             "edge" => 16,
             "title-height" => 28,
             "controls" => "left",
             "title-align" => "center",
             "glyphs" => "pixel",
             "font" => "Iosevka Term",
             "texture-title" => "chrome/textures/title.png",
             "texture-shelf" => "chrome/textures/shelf.svg",
             "fonts" => [%{"family" => "Iosevka Term", "src" => "chrome/fonts/iosevka.woff2"}]
           }
  end

  test "an empty file, or one that declares a little, is the default look with those changes" do
    assert Chrome.parse("", "chrome.css") == {:ok, %{"fonts" => []}}
    assert Chrome.parse(":root {}", "chrome.css") == {:ok, %{"fonts" => []}}

    assert Chrome.parse(root("--chrome-font: system;\n"), "chrome.css") ==
             {:ok, %{"fonts" => [], "font" => "system"}}
  end

  test "each length is a whole number of px within its bounds" do
    for {name, first, last} <- [
          {"--chrome-radius", 0, 24},
          {"--chrome-border", 0, 4},
          {"--chrome-edge", 4, 16},
          {"--chrome-title-height", 28, 56}
        ] do
      key = String.replace_prefix(name, "--chrome-", "")

      for pixels <- [first, last] do
        assert {:ok, %{^key => ^pixels}} = Chrome.parse(root("#{name}: #{pixels}px;\n"), "c.css")
      end

      for value <- [
            "#{first - 1}px",
            "#{last + 1}px",
            "#{last}",
            "#{last}.5px",
            "#{last}em",
            "#{last}PX"
          ] do
        assert {2, sentence} = refusal(root("#{name}: #{value};\n"))
        assert sentence == "#{name} is a whole number of px from #{first} to #{last}", value
      end
    end
  end

  test "each keyword is one of its words, lowercase" do
    for {name, words} <- [
          {"--chrome-controls", ~w(left right)},
          {"--chrome-title-align", ~w(left center)},
          {"--chrome-glyphs", ~w(plain round square pixel)}
        ] do
      for word <- words, do: assert({:ok, _} = Chrome.parse(root("#{name}: #{word};\n"), "c.css"))

      for word <- ["middle", String.upcase(hd(words)), ""] do
        assert {2, _} = refusal(root("#{name}: #{word};\n")), word
      end
    end
  end

  test "a mode's colours are literals declared together" do
    assert {:ok, %{"light" => %{"ground" => "#ffffff"}}} = Chrome.parse(root(@light), "c.css")

    for value <- ["white", "#ffff", "#fffffff", "rgb(0, 0, 0)", "#ggg", "#ffffff80"] do
      assert {2, "--chrome-ground is a colour literal, #rgb or #rrggbb"} =
               refusal(root(String.replace(@light, "#ffffff", value))),
             value
    end

    # The refusal names the line of the mode's first colour declared.
    assert {2, sentence} =
             refusal(root("--chrome-surface-dark: #000000;\n--chrome-ink-dark: #ffffff;\n"))

    assert sentence =~ "the dark mode lacks --chrome-ground-dark, --chrome-accent-dark"
  end

  test "ink and accent hold their contrast floors against their ground, at the boundary" do
    # #767676 on white is 4.54 to 1, #777777 4.48; #949494 is 3.03, #969696 2.96.
    assert_in_delta Chrome.contrast("#767676", "#ffffff"), 4.54, 0.01
    assert_in_delta Chrome.contrast("#777777", "#ffffff"), 4.48, 0.01
    assert Chrome.contrast("#000", "#fff") == 21.0

    passes = fn ink, accent ->
      @light
      |> String.replace("#1d1b16", ink)
      |> String.replace("#2f6f6a", accent)
      |> root()
      |> Chrome.parse("c.css")
    end

    assert {:ok, _} = passes.("#767676", "#949494")

    assert {:error,
            {4, "--chrome-ink against --chrome-ground is 4.48 to 1, under the floor of 4.5 to 1"}} =
             passes.("#777777", "#949494")

    assert {:error, {5, sentence}} = passes.("#767676", "#969696")

    assert sentence =~
             "--chrome-accent against --chrome-ground is 2.96 to 1, under the floor of 3.0"

    dark =
      @light
      |> String.replace(":", "-dark:")
      |> String.replace("#ffffff", "#000000")
      |> String.replace("#1d1b16", "#595959")

    assert {:error, {4, sentence}} = Chrome.parse(root(dark), "c.css")
    assert sentence =~ "--chrome-ink-dark against --chrome-ground-dark"
  end

  test "the font is system or a family the file's @font-face declares" do
    face = "@font-face {\n  font-family: \"Inter\";\n  src: url(inter.woff2);\n}\n"

    assert {:ok, %{"font" => "Inter", "fonts" => [%{"src" => "inter.woff2"}]}} =
             Chrome.parse(root("--chrome-font: \"Inter\";\n") <> face, "c.css")

    assert {2, "--chrome-font names \"Mono\", which no @font-face here declares"} =
             refusal(root("--chrome-font: \"Mono\";\n") <> face)

    assert {2, _} = refusal(root("--chrome-font: Inter;\n"))
    assert {2, _} = refusal(root("--chrome-font: 'Inter';\n"))
  end

  test "@font-face declares exactly a family and a .woff2 src, each once" do
    face = fn body -> "@font-face {\n" <> body <> "}\n" end

    assert {:ok, _} =
             Chrome.parse(
               face.(~s{font-family: "A";\nsrc: url("a.woff2") format("woff2");\n}),
               "c.css"
             )

    assert {2, "src is url() of a .woff2 file, then format(\"woff2\") or nothing"} =
             refusal(face.(~s{src: url("a.woff2") format("woff");\nfont-family: "A";\n}))

    assert {2, "a font's src is a .woff2 file in the version"} =
             refusal(face.(~s{src: url("a.ttf");\nfont-family: "A";\n}))

    assert {3, "@font-face declares font-family and src, and \"font-weight\" is neither"} =
             refusal(face.(~s{font-family: "A";\nfont-weight: 700;\nsrc: url(a.woff2);\n}))

    assert {3, "font-family is declared twice"} =
             refusal(face.(~s{font-family: "A";\nfont-family: "B";\nsrc: url(a.woff2);\n}))

    assert {1, "@font-face declares its src"} = refusal(face.(~s{font-family: "A";\n}))
    assert {1, "@font-face declares its font-family"} = refusal(face.("src: url(a.woff2);\n"))

    assert {5, "the family \"A\" is declared twice"} =
             refusal(
               face.(~s{font-family: "A";\nsrc: url(a.woff2);\n}) <>
                 face.(~s{font-family: "A";\nsrc: url(b.woff2);\n})
             )

    assert {2, _} = refusal(face.(~s{font-family: "A;B";\nsrc: url(a.woff2);\n}))
  end

  test "a url() is quoted or not and names a relative path of plain segments under the file's directory" do
    for {value, path} <- [
          {~s|url("t.png")|, "themes/t.png"},
          {"url(t.png)", "themes/t.png"},
          {"url(img/t-1_a.png)", "themes/img/t-1_a.png"}
        ] do
      assert {:ok, %{"texture-title" => ^path}} =
               Chrome.parse(root("--chrome-texture-title: #{value};\n"), "themes/chrome.css")
    end

    for {value, sentence} <- [
          {"url(../t.png)",
           "url() names a relative path of plain segments, never .., . or an absolute path"},
          {~s|url("../../etc/t.png")|,
           "url() names a relative path of plain segments, never .., . or an absolute path"},
          {"url(./t.png)",
           "url() names a relative path of plain segments, never .., . or an absolute path"},
          {"url(/t.png)",
           "url() names a relative path of plain segments, never .., . or an absolute path"},
          {"url(https://cdn.example/t.png)",
           "url() names a file in the version, never another origin"},
          {~s|url("//cdn.example/t.png")|,
           "url() names a file in the version, never another origin"},
          {"url(data:image/png;base64,AAAA)", "a declaration is a property, :, and its value"},
          {~s|url('t.png')|,
           "url() names a relative path of plain segments, never .., . or an absolute path"},
          {"url( t.png )", ~s|"url( t.png )" is not url() of a file in the version|},
          {"url(t.gif)", "--chrome-texture-title is url() of a .png or .svg file in the version"},
          {"url(t.webp)",
           "--chrome-texture-title is url() of a .png or .svg file in the version"},
          {"url(t.avif)", "--chrome-texture-title is url() of a .png or .svg file in the version"}
        ] do
      assert {_line, ^sentence} = refusal(root("--chrome-texture-title: #{value};\n")), value
    end
  end

  test "comments, escapes, !important and text outside ASCII are refused naming their line" do
    assert {3, "comments are not part of the chrome grammar"} =
             refusal(root("--chrome-radius: 8px;\n/* rounded */\n"))

    assert {2, "escapes are not part of the chrome grammar"} =
             refusal(root("--chrome-\\72 adius: 8px;\n"))

    assert {2, "!important is not part of the chrome grammar"} =
             refusal(root("--chrome-radius: 8px !important;\n"))

    assert {2, "only ASCII text is read"} = refusal(root("--chrome-font: \"Café\";\n"))
    assert {1, "only ASCII text is read"} = refusal(<<0xEF, 0xBB, 0xBF>> <> root(""))
    assert {2, "only ASCII text is read"} = refusal(root("--chrome-radius: 8px;\u0000\n"))
  end

  test "uppercase, unknown properties and other selectors or at-rules are refused" do
    assert {2, ~s|"--Chrome-Radius" is not a property the chrome grammar reads|} =
             refusal(root("--Chrome-Radius: 8px;\n"))

    assert {2, ~s|"--chrome-shadow" is not a property the chrome grammar reads|} =
             refusal(root("--chrome-shadow: 8px;\n"))

    assert {2, ~s|"color" is not a property the chrome grammar reads|} =
             refusal(root("color: red;\n"))

    assert {1, "a selector other than :root is refused"} = refusal(":ROOT { }")

    assert {1, "a selector other than :root is refused"} =
             refusal("body { --chrome-radius: 8px; }")

    assert {1, "a selector other than :root is refused"} = refusal(":root, body { }")
    assert {1, "a selector other than :root is refused"} = refusal(":root .shelf { }")

    assert {1, "an at-rule other than @font-face is refused"} =
             refusal("@import url(x.css);\n:root {}")

    assert {1, "an at-rule other than @font-face is refused"} =
             refusal("@media (prefers-color-scheme: dark) { :root { --chrome-radius: 8px; } }")

    # A property with a trailing selector: the rule closes, and what
    # follows is another rule, refused by its selector.
    assert {3, "a selector other than :root is refused"} =
             refusal(":root {\n  --chrome-radius: 8px; }\n  .shelf { color: red; }\n")

    assert {2, "a rule holds no rule inside it"} = refusal(":root {\n  :root { }\n}")
    assert {1, "the rule is not closed with }"} = refusal(":root { --chrome-radius: 8px;")
    assert {1, "a rule opens with { after :root or @font-face"} = refusal(":root")
  end

  test "each declaration ends with ;, once, and :root is declared once" do
    assert {2, "a declaration ends with ;"} = refusal(root("--chrome-radius: 8px\n"))
    assert {2, "an empty declaration is refused"} = refusal(root(";\n"))

    assert {2, "a declaration is a property, :, and its value"} =
             refusal(root("--chrome-radius 8px;\n"))

    assert {3, "--chrome-radius is declared twice"} =
             refusal(root("--chrome-radius: 8px;\n--chrome-radius: 9px;\n"))

    assert {4, ":root is declared once"} = refusal(root("") <> "\n" <> root(""))
  end

  test "the file is at most 16 KiB" do
    assert Chrome.max_bytes() == 16_384
    pad = fn bytes -> root("--chrome-radius: 8px;\n") <> String.duplicate(" ", bytes) end
    within = pad.(Chrome.max_bytes() - byte_size(pad.(0)))
    assert byte_size(within) == 16_384
    assert {:ok, _} = Chrome.parse(within, "c.css")

    assert {1, "the file is 16385 bytes; a chrome file is at most 16384"} = refusal(within <> " ")
  end
end
