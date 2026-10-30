# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture.RulesTest do
  @moduledoc """
  The frame's rules: the served types, the capabilities and what each
  opens in the sandbox and the permissions policy (never a forbidden
  token), the entry page's policy derived against the frame facts
  `tests/browser/README.md` records, the templates and the lockfile rule,
  and the declaration grammar — a capability or a placement the rules do
  not list, a stream no provider declares, and a feed's write or the
  layout's among the system actions each refused. A canvas is its
  version's own page on the vanilla or the react template, and is held
  tighter: its policy is the one string the plan names, naming only its
  own files, the SDK's one path and its open's data path, its sandbox is
  scripts alone, each declaration it may not make is refused with its own
  sentence, its page is among its files, and it reads only streams that
  declare a shape, each feed by its name; a stream that declares a shape
  is a canvas's alone. The origins a frame connects to are exactly the
  ones its policy admits, and the classes each read may carry are known
  before it is made, one read at a time and over a whole declaration. The
  facade answers what the module answers.
  """

  use ExUnit.Case, async: true

  alias Compendium.Tincture.Rules
  alias Prima.Manifest.Tincture

  @root Path.expand("../../../../..", __DIR__)
  @endpoint "https://cyfr.test"
  @nonce "bm9uY2Utb2YtdGhlLXBhZ2U"

  # The sandbox tokens no frame ever carries, whatever it is granted.
  @forbidden ~w(
    allow-same-origin
    allow-top-navigation allow-top-navigation-by-user-activation
    allow-top-navigation-to-custom-protocols
    allow-popups allow-popups-to-escape-sandbox
    allow-forms
  )

  @runs "reagent:local.runs"

  defp manifest(tincture),
    do: %{
      "type" => "tincture",
      "tincture" => tincture,
      "dependencies" => %{"static" => [%{"ref" => @runs, "reason" => "the runs it counts"}]}
    }

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

    test "no grant emits a forbidden token" do
      all = Rules.frame_capabilities()
      {:ok, tokens} = Rules.sandbox_tokens(all)

      for forbidden <- @forbidden, do: refute(forbidden in tokens)
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

    test "the document policy is the CSP with the sandbox the declaration opens, whole" do
      opts = %{endpoint: @endpoint, nonce: @nonce}
      pointer = manifest(%{"frame" => %{"capabilities" => ["pointer_lock"]}})

      assert Rules.frame_policy(pointer, opts) ==
               Rules.csp(pointer, opts) <> "; sandbox allow-scripts allow-pointer-lock"

      assert Compendium.tincture_frame_policy(pointer, opts) == Rules.frame_policy(pointer, opts)

      # A declaration the rules refuse opens nothing beyond scripts.
      refused = manifest(%{"frame" => %{"capabilities" => ["camera"]}})

      assert Rules.frame_policy(refused, opts) ==
               Rules.csp(refused, opts) <> "; sandbox allow-scripts"
    end

    test "an origin or a nonce outside its grammar raises rather than reaching a header" do
      for bad <- ["https://cyfr.test/path", "cyfr.test", "https://cyfr.test; script-src *"] do
        assert_raise ArgumentError, fn -> Rules.csp(%{}, %{endpoint: bad, nonce: @nonce}) end
      end

      assert_raise ArgumentError, fn -> Rules.csp(%{}, %{endpoint: @endpoint, nonce: "x'; y"}) end
    end

    # The canvas policy is its own function; every other tincture's page is
    # served under the frame policy alone, byte for byte.
    test "a tincture that is no canvas keeps its policy byte for byte" do
      assert Rules.csp(manifest(%{"connect" => ["api.example.com"]}), %{
               endpoint: @endpoint,
               nonce: @nonce
             }) ==
               "default-src 'self'; " <>
                 "script-src 'self' 'nonce-#{@nonce}' 'wasm-unsafe-eval'; " <>
                 "worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; " <>
                 "img-src 'self' https://cyfr.test data: blob:; font-src 'self' https://cyfr.test; " <>
                 "media-src 'self' https://cyfr.test blob:; " <>
                 "connect-src https://cyfr.test https://api.example.com; object-src 'none'; " <>
                 "base-uri 'self'; frame-ancestors https://cyfr.test; form-action 'none'"
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
        "background" => true,
        "size" => %{"preferred" => %{"w" => 400, "h" => 640}, "tile" => "right"}
      },
      "actions" => ["execution.list"],
      "streams" => [%{"name" => "executions.deltas", "subject" => "*"}]
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

      assert {:ok, %Tincture{streams: [], actions: []}} =
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

    test "the one placement is canvas, and float and a desktop are refused by the placement sentence" do
      assert Rules.placements() == ~w(canvas)

      for placement <- ["float", "desktop"] do
        assert Rules.validate_declaration(manifest(%{"frame" => %{"placement" => placement}})) ==
                 {:error, {:invalid_tincture, "tincture.frame.placement is one of canvas"}},
               placement
      end
    end

    test "a size hint is held to its bounds at publish, and an app's hint within them is kept" do
      assert {:ok, %Tincture{frame: %{size: size}}} =
               Rules.validate_declaration(manifest(@declared))

      assert size == %Prima.Manifest.Tincture.Size{preferred: %{w: 400, h: 640}, tile: "right"}

      for hint <- [
            %{"min" => %{"w" => 99, "h" => 100}},
            %{"preferred" => %{"w" => 4001, "h" => 100}},
            %{"aspect" => %{"w" => 0, "h" => 1}},
            %{"tile" => "bottom"},
            %{"max" => %{"w" => 100, "h" => 100}}
          ] do
        assert {:error, {:invalid_tincture, "tincture.frame.size" <> _}} =
                 Rules.validate_declaration(manifest(%{"frame" => %{"size" => hint}})),
               inspect(hint)
      end
    end

    for action <- ~w(feed.bind feed.remove feed.press) do
      test "#{action} among the system actions is refused, for every placement" do
        action = unquote(action)

        sentence =
          "tincture.actions names #{action}: a tincture never binds, removes or presses a feed; the person does"

        for placement <- [nil | Rules.placements()] do
          tincture = %{
            "frame" => %{"placement" => placement},
            "actions" => ["execution.list", action]
          }

          tincture =
            if placement == "canvas",
              do: Map.put(tincture, "entry", "index.html"),
              else: tincture

          assert Rules.validate_declaration(%{"type" => "tincture", "tincture" => tincture}) ==
                   {:error, {:invalid_tincture, sentence}},
                 inspect(placement)
        end

        # Reading the feeds is not one of them.
        assert {:ok, _} =
                 Rules.validate_declaration(
                   manifest(Map.put(@declared, "actions", ["execution.list", "feed.list"]))
                 )
      end
    end

    test "layout.edit among the system actions is refused, for every placement and for an app" do
      sentence = "tincture.actions names layout.edit: a tincture never writes the person's layout"

      for placement <- [nil | Rules.placements()] do
        frame = if placement, do: %{"placement" => placement}, else: %{}
        tincture = %{"frame" => frame, "actions" => ["execution.list", "layout.edit"]}

        tincture =
          if placement == "canvas",
            do: Map.put(tincture, "entry", "index.html"),
            else: tincture

        manifest = %{"type" => "tincture", "tincture" => tincture}

        assert Rules.validate_declaration(manifest) == {:error, {:invalid_tincture, sentence}},
               inspect(placement)

        assert Compendium.tincture_declaration(manifest) ==
                 {:error, {:invalid_tincture, sentence}}
      end

      # Reading the layout is not refused here.
      assert {:ok, _} =
               Rules.validate_declaration(
                 manifest(Map.put(@declared, "actions", ["execution.list", "layout.get"]))
               )
    end

    for action <- ["schedule.create", "schedule.update"] do
      test "#{action} among the system actions is refused, for every placement and for an app" do
        action = unquote(action)

        sentence =
          "tincture.actions names #{action}: a tincture never creates or changes a schedule"

        for placement <- [nil | Rules.placements()] do
          frame = if placement, do: %{"placement" => placement}, else: %{}
          tincture = %{"frame" => frame, "actions" => ["execution.list", action]}

          tincture =
            if placement == "canvas",
              do: Map.put(tincture, "entry", "index.html"),
              else: tincture

          manifest = %{"type" => "tincture", "tincture" => tincture}

          assert Rules.validate_declaration(manifest) == {:error, {:invalid_tincture, sentence}},
                 inspect(placement)

          assert Compendium.tincture_declaration(manifest) ==
                   {:error, {:invalid_tincture, sentence}}
        end
      end
    end

    test "every tool only an agent asks for is refused among the system actions; a schedule's other actions are not" do
      for tool <- Prima.Manifest.Caps.agent_only_tools() do
        assert {:error, {:invalid_tincture, "tincture.actions names " <> _}} =
                 Rules.validate_declaration(
                   manifest(Map.put(@declared, "actions", ["execution.list", tool]))
                 ),
               tool
      end

      for action <- ["schedule.list", "schedule.get", "schedule.delete", "schedule.pause"] do
        assert {:ok, _} =
                 Rules.validate_declaration(
                   manifest(Map.put(@declared, "actions", ["execution.list", action]))
                 ),
               action
      end
    end

    test "a frame may invoke a component its dependencies.static names, and no other" do
      declared = manifest(@declared)

      refute Rules.invokes?(declared, "reagent:local.stripe")
      assert Rules.invokes?(declared, "reagent:local.runs:1.0.0")
      assert Rules.invokes?(declared, "r:local.runs")
      refute Rules.invokes?(declared, "reagent:local.runs-two")
      refute Rules.invokes?(declared, nil)
      assert Compendium.tincture_invokes?(declared, @runs)

      pinned = %{
        "dependencies" => %{"static" => ["reagent:local.runs:1.0.0"]}
      }

      refute Rules.invokes?(pinned, "reagent:local.runs:2.0.0")
      assert Rules.invokes?(pinned, "reagent:local.runs")
    end

    test "a tincture that is no canvas keeps its origins and dependencies" do
      assert {:ok, _} =
               Rules.validate_declaration(
                 manifest(%{
                   "connect" => ["api.example.com"],
                   "frame" => %{"capabilities" => ["pointer_lock"]}
                 })
               )
    end

    test "a malformed block is refused as the shapes refuse it" do
      assert {:error, {:invalid_tincture, _}} =
               Rules.validate_declaration(manifest(%{"streams" => "nope"}))
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

      # A holder-bound stream is declared with no subject: the gate
      # supplies the holder's own, and a declared one is refused.
      held = %{@deltas | bind: :holder}
      assert Rules.check_streams(none, [held]) == :ok
      assert {:error, {:invalid_tincture, _}} = Rules.check_streams(decl, [held])
      assert {:error, {:invalid_tincture, _}} = Rules.check_streams(literal, [held])
    end
  end

  describe "a canvas's policy" do
    @shell "https://shell.test"
    @credential "assetcred_0123456789abcdef"
    @frame "frm_canvas_0001"
    @sdk "/_c/v1/sdk/0123456789abcdef.js"

    defp canvas_opts(overrides \\ %{}) do
      Map.merge(
        %{
          endpoint: @endpoint,
          shell: @shell,
          asset_credential: @credential,
          frame_id: @frame,
          sdk_path: @sdk
        },
        overrides
      )
    end

    test "is exactly the plan's policy: the version's files, the SDK's path and the open's data path" do
      files = "https://cyfr.test/_s/#{@credential}/"
      data = "https://cyfr.test/_f/v1/o/#{@frame}/"

      policy = Rules.canvas_page_csp(canvas_opts())

      assert policy ==
               "default-src 'none'; script-src #{files} https://cyfr.test#{@sdk}; " <>
                 "style-src #{files} 'unsafe-inline'; worker-src blob: #{files}; " <>
                 "img-src #{files} data: blob:; font-src #{files}; media-src #{files}; " <>
                 "connect-src #{data} #{files}; frame-src 'none'; object-src 'none'; " <>
                 "base-uri #{files}; form-action 'none'; frame-ancestors #{@shell}; " <>
                 "sandbox allow-scripts"

      assert files == @endpoint <> "/" <> Prima.TinctureUrl.asset_prefix() <> "/#{@credential}/"
      assert data == @endpoint <> Prima.TinctureWire.data_path(@frame)
      assert Compendium.tincture_canvas_page_csp(canvas_opts()) == policy
    end

    test "weakens nothing: no 'self', no nonce, no inline script, no host source but its own" do
      policy = Rules.canvas_page_csp(canvas_opts())
      d = directives(policy)

      refute policy =~ "'self'"
      refute policy =~ "nonce"
      refute policy =~ "unsafe-eval"
      refute policy =~ "wasm-unsafe-eval"
      refute String.ends_with?(policy, "; ")

      # Scripts are the version's files and the SDK's one path, never an
      # origin, an inline script or a nonce.
      assert d["script-src"] == [
               "https://cyfr.test/_s/#{@credential}/",
               "https://cyfr.test" <> @sdk
             ]

      # An inline style is the one inline allowance.
      inline = for {name, sources} <- d, "'unsafe-inline'" in sources, do: name
      assert inline == ["style-src"]

      allowed = [
        "https://cyfr.test/_s/#{@credential}/",
        "https://cyfr.test" <> @sdk,
        "https://cyfr.test/_f/v1/o/#{@frame}/",
        @shell
      ]

      hosts =
        for {_directive, sources} <- d,
            source <- sources,
            String.contains?(source, "://"),
            uniq: true,
            do: source

      assert Enum.sort(hosts) == Enum.sort(allowed)

      # No source is a whole origin: each names a path under it.
      for host <- hosts -- [@shell], do: assert(URI.parse(host).path not in [nil, "", "/"])

      # The open's data path and its own files are the only connections; a
      # `<base>` names its own files alone; the shell alone may frame it;
      # the sandbox is the canvas's tokens.
      assert d["connect-src"] == [
               "https://cyfr.test/_f/v1/o/#{@frame}/",
               "https://cyfr.test/_s/#{@credential}/"
             ]

      assert d["base-uri"] == ["https://cyfr.test/_s/#{@credential}/"]
      assert d["frame-ancestors"] == [@shell]
      assert d["frame-src"] == ["'none'"]
      assert d["sandbox"] == Rules.canvas_sandbox_tokens()
      assert d["default-src"] == ["'none'"]

      # Another open's policy names another data path.
      other = directives(Rules.canvas_page_csp(canvas_opts(%{frame_id: "frm_canvas_0002"})))
      refute other["connect-src"] == d["connect-src"]
    end

    test "a value outside its grammar raises, and the sentence names no value" do
      canary = "CANARYcredential0123456789"

      for {key, bad} <- [
            endpoint: "https://cyfr.test/#{canary}",
            shell: "#{canary}; script-src *",
            asset_credential: canary <> "/..",
            asset_credential: "." <> canary,
            frame_id: canary <> "/x",
            frame_id: "short",
            sdk_path: canary <> ".js",
            sdk_path: "/_c/v1/sdk/../" <> canary,
            sdk_path: "/_c/v1/sdk/#{canary}.js; script-src *",
            sdk_path: "https://cdn.example/#{canary}.js"
          ] do
        error =
          assert_raise ArgumentError, fn -> Rules.canvas_page_csp(canvas_opts(%{key => bad})) end

        refute Exception.message(error) =~ canary
        refute Exception.message(error) =~ "CANARY"
      end

      error =
        assert_raise ArgumentError, fn ->
          Rules.canvas_page_csp(Map.delete(canvas_opts(%{asset_credential: canary}), :sdk_path))
        end

      refute Exception.message(error) =~ canary
    end

    test "a canvas's sandbox is scripts alone, never with the same origin" do
      assert Rules.canvas_sandbox_tokens() == ["allow-scripts"]
      assert Compendium.tincture_canvas_sandbox_tokens() == ["allow-scripts"]

      for token <- Rules.canvas_sandbox_tokens(), do: refute(token in @forbidden)
    end

    test "a canvas page's connection allowlist names the origin that served it" do
      assert Rules.canvas_connection_allowlist() == "(response-origin)"

      assert Compendium.tincture_canvas_connection_allowlist() ==
               Rules.canvas_connection_allowlist()
    end
  end

  describe "a canvas" do
    @vanilla %{"entry" => "index.html"}
    @react %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}}
    @template_sentence "a canvas declares tincture.entry index.html with no tincture.build, " <>
                         "or tincture.entry dist/index.html with tincture.build.tool vite"

    defp canvas(tincture \\ %{}, extra \\ %{}) do
      %{
        "type" => "tincture",
        "tincture" => Map.merge(Map.put(@vanilla, "frame", %{"placement" => "canvas"}), tincture)
      }
      |> Map.merge(extra)
    end

    defp canvas_refused(manifest, sentence) do
      assert Rules.validate_declaration(manifest) ==
               {:error, {:invalid_tincture, "tincture.frame.placement canvas: " <> sentence}}

      assert Compendium.tincture_declaration(manifest) == Rules.validate_declaration(manifest)
    end

    defp object_shape(fields) do
      {:ok, shape} =
        Prima.Canvas.Shape.validate(%{
          "type" => "object",
          "fields" => Map.new(fields, &{&1, %{"type" => "json"}})
        })

      shape
    end

    defp canvas_table do
      [
        %Prima.Provider.Stream{
          name: "runs.changes",
          topic: :executions,
          projection: ["kind", "execution_id"],
          deadline_bound: 600,
          shape: object_shape(["kind", "execution_id"])
        },
        %Prima.Provider.Stream{
          name: "feed.results",
          topic: :feeds,
          projection: ["feed", "result"],
          subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
          deadline_bound: 600,
          shape: object_shape(["feed", "result"]),
          filter: "feed"
        },
        @deltas
      ]
    end

    defp streams_of(entries) do
      {:ok, declaration} =
        Rules.validate_declaration(canvas(%{"streams" => entries}))

      declaration
    end

    test "a vanilla canvas and a react canvas that keep the rules are answered as the struct" do
      streams = [%{"name" => "feed.results", "subject" => "btc"}]

      for template <- [@vanilla, @react] do
        assert {:ok, %Tincture{} = decl} =
                 Rules.validate_declaration(canvas(Map.put(template, "streams", streams)))

        assert decl.frame.placement == "canvas"
        assert decl.streams == [%Tincture.Stream{name: "feed.results", subject: "btc"}]
      end

      assert "canvas" in Rules.placements()

      # A react canvas is built, so it ships its lockfile; a vanilla one is not.
      assert Rules.lockfile_required?(canvas(@react))
      refute Rules.lockfile_required?(canvas(@vanilla))
    end

    test "a canvas declares one of its two templates' entry and build, and nothing else" do
      for tincture <- [
            %{"entry" => nil},
            %{"entry" => ""},
            %{"entry" => "canvas.js"},
            %{"entry" => "page.html"},
            %{"entry" => "dist/index.html"},
            %{"entry" => "index.html", "build" => %{"tool" => "vite"}},
            %{"entry" => "index.html", "build" => %{}},
            %{"entry" => "dist/index.html", "build" => %{"tool" => "webpack"}},
            %{"entry" => "dist/index.html", "build" => "vite"},
            %{"entry" => "dist/index.html", "build" => %{}},
            %{"entry" => "build/index.html", "build" => %{"tool" => "vite"}}
          ] do
        canvas_refused(canvas(tincture), @template_sentence)
      end
    end

    test "a manifest carrying a tincture.canvas block is refused as any canvas without its page" do
      block = %{"canvas" => %{"module" => "canvas.js"}}

      canvas_refused(
        canvas(Map.merge(%{"entry" => nil}, block)),
        @template_sentence
      )
    end

    test "each declaration a canvas may not make is refused with its own sentence" do
      refusals = [
        {canvas(%{"connect" => ["api.example.com"]}),
         "a canvas declares no tincture.connect origin"},
        {canvas(%{}, %{"caps" => %{"egress" => %{"domains" => ["api.example.com"]}}}),
         "a canvas declares no caps.egress"},
        {canvas(%{}, %{"dependencies" => %{"static" => ["reagent:local.runs"]}}),
         "a canvas declares no component dependency, static or dynamic"},
        {canvas(%{}, %{"dependencies" => %{"dynamic" => %{"discover" => true}}}),
         "a canvas declares no component dependency, static or dynamic"},
        {canvas(%{"frame" => %{"placement" => "canvas", "capabilities" => ["fullscreen"]}}),
         "a canvas declares no frame capability"},
        {canvas(%{"actions" => ["execution.list"]}), "a canvas declares no system action"},
        {canvas(%{
           "frame" => %{
             "placement" => "canvas",
             "size" => %{"preferred" => %{"w" => 400, "h" => 640}}
           }
         }), "a canvas declares no size: it fills the screen"}
      ]

      for {manifest, sentence} <- refusals, do: canvas_refused(manifest, sentence)

      # A react canvas is held to them alike.
      for {manifest, sentence} <- refusals do
        canvas_refused(update_in(manifest, ["tincture"], &Map.merge(&1, @react)), sentence)
      end

      # Each says which: no two kinds of refusal share a sentence.
      sentences = refusals |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      assert length(sentences) == length(refusals) - 1

      # Declared as empty, each is no declaration at all.
      assert {:ok, _} =
               Rules.validate_declaration(
                 canvas(%{"connect" => [], "actions" => []}, %{
                   "dependencies" => %{"static" => []}
                 })
               )
    end

    test "a canvas declaring background is refused" do
      canvas_refused(
        canvas(%{"frame" => %{"placement" => "canvas", "background" => true}}),
        "a canvas declares no background: hidden, it reads and acts on nothing"
      )

      assert {:ok, %Tincture{frame: %{background: false}}} =
               Rules.validate_declaration(
                 canvas(%{"frame" => %{"placement" => "canvas", "background" => false}})
               )
    end

    test "a canvas reads only streams that declare a shape, each feed by its name, once" do
      table = canvas_table()

      ok =
        streams_of([%{"name" => "runs.changes"}, %{"name" => "feed.results", "subject" => "btc"}])

      assert Rules.check_canvas_streams(ok, table) == :ok
      assert Rules.check_streams(ok, table) == :ok
      assert Compendium.tincture_check_canvas_streams(ok, table) == :ok

      two_feeds =
        streams_of([
          %{"name" => "feed.results", "subject" => "btc"},
          %{"name" => "feed.results", "subject" => "eth"}
        ])

      assert Rules.check_canvas_streams(two_feeds, table) == :ok

      for {entries, sentence} <- [
            {[%{"name" => "executions.deltas", "subject" => "*"}],
             "tincture.streams names executions.deltas, which a canvas cannot read: " <>
               "the stream declares no shape"},
            {[%{"name" => "builds.progress"}],
             "tincture.streams names builds.progress, which no provider declares"},
            {[%{"name" => "feed.results"}],
             "tincture.streams feed.results: a canvas names the feed it reads as the subject"},
            {[%{"name" => "feed.results", "subject" => "*"}],
             "tincture.streams feed.results: a canvas names each feed it reads, never \"*\" for any"},
            {[%{"name" => "feed.results", "subject" => "BTC:usd"}],
             "tincture.streams feed.results: the subject must be a feed's name"},
            {[
               %{"name" => "feed.results", "subject" => "btc"},
               %{"name" => "feed.results", "subject" => "btc"}
             ], "tincture.streams declares a stream twice"},
            {[%{"name" => "runs.changes"}, %{"name" => "runs.changes"}],
             "tincture.streams declares a stream twice"}
          ] do
        assert Rules.check_canvas_streams(streams_of(entries), table) ==
                 {:error, {:invalid_tincture, "tincture.frame.placement canvas: " <> sentence}}
      end
    end

    test "a canvas's files hold its page, and only its page is required of them" do
      vanilla = canvas()
      react = canvas(@react)

      assert Rules.check_canvas_files(vanilla, ["index.html", "app.js", "about.html"]) == :ok

      assert Rules.check_canvas_files(react, [
               "index.html",
               "src/main.tsx",
               "package.json",
               "package-lock.json",
               "dist/index.html",
               "dist/assets/index-abc.js"
             ]) == :ok

      for {manifest, entry, paths} <- [
            {vanilla, "index.html", ["app.js", "dist/index.html"]},
            {vanilla, "index.html", []},
            # A react canvas's page is its build's: its sources alone hold none.
            {react, "dist/index.html", ["index.html", "src/main.tsx", "package.json"]}
          ] do
        assert Rules.check_canvas_files(manifest, paths) ==
                 {:error,
                  {:invalid_tincture,
                   "tincture.frame.placement canvas: its page #{entry} is not among the " <>
                     "version's files"}}
      end

      # An app's files are no canvas's to hold.
      app = %{"tincture" => %{"frame" => %{"capabilities" => ["pointer_lock"]}}}
      assert Rules.check_canvas_files(app, []) == :ok

      assert Compendium.tincture_check_canvas_files(react, ["index.html"]) ==
               Rules.check_canvas_files(react, ["index.html"])
    end
  end

  describe "a stream that declares a shape" do
    defp declared(frame, entries) do
      {:ok, declaration} =
        Rules.validate_declaration(%{
          "type" => "tincture",
          "tincture" => %{"frame" => frame, "streams" => entries}
        })

      declaration
    end

    defp shaped_refusal(name),
      do:
        {:error,
         {:invalid_tincture,
          "tincture.streams names #{name}, which declares a shape: " <>
            "a stream that declares a shape is read by a canvas alone"}}

    test "is refused in an app, framed or not, whatever its subject" do
      table = canvas_table()

      for frame <- [%{"capabilities" => ["pointer_lock"]}, %{}],
          entry <- [
            %{"name" => "feed.results", "subject" => "btc"},
            %{"name" => "feed.results", "subject" => "*"},
            %{"name" => "runs.changes"}
          ] do
        declaration = declared(frame, [entry])

        assert Rules.check_streams(declaration, table) == shaped_refusal(entry["name"]),
               inspect({frame, entry})

        assert Compendium.tincture_check_streams(declaration, table) ==
                 shaped_refusal(entry["name"])
      end

      # Beside a stream it may open, the shaped one is still named.
      mixed =
        declared(%{}, [
          %{"name" => "executions.deltas", "subject" => "*"},
          %{"name" => "runs.changes"}
        ])

      assert Rules.check_streams(mixed, table) == shaped_refusal("runs.changes")
    end

    test "the schedules' two streams, as the catalog declares them, are a canvas's alone " <>
           "and take no subject" do
      table = Sanctum.Catalog.streams()

      for name <- ["schedules.changes", "schedule_runs.changes"] do
        assert Rules.check_streams(streams_of([%{"name" => name}]), table) == :ok, name

        for frame <- [%{"capabilities" => ["pointer_lock"]}, %{}] do
          assert Rules.check_streams(declared(frame, [%{"name" => name}]), table) ==
                   shaped_refusal(name)
        end

        for subject <- ["sch_1", "*"] do
          assert {:error, {:invalid_tincture, _}} =
                   Rules.check_streams(
                     streams_of([%{"name" => name, "subject" => subject}]),
                     table
                   ),
                 "#{name} took the subject #{subject}"
        end
      end
    end

    test "is a canvas's to declare, and a stream without one stays any tincture's" do
      table = canvas_table()

      canvas =
        streams_of([%{"name" => "runs.changes"}, %{"name" => "feed.results", "subject" => "btc"}])

      assert Rules.check_streams(canvas, table) == :ok

      for frame <- [%{"capabilities" => ["pointer_lock"]}, %{}] do
        assert Rules.check_streams(
                 declared(frame, [%{"name" => "executions.deltas", "subject" => "*"}]),
                 table
               ) == :ok
      end
    end
  end

  describe "the origins a frame connects to and what its reads may carry" do
    test "the origins are the declared domains the connect grammar admits, once each, " <>
           "exactly as the policy admits them" do
      declared =
        manifest(%{
          "connect" => ["api.example.com", "*.example.org", "https://bad", "api.example.com"]
        })

      assert Rules.connect_origins(declared) == ["api.example.com", "*.example.org"]

      assert declared
             |> Rules.csp(%{endpoint: @endpoint, nonce: @nonce})
             |> directives()
             |> Map.fetch!("connect-src") ==
               [@endpoint | Enum.map(Rules.connect_origins(declared), &"https://#{&1}")]

      for none <- [manifest(%{}), manifest(%{"connect" => []}), %{"tincture" => "x"}, nil] do
        assert Rules.connect_origins(none) == []
      end
    end

    test "an invoke may carry every class, and a stored file its grant's and the outside" do
      assert Rules.read_classes(:invoke) == Prima.Source.classes()
      assert Rules.read_classes(:storage) == [:files_by_grant, :outside]
    end

    test "an action carries what its catalogued operation declares, every class when the " <>
           "catalog holds none" do
      assert Rules.read_classes({:action, "system.status"}) == []
      assert Rules.read_classes({:action, "component.search"}) == [:outside]

      for operation <- [
            "system.status",
            "component.search",
            "execution.list",
            "notes.read",
            "notes.search"
          ] do
        [tool, action] = String.split(operation, ".")
        {:ok, {_provider, %{operations: operations}}} = Sanctum.Catalog.lookup(tool)
        declared = Enum.find(operations, &(&1.action == action))

        assert Rules.read_classes({:action, operation}) ==
                 Prima.Operation.possible_classes(declared),
               operation
      end

      for unknown <- ["no_such_tool.read", "system.no_such_action", "system"] do
        assert Rules.read_classes({:action, unknown}) == Prima.Source.classes(), unknown
      end
    end

    test "a stream over a turn, a thread or notes may carry every class, and any other " <>
           "the outside alone" do
      for name <- ["turn.events", "thread.messages", "notes.changes"] do
        assert Rules.read_classes({:stream, name}) == Prima.Source.classes(), name
      end

      for name <- [
            "mcp_servers.changes",
            "confirmation.changes",
            "feed.results",
            "runs.changes",
            "schedules.changes",
            "schedule_runs.changes",
            "threads_seen.changes"
          ] do
        assert Rules.read_classes({:stream, name}) == [:outside], name
      end
    end

    test "a frame's declared reads together carry every class any of them may" do
      plain = %{
        "type" => "tincture",
        "tincture" => %{
          "actions" => ["system.status"],
          "streams" => [%{"name" => "mcp_servers.changes"}]
        }
      }

      assert Rules.frame_classes(plain) == [:outside]

      assert Rules.frame_classes(put_in(plain, ["tincture", "streams"], [%{"name" => "notes.x"}])) ==
               Prima.Source.classes()

      # Each static dependency is an invoke, which may carry every class.
      assert Rules.frame_classes(Map.put(plain, "dependencies", %{"static" => [@runs]})) ==
               Prima.Source.classes()

      assert Rules.frame_classes(%{"type" => "tincture", "tincture" => %{}}) == []

      # A declaration that does not read is held to every class.
      assert Rules.frame_classes(manifest(%{"streams" => "nope"})) == Prima.Source.classes()
    end
  end

  test "the facade answers what the rules answer" do
    declared = manifest(%{"connect" => ["api.example.com"], "actions" => ["system.status"]})
    assert Compendium.tincture_connect_origins(declared) == Rules.connect_origins(declared)
    assert Compendium.tincture_frame_classes(declared) == Rules.frame_classes(declared)

    for read <- [:invoke, :storage, {:action, "system.status"}, {:stream, "thread.messages"}] do
      assert Compendium.tincture_read_classes(read) == Rules.read_classes(read)
    end

    assert Compendium.tincture_served_types() == Rules.served_types()

    assert Compendium.tincture_sandbox_tokens(["pointer_lock"]) ==
             Rules.sandbox_tokens(["pointer_lock"])

    assert Compendium.tincture_allow_attribute(["gamepad"]) == Rules.allow_attribute(["gamepad"])
    assert Compendium.tincture_templates() == Rules.templates()
    assert Compendium.tincture_lockfile_required?(%{}) == Rules.lockfile_required?(%{})
  end
end
