# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture.Rules do
  @moduledoc """
  The rules a tincture's frame is served and held by, in one module: the
  file types a version serves, the frame capabilities a manifest may
  declare and what each opens in the frame's `sandbox` and `allow`
  attributes, the entry page's Content Security Policy, the templates a
  tincture starts from, the lockfile a build tincture ships, and the
  grammar of its frame, cards, streams and system actions.

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
  @placements ~w(float desktop)

  # Every frame runs its scripts; nothing else is on unless granted.
  @sandbox_always ["allow-scripts"]
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

  # The map is checked here, once, so a change that would emit a forbidden
  # token fails the build rather than a review.
  case for(
         {_capability, tokens} <- @sandbox_by_capability,
         token <- tokens,
         token in @forbidden_sandbox_tokens,
         do: token
       ) ++ Enum.filter(@sandbox_always, &(&1 in @forbidden_sandbox_tokens)) do
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

  @doc "The placements a frame may declare: floating over the shell, or a desktop of its own."
  @spec placements() :: [String.t()]
  def placements, do: @placements

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
  The manifest's frame, cards, streams and system actions, held to their
  shapes (`Prima.Manifest.Tincture`) and to these rules: every capability
  is one of `frame_capabilities/0`, a placement is one of `placements/0`,
  card names are distinct, a card's image is a served image, each button
  names an action the declaration lists, a card's stream is one it
  declares, a card's source names a component the tincture may invoke
  (`invokes?/2`), and a card that shows a number or a list has a source
  (one without is static). A desktop (placement `desktop`) reaches
  nothing of its own: it declares no `tincture.connect` origin, no
  `caps.egress` and no component dependency, static or dynamic; the cards
  it draws are other tinctures'. A manifest that declares none of the
  blocks answers the empty declaration. Which streams exist is
  `check_streams/2`'s.
  """
  @spec validate_declaration(term()) :: {:ok, Tincture.t()} | {:error, refusal()}
  def validate_declaration(manifest) do
    with {:ok, %Tincture{} = declaration} <- Tincture.from_manifest(manifest),
         :ok <- known(declaration.frame.capabilities),
         :ok <- placement(declaration.frame.placement),
         :ok <- desktop(declaration.frame.placement, manifest),
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
