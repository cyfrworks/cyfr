# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture.Rules do
  @moduledoc """
  The rules a tincture's frame is served and held by, in one module: the
  file types a version serves, the frame capabilities a manifest may
  declare and what each opens in the frame's `sandbox` and `allow`
  attributes, the entry page's Content Security Policy and the origins it
  admits, the source classes a frame's reads may carry, the templates a
  tincture starts from, the lockfile a build tincture ships, and the
  grammar of its frame, streams and system actions. A desktop, what the
  code calls a canvas (a declaration with the `tincture.desktop` block,
  `Prima.Manifest.Tincture.canvas?/1`), is held tighter: it is its
  version's own page on the vanilla or the react template, its
  declaration reaches nothing of its own, it reads only canvas-readable
  streams, which no other declaration names (`check_streams/2`), its
  controls run only what the person may run directly and its chrome holds
  to its grammar (`check_desktop/2`, `check_chrome/2`), its frame's
  sandbox is `allow-scripts` alone (`canvas_sandbox_tokens/0`), and its
  page's one policy, which its workers inherit, is `canvas_page_csp/1`.

  The publish check reads this module. Every other reader goes through the
  `Compendium` facade or the data it derives, so no frame's sandbox token
  and no directive of a frame's page policy (its entry CSP and `sandbox`
  directive, `frame_policy/2`, or a canvas's, `canvas_page_csp/1`) is
  written anywhere else. The console's page policy and the API's and the
  OAuth callback's response policies are their own surfaces', not a
  frame's, and the seam test rosters each by reason.

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

  These rules hold a first-party tincture as they hold any other: the
  shipped canvas and the console's tinctures are untrusted code here, and
  none is exempt from a sandbox token or a page policy.
  """

  alias Prima.Manifest.Caps
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

  # Every frame runs its scripts; nothing else is on unless granted.
  @sandbox_always ["allow-scripts"]

  # A canvas's frame runs its scripts and nothing else, whatever it is
  # granted: it declares no capability.
  @canvas_sandbox ["allow-scripts"]
  @sandbox_by_capability %{"pointer_lock" => ["allow-pointer-lock"]}
  # A capability only delegates a browser feature to the frame through its
  # `allow` attribute; whatever permission the browser or the operating
  # system asks for that feature it still asks for itself, and no
  # capability or grant here answers it.
  @allow_by_capability %{
    "fullscreen" => "fullscreen",
    "gamepad" => "gamepad",
    "audio_autoplay" => "autoplay"
  }

  # The sandbox tokens no frame ever carries, whatever it is granted.
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

  # The templates a canvas is written on, and each one's entry and build
  # tool: a canvas's declaration names one of these pairs.
  @canvas_template_names ~w(vanilla react)
  @canvas_templates for t <- @templates, t.name in @canvas_template_names, do: t

  @lockfile "package-lock.json"

  # The system actions no tincture declares: every tool only an agent asks
  # for (`Prima.Manifest.Caps.agent_only_tools/0`) and a feed's press,
  # which the person makes.
  @feed_press "feed.press"
  @persons_actions Enum.uniq(Caps.agent_only_tools() ++ [@feed_press])

  # The one `execute` a desktop's control runs besides a feed's press,
  # admitted by its exact name: a retry runs again a run the person
  # already ran, with its component, input and the grant revision it ran
  # under (`Opus.Provider`), so it composes nothing the person has not
  # approved. Every other `execute` stays refused until a control can be
  # previewed.
  @execution_retry "execution.retry"

  # The operations a desktop's control never runs while no frame can ask
  # the person for them: each tool only an agent asks for, which binds or
  # ends a feed, schedules or rearranges the screen. Every operation that
  # asks for the person's own confirmation (a `consent` class: a grant
  # among them) is refused beside them.
  @persons_controls Caps.agent_only_tools()

  # The stream namespaces whose events carry a thread's or the notes'
  # material, which may be of any source class: a thread's title, the
  # people in it and what waits on the person are their own words.
  @thread_streams ~w(turn thread threads notes attention)

  @origin ~r/\Ahttps?:\/\/(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?\z/
  @nonce ~r/\A[A-Za-z0-9+\/_=-]{16,128}\z/
  # An absolute path whose every segment is plain and none is `.` or `..`.
  @absolute_path ~r/\A(?:\/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+\z/

  # The root element of an SVG texture: `<svg`, its attributes, each a
  # name and a quoted value, and its close.
  @svg_start_tag ~r/\A<svg((?:\s+[A-Za-z_:][A-Za-z0-9_:.-]*\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*\/?>/
  @svg_attribute ~r/([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/

  @typedoc "A refusal in `Prima.Manifest`'s block vocabulary: the tag and a sentence."
  @type refusal :: {:invalid_tincture, String.t()}

  @typedoc """
  One read a frame makes: an invoke of a component, a system action by its
  operation name, a stream by its name, or a stored file.
  """
  @type read :: :invoke | {:action, String.t()} | {:stream, String.t()} | :storage

  @typedoc "A template a tincture starts from: its name, its build tool (nil for none) and its entry."
  @type template :: %{name: String.t(), build: String.t() | nil, entry: String.t()}

  @typedoc "What the CSP is derived for: the endpoint's origin, the page's nonce and the shell's origin."
  @type csp_opts :: %{
          required(:endpoint) => String.t(),
          required(:nonce) => String.t(),
          optional(:shell) => String.t()
        }

  @typedoc """
  What a canvas page's policy is derived for: the endpoint's origin, the
  shell's origin, the version's asset credential, the open's frame id and
  the path the SDK's script is served at.
  """
  @type canvas_csp_opts :: %{
          required(:endpoint) => String.t(),
          required(:shell) => String.t(),
          required(:asset_credential) => String.t(),
          required(:frame_id) => String.t(),
          required(:sdk_path) => String.t()
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
  `tincture.frame.capabilities`. Beside them the frame declares whether
  it runs in the `background` and its `size` hint
  (`Prima.Manifest.Tincture.Size`).
  """
  @spec frame_capabilities() :: [String.t()]
  def frame_capabilities, do: @frame_capabilities

  @doc """
  A canvas frame's `sandbox` tokens: `allow-scripts` alone, never with
  `allow-same-origin`. A canvas declares no capability, so nothing is
  added to them.
  """
  @spec canvas_sandbox_tokens() :: [String.t()]
  def canvas_sandbox_tokens, do: @canvas_sandbox

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
  the manifest's declaration: `connect-src` names the endpoint's origin,
  its WebSocket origin (`ws` or `wss` as the endpoint is `http` or
  `https`) for the frame's stream connection, and the manifest's
  `tincture.connect` domains (over `https`), never `'self'`; `script-src` admits `'self'`, the page's nonce and
  `'wasm-unsafe-eval'`, and `style-src` `'self'` and inline styles;
  `worker-src` admits `'self'` and `blob:`; `frame-ancestors` names the
  shell (the endpoint unless `shell:` says otherwise); and `form-action`
  is `'none'`.

  `frame-ancestors` admits only the shell's origin, which a frame's
  opaque origin never is, so no tincture's page is framed by another's.
  A page starts its workers from `blob:` URLs its own scripts make; the
  browser's side is shown by the hostile-frame proof (`blob_worker`) and,
  for a canvas, by the canvas proof (`worker_policy`).

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

    connect = manifest |> connect_origins() |> Enum.map(&"https://#{&1}")

    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}' 'wasm-unsafe-eval'",
      "worker-src 'self' blob:",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' #{endpoint} data: blob:",
      "font-src 'self' #{endpoint}",
      "media-src 'self' #{endpoint} blob:",
      Enum.join(["connect-src", endpoint, socket_origin(endpoint) | connect], " "),
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors #{shell}",
      "form-action 'none'"
    ]
    |> Enum.join("; ")
  end

  @doc """
  A tincture document's whole policy: its `csp/2` under `opts`, with a
  `sandbox` directive opening exactly what the declaration's frame
  capabilities open (`sandbox_tokens/1`). A declaration these rules refuse,
  which the publish check keeps from being installed, opens nothing beyond
  scripts. The served headers take this value whole, so the frame's
  sandbox directive has no other writer.
  """
  @spec frame_policy(map(), csp_opts()) :: String.t()
  def frame_policy(manifest, opts) when is_map(manifest) do
    declared =
      case validate_declaration(manifest) do
        {:ok, declaration} -> declaration.frame.capabilities
        {:error, _refused} -> []
      end

    tokens =
      case sandbox_tokens(declared) do
        {:ok, tokens} -> tokens
        {:error, _refused} -> @sandbox_always
      end

    csp(manifest, opts) <> "; sandbox " <> Enum.join(tokens, " ")
  end

  @doc """
  The origins a frame's page may connect to beyond its endpoint: the
  manifest's `tincture.connect` domains that hold to the connect grammar
  (`Prima.Manifest.valid_connect_domain?/1`), spelled as declared, each
  once, in declared order. `csp/2` admits exactly these, over `https`, and
  each is an exit of the frame (`Prima.Flow`): what the frame reads may
  reach it only as the frame's grant lets it flow there. A manifest that
  declares none, a canvas always, has none.
  """
  @spec connect_origins(term()) :: [String.t()]
  def connect_origins(%{"tincture" => %{"connect" => connect}}) do
    connect
    |> List.wrap()
    |> Enum.filter(&Prima.Manifest.valid_connect_domain?/1)
    |> Enum.uniq()
  end

  def connect_origins(_manifest), do: []

  # The endpoint's WebSocket origin, where a frame's stream connection is:
  # a host-source of `http` admits no `ws` URL, so it is named apart.
  defp socket_origin("https://" <> rest), do: "wss://" <> rest
  defp socket_origin("http://" <> rest), do: "ws://" <> rest

  @doc """
  A canvas page's `Content-Security-Policy` header value, the one policy
  of its page and of the workers the page starts, which inherit it. With
  `F` the version's files under the asset credential (`E/_s/A/`,
  `Prima.TinctureUrl`), `D` the open's data path over the endpoint's
  WebSocket origin (`ws` or `wss` as `E` is `http` or `https`,
  `W/_f/v1/o/<frame id>/`, `Prima.TinctureWire.data_path/1`), where its
  stream connection is, and `S` the shell:

      default-src 'none'; script-src F E<sdk path>; style-src F 'unsafe-inline';
      worker-src blob: F; img-src F data: blob:; font-src F; media-src F;
      connect-src D F; frame-src 'none'; object-src 'none'; base-uri F;
      form-action 'none'; frame-ancestors S; sandbox allow-scripts

  Scripts load only from the version's own files and the SDK's one path,
  and no inline script runs. Styles may be inline, since CSS reaches the
  network only through an `@import`, which `style-src` bounds, and images
  and fonts, which `img-src` and `font-src` bound, and each of the three
  names `F` alone of the network. The page connects to its open's stream
  connection and its own files and nothing else, a `<base>` it writes names
  only its own files, and the policy carries the canvas sandbox
  (`canvas_sandbox_tokens/0`).

  `endpoint` and `shell` are origins (`scheme://host[:port]`),
  `asset_credential` an asset credential, `frame_id` a frame id and
  `sdk_path` an absolute path. A value outside its grammar raises, and the
  sentence names no value: the credential is one.
  """
  @spec canvas_page_csp(canvas_csp_opts()) :: String.t()
  def canvas_page_csp(%{
        endpoint: endpoint,
        shell: shell,
        asset_credential: credential,
        frame_id: frame_id,
        sdk_path: sdk_path
      }) do
    for origin <- [endpoint, shell],
        not (is_binary(origin) and Regex.match?(@origin, origin)),
        do: raise(ArgumentError, "a CSP origin is scheme://host[:port]")

    unless Prima.TinctureUrl.credential?(credential),
      do: raise(ArgumentError, "an asset credential is opaque, URL-safe and bounded")

    unless Prima.TinctureWire.frame_id?(frame_id),
      do: raise(ArgumentError, "a frame id is 8 to 64 URL-safe characters")

    unless is_binary(sdk_path) and Regex.match?(@absolute_path, sdk_path),
      do: raise(ArgumentError, "the SDK's path is an absolute path of plain segments")

    files = "#{endpoint}/#{Prima.TinctureUrl.asset_prefix()}/#{credential}/"
    data = socket_origin(endpoint) <> Prima.TinctureWire.data_path(frame_id)

    [
      "default-src 'none'",
      "script-src #{files} #{endpoint}#{sdk_path}",
      "style-src #{files} 'unsafe-inline'",
      "worker-src blob: #{files}",
      "img-src #{files} data: blob:",
      "font-src #{files}",
      "media-src #{files}",
      "connect-src #{data} #{files}",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri #{files}",
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
          "a frame id and the SDK's path"
      )

  @doc """
  A canvas page's `Connection-Allowlist` header value, `(response-origin)`:
  the page may open connections only to the origin that served it. Only
  Chromium reads the header, where it stops a peer connection's traffic
  from the page; other browsers ignore it, so it closes nothing there.
  """
  @spec canvas_connection_allowlist() :: String.t()
  def canvas_connection_allowlist, do: "(response-origin)"

  @doc "The templates a tincture starts from: vanilla, Vite and React."
  @spec templates() :: [template()]
  def templates, do: @templates

  @doc """
  The templates a canvas is written on, of `templates/0`: vanilla and
  React. A canvas's declaration names one's entry and build tool.
  """
  @spec canvas_templates() :: [template()]
  def canvas_templates, do: @canvas_templates

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
  The manifest's frame, streams, system actions and desktop block, held
  to their shapes (`Prima.Manifest.Tincture`, which also holds
  `frame.size` and the desktop block to their bounds) and to these rules:
  every capability is one of `frame_capabilities/0`. No tincture declares
  `feed.bind`, `feed.remove` or `feed.press` among its system actions:
  those are the person's alone. Nor does any declare `layout.edit`: the
  layout is the person's arrangement, and no tincture writes it. Nor
  `schedule.create` or `schedule.update`: no tincture schedules itself.
  Each tool only an agent asks for (`Prima.Manifest.Caps.agent_only_tools/0`)
  is refused here by its exact name.

  A desktop (a declaration with the `tincture.desktop` block) is its
  version's own page, written on the vanilla or the react template
  (`templates/0`): `tincture.entry` `index.html` with no
  `tincture.build`, or `dist/index.html` with `tincture.build.tool`
  `vite`, whose version ships its lockfile (`lockfile_required?/1`). It
  reaches nothing of its own, and hidden it reads and acts on nothing: no
  `tincture.connect` origin, no `caps.egress`, no component dependency,
  static or dynamic, no frame capability, no background and no system
  action; it fills the screen, so it declares no size; and it is never
  opened with a subject, so it declares no `tincture.subjects`. Each
  refusal says which.

  A manifest that declares none of the blocks answers the empty
  declaration. Which streams exist, and that only a desktop names one that
  declares a shape, is `check_streams/2`'s; what a desktop reads and which
  operations its controls run is `check_desktop/2`'s; its chrome is
  `check_chrome/2`'s.
  """
  @spec validate_declaration(term()) :: {:ok, Tincture.t()} | {:error, refusal()}
  def validate_declaration(manifest) do
    with {:ok, %Tincture{} = declaration} <- Tincture.from_manifest(manifest),
         :ok <- known(declaration.frame.capabilities),
         :ok <- no_persons_action(declaration.actions),
         :ok <- canvas(declaration, manifest) do
      {:ok, declaration}
    end
  end

  @doc """
  Whether the tincture `manifest` may invoke the component `ref`: one
  among its `dependencies.static`, by type, publisher and name, and by
  version where both name one. The one rule a frame's invoke is admitted
  by.
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

  @doc """
  The source classes (`Prima.Source`) a frame's read may carry, known
  before anything is read or run, in class order:

    * `:invoke`, a component's result: every class, since a run's answer
      carries whatever its run read;
    * `{:action, "tool.action"}`, a system action: what the catalogued
      operation declares its answers may carry
      (`Prima.Operation.possible_classes/1`, `outside` for an operation that
      declares nothing), and every class for one the catalog does not hold;
    * `{:stream, name}`, a stream's events and its refresh: every class for
      a stream over a turn, a thread, the threads, notes or what needs
      the person's attention (a name under `turn.`, `thread.`, `threads.`,
      `notes.` or `attention.`), whose events carry a person's own words,
      `outside` for any other;
    * `:storage`, a stored file: `files_by_grant` and `outside`, since a
      file carries no provenance of its own.

  Nothing is read for the answer: the operation table is the catalog's
  (`Sanctum.Catalog`), loaded at boot.
  """
  @spec read_classes(read()) :: [Prima.Source.class()]
  def read_classes(:invoke), do: Prima.Source.classes()
  def read_classes(:storage), do: [:files_by_grant, :outside]

  def read_classes({:action, operation}) when is_binary(operation) do
    case catalogued(operation) do
      %Prima.Operation{} = declared -> Prima.Operation.possible_classes(declared)
      nil -> Prima.Source.classes()
    end
  end

  def read_classes({:stream, name}) when is_binary(name) do
    [namespace | _rest] = String.split(name, ".")
    if namespace in @thread_streams, do: Prima.Source.classes(), else: [:outside]
  end

  @doc """
  The source classes any read the manifest declares may carry
  (`read_classes/1` over each): an invoke of each of its
  `dependencies.static`, each of its `actions` and each of its `streams`,
  in class order. A run a frame invokes starts holding these
  (`Opus.Tincture`), since what the frame passes it may carry anything the
  frame has read. A declaration that does not read is every class.
  """
  @spec frame_classes(term()) :: [Prima.Source.class()]
  def frame_classes(manifest) do
    case validate_declaration(manifest) do
      {:ok, %Tincture{} = declaration} ->
        reads =
          Enum.map(static_dependencies(manifest), fn _dependency -> :invoke end) ++
            Enum.map(declaration.actions, &{:action, &1}) ++
            Enum.map(declaration.streams, &{:stream, &1.name})

        classes = Enum.flat_map(reads, &read_classes/1)
        Enum.filter(Prima.Source.classes(), &(&1 in classes))

      {:error, _unreadable} ->
        Prima.Source.classes()
    end
  end

  defp catalogued(operation) do
    with [tool, action] <- String.split(operation, ".", parts: 2),
         {_provider, %{operations: operations}} <- Map.get(Sanctum.Catalog.operations(), tool) do
      Enum.find(operations, &(&1.action == action))
    else
      _uncatalogued -> nil
    end
  end

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

  A stream whose entry carries a `shape` is what a desktop reads
  (`check_desktop/2`), and a desktop alone declares one: a declaration
  without the desktop block naming such a stream is refused, whatever its
  subject. A desktop's streams are its `data` and `feeds`
  (`Prima.Manifest.Tincture`).
  """
  @spec check_streams(Tincture.t(), [Prima.Provider.Stream.t()]) :: :ok | {:error, refusal()}
  def check_streams(%Tincture{} = declaration, streams) when is_list(streams) do
    if Tincture.canvas?(declaration),
      do: check_desktop_streams(declaration.desktop, streams),
      else: check_app_streams(declaration.streams, streams)
  end

  defp check_app_streams(declared, streams) do
    Enum.reduce_while(declared, :ok, fn %Tincture.Stream{name: name, subject: subject}, :ok ->
      case Prima.Provider.fetch_stream(streams, name) do
        {:error, :undeclared_stream} ->
          {:halt, refuse("tincture.streams names #{name}, which no provider declares")}

        {:ok, %Prima.Provider.Stream{shape: shape}} when not is_nil(shape) ->
          {:halt,
           refuse(
             "tincture.streams names #{name}, which declares a shape: " <>
               "a stream that declares a shape is read by a desktop alone, in tincture.desktop.data"
           )}

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

  # A desktop's data are canvas-readable streams (a provider's that
  # declares a shape) that take no subject of the desktop's naming and
  # filter nothing; its feeds are read from the stream that filters by the
  # feed's name. The grammar holds each name once.
  defp check_desktop_streams(%Tincture.Desktop{data: data, feeds: feeds}, streams) do
    with :ok <- each(data, &data_stream(Prima.Provider.fetch_stream(streams, &1), &1)) do
      feed_stream(Prima.Provider.fetch_stream(streams, Tincture.feed_results()), feeds)
    end
  end

  defp data_stream({:error, :undeclared_stream}, name),
    do: refuse("tincture.desktop.data names #{name}, which no provider declares")

  defp data_stream({:ok, %Prima.Provider.Stream{shape: nil}}, name),
    do:
      refuse(
        "tincture.desktop.data names #{name}, which a desktop cannot read: " <>
          "the stream declares no shape"
      )

  defp data_stream({:ok, %Prima.Provider.Stream{filter: filter}}, name) when not is_nil(filter),
    do:
      refuse(
        "tincture.desktop.data names #{name}, which is read by name: " <>
          "a desktop names each feed in tincture.desktop.feeds"
      )

  defp data_stream({:ok, %Prima.Provider.Stream{} = stream}, name) do
    if subject_taken?(stream, nil),
      do: :ok,
      else:
        refuse("tincture.desktop.data names #{name}, whose subject a desktop would have to name")
  end

  defp feed_stream(_found, []), do: :ok

  defp feed_stream({:ok, %Prima.Provider.Stream{shape: shape, filter: filter} = stream}, feeds)
       when not is_nil(shape) and not is_nil(filter) do
    case Enum.find(feeds, &(not Prima.Provider.Stream.admits?(stream, &1))) do
      nil -> :ok
      feed -> refuse("tincture.desktop.feeds names #{feed}, which is no feed's name")
    end
  end

  defp feed_stream(_unread, _feeds),
    do:
      refuse(
        "tincture.desktop.feeds names feeds, and no provider declares #{Tincture.feed_results()} " <>
          "for a desktop to read them"
      )

  @doc """
  Whether a desktop's controls are ones it may offer today, read against
  the operation table (`Sanctum.Catalog.operations/0`) and `streams`, as
  `check_streams/2` takes them. Each control's operation is looked up by
  name: `#{@feed_press}`, `#{@execution_retry}`, or a `write` the person
  makes directly, is admitted; an operation the catalog does not hold, a person-only act (a
  tool only an agent asks for, `#{Enum.join(@persons_controls, "`, `")}`,
  or any operation that asks for the person's confirmation, a grant among
  them), an administrator's (`scope: :platform` or the `admin`
  permission), one reachable only inside a run, and every `read`, other
  `execute`, `destructive` and `external` operation are refused, each
  naming which. A control's `pick` names a stream the desktop reads (a
  name in `data`, or `#{"feed.results"}` with a feed in `feeds`), a
  `field` that resolves in that stream's shape to a string, a list of
  strings or an enum the shape declares (never a `json` value, beneath
  which it declares nothing), or for `#{"feed.results"}` any pointer
  beneath `/result/`, the feed's own value, admitted by its form: the
  choices are the strings the stream publishes there across its current
  state, which the shell reads again at each press
  (`Compendium.Desktop.control/4`). And an `arg` the operation takes. A
  declaration without the desktop block holds nothing here. Publish runs
  it beside `check_streams/2`.
  """
  @spec check_desktop(Tincture.t(), [Prima.Provider.Stream.t()]) :: :ok | {:error, refusal()}
  def check_desktop(%Tincture{desktop: %Tincture.Desktop{} = desktop}, streams)
      when is_list(streams) do
    each(desktop.controls, &control(&1, desktop, streams))
  end

  def check_desktop(%Tincture{}, streams) when is_list(streams), do: :ok

  defp control(%Tincture.Control{id: id, operation: operation, pick: pick}, desktop, streams) do
    where = "tincture.desktop.controls #{id}"

    with {:ok, declared} <- control_operation(catalogued(operation), operation, where) do
      pick(pick, declared, desktop, streams, where)
    end
  end

  defp control_operation(nil, operation, where),
    do: refuse("#{where} runs #{operation}, which no provider declares")

  defp control_operation(%Prima.Operation{} = declared, operation, where) do
    cond do
      operation in [@feed_press, @execution_retry] ->
        {:ok, declared}

      operation in @persons_controls or not is_nil(declared.consent) ->
        refuse(
          "#{where} runs #{operation}, which is the person's own act: a desktop cannot ask " <>
            "the person for it yet"
        )

      declared.scope == :platform or declared.permission == :admin ->
        refuse("#{where} runs #{operation}, which is an administrator's")

      :external not in declared.planes ->
        refuse("#{where} runs #{operation}, which runs only inside a run")

      declared.kind == :write ->
        {:ok, declared}

      true ->
        refuse(
          "#{where} runs #{operation}, which is #{kind_sentence(declared.kind)}: " <>
            "a control runs a write, #{@feed_press} or #{@execution_retry}"
        )
    end
  end

  defp kind_sentence(:read), do: "a read"
  defp kind_sentence(:execute), do: "an execute"
  defp kind_sentence(:destructive), do: "destructive"
  defp kind_sentence(:external), do: "external"

  defp pick(nil, _declared, _desktop, _streams, _where), do: :ok

  defp pick(%Tincture.Pick{} = pick, declared, desktop, streams, where) do
    where = "#{where}: the pick"

    with :ok <- picked_stream(pick, desktop, where),
         {:ok, %Prima.Provider.Stream{shape: shape}} <-
           Prima.Provider.fetch_stream(streams, pick.stream),
         {:ok, segments} <- Tincture.pointer_segments(pick.field) |> pointer(where),
         :ok <- picked_field(pick.stream, shape, segments, pick.field, where) do
      if Enum.any?(declared.args, &(&1.name == pick.arg)),
        do: :ok,
        else:
          refuse(
            "#{where} fills #{pick.arg}, which #{declared.tool}.#{declared.action} takes " <>
              "no argument named"
          )
    else
      {:error, :undeclared_stream} ->
        refuse("#{where} reads #{pick.stream}, which no provider declares")

      {:error, _} = refusal ->
        refusal
    end
  end

  defp picked_stream(%Tincture.Pick{stream: stream, subject: nil}, desktop, where) do
    if stream in desktop.data,
      do: :ok,
      else: picked_refuse(where, stream)
  end

  defp picked_stream(%Tincture.Pick{stream: stream, subject: subject}, desktop, where) do
    if stream == Tincture.feed_results() and subject in desktop.feeds,
      do: :ok,
      else: picked_refuse(where, stream)
  end

  defp picked_refuse(where, stream),
    do:
      refuse(
        "#{where} reads #{stream}, which the desktop does not: a pick reads a stream in " <>
          "tincture.desktop.data, or #{Tincture.feed_results()} with a feed in tincture.desktop.feeds"
      )

  defp pointer({:ok, segments}, _where), do: {:ok, segments}

  defp pointer(:error, where),
    do: refuse("#{where}'s field is no RFC 6901 pointer")

  # A feed's result is the feed's own, a json value whose shape the rules
  # never see, so a pick from `feed.results` is admitted by its pointer's
  # form under /result/ and the press checks the value against the feed's
  # current result. Every other stream's pointer resolves in its shape.
  defp picked_field(stream, shape, segments, field, where) do
    cond do
      stream != Tincture.feed_results() ->
        resolves(shape, segments, field, where)

      match?(["result", _ | _], segments) ->
        :ok

      true ->
        refuse(
          "#{where}'s field #{field} is outside /result/: a pick from " <>
            "#{Tincture.feed_results()} reads beneath the feed's result"
        )
    end
  end

  # A pointer walks an object's fields, and resolves only where it ends on
  # a string, a list of strings or an enum the shape declares. A `json` node declares
  # nothing beneath it, so a pointer that reaches one, or reaches past it,
  # resolves to nothing a pick can offer.
  defp resolves(%{"type" => "json"}, _segments, field, where),
    do:
      refuse(
        "#{where}'s field #{field} reaches a json value in the stream's shape, which " <>
          "declares no string, list of strings or enum: a pick takes one the shape declares"
      )

  defp resolves(%{"type" => "enum"}, [], _field, _where), do: :ok

  defp resolves(%{"type" => "string"}, [], _field, _where), do: :ok

  defp resolves(%{"type" => "list", "of" => %{"type" => "string"}}, [], _field, _where), do: :ok

  defp resolves(%{"type" => type}, [], field, where),
    do:
      refuse(
        "#{where}'s field #{field} is #{article(type)} #{type} in the stream's shape: " <>
          "a pick takes a string, a list of strings or an enum"
      )

  defp resolves(%{"type" => "object", "fields" => fields}, [segment | rest], field, where) do
    case Map.fetch(fields, segment) do
      {:ok, shape} -> resolves(shape, rest, field, where)
      :error -> refuse("#{where}'s field #{field} names no field of the stream's shape")
    end
  end

  defp resolves(_shape, _segments, field, where),
    do: refuse("#{where}'s field #{field} names no field of the stream's shape")

  defp article(type) when type in ~w(enum integer object), do: "an"
  defp article(_type), do: "a"

  @doc """
  Whether a desktop's chrome declaration holds: for a declaration whose
  desktop block names `chrome`, the file is among the version's files
  (`read`, from a relative path to `{:ok, bytes}` or `:error`), it reads
  as the chrome grammar (`Prima.Manifest.Chrome.parse/2`), and each file
  it names is in the version, at most its byte cap: a texture a PNG whose
  header says it is at most its pixel cap a side, or an SVG whose root
  element's `width` and `height` say so, and a font a WOFF2 (its
  signature `wOF2`). Whether a font may be shipped is its author's to
  know: no licence file is asked for. Answers the accepted tokens, nil
  for a desktop that names no chrome or a declaration that is no
  desktop. A refusal names the chrome file and its line, and nothing is
  applied.
  """
  @spec check_chrome(Tincture.t(), (String.t() -> {:ok, binary()} | :error)) ::
          {:ok, Prima.Manifest.Chrome.tokens() | nil} | {:error, refusal()}
  def check_chrome(%Tincture{desktop: %Tincture.Desktop{chrome: path}}, read)
      when is_binary(path) and is_function(read, 1) do
    where = "tincture.desktop.chrome #{path}"

    with {:ok, css} <- read_file(read, path, where),
         {:ok, tokens} <- parsed(Prima.Manifest.Chrome.parse(css, path), where),
         :ok <- textures(tokens, read, where),
         :ok <- fonts(tokens, read, where) do
      {:ok, tokens}
    end
  end

  def check_chrome(%Tincture{}, read) when is_function(read, 1), do: {:ok, nil}

  defp read_file(read, path, where) do
    case read.(path) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _absent -> refuse("#{where} is not among the version's files")
    end
  end

  defp parsed({:ok, tokens}, _where), do: {:ok, tokens}

  defp parsed({:error, {line, sentence}}, where),
    do: refuse("#{where} line #{line}: #{sentence}")

  defp textures(tokens, read, where) do
    %{bytes: cap} = Prima.Manifest.Chrome.file_caps()

    tokens
    |> Map.take(~w(texture-title texture-shelf))
    |> Enum.sort()
    |> each(fn {_key, path} ->
      with {:ok, bytes} <- read_file(read, path, "#{where}: #{path}"),
           :ok <- within(bytes, cap, "#{where}: #{path}") do
        dimensions(Path.extname(path), bytes, "#{where}: #{path}")
      end
    end)
  end

  defp fonts(%{"fonts" => fonts}, read, where) do
    %{bytes: cap} = Prima.Manifest.Chrome.file_caps()

    each(fonts, fn %{"src" => path} ->
      font = "#{where}: #{path}"

      with {:ok, bytes} <- read_file(read, path, font),
           :ok <- within(bytes, cap, font) do
        woff2(bytes, font)
      end
    end)
  end

  defp within(bytes, cap, _where) when byte_size(bytes) <= cap, do: :ok

  defp within(bytes, cap, where),
    do: refuse("#{where} is #{byte_size(bytes)} bytes, over the cap of #{cap}")

  defp woff2(<<"wOF2", _rest::binary>>, _where), do: :ok
  defp woff2(_bytes, where), do: refuse("#{where} is not a WOFF2 font")

  defp dimensions(
         ".png",
         <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32, height::32,
           _rest::binary>>,
         where
       ),
       do: within_pixels(width, height, where)

  defp dimensions(".png", _bytes, where), do: refuse("#{where} is not a PNG image")

  # An SVG's size is its root element's: past the prolog, which holds only
  # whitespace, an XML declaration, comments and processing instructions
  # (a document type is refused), the first element is `svg`, whose
  # `width` and `height` attributes are whole pixels.
  defp dimensions(".svg", bytes, where) do
    with {:ok, root} <- svg_root(bytes),
         [_, attributes] <- Regex.run(@svg_start_tag, root),
         pairs = Regex.scan(@svg_attribute, attributes, capture: :all_but_first),
         {:ok, width} <- svg_pixels(pairs, "width"),
         {:ok, height} <- svg_pixels(pairs, "height") do
      within_pixels(width, height, where)
    else
      _ ->
        refuse("#{where}: an SVG texture's root element says its width and height in pixels")
    end
  end

  defp svg_root(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: svg_root(rest)

  defp svg_root(bytes) do
    case String.trim_leading(bytes) do
      "<?" <> rest -> skip_past(rest, "?>")
      "<!--" <> rest -> skip_past(rest, "-->")
      "<svg" <> _ = root -> {:ok, root}
      _other -> :error
    end
  end

  defp skip_past(bytes, closing) do
    case :binary.split(bytes, closing) do
      [_skipped, rest] -> svg_root(rest)
      [_unclosed] -> :error
    end
  end

  # The value of the one attribute `name`, as whole pixels.
  defp svg_pixels(pairs, name) do
    # A double-quoted value is the second capture, a single-quoted one the
    # third.
    case for([^name | values] <- pairs, do: Enum.join(values)) do
      [value] ->
        case Regex.run(~r/\A([0-9]{1,5})(?:px)?\z/, value) do
          [_, digits] -> {:ok, String.to_integer(digits)}
          nil -> :error
        end

      _none_or_several ->
        :error
    end
  end

  defp within_pixels(width, height, where) do
    %{texture_pixels: cap} = Prima.Manifest.Chrome.file_caps()

    if width in 1..cap and height in 1..cap,
      do: :ok,
      else: refuse("#{where} is #{width} by #{height} pixels; a texture is at most #{cap} a side")
  end

  defp each(list, check) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  @doc """
  Whether a desktop version's files hold its page: for a manifest with
  the desktop block, its `tincture.entry` is among `paths`, the
  version's relative file paths, as publish holds every tincture's entry
  (`Compendium.TinctureValidator`), so a react canvas's `dist/index.html`
  is there once its build is and not before. Of a canvas's `.html` files
  only the entry is ever a page: its page route serves the entry
  (`Emissary.Web.CanvasController`), and the version's served files
  serve no page of a canvas (`Emissary.Web.TinctureAssets`). Any other
  manifest holds its files to nothing here. Publish runs it once the
  declaration and its streams are held.
  """
  @spec check_canvas_files(term(), [String.t()]) :: :ok | {:error, refusal()}
  def check_canvas_files(
        %{"tincture" => %{"desktop" => %{}} = tincture},
        paths
      )
      when is_list(paths) do
    case Map.get(tincture, "entry") do
      entry when is_binary(entry) ->
        if entry in paths,
          do: :ok,
          else: desktop_refuse("its page #{entry} is not among the version's files")

      _none ->
        desktop_refuse("a desktop names its page as tincture.entry")
    end
  end

  def check_canvas_files(_manifest, paths) when is_list(paths), do: :ok

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

  # A desktop is its version's own page, written on a canvas template. It
  # reaches nothing of its own, and hidden it reads and acts on nothing.
  defp canvas(%Tincture{desktop: %Tincture.Desktop{}} = declaration, manifest) do
    tincture = section(manifest, "tincture")
    dependencies = section(manifest, "dependencies")

    cond do
      not canvas_template?(Map.get(tincture, "entry"), Map.get(tincture, "build")) ->
        desktop_refuse(
          "a desktop declares " <>
            Enum.map_join(@canvas_templates, ", or ", &canvas_template_sentence/1)
        )

      present?(Map.get(tincture, "connect")) ->
        desktop_refuse("a desktop declares no tincture.connect origin")

      Map.has_key?(section(manifest, "caps"), "egress") ->
        desktop_refuse("a desktop declares no caps.egress")

      present?(Map.get(dependencies, "static")) or
          not is_nil(Map.get(dependencies, "dynamic")) ->
        desktop_refuse("a desktop declares no component dependency, static or dynamic")

      declaration.frame.capabilities != [] ->
        desktop_refuse("a desktop declares no frame capability")

      declaration.frame.background ->
        desktop_refuse("a desktop declares no background: hidden, it reads and acts on nothing")

      declaration.actions != [] ->
        desktop_refuse("a desktop declares no system action")

      not is_nil(declaration.frame.size) ->
        desktop_refuse("a desktop declares no size: it fills the screen")

      declaration.subjects != [] ->
        desktop_refuse("a desktop declares no tincture.subjects: it is never opened with one")

      true ->
        :ok
    end
  end

  defp canvas(%Tincture{}, _manifest), do: :ok

  defp canvas_template?(entry, build) do
    Enum.any?(@canvas_templates, fn
      %{entry: ^entry, build: nil} -> is_nil(build)
      %{entry: ^entry, build: tool} -> match?(%{"tool" => ^tool}, build)
      _another -> false
    end)
  end

  defp canvas_template_sentence(%{entry: entry, build: nil}),
    do: "tincture.entry #{entry} with no tincture.build"

  defp canvas_template_sentence(%{entry: entry, build: tool}),
    do: "tincture.entry #{entry} with tincture.build.tool #{tool}"

  defp section(manifest, key) when is_map(manifest) do
    case Map.get(manifest, key) do
      %{} = section -> section
      _absent -> %{}
    end
  end

  defp section(_manifest, _key), do: %{}

  defp desktop_refuse(sentence), do: refuse("tincture.desktop: " <> sentence)

  defp present?(value) when value in [nil, false, [], ""], do: false
  defp present?(_value), do: true

  # Binding, removing or pressing a feed is the person's alone: a bind or a
  # removal they approve, a press of a control Prism draws. The layout is
  # the person's arrangement of their screen, and Prism alone places frames
  # from it: a tincture that could write it could place, size or raise
  # itself or any other tincture, or take a canvas off the person's screen.
  # A schedule fires runs on its own under a profile's authority: a
  # tincture that could create or change one could schedule itself. A
  # tincture's frame reaches none of them, app or desktop.
  defp no_persons_action(actions) do
    case Enum.find(actions, &(&1 in @persons_actions)) do
      nil ->
        :ok

      "feed." <> _ = action ->
        refuse(
          "tincture.actions names #{action}: a tincture never binds, removes or presses a " <>
            "feed; the person does"
        )

      "layout." <> _ = action ->
        refuse("tincture.actions names #{action}: a tincture never writes the person's layout")

      "schedule." <> _ = action ->
        refuse("tincture.actions names #{action}: a tincture never creates or changes a schedule")

      action ->
        refuse("tincture.actions names #{action}: only an agent asks for it")
    end
  end

  defp refuse(sentence), do: {:error, {:invalid_tincture, sentence}}
end
