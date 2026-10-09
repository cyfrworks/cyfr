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
      canvas `canvas_id`, `full` (the whole screen while it is shown) or as a
      `column` beside the canvas (`open_app/7`);
    * `{:floating, canvas_id, ref}` — the tincture `ref` floating over canvas
      `canvas_id` where the layout puts it (`open_floating/6`);
    * `{:full, tincture_id}` — a tincture launched from the picker
      (`launch/3`).

  A tincture belongs to the canvas it was opened on. Only this module's own
  open path makes a frame under a canvas or a validation key: `put/2`
  refuses one, so a canvas frame created by anything but `Prism.Frames` is
  impossible.

  ## Opening

  An open reads the version's declaration through `Compendium`, and mints
  the frame's credential bound to the person, the tincture version and its
  release digest, the grant revision of the tincture's owner profile
  (`Compendium.tincture_grant_revision/2`) and a fresh frame id. No URL
  carries the frame credential.

    * A canvas or validation frame opens only a version whose placement is
      `canvas`, and an app, a floating or a launched frame never opens one;
      a floating frame needs the placement `float`. Anything else is
      refused `:undeclared`.
    * One builder makes every canvas-placement frame, live or validation,
      so its address, its sandbox and its boot have one definition. Its
      `src` is the canvas's host page (`Prima.CanvasWire.page_path/2`) under
      an asset credential for the version, its `sandbox` the canvas's
      (`Compendium.tincture_canvas_sandbox_tokens/0`) and it has no
      `allow`. It holds the fields of its `boot` but the credential: the
      mode, its data path, the module's address under the asset
      credential, the toolkit major, and the streams the served version's
      stored declaration names, never anything a frame or a module sends.
    * Any other frame takes its `sandbox` and `allow` from the rules for
      the capabilities it declares (`frame_attributes/2`), and a private
      tincture's page is served under an asset credential
      (`Prima.TinctureUrl`'s `/_s/` path), a public one's at its `/t/`
      address.

  A step that refuses leaves a frame in state `:refused` that renders its
  refusal and holds no credential. A tincture whose one owner profile waits
  for the person to consent again is refused as `:ungranted`. A frame
  remembers the actions its version declares (`actions`), which is what the
  shell reads before it honours a verb that needs one.

  ## The canvases and visibility

  The visible canvas is the value's (`visible_canvas/1`): the layout's first
  canvas at the first arrangement, kept across postures and switches, and
  the first again when the layout drops it (`arrange/4`). With a `full`
  frame active — a launch, or a `full` app of the visible canvas — it alone
  is visible. Otherwise the visible canvas's frame, its `column` apps and
  its floating frames are. Every other canvas and its apps and floating
  frames are hidden, and a validation frame is never visible.

  A hidden frame without a declared `background` grant is frozen: its
  credential is suspended through Sanctum before the view signals it to
  stop, and a suspension that cannot be recorded discards the frame. A
  hidden canvas is frozen whatever its declaration says. A shown frame's
  credential is resumed before it is signalled live; a resume that fails
  revokes the credential and leaves the frame showing its refusal. A
  validation frame is never frozen or thawed: its credential is never
  suspended.

  ## Attribution and the handshake

  A message is attributed to the live frame whose id it names and that
  this value holds; a frozen or refused frame acts on nothing, and any
  other message is dropped and counted (`drop_message/1`). A frame's
  bearer is handed over once (`handshake/2`): a canvas or validation
  frame's inside its `boot`, any other frame's alone.

  ## Ending

  Every credential minted is remembered (`minted/1`) until it is
  revoked, and `revoke_all/2` revokes each one; the view calls it on
  every path that ends it. `clear/2` revokes them all and holds no
  frame, which is how safe mode starts.

  The pure transitions — placement, visibility, attribution, the
  handshake and the signals the view sends — take no context and touch
  no store. The functions that take a context first are the effects:
  each reaches a credential only through `Sanctum.TinctureAuth`.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  @typedoc "A floating position: `x` and `y` in hundredths of a percent of the viewport."
  @type position :: %{x: non_neg_integer(), y: non_neg_integer()}

  @typedoc "Where a frame sits."
  @type placement ::
          :canvas
          | :validation
          | :full
          | {:column, non_neg_integer()}
          | {:floating, position()}

  @typedoc "A versionless tincture reference, as the layout names one."
  @type ref :: String.t()

  @typedoc "The key a frame is held under: one frame per key."
  @type key ::
          {:canvas, String.t()}
          | {:validation, String.t()}
          | {:app, String.t(), ref()}
          | {:floating, String.t(), ref()}
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

  @typedoc "What a canvas-placement frame's `boot` carries, but the credential."
  @type boot :: %{String.t() => term()}

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
          placement: placement(),
          visible: boolean(),
          background: boolean(),
          actions: [String.t()],
          arranged: boolean(),
          boot: boot() | nil
        }

  @typedoc "What the view signals a frame: its id and `frozen` or `live`."
  @type signal :: %{frame: String.t(), state: String.t()}

  @typedoc "What a frame's bridge is handed at its handshake."
  @type handshake :: %{credential: String.t()} | %{boot: boot()}

  @typedoc """
  A mint of a frame credential: `Sanctum.TinctureAuth.mint_frame_credential/5`
  or `mint_validation_credential/5`, which take the same arguments.
  """
  @type mint :: (Context.t(), map(), String.t(), non_neg_integer(), String.t() ->
                   {:ok, %{credential: String.t(), id: String.t()}} | {:error, term()})

  @type t :: %__MODULE__{
          frames: %{key() => frame()},
          order: [key()],
          active: key() | nil,
          minted: [String.t()],
          dropped: non_neg_integer(),
          canvas: String.t() | nil
        }

  defstruct frames: %{}, order: [], active: nil, minted: [], dropped: 0, canvas: nil

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
  The active `full` frame, shown above everything: a launch, or a `full`
  app of the visible canvas. An app of another canvas is never active.
  """
  @spec active(t()) :: frame() | nil
  def active(%__MODULE__{active: nil}), do: nil

  def active(%__MODULE__{active: key} = t) do
    case get(t, key) do
      nil -> nil
      frame -> if shows_full?(t, frame), do: frame, else: nil
    end
  end

  @doc "The card id of the active `full` frame's tincture, or nil."
  @spec active_tincture(t()) :: String.t() | nil
  def active_tincture(t) do
    case active(t) do
      %{tincture_id: tincture_id} -> tincture_id
      nil -> nil
    end
  end

  @doc "The ids of every credential minted and not yet known revoked."
  @spec minted(t()) :: [String.t()]
  def minted(%__MODULE__{minted: minted}), do: minted

  @doc "How many frame messages were dropped."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc "Whether `key` is a canvas-placement frame's: a canvas's or a validation's."
  @spec canvas_key?(term()) :: boolean()
  def canvas_key?({:canvas, id}) when is_binary(id), do: true
  def canvas_key?({:validation, id}) when is_binary(id), do: true
  def canvas_key?(_key), do: false

  @doc "The canvas a key belongs to, or nil for a launch."
  @spec canvas_of(key()) :: String.t() | nil
  def canvas_of({kind, id}) when kind in [:canvas, :validation], do: id
  def canvas_of({kind, id, _ref}) when kind in [:app, :floating], do: id
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
  Whether the card's declaration lets it float: its frame declares the
  placement `float`. A declaration that does not hold to the rules lets
  nothing float.
  """
  @spec floats?(card()) :: boolean()
  def floats?(card), do: placement_of(card) == "float"

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
  `Compendium.layout/2`'s arrangement), each with its key, its placement
  and the card it opens: every `column` app whose tincture is installed,
  in order, and every floating entry whose tincture is installed and
  declares `float`. A `full` app opens only when it is asked for.
  """
  @spec placements(Prima.Layout.arranged(), [card()]) :: [{key(), placement(), card()}]
  def placements(%{id: canvas_id, apps: apps, floating: floating}, cards) do
    columns =
      for %{tincture: ref, mode: :column, order: order} <- apps,
          card = resolve(ref, cards),
          do: {{:app, canvas_id, ref}, {:column, order}, card}

    floated =
      for %{tincture: ref, position: position} <- floating,
          card = resolve(ref, cards),
          floats?(card),
          do: {{:floating, canvas_id, ref}, {:floating, position}, card}

    columns ++ floated
  end

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
  canvas or validation frame's `boot`, its bearer inside it, and any other
  frame's bearer alone. Only a frame held under a canvas or validation key
  is answered a `boot`.
  """
  @spec handshake(t(), term()) :: {:ok, handshake(), frame(), t()} | :error
  def handshake(%__MODULE__{} = t, frame_id) do
    case hand_over(t, frame_id) do
      {:ok, bearer, t} ->
        %{key: key, boot: boot} = frame = find(t, frame_id)

        if canvas_key?(key) and is_map(boot),
          do: {:ok, %{boot: Map.put(boot, "credential", bearer)}, frame, t},
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
      raise(ArgumentError, "a canvas or validation frame is made only by Prism.Frames' open path")

  def put(%__MODULE__{} = t, %{key: _key} = frame), do: hold(t, frame)

  @doc """
  Forget the frame under `key`. When it was the active `full` frame, the
  first `full` frame still held that the visible canvas may show becomes
  active.
  """
  @spec forget(t(), key()) :: t()
  def forget(%__MODULE__{} = t, key) do
    t = %{t | frames: Map.delete(t.frames, key), order: List.delete(t.order, key)}

    if t.active == key,
      do: %{t | active: Enum.find(t.order, &shows_full?(t, get(t, &1)))},
      else: t
  end

  @doc """
  Make the `full` frame under `key` the active one: a launch, or a `full`
  app. Any other key changes nothing.
  """
  @spec activate(t(), key()) :: t()
  def activate(%__MODULE__{} = t, key) do
    case get(t, key) do
      %{placement: :full} -> %{t | active: key}
      _other -> t
    end
  end

  @doc """
  Move a floating frame to a layout position, or a column app to its
  order. Only those move, and only to a placement of their own kind.
  """
  @spec place(t(), key(), placement()) :: t()
  def place(%__MODULE__{} = t, {:floating, _, _} = key, {:floating, _} = placement),
    do: move(t, key, placement)

  def place(%__MODULE__{} = t, {:app, _, _} = key, {:column, _} = placement) do
    case get(t, key) do
      %{placement: {:column, _}} -> move(t, key, placement)
      _other -> t
    end
  end

  def place(%__MODULE__{} = t, _key, _placement), do: t

  defp move(t, key, placement) do
    case get(t, key) do
      nil -> t
      frame -> put_frame(t, key, %{frame | placement: placement})
    end
  end

  @doc """
  Each frame's visibility: with a `full` frame active, it alone is
  visible; with none, the visible canvas's frame, its `column` apps and
  its floating frames are. A validation frame is never visible.
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
  defp visible?(%{key: {:app, id, _}, placement: {:column, _}}, nil, canvas), do: id == canvas
  defp visible?(%{key: {:floating, id, _}}, nil, canvas), do: id == canvas
  defp visible?(_full, nil, _canvas), do: false

  # A launch is shown whatever canvas is visible; a full app only over its
  # own canvas.
  defp shows_full?(_t, %{key: {:full, _}, placement: :full}), do: true
  defp shows_full?(t, %{key: {:app, id, _}, placement: :full}), do: id == t.canvas
  defp shows_full?(_t, _frame), do: false

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
    t = open(ctx, t, key, card, :full, false)
    settle(ctx, activate(t, key))
  end

  @doc """
  Open `card` over canvas `canvas_id` as an app in `mode`, `:full` or
  `:column` (at `order`), unless one is held under its key; a `full` app
  is made the active frame. `arranged` says the layout placed it, so the
  next arrangement may move or discard it. Visibility is settled.
  """
  @spec open_app(
          Context.t(),
          t(),
          String.t(),
          card(),
          Prima.Layout.mode(),
          non_neg_integer(),
          boolean()
        ) :: t()
  def open_app(
        %Context{} = ctx,
        %__MODULE__{} = t,
        canvas_id,
        card,
        mode,
        order,
        arranged \\ false
      )
      when mode in [:full, :column] do
    key = {:app, canvas_id, ref_of(card)}
    placement = if mode == :full, do: :full, else: {:column, order}
    t = open(ctx, t, key, card, placement, arranged)
    settle(ctx, if(mode == :full, do: activate(t, key), else: t))
  end

  @doc """
  Open `card` floating over canvas `canvas_id` at `position`, unless one is
  held under its key; one held moves there. `arranged` as `open_app/7`'s.
  Visibility is settled.
  """
  @spec open_floating(Context.t(), t(), String.t(), card(), position(), boolean()) :: t()
  def open_floating(
        %Context{} = ctx,
        %__MODULE__{} = t,
        canvas_id,
        card,
        position,
        arranged \\ false
      ) do
    key = {:floating, canvas_id, ref_of(card)}
    placement = {:floating, position}
    settle(ctx, open(ctx, place(t, key, placement), key, card, placement, arranged))
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
      frame = %{base_frame(key, new_frame_id(), card, :canvas, false) | refusal: refusal}
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
    * of the visible canvas's frames the layout placed (`placements/2`),
      one it no longer places, or places in another kind, is discarded; one
      it places anew is opened; a floating frame moves to its layout
      position and a column to its order.

  Apps and floating frames opened on the canvas's own ask, and the frames
  of hidden canvases, are left as they are. Visibility is settled.
  """
  @spec arrange(Context.t(), t(), [Prima.Layout.arranged()], [card()]) :: t()
  def arrange(%Context{} = ctx, %__MODULE__{} = t, arrangement, cards)
      when is_list(arrangement) do
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
  the frames the layout places over it are held (`arrange/4`), and every
  other canvas and its apps and floating frames are hidden — frozen,
  apps with a background grant excepted. A canvas the arrangement does
  not have changes nothing.
  """
  @spec show(Context.t(), t(), String.t(), [Prima.Layout.arranged()], [card()]) :: t()
  def show(%Context{} = ctx, %__MODULE__{} = t, canvas_id, arrangement, cards) do
    if Enum.any?(arrangement, &(&1.id == canvas_id)),
      do: arrange(ctx, %{t | canvas: canvas_id}, arrangement, cards),
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
    placed = placements(canvas, cards)
    wanted = Map.new(placed, fn {key, placement, card} -> {key, {placement, card.id}} end)

    stale =
      for %{key: key, arranged: true, placement: placement, tincture_id: tincture_id} <- list(t),
          canvas_of(key) == canvas.id,
          not same_kind?(Map.get(wanted, key), placement, tincture_id),
          do: key

    t = Enum.reduce(stale, t, &drop(ctx, &2, &1))

    Enum.reduce(placed, t, fn {key, placement, card}, t ->
      case get(t, key) do
        nil ->
          open(ctx, t, key, card, placement, true)

        %{placement: held} = frame ->
          if same_kind?({placement, card.id}, held, frame.tincture_id) do
            put_frame(t, key, %{frame | placement: placement, arranged: true})
          else
            open(ctx, drop(ctx, t, key), key, card, placement, true)
          end
      end
    end)
  end

  defp same_kind?(nil, _held, _tincture_id), do: false

  defp same_kind?({placement, tincture_id}, held, held_tincture),
    do: kind(placement) == kind(held) and tincture_id == held_tincture

  defp kind({kind, _}), do: kind
  defp kind(kind), do: kind

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

        case TinctureAuth.resume_frame(ctx, frame.credential_id) do
          {:ok, _row} ->
            thaw(t, key)

          {:error, reason} ->
            revoke(ctx, frame.credential_id)
            refuse(t, key, refusal(reason))
        end
    end)
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
    ref = Prima.ComponentRef.build("tincture", card.publisher, card.name, card.version)

    case Compendium.inspect_component(ctx, ref) do
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
  defp open(ctx, %__MODULE__{} = t, key, card, placement, arranged) do
    if Map.has_key?(t.frames, key) do
      t
    else
      frame = open_frame(ctx, key, card, placement, arranged)
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

  defp base_frame(key, frame_id, card, placement, arranged) do
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
      placement: placement,
      visible: false,
      background: false,
      actions: [],
      arranged: arranged,
      boot: nil
    }
  end

  # One open of a frame that is not a canvas's: the declaration, the
  # attributes it derives, the page's address and the frame's credential.
  defp open_frame(ctx, key, card, placement, arranged) do
    frame_id = new_frame_id()
    base = base_frame(key, frame_id, card, placement, arranged)

    with {:ok, declaration} <- Compendium.tincture_declaration(card.manifest),
         :ok <- placed_as_declared(declaration, key),
         {:ok, attributes} <- frame_attributes(declaration, declaration.frame.capabilities),
         {:ok, digest} <- version_digest(ctx, card),
         {:ok, src} <- frame_src(ctx, card, digest),
         {:ok, revision} <- Compendium.tincture_grant_revision(ctx, ref_of(card)),
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
          state: :live,
          visible: true
      }
    else
      {:error, reason} -> %{base | refusal: refusal(reason)}
    end
  end

  # The one builder of a canvas-placement frame, live or validation: its
  # host page under an asset credential for the version, the canvas's
  # sandbox and no `allow`, and its boot from the version's stored
  # declaration. Only `mint` differs between the two.
  defp canvas_frame(ctx, {kind, _id} = key, card, mode, mint) do
    frame_id = new_frame_id()
    base = base_frame(key, frame_id, card, kind, false)

    with {:ok, declaration} <- Compendium.tincture_declaration(card.manifest),
         :ok <- placed_as_declared(declaration, key),
         {:ok, module} <- Compendium.tincture_canvas_module(card.manifest),
         {:ok, digest} <- version_digest(ctx, card),
         {:ok, %{credential: asset}} <- TinctureAuth.mint_asset_credential(ctx, digest),
         {:ok, revision} <- Compendium.tincture_grant_revision(ctx, ref_of(card)),
         {:ok, minted} <- mint.(ctx, base.reference, digest, revision, frame_id) do
      %{
        base
        | src: Prima.CanvasWire.page_path(asset, frame_id),
          sandbox: Enum.join(Compendium.tincture_canvas_sandbox_tokens(), " "),
          credential_id: minted.id,
          bearer: minted.credential,
          state: :live,
          visible: kind == :canvas,
          boot: %{
            "mode" => mode,
            "data_path" => Prima.CanvasWire.data_path(frame_id),
            "module_url" => asset_path(asset, card, String.split(module, "/")),
            "toolkit" => declaration.canvas.toolkit,
            "streams" =>
              Enum.map(declaration.streams, &%{"name" => &1.name, "subject" => &1.subject})
          }
      }
    else
      {:error, reason} -> %{base | refusal: refusal(reason)}
    end
  end

  # A canvas frame opens only a canvas, and nothing else opens one; a
  # floating frame opens only a tincture that declares `float`.
  defp placed_as_declared(%{frame: %{placement: "canvas"}}, {kind, _id})
       when kind in [:canvas, :validation],
       do: :ok

  defp placed_as_declared(_declaration, {kind, _id}) when kind in [:canvas, :validation],
    do: {:error, {:placement, "canvas"}}

  defp placed_as_declared(%{frame: %{placement: "canvas"}}, _key),
    do: {:error, {:placement, "not canvas"}}

  defp placed_as_declared(%{frame: %{placement: "float"}}, {:floating, _id, _ref}), do: :ok

  defp placed_as_declared(_declaration, {:floating, _id, _ref}),
    do: {:error, {:placement, "float"}}

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
