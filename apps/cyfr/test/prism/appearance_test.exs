# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AppearanceTest do
  @moduledoc """
  How the screen looks to a desktop: the appearance its handshake carries,
  held to the wire whatever the browser reported, the console's own accent,
  the person by their display name alone, and a desktop's chrome tokens as
  the canvas hook applies them.
  """

  use ExUnit.Case, async: false

  alias Prism.Appearance

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  @app_css Path.expand("../../assets/css/app.css", __DIR__)

  test "the accent is the console's own, as app.css spells it" do
    [_, accent] = Regex.run(~r/--color-accent-primary:\s*(#[0-9a-f]{6});/, File.read!(@app_css))
    assert Appearance.accent() == accent
    assert Appearance.mode() == "dark"
  end

  test "what the browser reports is taken where the wire takes it, and its default otherwise" do
    assert Appearance.block(%{
             "locale" => "pt-PT",
             "time_zone" => "Europe/Lisbon",
             "safe_areas" => %{"top" => 47, "right" => 0, "bottom" => 33.6, "left" => 9000}
           }) == %{
             "mode" => "dark",
             "accent" => Appearance.accent(),
             "locale" => "pt-PT",
             "time_zone" => "Europe/Lisbon",
             "safe_areas" => %{"top" => 47, "right" => 0, "bottom" => 34, "left" => 512}
           }

    for report <- [
          %{},
          %{"locale" => "en_GB", "time_zone" => "../../etc", "safe_areas" => "all"},
          %{"locale" => 7, "time_zone" => nil, "safe_areas" => %{"top" => -1, "left" => "3"}}
        ] do
      assert %{
               "locale" => "en",
               "time_zone" => "UTC",
               "safe_areas" => %{"top" => 0, "right" => 0, "bottom" => 0, "left" => 0}
             } = Appearance.block(report)
    end

    # Whatever was reported, the block is one the wire's handshake takes.
    block = Appearance.block(%{"locale" => String.duplicate("a", 300)})

    assert Prima.TinctureWire.canvas_handshake("frm_8f3c2a1b9d", "c", "live", [], %{
             "prefs" => %{"document" => %{}, "revision" => 0},
             "appearance" => block,
             "person" => %{"name" => nil}
           })
  end

  test "a desktop's tokens are applied for Prism's mode, each where the declaration holds it" do
    url = &("/_s/ast.v1.x/local/styled/1.0.0/" <> &1)

    light = %{
      "ground" => "#f4f1ea",
      "surface" => "#ffffff",
      "ink" => "#1d1b16",
      "accent" => "#8a3b12"
    }

    dark = %{
      "ground" => "#101010",
      "surface" => "#1a1a1a",
      "ink" => "#f0f0f0",
      "accent" => "#e0a060"
    }

    tokens = %{
      "light" => light,
      "dark" => dark,
      "radius" => 4,
      "title-height" => 40,
      "controls" => "left",
      "font" => "Inter",
      "fonts" => [%{"family" => "Inter", "src" => "fonts/inter.woff2"}],
      "texture-shelf" => "felt.svg"
    }

    assert Appearance.chrome(tokens, url) == %{
             "colours" => dark,
             "lengths" => %{"radius" => 4, "title-height" => 40},
             "keywords" => %{"controls" => "left"},
             "font" => %{"family" => "Inter", "src" => url.("fonts/inter.woff2")},
             "textures" => %{"shelf" => url.("felt.svg")}
           }

    # Only a light set: the desktop's one look. The system font names none.
    assert %{"colours" => ^light} =
             Appearance.chrome(%{"light" => light, "font" => "system", "fonts" => []}, url)

    refute Map.has_key?(
             Appearance.chrome(%{"light" => light, "font" => "system", "fonts" => []}, url),
             "font"
           )

    # Tokens that declare nothing apply nothing.
    assert Appearance.chrome(%{"fonts" => []}, url) == nil
    assert Appearance.chrome(nil, url) == nil
  end

  test "a person with no display name, or none the wire takes, is told as none" do
    assert Appearance.person_name(nil) == nil
    assert Appearance.person_name("usr_not_anyone") == nil
  end
end
