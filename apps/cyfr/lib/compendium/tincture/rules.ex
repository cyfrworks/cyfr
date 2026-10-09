# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture.Rules do
  @moduledoc """
  The rules a tincture's frame is served and held by, in one module: the
  file types a version serves, the frame capabilities a manifest may
  declare and what each opens in the frame's `sandbox` and `allow`
  attributes, the entry page's Content Security Policy, the templates a
  tincture starts from, the lockfile a build tincture ships, and the
  grammar of its frame, canvas, cards, streams and system actions. A
  canvas (placement `canvas`) is held tighter: its declaration reaches
  nothing of its own and reads only canvas-readable streams
  (`check_canvas_streams/2`), its frame's sandbox is `allow-scripts` alone
  (`canvas_sandbox_tokens/0`), and its one policy, for its host page and
  its workers alike, is `canvas_page_csp/1`.

  The publish check reads this module. Every other reader goes through the
  `Compendium` facade or the data it derives, so no sandbox token or CSP
  directive is written anywhere else.

  ## What the frame is, in every browser

  These rules are frozen against the frame facts recorded in
  `tests/browser/README.md`:

    * a frame sandboxed without `allow-same-origin` has the origin `null`,
      so every data request it makes is cross-origin — and WebKit refuses
      one under `connect-src 'self'` before sending it, so `connect-src`
      names the endpoint's origin and never `'self'`;
    * a script from any path of the origin runs under `script-src 'self'`,
      another tincture's included, so a version's immutability is the
      publish check's guarantee, not the policy's;
    * a worker from a `blob:` URL and WebAssembly are closed by a
      `script-src` without `'wasm-unsafe-eval'` and a `worker-src` without
      `blob:`, and both are opened here;
    * a form submission is closed by the sandbox without `allow-forms`,
      and closed again by `form-action 'none'`.

  The sandbox never carries `allow-same-origin`, `allow-top-navigation` or
  `allow-popups` (or their variants), nor `allow-forms`: the map from
  capabilities to tokens is checked when this module compiles.
  """

  alias Prima.Manifest.Tincture

  # The served file types: extension to the MIME type a file is served
  # with. Pages, scripts, styles, JSON and source maps; fonts; SVG and
  # raster images (never `.webp`, which the listing's launch constraint
  # blocks — `Compendium.Tincture`); WebAssembly and engine data packs;
  # audio; glTF, GLB and their buffers; KTX2 textures.
  @served_types %{
    ".html" => "text/html",
    ".js" => "text/javascript",
    ".mjs" => "text/javascript",
    ".css" => "text/css",
    ".json" => "application/json",
    ".map" => "application/json",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf" => "font/ttf",
    ".otf" => "font/otf",
    ".eot" => "application/vnd.ms-fontobject",
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".ico" => "image/x-icon",
    ".wasm" => "application/wasm",
    ".pck" => "application/octet-stream",
    ".data" => "application/octet-stream",
    ".mp3" => "audio/mpeg",
    ".ogg" => "audio/ogg",
    ".oga" => "audio/ogg",
    ".opus" => "audio/ogg",
    ".wav" => "audio/wav",
    ".flac" => "audio/flac",
    ".m4a" => "audio/mp4",
    ".gltf" => "model/gltf+json",
    ".glb" => "model/gltf-binary",
    ".bin" => "application/octet-stream",
    ".ktx2" => "image/ktx2"
  }

  @frame_capabilities ~w(pointer_lock fullscreen gamepad audio_autoplay)
  @placements ~w(float desktop canvas)

  # The toolkit majors a canvas may be drawn by.
  @toolkit_majors [1]

  # A canvas's module is a script of its version: a relative path ending
  # `.js` or `.mjs`.
  @module_extensions ~w(.js .mjs)

  # Every frame runs its scripts; nothing else is on unless granted.
  @sandbox_always ["allow-scripts"]

  # A canvas's frame runs its scripts and nothing else, whatever it is
  # granted: it declares no capability.
  @canvas_sandbox ["allow-scripts"]
  @sandbox_by_capability %{"pointer_lock" => ["allow-pointer-lock"]}
  @allow_by_capability %{
    "fullscreen" => "fullscreen",
    "gamepad" => "gamepad",
    "audio_autoplay" => "autoplay"
  }

  @forbidden_sandbox_tokens ~w(
    allow-same-origin
    allow-top-navigation allow-top-navigation-by-user-activation
    allow-top-navigation-to-custom-protocols
    allow-popups allow-popups-to-escape-sandbox
    allow-forms
  )

  @templates [
    %{name: "vanilla", build: nil, entry: "index.html"},
    %{name: "vite", build: "vite", entry: "dist/index.html"},
    %{name: "react", build: "vite", entry: "dist/index.html"}
  ]

  @lockfile "package-lock.json"

  @image_types ~w(.svg .png .jpg .jpeg .gif)

  @origin ~r/\Ahttps?:\/\/(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?\z/
  @nonce ~r/\A[A-Za-z0-9+\/_=-]{16,128}\z/

  @typedoc "A refusal in `Prima.Manifest`'s block vocabulary: the tag and a sentence."
  @type refusal :: {:invalid_tincture, String.t()}

  @typedoc "A template a tincture starts from: its name, its build tool (nil for none) and its entry."
  @type template :: %{name: String.t(), build: String.t() | nil, entry: String.t()}

  @typedoc "What the CSP is derived for: the endpoint's origin, the page's nonce and the shell's origin."
  @type csp_opts :: %{
          required(:endpoint) => String.t(),
          required(:nonce) => String.t(),
          optional(:shell) => String.t()
        }

  @typedoc """
  What a canvas's policy is derived for: the endpoint's origin, the
  shell's origin, the version's asset credential, the open's frame id and
  the page's nonce.
  """
  @type canvas_csp_opts :: %{
          required(:endpoint) => String.t(),
          required(:shell) => String.t(),
          required(:asset_credential) => String.t(),
          required(:frame_id) => String.t(),
          required(:nonce) => String.t()
        }

  # The maps are checked here, once, so a change that would emit a
  # forbidden token fails the build rather than a review.
  case for(
         {_capability, tokens} <- @sandbox_by_capability,
         token <- tokens,
         token in @forbidden_sandbox_tokens,
         do: token
       ) ++
         Enum.filter(@sandbox_always ++ @canvas_sandbox, &(&1 in @forbidden_sandbox_tokens)) do
    [] -> :ok
    bad -> raise CompileError, description: "the frame sandbox map emits #{Enum.join(bad, ", ")}"
  end

  @doc "The served file types: each extension a version serves, to the MIME type it is served with."
  @spec served_types() :: %{String.t() => String.t()}
  def served_types, do: @served_types

  @doc """
  The frame capabilities a manifest may declare in
  `tincture.frame.capabilities`. Beside them the frame declares its
  `placement` (`placements/0`) and whether it runs in the `background`.
  """
  @spec frame_capabilities() :: [String.t()]
  def frame_capabilities, do: @frame_capabilities

  @doc """
  The placements a frame may declare: floating over the shell, a desktop
  of its own, or a canvas, a page the toolkit draws from the module its
  `tincture.canvas` block names (`validate_declaration/1`).
  """
  @spec placements() :: [String.t()]
  def placements, do: @placements

  @doc "The toolkit majors a canvas's `tincture.canvas.toolkit` may name."
  @spec toolkit_majors() :: [pos_integer()]
  def toolkit_majors, do: @toolkit_majors

  @doc """
  A canvas frame's `sandbox` tokens: `allow-scripts` alone, never with
  `allow-same-origin`. A canvas declares no capability, so nothing is
  added to them.
  """
  @spec canvas_sandbox_tokens() :: [String.t()]
  def canvas_sandbox_tokens, do: @canvas_sandbox

  @doc "The sandbox tokens no frame ever carries, whatever it is granted."
  @spec forbidden_sandbox_tokens() :: [String.t()]
  def forbidden_sandbox_tokens, do: @forbidden_sandbox_tokens

  @doc """
  The frame's `sandbox` tokens for the capabilities its grant holds:
  `allow-scripts` always, `allow-pointer-lock` only when `pointer_lock` is
  granted. A capability that is not one of `frame_capabilities/0` is
  refused.
  """
  @spec sandbox_tokens([String.t()]) :: {:ok, [String.t()]} | {:error, refusal()}
  def sandbox_tokens(granted) when is_list(granted) do
    with :ok <- known(granted) do
      granted_tokens =
        granted
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(&Map.get(@sandbox_by_capability, &1, []))

      {:ok, @sandbox_always ++ granted_tokens}
    end
  end

  @doc """
  The sandbox tokens a capability-to-token map would emit that no frame
  may carry: the check this module's own map passes at compile time,
  answered for any map.
  """
  @spec sandbox_violations(%{String.t() => [String.t()]}) :: [String.t()]
  def sandbox_violations(map) when is_map(map) do
    for {_capability, tokens} <- map,
        token <- tokens,
        token in @forbidden_sandbox_tokens,
        uniq: true,
        do: token
  end

  @doc """
  The frame's `allow` attribute (its permissions policy) for the
  capabilities its grant holds: `fullscreen`, `gamepad` and `autoplay`,
  each only when granted, joined by `; `. `""` when none is. A capability
  that is not one of `frame_capabilities/0` is refused.
  """
  @spec allow_attribute([String.t()]) :: {:ok, String.t()} | {:error, refusal()}
  def allow_attribute(granted) when is_list(granted) do
    with :ok <- known(granted) do
      {:ok,
       granted
       |> Enum.uniq()
       |> Enum.sort()
       |> Enum.flat_map(&List.wrap(Map.get(@allow_by_capability, &1)))
       |> Enum.join("; ")}
    end
  end

  @doc """
  The entry page's `Content-Security-Policy` header value, derived from
  the manifest's declaration: `connect-src` names the endpoint's origin
  and the manifest's `tincture.connect` domains (over `https`), never
  `'self'`; `script-src` carries the page's nonce and
  `'wasm-unsafe-eval'`; `worker-src` admits `blob:`; `frame-ancestors`
  names the shell (the endpoint unless `shell:` says otherwise); and
  `form-action` is `'none'`.

  `endpoint` and `shell` are origins (`scheme://host[:port]`) and `nonce`
  the page's own; a value outside those grammars raises, since each comes
  from the server's configuration or its own random bytes.
  """
  @spec csp(map(), csp_opts()) :: String.t()
  def csp(manifest, %{endpoint: endpoint, nonce: nonce} = opts) when is_map(manifest) do
    shell = Map.get(opts, :shell, endpoint)

    for origin <- [endpoint, shell],
        not (is_binary(origin) and Regex.match?(@origin, origin)),
        do: raise(ArgumentError, "a CSP origin is scheme://host[:port]")

    unless is_binary(nonce) and Regex.match?(@nonce, nonce),
      do: raise(ArgumentError, "a CSP nonce is 16 to 128 base64 characters")

    connect =
      (get_in(manifest, ["tincture", "connect"]) || [])
      |> List.wrap()
      |> Enum.filter(&Prima.Manifest.valid_connect_domain?/1)
      |> Enum.uniq()
      |> Enum.map(&"https://#{&1}")

    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}' 'wasm-unsafe-eval'",
      "worker-src 'self' blob:",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' #{endpoint} data: blob:",
      "font-src 'self' #{endpoint}",
      "media-src 'self' #{endpoint} blob:",
      Enum.join(["connect-src", endpoint | connect], " "),
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors #{shell}",
      "form-action 'none'"
    ]
    |> Enum.join("; ")
  end

  @doc """
  A canvas's `Content-Security-Policy` header value: the one policy of its
  host page and of the workers the page starts from `blob:` URLs, which
  inherit it. It names no `'self'`, no `'unsafe-inline'` and no
  `'unsafe-eval'`, and only two host sources: the version's served prefix
  under the asset credential (`E/_s/A/`, `Prima.TinctureUrl`), for its
  scripts, workers and images, and the open's own data path
  (`E/_f/v1/o/F/`, `Prima.CanvasWire.data_path/1`), its only connection.
  Scripts and styles otherwise run only under the page's nonce, and the
  policy carries the canvas sandbox (`canvas_sandbox_tokens/0`).

  `endpoint` and `shell` are origins (`scheme://host[:port]`),
  `asset_credential` an asset credential, `frame_id` a frame id and
  `nonce` the page's own. A value outside its grammar raises, and the
  sentence names no value: the credential is one.
  """
  @spec canvas_page_csp(canvas_csp_opts()) :: String.t()
  def canvas_page_csp(%{
        endpoint: endpoint,
        shell: shell,
        asset_credential: credential,
        frame_id: frame_id,
        nonce: nonce
      }) do
    for origin <- [endpoint, shell],
        not (is_binary(origin) and Regex.match?(@origin, origin)),
        do: raise(ArgumentError, "a CSP origin is scheme://host[:port]")

    unless is_binary(nonce) and Regex.match?(@nonce, nonce),
      do: raise(ArgumentError, "a CSP nonce is 16 to 128 base64 characters")

    unless Prima.TinctureUrl.credential?(credential),
      do: raise(ArgumentError, "an asset credential is opaque, URL-safe and bounded")

    unless Prima.TinctureWire.frame_id?(frame_id),
      do: raise(ArgumentError, "a frame id is 8 to 64 URL-safe characters")

    files = "#{endpoint}/#{Prima.TinctureUrl.asset_prefix()}/#{credential}/"
    data = endpoint <> Prima.CanvasWire.data_path(frame_id)

    [
      "default-src 'none'",
      "script-src 'nonce-#{nonce}' #{files}",
      "style-src 'nonce-#{nonce}'",
      "worker-src blob: #{files}",
      "img-src #{files} data: blob:",
      "connect-src #{data}",
      "font-src 'none'",
      "media-src 'none'",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors #{shell}",
      Enum.join(["sandbox" | @canvas_sandbox], " ")
    ]
    |> Enum.join("; ")
  end

  def canvas_page_csp(_opts),
    do:
      raise(
        ArgumentError,
        "a canvas policy is derived from an endpoint, a shell, an asset credential, " <>
          "a frame id and a nonce"
      )

  @doc "The templates a tincture starts from: vanilla, Vite and React."
  @spec templates() :: [template()]
  def templates, do: @templates

  @doc "The lockfile a build tincture ships beside its `package.json`."
  @spec lockfile() :: String.t()
  def lockfile, do: @lockfile

  @doc """
  Whether the manifest's tincture is built (it declares `tincture.build`)
  and so must ship `lockfile/0`: a build resolves exactly what the lockfile
  pins, never what a registry answers on the day.
  """
  @spec lockfile_required?(term()) :: boolean()
  def lockfile_required?(%{"tincture" => %{"build" => %{}}}), do: true
  def lockfile_required?(_manifest), do: false

  @doc """
  The manifest's frame, canvas, cards, streams and system actions, held to
  their shapes (`Prima.Manifest.Tincture`) and to these rules: every
  capability is one of `frame_capabilities/0`, a placement is one of
  `placements/0`, card names are distinct, a card's image is a served
  image, each button names an action the declaration lists, a card's
  stream is one it declares, a card's source names a component the
  tincture may invoke (`invokes?/2`), and a card that shows a number or a
  list has a source (one without is static). A desktop (placement
  `desktop`) reaches nothing of its own: it declares no `tincture.connect`
  origin, no `caps.egress` and no component dependency, static or dynamic;
  the cards it draws are other tinctures'.

  A canvas (placement `canvas`) declares `tincture.canvas`, which no other
  placement does: its `module`, a relative path with no `..` and no
  scheme ending `.js` or `.mjs`, which is its entry, so it declares no
  `tincture.entry`; and its `toolkit`, one of `toolkit_majors/0`. It
  reaches nothing of its own and runs only while shown: no
  `tincture.connect` origin, no `caps.egress`, no component dependency,
  static or dynamic, no `tincture.build`, no frame capability, no
  background, no system action and no card. Each refusal says which.

  A manifest that declares none of the blocks answers the empty
  declaration. Which streams exist is `check_streams/2`'s, and which a
  canvas may read `check_canvas_streams/2`'s.
  """
  @spec validate_declaration(term()) :: {:ok, Tincture.t()} | {:error, refusal()}
  def validate_declaration(manifest) do
    with {:ok, %Tincture{} = declaration} <- Tincture.from_manifest(manifest),
         :ok <- known(declaration.frame.capabilities),
         :ok <- placement(declaration.frame.placement),
         :ok <- desktop(declaration.frame.placement, manifest),
         :ok <- canvas(declaration, manifest),
         :ok <- distinct_cards(declaration.cards),
         :ok <- cards(declaration, manifest) do
      {:ok, declaration}
    end
  end

  @doc """
  Whether the tincture `manifest` may invoke the component `ref`: one
  among its `dependencies.static`, by type, publisher and name, and by
  version where both name one. The one rule a frame's invoke is admitted
  by and a card's source is held to.
  """
  @spec invokes?(term(), term()) :: boolean()
  def invokes?(manifest, ref) when is_binary(ref) do
    case Prima.ComponentRef.normalize_flexible(ref) do
      {:ok, wanted} ->
        manifest |> static_dependencies() |> Enum.any?(&same_component?(&1, wanted))

      {:error, _} ->
        false
    end
  end

  def invokes?(_manifest, _ref), do: false

  defp static_dependencies(%{"dependencies" => %{"static" => static}}) when is_list(static) do
    for entry <- static,
        ref = dependency_ref(entry),
        is_binary(ref),
        {:ok, parsed} <- [Prima.ComponentRef.normalize_flexible(ref)],
        do: parsed
  end

  defp static_dependencies(_manifest), do: []

  defp dependency_ref(ref) when is_binary(ref), do: ref
  defp dependency_ref(%{"ref" => ref}), do: ref
  defp dependency_ref(_entry), do: nil

  defp same_component?(declared, wanted) do
    {declared.type, declared.namespace, declared.name} ==
      {wanted.type, wanted.namespace, wanted.name} and
      (is_nil(declared.version) or is_nil(wanted.version) or declared.version == wanted.version)
  end

  @doc """
  Whether every stream the declaration opens is one a provider declares
  (`streams`, every provider's `Prima.Provider.streams/1`), with a subject
  that stream takes: none for a stream without a subject grammar or one
  bound to its holder (`bind: :holder`), whose subject the gate supplies;
  `"*"` or a literal its grammar admits for any other.
  """
  @spec check_streams(Tincture.t(), [Prima.Provider.Stream.t()]) :: :ok | {:error, refusal()}
  def check_streams(%Tincture{streams: declared}, streams) when is_list(streams) do
    Enum.reduce_while(declared, :ok, fn %Tincture.Stream{name: name, subject: subject}, :ok ->
      case Prima.Provider.fetch_stream(streams, name) do
        {:error, :undeclared_stream} ->
          {:halt, refuse("tincture.streams names #{name}, which no provider declares")}

        {:ok, stream} ->
          if subject_taken?(stream, subject),
            do: {:cont, :ok},
            else:
              {:halt, refuse("tincture.streams #{name}: the stream does not take that subject")}
      end
    end)
  end

  defp subject_taken?(%Prima.Provider.Stream{bind: :holder}, subject), do: is_nil(subject)
  defp subject_taken?(%Prima.Provider.Stream{subject: nil}, subject), do: is_nil(subject)
  defp subject_taken?(%Prima.Provider.Stream{}, nil), do: false

  defp subject_taken?(%Prima.Provider.Stream{} = stream, subject) do
    subject == Tincture.any_subject() or Prima.Provider.Stream.admits?(stream, subject)
  end

  @doc """
  Whether every stream a canvas's declaration opens is one a canvas may
  read: a stream a provider declares (`streams`, as `check_streams/2`
  takes them) whose entry carries a `shape`, which is what makes it
  canvas-readable (`Prima.Provider.Stream`). A stream whose subject
  filters its payloads (one with a `filter`, such as a feed's results by
  the feed's name) is declared with a literal subject in the feed-name
  grammar (`Prima.Feed.name?/1`), never `"*"` and never none, so a canvas
  names each feed it reads; and each name and subject is declared once.
  Publish runs it beside `check_streams/2` for a version whose placement
  is `canvas`.
  """
  @spec check_canvas_streams(Tincture.t(), [Prima.Provider.Stream.t()]) ::
          :ok | {:error, refusal()}
  def check_canvas_streams(%Tincture{streams: declared}, streams) when is_list(streams) do
    checked =
      Enum.reduce_while(declared, :ok, fn %Tincture.Stream{name: name, subject: subject}, :ok ->
        case canvas_stream(Prima.Provider.fetch_stream(streams, name), name, subject) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end
      end)

    pairs = Enum.map(declared, &{&1.name, &1.subject})

    cond do
      checked != :ok -> checked
      Enum.uniq(pairs) != pairs -> canvas_refuse("tincture.streams declares a stream twice")
      true -> :ok
    end
  end

  defp canvas_stream({:error, :undeclared_stream}, name, _subject),
    do: canvas_refuse("tincture.streams names #{name}, which no provider declares")

  defp canvas_stream({:ok, %Prima.Provider.Stream{shape: nil}}, name, _subject),
    do:
      canvas_refuse(
        "tincture.streams names #{name}, which a canvas cannot read: the stream declares no shape"
      )

  defp canvas_stream({:ok, %Prima.Provider.Stream{filter: nil}}, _name, _subject), do: :ok

  defp canvas_stream({:ok, %Prima.Provider.Stream{}}, name, nil),
    do: canvas_refuse("tincture.streams #{name}: a canvas names the feed it reads as the subject")

  defp canvas_stream({:ok, %Prima.Provider.Stream{}}, name, subject) do
    cond do
      subject == Tincture.any_subject() ->
        canvas_refuse(
          "tincture.streams #{name}: a canvas names each feed it reads, never \"*\" for any"
        )

      Prima.Feed.name?(subject) ->
        :ok

      true ->
        canvas_refuse("tincture.streams #{name}: the subject must be a feed's name")
    end
  end

  @doc """
  Whether a version's files are a canvas's, for a declaration whose
  placement is `canvas`: they hold the module its `tincture.canvas` block
  names, and no `.html` or `.htm` file anywhere, in any case, since the
  host page is CYFR's and never the version's. `paths` are the version's
  relative file paths. Any other declaration holds its files to nothing
  here. Publish runs it once the declaration and its streams are held.
  """
  @spec check_canvas_files(Tincture.t(), [String.t()]) :: :ok | {:error, refusal()}
  def check_canvas_files(
        %Tincture{frame: %{placement: "canvas"}, canvas: %Tincture.Canvas{module: module}},
        paths
      )
      when is_list(paths) do
    cond do
      page = Enum.find(Enum.sort(paths), &page?/1) ->
        refuse("#{page} is a page, and a canvas holds none: its host page is CYFR's")

      module not in paths ->
        refuse("the canvas's module #{module} is not among the version's files")

      true ->
        :ok
    end
  end

  def check_canvas_files(%Tincture{}, paths) when is_list(paths), do: :ok

  @doc """
  The module a canvas's manifest names in its `tincture.canvas` block,
  which is the canvas's entry: a non-empty string, held to the entry rule
  by its reader. A manifest that names none has no entry, never the
  default page.
  """
  @spec canvas_module(term()) :: {:ok, String.t()} | {:error, refusal()}
  def canvas_module(%{"tincture" => %{"canvas" => %{"module" => module}}})
      when is_binary(module) and module != "",
      do: {:ok, module}

  def canvas_module(_manifest), do: refuse("a canvas's entry is its module, and it names none")

  defp page?(path), do: String.downcase(Path.extname(path)) in [".html", ".htm"]

  defp known(capabilities) do
    case Enum.reject(capabilities, &(&1 in @frame_capabilities)) do
      [] ->
        :ok

      unknown ->
        refuse(
          "tincture.frame declares capabilities no frame has: #{unknown |> Enum.map(&to_string/1) |> Enum.join(", ")}"
        )
    end
  end

  defp placement(nil), do: :ok
  defp placement(placement) when placement in @placements, do: :ok

  defp placement(_placement),
    do: refuse("tincture.frame.placement is one of #{Enum.join(@placements, ", ")}")

  defp distinct_cards(cards) do
    names = Enum.map(cards, & &1.name)

    if Enum.uniq(names) == names,
      do: :ok,
      else: refuse("tincture.cards names a card twice")
  end

  # A desktop draws other tinctures' cards and reaches nothing of its own.
  defp desktop("desktop", manifest) do
    tincture = if is_map(manifest), do: Map.get(manifest, "tincture"), else: nil
    caps = if is_map(manifest), do: Map.get(manifest, "caps"), else: nil
    dependencies = if is_map(manifest), do: Map.get(manifest, "dependencies"), else: nil

    cond do
      present?(is_map(tincture) && Map.get(tincture, "connect")) ->
        refuse("tincture.frame.placement desktop: a desktop declares no tincture.connect origin")

      is_map(caps) and Map.has_key?(caps, "egress") ->
        refuse("tincture.frame.placement desktop: a desktop declares no caps.egress")

      is_map(dependencies) and
          (present?(Map.get(dependencies, "static")) or
             not is_nil(Map.get(dependencies, "dynamic"))) ->
        refuse(
          "tincture.frame.placement desktop: a desktop declares no component dependency; " <>
            "the cards it draws are other tinctures'"
        )

      true ->
        :ok
    end
  end

  defp desktop(_placement, _manifest), do: :ok

  # A canvas is a page the toolkit draws from its module. It reaches
  # nothing of its own and runs only while it is shown; the block that
  # names its module is a canvas's alone.
  defp canvas(%Tincture{frame: %{placement: "canvas"}} = declaration, manifest) do
    tincture = section(manifest, "tincture")
    dependencies = section(manifest, "dependencies")

    cond do
      is_nil(declaration.canvas) ->
        canvas_refuse("a canvas declares tincture.canvas, its module and its toolkit")

      not is_nil(Map.get(tincture, "entry")) ->
        canvas_refuse("a canvas's entry is its module, so it declares no tincture.entry")

      not canvas_module?(declaration.canvas.module) ->
        canvas_refuse(
          "tincture.canvas.module is a relative path with no .. and no scheme, " <>
            "ending #{Enum.join(@module_extensions, " or ")}"
        )

      declaration.canvas.toolkit not in @toolkit_majors ->
        canvas_refuse("tincture.canvas.toolkit is one of #{Enum.join(@toolkit_majors, ", ")}")

      present?(Map.get(tincture, "connect")) ->
        canvas_refuse("a canvas declares no tincture.connect origin")

      Map.has_key?(section(manifest, "caps"), "egress") ->
        canvas_refuse("a canvas declares no caps.egress")

      present?(Map.get(dependencies, "static")) or
          not is_nil(Map.get(dependencies, "dynamic")) ->
        canvas_refuse("a canvas declares no component dependency, static or dynamic")

      not is_nil(Map.get(tincture, "build")) ->
        canvas_refuse("a canvas declares no tincture.build")

      declaration.frame.capabilities != [] ->
        canvas_refuse("a canvas declares no frame capability")

      declaration.frame.background ->
        canvas_refuse("a canvas does not run in the background; it runs only while shown")

      declaration.actions != [] ->
        canvas_refuse("a canvas declares no system action")

      declaration.cards != [] ->
        canvas_refuse("a canvas declares no card")

      true ->
        :ok
    end
  end

  defp canvas(%Tincture{canvas: %Tincture.Canvas{}}, _manifest),
    do: refuse("tincture.canvas is declared only by a canvas (tincture.frame.placement canvas)")

  defp canvas(%Tincture{}, _manifest), do: :ok

  # A path inside the version, as the served prefix serves it: relative,
  # every segment plain, no `..`, no scheme, a script's extension.
  defp canvas_module?(module) when is_binary(module) do
    not String.contains?(module, ":") and
      Prima.PathSafety.validate_relative_path(module) == :ok and
      Enum.all?(String.split(module, "/"), &(&1 != "")) and
      Path.extname(module) in @module_extensions
  end

  defp canvas_module?(_module), do: false

  defp section(manifest, key) when is_map(manifest) do
    case Map.get(manifest, key) do
      %{} = section -> section
      _absent -> %{}
    end
  end

  defp section(_manifest, _key), do: %{}

  defp canvas_refuse(sentence), do: refuse("tincture.frame.placement canvas: " <> sentence)

  defp present?(value) when value in [nil, false, [], ""], do: false
  defp present?(_value), do: true

  defp cards(%Tincture{cards: cards, actions: actions, streams: streams}, manifest) do
    stream_names = MapSet.new(streams, & &1.name)

    Enum.reduce_while(cards, :ok, fn card, :ok ->
      case card_rules(card, actions, stream_names, manifest) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp card_rules(card, actions, stream_names, manifest) do
    cond do
      card.source && not invokes?(manifest, card.source.component) ->
        refuse(
          "tincture.cards #{card.name}: its source #{card.source.component} is not a component " <>
            "dependencies.static declares"
        )

      is_nil(card.source) and (card.number || card.list) ->
        refuse(
          "tincture.cards #{card.name}: a card that shows a number or a list has a source to refresh it from"
        )

      undeclared = Enum.find(card.buttons, &(&1.action not in actions)) ->
        refuse(
          "tincture.cards #{card.name}: a button names #{undeclared.action}, which tincture.actions does not declare"
        )

      card.stream && not MapSet.member?(stream_names, card.stream) ->
        refuse(
          "tincture.cards #{card.name}: its stream #{card.stream} is not one tincture.streams declares"
        )

      card.image && not image?(card.image) ->
        refuse(
          "tincture.cards #{card.name}: the image must be a served image (#{Enum.join(@image_types, ", ")})"
        )

      true ->
        :ok
    end
  end

  defp image?(path), do: String.downcase(Path.extname(path)) in @image_types

  defp refuse(sentence), do: {:error, {:invalid_tincture, sentence}}
end
