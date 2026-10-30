# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Frames do
  @moduledoc """
  The shell's frames: every tincture frame one shell view creates,
  places, freezes, discards and attributes a message to, and which of the
  person's canvases the glass shows. A plain value held in the view's
  assigns; it starts no process.

  ## Keys

  Each frame is held under one key, one frame per key:

    * `{:canvas, id}` — the frame of the layout's canvas `id`, live, at the
      version the shell opened (`open_canvas/4`);
    * `{:validation, id}` — the hidden, inert frame a candidate version of
      canvas `id` is trialled in (`open_validation/5`);
    * `{:app, canvas_id, ref}` — the tincture `ref` (versionless) opened over
      canvas `canvas_id` where the layout places it (`open_app/5`,
      `arrange/5`);
    * `{:full, tincture_id}` — a tincture launched from the picker
      (`launch/3`).

  A tincture belongs to the canvas it was opened on. Only this module's own
  open path makes a frame under a canvas or a validation key: `put/2`
  refuses one, so a canvas frame created by anything but `Prism.Frames` is
  impossible.

  ## Opening

  An open reads the version's declaration through `Compendium`, and mints
  the frame's credential bound to the person, the tincture version and its
  release digest, the grant revision of the tincture's owner profile held
  to that version (`Compendium.tincture_grant_revision/2`) and a fresh
  frame id. No URL carries the frame credential.

  A frame's sandbox isolates the tincture's code, not what it is handed:
  whatever a frame is given, its bearer included, is disclosed to the
  tincture, so what a frame may be given is bounded where it is handed
  out — by its grant, its declaration and its credential — never by the
  sandbox.

    * A canvas or validation frame opens only a version whose placement is
      `canvas`, and an app or a launched frame never opens one. Anything
      else is refused `:undeclared`.
    * One builder makes every canvas-placement frame, live or validation,
      so its address, its sandbox and its handshake have one definition.
      Its `src` is the canvas's page (`Prima.TinctureWire.page_path/2`)
      under an asset credential for the version, its `sandbox` the
      canvas's (`Compendium.tincture_canvas_sandbox_tokens/0`) and it has
      no `allow`. It holds its handshake's `canvas` block: the mode, its
      data path and the streams the served version's stored declaration
      names, never anything a frame or a page sends.
    * Any other frame takes its `sandbox` and `allow` from the rules for
      the capabilities it declares (`frame_attributes/2`), and a private
      tincture's page is served under an asset credential
      (`Prima.TinctureUrl`'s `/_s/` path), a public one's at its `/t/`
      address.

  A step that refuses leaves a frame in state `:refused` that renders its
  refusal and holds no credential. A tincture whose one owner profile waits
  for the person to consent again, that holds no grant, or whose version
  reads more than its grant's shape is refused as `:ungranted`. A frame
  remembers the actions its version declares (`actions`), which is what the
  shell reads before it honours a verb that needs one.

  ## Placements

  An app stands over its canvas as the layout places it (`Prima.Layout`):
  a `{:window, geometry}`, a `{:tile, side, share}` or `:full`, at its
  `stack` (the layout's `order`: the stacking order of windows, the
  left-to-right order of tiles), and `minimised` or not. In the hand
  posture every app stands `:full`, whatever the layout stores for it, in
  stacking order. Moving, resizing, raising, minimising and restoring an
  app (`place/3`, `resize/3`, `raise/2`, `minimise/2`, `restore/2`) and an
  arrangement that places a held app anew keep its frame: its id, its
  credential and its page stay. Only closing an app, or a layout that no
  longer places it, discards its frame.

  ## The canvases and visibility

  The visible canvas is the value's (`visible_canvas/1`): the layout's first
  canvas at the first arrangement, kept across postures and switches, and
  the first again when the layout drops it (`arrange/5`). The active frame
  is a launch, or else the visible canvas's topmost `full` app that is not
  minimised (`active/1`): it alone is visible. Otherwise the visible
  canvas's frame and its windows and tiles that are not minimised are.
  Every other canvas and its apps are hidden, a minimised app is hidden,
  and a validation frame is never visible.

  A hidden frame without a declared `background` grant is frozen: its
  credential is suspended through Sanctum before the view signals it to
  stop, and a suspension that cannot be recorded discards the frame. A
  hidden canvas is frozen whatever its declaration says. A shown frame's
  credential is resumed before it is signalled live, and the resume
  rotates its bearer (`Sanctum.TinctureAuth.resume_frame/3`); a resume
  that fails revokes the credential and leaves the frame showing its
  refusal. A canvas's resume keeps its row's deadline and signs nothing,
  so a canvas whose deadline passed while it was hidden is refused at its
  resume. A validation frame is never frozen or thawed: its credential is
  never suspended.

  ## Renewal

  A frame remembers its credential's `deadline`. While it is live, a
  frame that is not a validation's, a shown canvas's included, is renewed
  before that deadline (`renew/4`, `Sanctum.TinctureAuth.renew_frame/2`):
  its bearer is rotated and its deadline moves. A new bearer from a
  renewal or a resume replaces the frame's own while its handshake has
  not happened, and is otherwise queued for the view to hand the frame
  over its port (`take_replacements/1`), never kept, as the handshake's
  credential message.

  ## Attribution and the handshake

  A message is attributed to the live frame whose id it names and that
  this value holds; a frozen or refused frame acts on nothing, and any
  other message is dropped and counted (`drop_message/1`). A frame's
  bearer is handed over once (`handshake/2`): a canvas or validation
  frame's beside its `canvas` block (`Prima.TinctureWire.canvas_handshake/4`),
  any other frame's alone. A bearer that replaces it later reaches the
  frame only as a replacement.

  ## Ending

  Every credential minted is remembered until it is revoked, and
  `revoke_all/2` revokes each one; the view calls it on every path that
  ends it. `clear/2` revokes them all and holds no frame, which is how
  safe mode starts.

  The pure transitions — placement, visibility, attribution, the
  handshake and the signals the view sends — take no context and touch
  no store. The functions that take a context first are the effects:
  each reaches a credential only through `Sanctum.TinctureAuth`.
  """

  # `raise/2` raises an app over its canvas; the exception is `Kernel.raise/2`.
  import Kernel, except: [raise: 2]

  require Logger

  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  @typedoc "Where an app stands over its canvas."
  @type app_placement ::
          :full
          | {:window, Prima.Layout.geometry()}
          | {:tile, Prima.Layout.side(), pos_integer()}

  @typedoc "Where a frame sits."
  @type placement :: :canvas | :validation | app_placement()

  @typedoc "A versionless tincture reference, as the layout names one."
  @type ref :: String.t()

  @typedoc "The key a frame is held under: one frame per key."
  @type key ::
          {:canvas, String.t()}
          | {:validation, String.t()}
          | {:app, String.t(), ref()}
          | {:full, String.t()}

  @typedoc "A frame's state."
  @type state :: :live | :frozen | :refused

  @typedoc "Why a frame renders a refusal instead of a page."
  @type refusal :: :unavailable | :undeclared | :unregistered | :ungranted | :refused

  @typedoc """
  A tincture as the shell lists it: its card id, publisher, name,
  version, manifest, entry, athanor segment and whether it is public.
  """
  @type card :: %{
          required(:id) => String.t(),
          required(:publisher) => String.t(),
          required(:name) => String.t(),
          required(:version) => String.t(),
          required(:manifest) => map() | nil,
          required(:entry) => String.t() | nil,
          required(:athanor_segment) => String.t() | nil,
          required(:public) => boolean() | :unknown,
          optional(atom()) => term()
        }

  @typedoc """
  A canvas-placement frame's handshake block: its `mode`, `data_path`
  and `streams` (`Prima.TinctureWire.canvas_handshake/4`).
  """
  @type canvas :: %{String.t() => term()}

  @typedoc "One frame."
  @type frame :: %{
          key: key(),
          id: String.t(),
          tincture_id: String.t(),
          reference: %{publisher: String.t(), name: String.t(), version: String.t()},
          src: String.t() | nil,
          sandbox: String.t() | nil,
          allow: String.t() | nil,
          state: state(),
          refusal: refusal() | nil,
          credential_id: String.t() | nil,
          bearer: String.t() | nil,
          deadline: DateTime.t() | nil,
          placement: placement(),
          stack: non_neg_integer(),
          minimised: boolean(),
          visible: boolean(),
          background: boolean(),
          actions: [String.t()],
          canvas: canvas() | nil
        }

  @typedoc "What the view signals a frame: its id and `frozen` or `live`."
  @type signal :: %{frame: String.t(), state: String.t()}

  @typedoc """
  What a frame's bridge is handed at its handshake: its credential, and a
  canvas-placement frame's `canvas` block beside it.
  """
  @type handshake :: %{required(:credential) => String.t()} | %{String.t() => term()}

  @typedoc "A bearer that replaces one frame's own, for the view to hand that frame."
  @type replacement :: %{frame: String.t(), credential: String.t()}

  @typedoc """
  What a renewal did: `:renewed`, the frame's bearer rotated; `:retry`, the
  store or the member could not answer; `:expired`, the credential ran out
  and is left to expire; `:refused`, the frame revoked and showing its
  refusal; `:stale`, nothing, for a frame not held live at that deadline.
  """
  @type renewal :: :renewed | :retry | :expired | :refused | :stale

  @typedoc """
  A mint of a frame credential: `Sanctum.TinctureAuth.mint_frame_credential/5`
  or `mint_validation_credential/5`, which take the same arguments.
  """
  @type mint :: (Context.t(), map(), String.t(), non_neg_integer(), String.t() ->
                   {:ok, %{credential: String.t(), id: String.t(), deadline: DateTime.t()}}
                   | {:error, term()})

  @type t :: %__MODULE__{
          frames: %{key() => frame()},
          order: [key()],
          active: key() | nil,
          minted: [String.t()],
          dropped: non_neg_integer(),
          canvas: String.t() | nil,
          posture: Prima.Layout.posture_name(),
          replacements: [replacement()]
        }

  defstruct frames: %{},
            order: [],
            active: nil,
            minted: [],
            dropped: 0,
            canvas: nil,
            posture: "desk",
            replacements: []

  # ============================================================================
  # Pure: reading
  # ============================================================================

  @doc "No frames, and no canvas shown."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Every frame held, in the order it was opened."
  @spec list(t()) :: [frame()]
  def list(%__MODULE__{frames: frames, order: order}),
    do: Enum.map(order, &Map.fetch!(frames, &1))

  @doc "The frame held under `key`, or nil."
  @spec get(t(), key()) :: frame() | nil
  def get(%__MODULE__{frames: frames}, key), do: Map.get(frames, key)

  @doc "The id of the canvas the glass shows, or nil when the layout has none."
  @spec visible_canvas(t()) :: String.t() | nil
  def visible_canvas(%__MODULE__{canvas: canvas}), do: canvas

  @doc """
  The active `full` frame, shown above everything: a launch, or else the
  visible canvas's topmost `full` app that is not minimised. An app of
  another canvas is never active.
  """
  @spec active(t()) :: frame() | nil
  def active(%__MODULE__{} = t) do
    case t.active && get(t, t.active) do
      %{} = launch ->
        launch

      _none ->
        t
        |> list()
        |> Enum.filter(&full_app?(t, &1))
        |> Enum.max_by(& &1.stack, fn -> nil end)
    end
  end

  defp full_app?(t, %{key: {:app, id, _}, placement: :full, minimised: false}),
    do: id == t.canvas

  defp full_app?(_t, _frame), do: false

  @doc "The posture the value arranges for, `desk` or `hand`."
  @spec posture(t()) :: Prima.Layout.posture_name()
  def posture(%__MODULE__{posture: posture}), do: posture

  @doc "The card id of the active `full` frame's tincture, or nil."
  @spec active_tincture(t()) :: String.t() | nil
  def active_tincture(t) do
    case active(t) do
      %{tincture_id: tincture_id} -> tincture_id
      nil -> nil
    end
  end

  @doc "How many frame messages were dropped."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc """
  The bearers queued for frames already handed theirs, in the order they
  were rotated, and the value without them: the view hands each to its
  frame and keeps none.
  """
  @spec take_replacements(t()) :: {[replacement()], t()}
  def take_replacements(%__MODULE__{replacements: replacements} = t),
    do: {replacements, %{t | replacements: []}}

  @doc """
  Whether the frame is one the view renews: live, holding a deadline, and
  not a validation's, whose credential is never renewed. A shown canvas is
  renewed as any frame is; a hidden one is frozen, so it is not.
  """
  @spec renewable?(frame()) :: boolean()
  def renewable?(%{state: :live, key: {:validation, _id}}), do: false
  def renewable?(%{state: :live, deadline: %DateTime{}}), do: true
  def renewable?(_frame), do: false

  @doc "Whether `key` is a canvas-placement frame's: a canvas's or a validation's."
  @spec canvas_key?(term()) :: boolean()
  def canvas_key?({:canvas, id}) when is_binary(id), do: true
  def canvas_key?({:validation, id}) when is_binary(id), do: true
  def canvas_key?(_key), do: false

  @doc "The canvas a key belongs to, or nil for a launch."
  @spec canvas_of(key()) :: String.t() | nil
  def canvas_of({kind, id}) when kind in [:canvas, :validation], do: id
  def canvas_of({:app, id, _ref}), do: id
  def canvas_of({:full, _tincture_id}), do: nil

  @doc "Whether the live frame `frame` declares the action `operation` (`tool.action`)."
  @spec declares?(frame(), String.t()) :: boolean()
  def declares?(%{actions: actions}, operation) when is_binary(operation),
    do: operation in actions

  def declares?(_frame, _operation), do: false

  @doc "The versionless reference of a listed card: `tincture:<publisher>.<name>`."
  @spec ref_of(card()) :: ref()
  def ref_of(%{publisher: publisher, name: name}),
    do: Prima.ComponentRef.build("tincture", publisher, name)

  @doc """
  The reference pinned to the version a card, or a frame's `reference`,
  names: what its frame opens and what the grant it waits for is planned
  for.
  """
  @spec version_ref(%{
          required(:publisher) => String.t(),
          required(:name) => String.t(),
          required(:version) => String.t(),
          optional(atom()) => term()
        }) :: String.t()
  def version_ref(%{publisher: publisher, name: name, version: version}),
    do: Prima.ComponentRef.build("tincture", publisher, name, version)

  # ============================================================================
  # Pure: the declaration and the layout
  # ============================================================================

  @doc """
  The frame's `sandbox` and `allow` attributes for the capabilities it
  asks for, derived by `Compendium`'s rules: `sandbox` always carries
  `allow-scripts` and never `allow-same-origin`, and each other token or
  permission is present only for a capability asked for. A capability the
  declaration does not list is refused as `{:undeclared_capability,
  names}`; one no frame has, with the rules' own refusal.
  """
  @spec frame_attributes(Prima.Manifest.Tincture.t(), [String.t()]) ::
          {:ok, %{sandbox: String.t(), allow: String.t(), capabilities: [String.t()]}}
          | {:error, {:undeclared_capability, [String.t()]} | {:invalid_tincture, String.t()}}
  def frame_attributes(%Prima.Manifest.Tincture{frame: frame}, requested)
      when is_list(requested) do
    with [] <- Enum.reject(requested, &(&1 in frame.capabilities)),
         {:ok, tokens} <- Compendium.tincture_sandbox_tokens(requested),
         {:ok, allow} <- Compendium.tincture_allow_attribute(requested) do
      {:ok, %{sandbox: Enum.join(tokens, " "), allow: allow, capabilities: Enum.sort(requested)}}
    else
      [_ | _] = undeclared -> {:error, {:undeclared_capability, Enum.uniq(undeclared)}}
      {:error, _refusal} = refused -> refused
    end
  end

  @doc """
  Whether the card is a canvas: its frame declares the placement
  `canvas`. A declaration that does not hold to the rules is no canvas.
  """
  @spec canvas?(card()) :: boolean()
  def canvas?(card), do: placement_of(card) == "canvas"

  defp placement_of(%{manifest: manifest}) do
    case Compendium.tincture_declaration(manifest) do
      {:ok, %{frame: %{placement: placement}}} -> placement
      {:error, _refused} -> nil
    end
  end

  defp placement_of(_card), do: nil

  @doc """
  The listed card a versionless layout reference names, or nil when no
  tincture it names is installed.
  """
  @spec resolve(ref(), [card()]) :: card() | nil
  def resolve(ref, cards) when is_binary(ref) and is_list(cards) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %Prima.ComponentRef{type: "tincture", namespace: publisher, name: name}} ->
        Enum.find(cards, &(&1.publisher == publisher and &1.name == name))

      _ ->
        nil
    end
  end

  def resolve(_ref, _cards), do: nil

  @doc """
  The frames the layout places over the canvas `arranged` (one canvas of
  `Compendium.layout/2`'s arrangement) in `posture`, each with its key,
  its placement, its stack, whether it is minimised and the card it
  opens: every app whose tincture is installed, in the layout's order. In
  the hand every app is `:full`.
  """
  @spec placements(Prima.Layout.arranged(), [card()], Prima.Layout.posture_name()) :: [
          {key(), app_placement(), non_neg_integer(), boolean(), card()}
        ]
  def placements(%{id: canvas_id, apps: apps}, cards, posture) do
    for %{tincture: ref, order: order, minimised: minimised} = app <- apps,
        card = resolve(ref, cards),
        do: {{:app, canvas_id, ref}, app_placement(app, posture), order, minimised, card}
  end

  @doc """
  The placement a layout app stands in for `posture`: in the hand, `:full`
  whatever the layout stores; on the desk, its window, its tile or full.
  """
  @spec app_placement(Prima.Layout.app(), Prima.Layout.posture_name()) :: app_placement()
  def app_placement(_app, "hand"), do: :full
  def app_placement(%{placement: :window, geometry: geometry}, _desk), do: {:window, geometry}

  def app_placement(%{placement: :tile, side: side, share: share}, _desk),
    do: {:tile, side, share}

  def app_placement(%{placement: :full}, _desk), do: :full

  # ============================================================================
  # Pure: attribution and the handshake
  # ============================================================================

  @doc """
  The live frame `frame_id` names, when this value holds it. A frozen or
  refused frame, and an id this value never held, attribute nothing.
  """
  @spec attribute(t(), term()) :: {:ok, frame()} | :error
  def attribute(%__MODULE__{} = t, frame_id) when is_binary(frame_id) do
    case find(t, frame_id) do
      %{state: :live} = frame -> {:ok, frame}
      _frozen_refused_or_unknown -> :error
    end
  end

  def attribute(%__MODULE__{}, _frame_id), do: :error

  @doc """
  The bearer of frame `frame_id`, handed over once: the answer holds the
  frame without it, so a second ask gets `:error`, as does an id this
  value never held.
  """
  @spec hand_over(t(), term()) :: {:ok, String.t(), t()} | :error
  def hand_over(%__MODULE__{} = t, frame_id) when is_binary(frame_id) do
    case find(t, frame_id) do
      %{bearer: bearer, key: key} = frame when is_binary(bearer) ->
        {:ok, bearer, put_frame(t, key, %{frame | bearer: nil})}

      _spent_or_unknown ->
        :error
    end
  end

  def hand_over(%__MODULE__{}, _frame_id), do: :error

  @doc """
  What frame `frame_id`'s bridge is handed, once (`hand_over/2`): a
  canvas or validation frame's bearer and its `canvas` block, the canvas
  handshake (`Prima.TinctureWire.canvas_handshake/4`), and any other
  frame's bearer alone. Only a frame held under a canvas or validation key
  is answered a `canvas` block.
  """
  @spec handshake(t(), term()) :: {:ok, handshake(), frame(), t()} | :error
  def handshake(%__MODULE__{} = t, frame_id) do
    case hand_over(t, frame_id) do
      {:ok, bearer, t} ->
        %{key: key, id: id, canvas: canvas} = frame = find(t, frame_id)

        if canvas_key?(key) and is_map(canvas),
          do:
            {:ok,
             Prima.TinctureWire.canvas_handshake(id, bearer, canvas["mode"], canvas["streams"]),
             frame, t},
          else: {:ok, %{credential: bearer}, frame, t}

      :error ->
        :error
    end
  end

  @doc "Count one dropped frame message."
  @spec drop_message(t()) :: t()
  def drop_message(%__MODULE__{dropped: dropped} = t), do: %{t | dropped: dropped + 1}

  # ============================================================================
  # Pure: placement and visibility
  # ============================================================================

  @doc """
  Hold `frame`, after every frame already held; a frame under a key
  already held replaces it in place. A frame under a canvas or validation
  key raises: only this module's own open path makes one.
  """
  @spec put(t(), frame()) :: t()
  def put(%__MODULE__{}, %{key: {kind, _id}}) when kind in [:canvas, :validation],
    do:
      Kernel.raise(
        ArgumentError,
        "a canvas or validation frame is made only by Prism.Frames' open path"
      )

  def put(%__MODULE__{} = t, %{key: _key} = frame), do: hold(t, frame)

  @doc """
  Forget the frame under `key`. When it was the active launch, the latest
  launch still held becomes active.
  """
  @spec forget(t(), key()) :: t()
  def forget(%__MODULE__{} = t, key) do
    t = %{t | frames: Map.delete(t.frames, key), order: List.delete(t.order, key)}

    if t.active == key,
      do: %{t | active: t.order |> Enum.filter(&match?({:full, _}, &1)) |> List.last()},
      else: t
  end

  @doc """
  Make the launch under `key` the active frame. Any other key changes
  nothing: an app is active by its placement and stack (`active/1`).
  """
  @spec activate(t(), key()) :: t()
  def activate(%__MODULE__{} = t, {:full, _} = key) do
    if get(t, key), do: %{t | active: key}, else: t
  end

  def activate(%__MODULE__{} = t, _key), do: t

  @doc """
  Stand the app under `key` at `placement`, a window, a tile or full,
  keeping its frame. Any other key, or a frame not held, changes nothing.
  """
  @spec place(t(), key(), app_placement()) :: t()
  def place(%__MODULE__{} = t, {:app, _, _} = key, placement) do
    if app_placement?(placement),
      do: transition(t, key, &%{&1 | placement: placement}),
      else: t
  end

  def place(%__MODULE__{} = t, _key, _placement), do: t

  @doc """
  Resize the app under `key`, keeping its frame: a window to `geometry`,
  a tile to a `share` of the width. A size of the other kind, or an app
  that is full, changes nothing.
  """
  @spec resize(t(), key(), Prima.Layout.geometry() | pos_integer()) :: t()
  def resize(%__MODULE__{} = t, {:app, _, _} = key, size) do
    transition(t, key, fn
      %{placement: {:window, _}} = frame when is_map(size) ->
        %{frame | placement: {:window, size}}

      %{placement: {:tile, side, _}} = frame when is_integer(size) ->
        %{frame | placement: {:tile, side, size}}

      frame ->
        frame
    end)
  end

  def resize(%__MODULE__{} = t, _key, _size), do: t

  @doc """
  Raise the app under `key` above every other app of its canvas, keeping
  its frame. Raising the topmost app changes nothing.
  """
  @spec raise(t(), key()) :: t()
  def raise(%__MODULE__{} = t, {:app, canvas_id, _} = key) do
    others =
      for %{key: {:app, ^canvas_id, _} = other, stack: stack} <- list(t), other != key, do: stack

    transition(t, key, fn frame ->
      case others do
        [] ->
          frame

        _ ->
          if frame.stack > Enum.max(others),
            do: frame,
            else: %{frame | stack: Enum.max(others) + 1}
      end
    end)
  end

  def raise(%__MODULE__{} = t, _key), do: t

  @doc "Minimise the app under `key`, keeping its frame and its placement."
  @spec minimise(t(), key()) :: t()
  def minimise(t, {:app, _, _} = key), do: transition(t, key, &%{&1 | minimised: true})
  def minimise(t, _key), do: t

  @doc "Show the minimised app under `key` again where it stood, raised."
  @spec restore(t(), key()) :: t()
  def restore(t, {:app, _, _} = key),
    do: t |> transition(key, &%{&1 | minimised: false}) |> raise(key)

  def restore(t, _key), do: t

  defp app_placement?(:full), do: true
  defp app_placement?({:window, %{x: _, y: _, w: _, h: _}}), do: true

  defp app_placement?({:tile, side, share}) when side in [:left, :right] and is_integer(share),
    do: true

  defp app_placement?(_placement), do: false

  @doc """
  Each frame's visibility: with a frame active (`active/1`), it alone is
  visible; with none, the visible canvas's frame and its windows and tiles
  that are not minimised are. A validation frame is never visible.
  """
  @spec visibility(t()) :: t()
  def visibility(%__MODULE__{} = t) do
    active = active(t)

    frames =
      Map.new(t.frames, fn {key, frame} ->
        {key, %{frame | visible: visible?(frame, active, t.canvas)}}
      end)

    %{t | frames: frames}
  end

  defp visible?(%{key: {:validation, _}}, _active, _canvas), do: false
  defp visible?(%{key: key}, %{key: active}, _canvas), do: key == active
  defp visible?(%{key: {:canvas, id}}, nil, canvas), do: id == canvas
  defp visible?(%{key: {:app, _, _}, minimised: true}, nil, _canvas), do: false
  defp visible?(%{key: {:app, id, _}, placement: {:window, _}}, nil, canvas), do: id == canvas

  defp visible?(%{key: {:app, id, _}, placement: {:tile, _, _}}, nil, canvas), do: id == canvas
  defp visible?(_full, nil, _canvas), do: false

  @doc """
  The credential transitions visibility asks for, in frame order: a
  hidden live frame without a background grant is to freeze — a canvas
  whatever it declares — and a visible frozen frame to thaw. A validation
  frame is left as it is.
  """
  @spec plan(t()) :: [{:freeze | :thaw, key()}]
  def plan(%__MODULE__{} = t) do
    t
    |> list()
    |> Enum.flat_map(fn
      %{key: {:validation, _}} ->
        []

      %{state: :live, visible: false, key: key} = frame ->
        if runs_hidden?(frame), do: [], else: [{:freeze, key}]

      %{state: :frozen, visible: true, key: key} ->
        [{:thaw, key}]

      _steady ->
        []
    end)
  end

  # A canvas's background is read as false, whatever its declaration says.
  defp runs_hidden?(%{key: {:canvas, _}}), do: false
  defp runs_hidden?(%{background: background}), do: background == true

  @doc "The frame under `key`, frozen."
  @spec freeze(t(), key()) :: t()
  def freeze(t, key), do: transition(t, key, &%{&1 | state: :frozen})

  @doc "The frame under `key`, live."
  @spec thaw(t(), key()) :: t()
  def thaw(t, key), do: transition(t, key, &%{&1 | state: :live})

  @doc "The frame under `key`, refused as `refusal`: it holds no bearer and renders the refusal."
  @spec refuse(t(), key(), refusal()) :: t()
  def refuse(t, key, refusal),
    do: transition(t, key, &%{&1 | state: :refused, refusal: refusal, bearer: nil})

  @doc """
  What the view signals the frames both values hold whose state moved
  between live and frozen: `%{frame: id, state: "frozen" | "live"}`.
  """
  @spec signals(t(), t()) :: [signal()]
  def signals(%__MODULE__{} = before, %__MODULE__{} = later) do
    for %{key: key, id: id, state: state} <- list(later),
        state in [:live, :frozen],
        %{id: ^id, state: previous} <- [get(before, key)],
        previous != state,
        previous in [:live, :frozen],
        do: %{frame: id, state: Atom.to_string(state)}
  end

  @doc "The refusal class an open, a resume, a mint or a refused call is shown as."
  @spec refusal(term()) :: refusal()
  def refusal(reason) when reason in [:unavailable, :not_owner, :identity_stale],
    do: :unavailable

  def refusal({:unavailable, _what}), do: :unavailable
  def refusal({:undeclared_capability, _names}), do: :undeclared
  def refusal({:invalid_tincture, _sentence}), do: :undeclared
  def refusal({:placement, _wanted}), do: :undeclared
  def refusal(:unregistered), do: :unregistered
  def refusal(:ungranted), do: :ungranted
  def refusal(_standing), do: :refused

  # ============================================================================
  # Effects: opening
  # ============================================================================

  @doc """
  Show `card` as the active `full` launch, opening it first when none is
  held, and settle visibility.
  """
  @spec launch(Context.t(), t(), card()) :: t()
  def launch(%Context{} = ctx, %__MODULE__{} = t, card) do
    key = {:full, card.id}
    t = open(t, ctx, key, card, :full, 0, false)
    settle(ctx, activate(t, key))
  end

  @doc """
  Open `card` over canvas `canvas_id` as an app at `placement`, `stack`
  and `minimised` (`:full` in the hand), unless one is held under its key;
  a held one is stood there, keeping its frame. Visibility is settled.
  """
  @spec open_app(Context.t(), t(), String.t(), card(), Prima.Layout.app()) :: t()
  def open_app(%Context{} = ctx, %__MODULE__{} = t, canvas_id, card, app) do
    key = {:app, canvas_id, ref_of(card)}
    placement = app_placement(app, t.posture)

    t
    |> open(ctx, key, card, placement, app.order, app.minimised)
    |> stand(key, placement, app.order, app.minimised)
    |> then(&settle(ctx, &1))
  end

  @doc """
  Open the live frame of canvas `canvas_id` for `card`, the version the
  shell chose, unless one is held under its key, and settle visibility.
  """
  @spec open_canvas(Context.t(), t(), String.t(), card()) :: t()
  def open_canvas(%Context{} = ctx, %__MODULE__{} = t, canvas_id, card) do
    key = {:canvas, canvas_id}

    if Map.has_key?(t.frames, key) do
      t
    else
      frame = canvas_frame(ctx, key, card, "live", &TinctureAuth.mint_frame_credential/5)
      settle(ctx, t |> hold(frame) |> remember_mint(frame))
    end
  end

  @doc """
  Open the hidden, inert validation frame of canvas `canvas_id` for
  `card`, the candidate version, under the credential `mint` makes,
  unless one is held under its key. It is never visible, and visibility
  never freezes or thaws it.
  """
  @spec open_validation(Context.t(), t(), String.t(), card(), mint()) :: t()
  def open_validation(%Context{} = ctx, %__MODULE__{} = t, canvas_id, card, mint)
      when is_function(mint, 5) do
    key = {:validation, canvas_id}

    if Map.has_key?(t.frames, key) do
      t
    else
      frame = canvas_frame(ctx, key, card, "validation", mint)
      t |> hold(frame) |> remember_mint(frame) |> visibility()
    end
  end

  @doc """
  Hold canvas `canvas_id`'s frame for `card` refused as `refusal`: it
  holds no credential and renders the refusal. A frame held under its key
  is left as it is.
  """
  @spec refuse_canvas(t(), String.t(), card(), refusal()) :: t()
  def refuse_canvas(%__MODULE__{} = t, canvas_id, card, refusal) do
    key = {:canvas, canvas_id}

    if Map.has_key?(t.frames, key) do
      t
    else
      frame = %{base_frame(key, new_frame_id(), card, :canvas) | refusal: refusal}
      t |> hold(frame) |> visibility()
    end
  end

  # ============================================================================
  # Effects: the screen
  # ============================================================================

  @doc """
  Discard the frame under `key`: its credential is revoked and the frame
  forgotten, then visibility is settled (the next `full` frame, if any,
  is shown).
  """
  @spec discard(Context.t(), t(), key()) :: t()
  def discard(%Context{} = ctx, %__MODULE__{} = t, key) do
    settle(ctx, drop(ctx, t, key))
  end

  @doc """
  Every credential this value minted revoked, and no frame held: the
  answer keeps the visible canvas and the count of dropped messages, and
  remembers only the credentials whose revocation could not be recorded.
  """
  @spec clear(Context.t(), t()) :: t()
  def clear(%Context{} = ctx, %__MODULE__{} = t) do
    %{minted: unrevoked} = revoke_all(ctx, t)
    %{new() | minted: unrevoked, dropped: t.dropped, canvas: t.canvas}
  end

  @doc """
  Hold the frames `arrangement` (`Compendium.layout/2`'s, one posture's
  canvases in order) asks of the visible canvas, for the listed `cards`:

    * every frame of a canvas the arrangement no longer has is discarded,
      its validation frame included, so nothing is activated for it;
    * the visible canvas stays visible while the arrangement has it, and is
      the arrangement's first otherwise, or none for an empty layout;
    * of the visible canvas's apps (`placements/3`), one the layout no
      longer places, or places for another tincture, is discarded; one it
      places is stood at its placement, stack and minimised as the layout
      says, keeping its frame; one it places anew is opened, unless it is
      minimised, which opens only when it is restored.

  The frames of hidden canvases are left as they are. Visibility is
  settled. Arranging twice for one arrangement changes nothing the second
  time.
  """
  @spec arrange(
          Context.t(),
          t(),
          [Prima.Layout.arranged()],
          [card()],
          Prima.Layout.posture_name()
        ) :: t()
  def arrange(%Context{} = ctx, %__MODULE__{} = t, arrangement, cards, posture)
      when is_list(arrangement) and posture in ["desk", "hand"] do
    t = %{t | posture: posture}
    ids = MapSet.new(arrangement, & &1.id)

    gone =
      for %{key: key} <- list(t),
          id = canvas_of(key),
          not is_nil(id),
          not MapSet.member?(ids, id),
          do: key

    t = Enum.reduce(gone, t, &drop(ctx, &2, &1))
    t = %{t | canvas: keep_canvas(t.canvas, arrangement)}

    t =
      case Enum.find(arrangement, &(&1.id == t.canvas)) do
        nil -> t
        canvas -> arrange_canvas(ctx, t, canvas, cards)
      end

    settle(ctx, t)
  end

  @doc """
  Show canvas `canvas_id` of `arrangement`: it becomes the visible canvas,
  the frames the layout places over it are held (`arrange/5`, in the
  value's posture), and every other canvas and its apps are hidden —
  frozen, apps with a background grant excepted. A canvas the
  arrangement does not have changes nothing.
  """
  @spec show(Context.t(), t(), String.t(), [Prima.Layout.arranged()], [card()]) :: t()
  def show(%Context{} = ctx, %__MODULE__{} = t, canvas_id, arrangement, cards) do
    if Enum.any?(arrangement, &(&1.id == canvas_id)),
      do: arrange(ctx, %{t | canvas: canvas_id}, arrangement, cards, t.posture),
      else: t
  end

  defp keep_canvas(canvas, arrangement) do
    if Enum.any?(arrangement, &(&1.id == canvas)) do
      canvas
    else
      case arrangement do
        [%{id: first} | _] -> first
        [] -> nil
      end
    end
  end

  defp arrange_canvas(ctx, t, canvas, cards) do
    placed = placements(canvas, cards, t.posture)
    wanted = Map.new(placed, fn {key, _placement, _stack, _minimised, card} -> {key, card.id} end)

    stale =
      for %{key: {:app, id, _} = key, tincture_id: tincture_id} <- list(t),
          id == canvas.id,
          Map.get(wanted, key) != tincture_id,
          do: key

    t = Enum.reduce(stale, t, &drop(ctx, &2, &1))

    Enum.reduce(placed, t, fn {key, placement, stack, minimised, card}, t ->
      cond do
        get(t, key) -> stand(t, key, placement, stack, minimised)
        minimised -> t
        true -> open(t, ctx, key, card, placement, stack, minimised)
      end
    end)
  end

  # The held app under `key` stood where the layout places it: its frame,
  # id and credential kept.
  defp stand(t, key, placement, stack, minimised),
    do: transition(t, key, &%{&1 | placement: placement, stack: stack, minimised: minimised})

  @doc """
  Discard every frame whose tincture `cards` no longer lists, and settle
  visibility.
  """
  @spec prune(Context.t(), t(), [card()]) :: t()
  def prune(%Context{} = ctx, %__MODULE__{} = t, cards) do
    listed = MapSet.new(cards, & &1.id)

    t
    |> list()
    |> Enum.reject(&MapSet.member?(listed, &1.tincture_id))
    |> Enum.reduce(t, &drop(ctx, &2, &1.key))
    |> then(&settle(ctx, &1))
  end

  @doc """
  Bring every frame's credential in line with its visibility
  (`visibility/1`, `plan/1`): a frame to freeze is suspended, and
  discarded when the suspension cannot be recorded; a frame to thaw is
  resumed, and when that fails its credential is revoked and it shows
  its refusal.
  """
  @spec settle(Context.t(), t()) :: t()
  def settle(%Context{} = ctx, %__MODULE__{} = t) do
    t = visibility(t)

    Enum.reduce(plan(t), t, fn
      {:freeze, key}, t ->
        case TinctureAuth.suspend_frame(ctx, get(t, key).credential_id) do
          {:ok, _row} -> freeze(t, key)
          {:error, _reason} -> drop(ctx, t, key)
        end

      {:thaw, key}, t ->
        frame = get(t, key)

        case TinctureAuth.resume_frame(ctx, frame.credential_id, rotate: not canvas_key?(key)) do
          {:ok, %{credential: _} = minted} ->
            t |> thaw(key) |> rotated(key, minted)

          {:ok, _kept} ->
            thaw(t, key)

          {:error, reason} ->
            revoke(ctx, frame.credential_id)
            refuse(t, key, refusal(reason))
        end
    end)
  end

  @doc """
  Renew the live frame `frame_id` whose credential's deadline is
  `deadline` (`Sanctum.TinctureAuth.renew_frame/2`): its bearer is rotated
  and its deadline moves. A frame not held, not live, a validation's, or
  held at another deadline is `:stale` and nothing is done. Otherwise the refusal decides:

  | refusal | renewal |
  |---|---|
  | `:unavailable`, `:not_owner`, `:identity_stale` | `:retry` |
  | `:suspended` | `:stale` |
  | `:expired` | `:expired`, left to expire |
  | any standing or identity refusal | `:refused`: revoked, showing it |
  """
  @spec renew(Context.t(), t(), String.t(), DateTime.t()) :: {renewal(), t()}
  def renew(%Context{} = ctx, %__MODULE__{} = t, frame_id, %DateTime{} = deadline)
      when is_binary(frame_id) do
    case find(t, frame_id) do
      %{key: key, deadline: held} = frame ->
        if renewable?(frame) and DateTime.compare(held, deadline) == :eq,
          do: renewed(ctx, t, key, frame),
          else: {:stale, t}

      nil ->
        {:stale, t}
    end
  end

  # The classes of a renewal's refusal: a member or a store that cannot
  # answer now may answer later, a suspended row is a timer the freeze
  # outran, an expired row is let go, and every standing or identity
  # refusal (`:not_standing`, `:not_member`, `:ip_not_allowed`,
  # `:expired_credential`, `:revoked`, `:not_found`, ...) ends the frame.
  defp renewed(ctx, t, key, frame) do
    case TinctureAuth.renew_frame(ctx, frame.credential_id) do
      {:ok, minted} ->
        {:renewed, rotated(t, key, minted)}

      {:error, reason} when reason in [:unavailable, :not_owner, :identity_stale] ->
        {:retry, t}

      {:error, :suspended} ->
        {:stale, t}

      {:error, :expired} ->
        {:expired, t}

      {:error, reason} ->
        revoke(ctx, frame.credential_id)
        {:refused, refuse(t, key, refusal(reason))}
    end
  end

  # A rotated bearer replaces the frame's own until its handshake hands it
  # over, and is queued for the view after.
  defp rotated(t, key, %{credential: bearer, deadline: deadline}) do
    case get(t, key) do
      nil ->
        t

      %{bearer: held, id: id} = frame ->
        cond do
          is_nil(held) ->
            t
            |> put_frame(key, %{frame | deadline: deadline})
            |> Map.update!(:replacements, &(&1 ++ [%{frame: id, credential: bearer}]))

          true ->
            put_frame(t, key, %{frame | bearer: bearer, deadline: deadline})
        end
    end
  end

  @doc """
  Revoke the credential `id` this value minted, whether or not a frame
  still holds it; revoking is idempotent, so one revoked already answers
  as it is. The answer remembers it only when its revocation could not be
  recorded.
  """
  @spec revoke(Context.t(), t(), String.t() | nil) :: t()
  def revoke(%Context{} = ctx, %__MODULE__{} = t, id) do
    case revoke(ctx, id) do
      :ok -> %{t | minted: List.delete(t.minted, id)}
      :error -> t
    end
  end

  @doc """
  Revoke every credential this value minted, revoked ones included, since
  revoking is idempotent. The answer remembers only those whose
  revocation could not be recorded.
  """
  @spec revoke_all(Context.t(), t()) :: t()
  def revoke_all(%Context{} = ctx, %__MODULE__{minted: minted} = t) do
    %{t | minted: Enum.reject(minted, &(revoke(ctx, &1) == :ok))}
  end

  @doc """
  The release digest of the exact version the card lists: what the frame
  and asset credentials bind as the version's digest.
  """
  @spec version_digest(Context.t(), card()) ::
          {:ok, String.t()} | {:error, :unregistered | :unavailable}
  def version_digest(%Context{} = ctx, card) do
    case Compendium.inspect_component(ctx, version_ref(card)) do
      {:ok, %{"release_digest" => "sha256:" <> _ = digest}} -> {:ok, digest}
      {:ok, _unreleased} -> {:error, :unregistered}
      {:error, {:not_found, _}} -> {:error, :unregistered}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  @doc "The path of `segments` inside the card's version, under an asset credential."
  @spec asset_path(String.t(), card(), [String.t()]) :: String.t()
  def asset_path(credential, card, segments) do
    Prima.TinctureUrl.asset_path(credential, [card.publisher, card.name, card.version | segments])
  end

  # ============================================================================
  # Internals
  # ============================================================================

  defp find(%__MODULE__{frames: frames}, frame_id) do
    Enum.find_value(frames, fn
      {_key, %{id: ^frame_id} = frame} -> frame
      _other -> nil
    end)
  end

  defp hold(t, %{key: key} = frame) do
    order = if Map.has_key?(t.frames, key), do: t.order, else: t.order ++ [key]
    %{t | frames: Map.put(t.frames, key, frame), order: order}
  end

  defp put_frame(t, key, frame), do: %{t | frames: Map.put(t.frames, key, frame)}

  defp transition(%__MODULE__{} = t, key, fun) do
    case get(t, key) do
      nil -> t
      frame -> put_frame(t, key, fun.(frame))
    end
  end

  # Open a frame of `card` under `key` at `placement`, unless one is held
  # under it. Visibility is not settled here.
  defp open(%__MODULE__{} = t, ctx, key, card, placement, stack, minimised) do
    if Map.has_key?(t.frames, key) do
      t
    else
      frame = open_frame(ctx, key, card, placement, stack, minimised)
      t |> hold(frame) |> remember_mint(frame)
    end
  end

  # Revoke and forget, without settling: a caller that drops several
  # settles once.
  defp drop(ctx, t, key) do
    case get(t, key) do
      nil ->
        t

      frame ->
        revoke(ctx, frame.credential_id)
        forget(t, key)
    end
  end

  defp remember_mint(t, %{credential_id: id}) when is_binary(id),
    do: %{t | minted: [id | t.minted]}

  defp remember_mint(t, _refused), do: t

  defp revoke(_ctx, nil), do: :ok

  defp revoke(ctx, id) when is_binary(id) do
    case TinctureAuth.revoke_frame(ctx, id) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Prism.Frames] frame credential #{id} not revoked: #{inspect(reason)}")
        :error
    end
  end

  defp base_frame(key, frame_id, card, placement, stack \\ 0, minimised \\ false) do
    %{
      key: key,
      id: frame_id,
      tincture_id: card.id,
      reference: %{publisher: card.publisher, name: card.name, version: card.version},
      src: nil,
      sandbox: nil,
      allow: nil,
      state: :refused,
      refusal: nil,
      credential_id: nil,
      bearer: nil,
      deadline: nil,
      placement: placement,
      stack: stack,
      minimised: minimised,
      visible: false,
      background: false,
      actions: [],
      canvas: nil
    }
  end

  # One open of a frame that is not a canvas's: the declaration, the
  # attributes it derives, the page's address and the frame's credential.
  defp open_frame(ctx, key, card, placement, stack, minimised) do
    frame_id = new_frame_id()
    base = base_frame(key, frame_id, card, placement, stack, minimised)

    with {:ok, declaration} <- Compendium.tincture_declaration(card.manifest),
         :ok <- placed_as_declared(declaration, key),
         {:ok, attributes} <- frame_attributes(declaration, declaration.frame.capabilities),
         {:ok, digest} <- version_digest(ctx, card),
         {:ok, src} <- frame_src(ctx, card, digest),
         {:ok, revision} <- Compendium.tincture_grant_revision(ctx, version_ref(card)),
         {:ok, minted} <-
           TinctureAuth.mint_frame_credential(ctx, base.reference, digest, revision, frame_id) do
      %{
        base
        | src: src,
          sandbox: attributes.sandbox,
          allow: attributes.allow,
          background: declaration.frame.background,
          actions: declaration.actions,
          credential_id: minted.id,
          bearer: minted.credential,
          deadline: minted.deadline,
          state: :live,
          visible: true
      }
    else
      {:error, reason} -> %{base | refusal: refusal(reason)}
    end
  end

  # The one builder of a canvas-placement frame, live or validation: its
  # page under an asset credential for the version, the canvas's sandbox
  # and no `allow`, and its handshake block from the version's stored
  # declaration. Only `mint` differs between the two.
  defp canvas_frame(ctx, {kind, _id} = key, card, mode, mint) do
    frame_id = new_frame_id()
    base = base_frame(key, frame_id, card, kind)

    with {:ok, declaration} <- Compendium.tincture_declaration(card.manifest),
         :ok <- placed_as_declared(declaration, key),
         {:ok, digest} <- version_digest(ctx, card),
         {:ok, %{credential: asset}} <- TinctureAuth.mint_asset_credential(ctx, digest),
         {:ok, revision} <- Compendium.tincture_grant_revision(ctx, version_ref(card)),
         {:ok, minted} <- mint.(ctx, base.reference, digest, revision, frame_id) do
      %{
        base
        | src: Prima.TinctureWire.page_path(asset, frame_id),
          sandbox: Enum.join(Compendium.tincture_canvas_sandbox_tokens(), " "),
          credential_id: minted.id,
          bearer: minted.credential,
          deadline: minted.deadline,
          state: :live,
          visible: kind == :canvas,
          canvas: %{
            "mode" => mode,
            "data_path" => Prima.TinctureWire.data_path(frame_id),
            "streams" =>
              Enum.map(declaration.streams, &%{"name" => &1.name, "subject" => &1.subject})
          }
      }
    else
      {:error, reason} -> %{base | refusal: refusal(reason)}
    end
  end

  # A canvas frame opens only a canvas, and nothing else opens one.
  defp placed_as_declared(%{frame: %{placement: "canvas"}}, {kind, _id})
       when kind in [:canvas, :validation],
       do: :ok

  defp placed_as_declared(_declaration, {kind, _id}) when kind in [:canvas, :validation],
    do: {:error, {:placement, "canvas"}}

  defp placed_as_declared(%{frame: %{placement: "canvas"}}, _key),
    do: {:error, {:placement, "not canvas"}}

  defp placed_as_declared(_declaration, _key), do: :ok

  # A private tincture's page, under an asset credential in its path; a
  # public one's, at its public address. Neither URL carries a credential
  # that opens anything but the version's files.
  defp frame_src(_ctx, %{public: true} = card, _digest),
    do: {:ok, Prima.TinctureUrl.path(card.athanor_segment, card.publisher, card.name)}

  defp frame_src(ctx, card, digest) do
    with {:ok, %{credential: credential}} <- TinctureAuth.mint_asset_credential(ctx, digest) do
      {:ok, asset_path(credential, card, String.split(card.entry, "/"))}
    end
  end

  defp new_frame_id,
    do: "frm_" <> Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)
end
