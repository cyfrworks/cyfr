# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture.RulesTest do
  @moduledoc """
  The frame's rules: the served types, the capabilities and what each
  opens in the sandbox and the permissions policy (never a forbidden
  token), the entry page's policy derived against the frame facts
  `tests/browser/README.md` records, the templates and the lockfile rule,
  and the declaration grammar — a capability the rules do not list, a card
  naming an action the declaration lacks and a stream no provider declares
  each refused. The facade answers what the module answers.
  """

  use ExUnit.Case, async: true

  alias Compendium.Tincture.Rules
  alias Prima.Manifest.Tincture

  @root Path.expand("../../../../..", __DIR__)
  @endpoint "https://cyfr.test"
  @nonce "bm9uY2Utb2YtdGhlLXBhZ2U"

  defp manifest(tincture), do: %{"type" => "tincture", "tincture" => tincture}

  describe "served types" do
    test "every family the frame serves has its type, and the listing's blocked raster is not served" do
      types = Rules.served_types()

      for {ext, mime} <- [
            {".html", "text/html"},
            {".js", "text/javascript"},
            {".css", "text/css"},
            {".json", "application/json"},
            {".map", "application/json"},
            {".woff2", "font/woff2"},
            {".svg", "image/svg+xml"},
            {".png", "image/png"},
            {".wasm", "application/wasm"},
            {".pck", "application/octet-stream"},
            {".ogg", "audio/ogg"},
            {".gltf", "model/gltf+json"},
            {".glb", "model/gltf-binary"},
            {".bin", "application/octet-stream"},
            {".ktx2", "image/ktx2"}
          ] do
        assert types[ext] == mime, "#{ext} is served as #{inspect(types[ext])}"
      end

      refute Map.has_key?(types, ".webp")
      refute Map.has_key?(types, ".db")
    end
  end

  describe "the sandbox and the permissions policy" do
    test "allow-scripts always, and pointer lock only when granted" do
      assert Rules.sandbox_tokens([]) == {:ok, ["allow-scripts"]}

      assert Rules.sandbox_tokens(["pointer_lock"]) ==
               {:ok, ["allow-scripts", "allow-pointer-lock"]}

      assert Rules.sandbox_tokens(["fullscreen", "gamepad", "audio_autoplay"]) ==
               {:ok, ["allow-scripts"]}
    end

    test "the allow attribute names fullscreen, gamepad and autoplay only when granted" do
      assert Rules.allow_attribute([]) == {:ok, ""}
      assert Rules.allow_attribute(["fullscreen"]) == {:ok, "fullscreen"}

      assert Rules.allow_attribute(["gamepad", "audio_autoplay", "fullscreen", "pointer_lock"]) ==
               {:ok, "autoplay; fullscreen; gamepad"}
    end

    test "a capability the rules do not list is refused" do
      for granted <- [["camera"], ["background"], ["pointer_lock", "same_origin"], [:fullscreen]] do
        assert {:error, {:invalid_tincture, _}} = Rules.sandbox_tokens(granted)
        assert {:error, {:invalid_tincture, _}} = Rules.allow_attribute(granted)
      end
    end

    test "no grant emits a forbidden token, and a map that would is caught" do
      all = Rules.frame_capabilities()
      {:ok, tokens} = Rules.sandbox_tokens(all)

      for forbidden <- ~w(allow-same-origin allow-top-navigation allow-popups allow-forms) do
        assert forbidden in Rules.forbidden_sandbox_tokens()
        refute forbidden in tokens
      end

      assert Rules.sandbox_violations(%{"pointer_lock" => ["allow-pointer-lock"]}) == []

      assert Rules.sandbox_violations(%{
               "pointer_lock" => ["allow-pointer-lock"],
               "storage" => ["allow-same-origin"],
               "links" => ["allow-popups", "allow-top-navigation"]
             })
             |> Enum.sort() == ["allow-popups", "allow-same-origin", "allow-top-navigation"]
    end
  end

  describe "the entry page's policy" do
    defp directives(csp) do
      csp
      |> String.split("; ")
      |> Map.new(fn directive ->
        [name | sources] = String.split(directive, " ")
        {name, sources}
      end)
    end

    test "is derived from the declaration and the endpoint, as the plan names each directive" do
      csp =
        Rules.csp(
          manifest(%{"connect" => ["api.example.com", "*.example.org", "https://bad"]}),
          %{
            endpoint: @endpoint,
            nonce: @nonce
          }
        )

      d = directives(csp)
      assert d["default-src"] == ["'self'"]
      assert d["script-src"] == ["'self'", "'nonce-#{@nonce}'", "'wasm-unsafe-eval'"]
      assert d["worker-src"] == ["'self'", "blob:"]

      assert d["connect-src"] == [
               @endpoint,
               "https://api.example.com",
               "https://*.example.org"
             ]

      assert d["frame-ancestors"] == [@endpoint]
      assert d["form-action"] == ["'none'"]
      assert d["object-src"] == ["'none'"]

      assert Rules.csp(manifest(%{}), %{
               endpoint: @endpoint,
               nonce: @nonce,
               shell: "https://shell.test"
             })
             |> directives()
             |> Map.fetch!("frame-ancestors") == ["https://shell.test"]
    end

    test "an origin or a nonce outside its grammar raises rather than reaching a header" do
      for bad <- ["https://cyfr.test/path", "cyfr.test", "https://cyfr.test; script-src *"] do
        assert_raise ArgumentError, fn -> Rules.csp(%{}, %{endpoint: bad, nonce: @nonce}) end
      end

      assert_raise ArgumentError, fn -> Rules.csp(%{}, %{endpoint: @endpoint, nonce: "x'; y"}) end
    end

    test "honours every frame fact the browser record holds" do
      # Prose wraps; the facts are read with its line breaks folded.
      record =
        @root
        |> Path.join("tests/browser/README.md")
        |> File.read!()
        |> String.replace(~r/\s+/, " ")

      # The facts the rules are frozen against are still the record's.
      assert record =~ "The document's origin is `null` in all three browsers"
      assert record =~ "CSP `connect-src 'self'` does not match the frame's own origin"
      assert record =~ "`<script>` from another tincture's path on the origin"
      assert record =~ "Worker from a `blob:` URL"
      assert record =~ "`script-src` lacks `'wasm-unsafe-eval'`"
      assert record =~ "the 'allow-forms' permission is not set"

      d = directives(Rules.csp(manifest(%{}), %{endpoint: @endpoint, nonce: @nonce}))

      # A null-origin frame's fetch: the endpoint by name, never 'self'.
      assert @endpoint in d["connect-src"]
      refute "'self'" in d["connect-src"]
      # A blob worker and WebAssembly are permitted.
      assert "blob:" in d["worker-src"]
      assert "'wasm-unsafe-eval'" in d["script-src"]
      # A form POST is refused by the policy and by the sandbox.
      assert d["form-action"] == ["'none'"]
      {:ok, tokens} = Rules.sandbox_tokens(Rules.frame_capabilities())
      refute "allow-forms" in tokens
      refute "allow-same-origin" in tokens
      # Nothing claims the policy isolates one tincture's scripts from
      # another's: `script-src` is the origin, as the record shows it runs.
      assert "'self'" in d["script-src"]
    end
  end

  describe "templates and the lockfile" do
    test "vanilla, Vite and React, each with its entry" do
      assert Enum.map(Rules.templates(), & &1.name) == ~w(vanilla vite react)

      for %{build: build, entry: entry} <- Rules.templates() do
        assert entry == if(build, do: "dist/index.html", else: "index.html")
      end
    end

    test "a built tincture ships its lockfile; an unbuilt one need not" do
      assert Rules.lockfile() == "package-lock.json"
      assert Rules.lockfile_required?(manifest(%{"build" => %{"tool" => "vite"}}))
      refute Rules.lockfile_required?(manifest(%{"entry" => "index.html"}))
      refute Rules.lockfile_required?(%{})
    end
  end

  describe "the declaration" do
    @declared %{
      "frame" => %{
        "capabilities" => ["pointer_lock"],
        "placement" => "float",
        "background" => true
      },
      "actions" => ["execution.list"],
      "streams" => [%{"name" => "executions.deltas", "subject" => "*"}],
      "cards" => [
        %{
          "name" => "runs",
          "title" => "Runs",
          "number" => "count",
          "image" => "public/media/icon.svg",
          "buttons" => [%{"label" => "Refresh", "action" => "execution.list"}],
          "stream" => "executions.deltas"
        }
      ]
    }

    @deltas %Prima.Provider.Stream{
      name: "executions.deltas",
      topic: :execution_events,
      projection: ["seq", "delta"],
      subject: ~S"\Aexec_[a-z0-9-]{1,64}\z",
      deadline_bound: 600
    }

    test "a declaration that keeps the rules is answered as the struct" do
      assert {:ok, %Tincture{} = decl} = Rules.validate_declaration(manifest(@declared))
      assert decl.frame.background
      assert Compendium.tincture_declaration(manifest(@declared)) == {:ok, decl}

      assert {:ok, %Tincture{cards: [], actions: []}} =
               Rules.validate_declaration(manifest(%{"entry" => "index.html"}))
    end

    test "a capability or a placement the rules do not list is refused" do
      for frame <- [
            %{"capabilities" => ["camera"]},
            %{"capabilities" => ["background"]},
            %{"placement" => "sidebar"}
          ] do
        assert {:error, {:invalid_tincture, _}} =
                 Rules.validate_declaration(manifest(Map.put(@declared, "frame", frame)))
      end
    end

    test "a card naming an action the declaration lacks is refused" do
      lacking = Map.put(@declared, "actions", ["records.get"])

      assert {:error, {:invalid_tincture, sentence}} =
               Rules.validate_declaration(manifest(lacking))

      assert sentence =~ "execution.list"
    end

    test "a card's stream must be declared, its name distinct and its image a served image" do
      undeclared = Map.put(@declared, "streams", [])
      assert {:error, {:invalid_tincture, _}} = Rules.validate_declaration(manifest(undeclared))

      twice = Map.update!(@declared, "cards", &(&1 ++ &1))
      assert {:error, {:invalid_tincture, _}} = Rules.validate_declaration(manifest(twice))

      mp4 =
        put_in(@declared, ["cards"], [%{"name" => "c", "title" => "C", "image" => "clip.mp4"}])

      assert {:error, {:invalid_tincture, _}} = Rules.validate_declaration(manifest(mp4))
    end

    test "a malformed block is refused as the shapes refuse it" do
      assert {:error, {:invalid_tincture, _}} =
               Rules.validate_declaration(manifest(%{"cards" => "nope"}))
    end

    test "a stream a provider does not declare is refused, and a subject the stream does not take" do
      {:ok, decl} = Rules.validate_declaration(manifest(@declared))

      assert Rules.check_streams(decl, [@deltas]) == :ok
      assert Compendium.tincture_check_streams(decl, [@deltas]) == :ok

      assert {:error, {:invalid_tincture, sentence}} = Rules.check_streams(decl, [])
      assert sentence =~ "no provider declares"

      literal = %{
        decl
        | streams: [%Tincture.Stream{name: "executions.deltas", subject: "exec_1"}]
      }

      assert Rules.check_streams(literal, [@deltas]) == :ok

      wrong = %{decl | streams: [%Tincture.Stream{name: "executions.deltas", subject: "other"}]}
      assert {:error, {:invalid_tincture, _}} = Rules.check_streams(wrong, [@deltas])

      none = %{decl | streams: [%Tincture.Stream{name: "executions.deltas", subject: nil}]}
      assert {:error, {:invalid_tincture, _}} = Rules.check_streams(none, [@deltas])

      subjectless = %{@deltas | subject: nil}
      assert {:error, {:invalid_tincture, _}} = Rules.check_streams(decl, [subjectless])
      assert Rules.check_streams(none, [subjectless]) == :ok
    end
  end

  test "the facade answers what the rules answer" do
    assert Compendium.tincture_served_types() == Rules.served_types()
    assert Compendium.tincture_frame_capabilities() == Rules.frame_capabilities()
    assert Compendium.tincture_placements() == Rules.placements()

    assert Compendium.tincture_sandbox_tokens(["pointer_lock"]) ==
             Rules.sandbox_tokens(["pointer_lock"])

    assert Compendium.tincture_allow_attribute(["gamepad"]) == Rules.allow_attribute(["gamepad"])
    assert Compendium.tincture_templates() == Rules.templates()
    assert Compendium.tincture_lockfile_required?(%{}) == Rules.lockfile_required?(%{})

    opts = %{endpoint: @endpoint, nonce: @nonce}
    assert Compendium.tincture_csp(%{}, opts) == Rules.csp(%{}, opts)
  end
end
