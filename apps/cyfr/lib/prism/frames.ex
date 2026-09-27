# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Frames do
  @moduledoc """
  The shell's frames: every tincture frame one shell view creates,
  places, freezes, discards and attributes a message to. A plain value
  held in the view's assigns; it starts no process.

  ## Opening

  A frame opens for a tincture the shell lists (a card, as the shell's
  tincture list holds it) at a placement: `:full` (the person launched
  it), `{:slot, slot_id}` (a `full` slot of the layout),
  `{:floating, position}` (a floating entry of the layout) or `:desktop`
  (the posture's desktop, under every slot and floating frame, one per
  value; only a tincture whose declaration names the placement `desktop`
  opens there). The open
  reads the version's declaration through `Compendium`, takes its
  `sandbox` and `allow` from the rules for the capabilities it declares
  (`frame_attributes/2`), and mints the frame's credential
  (`Sanctum.TinctureAuth.mint_frame_credential/5`) bound to the person,
  the tincture version and its release digest, the grant revision of the
  tincture's owner profile and a fresh frame id. A private tincture's
  page is served under an asset credential (`Prima.TinctureUrl`'s `/_s/`
  path), a public one's at its `/t/` address; no URL carries the frame
  credential. A step that refuses leaves a frame in state `:refused`
  that renders its refusal and holds no credential. A tincture whose one
  owner profile waits for the person to consent again
  (`needs_consent`) is refused as `:ungranted`: its frame opens once the
  person has granted what it declares now.

  A frame remembers the actions its version declares (`actions`), which
  is what the shell reads before it honours a verb that needs one.

  A tincture floats only when its declaration says so (`placement:
  "float"`) and only where the layout puts it; no message from a frame
  places, sizes or raises it.

  ## Visibility

  With a `:full` frame active, it alone is visible; with none, every
  slot and floating frame and the desktop are. A hidden frame without a declared
  `background` grant is frozen: its credential is suspended through
  Sanctum before the view signals it to stop, and a suspension that
  cannot be recorded discards the frame, so a hidden frame never keeps a
  credential the shell could not stop. A shown frame's credential is
  resumed before it is signalled live; a resume that fails revokes the
  credential and leaves the frame showing its refusal.

  ## Attribution

  A message is attributed to the live frame whose id it names and that
  this value holds; a frozen or refused frame acts on nothing, and any
  other message is dropped and counted (`drop_message/1`).

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
  @type placement :: :full | :desktop | {:slot, String.t()} | {:floating, position()}

  @typedoc "The key a frame is held under: one frame per key."
  @type key ::
          {:full, String.t()}
          | {:desktop, String.t()}
          | {:slot, String.t()}
          | {:floating, String.t()}

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
          required(:athanor_segment) => String.t(),
          required(:public) => boolean() | :unknown,
          optional(atom()) => term()
        }

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
          actions: [String.t()]
        }

  @typedoc "What the view signals a frame: its id and `frozen` or `live`."
  @type signal :: %{frame: String.t(), state: String.t()}

  @type t :: %__MODULE__{
          frames: %{key() => frame()},
          order: [key()],
          active: key() | nil,
          minted: [String.t()],
          dropped: non_neg_integer()
        }

  defstruct frames: %{}, order: [], active: nil, minted: [], dropped: 0

  # ============================================================================
  # Pure: reading
  # ============================================================================

  @doc "No frames."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Every frame held, in the order it was opened."
  @spec list(t()) :: [frame()]
  def list(%__MODULE__{frames: frames, order: order}),
    do: Enum.map(order, &Map.fetch!(frames, &1))

  @doc "The frame held under `key`, or nil."
  @spec get(t(), key()) :: frame() | nil
  def get(%__MODULE__{frames: frames}, key), do: Map.get(frames, key)

  @doc "The active `:full` frame, or nil."
  @spec active(t()) :: frame() | nil
  def active(%__MODULE__{active: nil}), do: nil
  def active(%__MODULE__{active: key} = t), do: get(t, key)

  @doc "The card id of the active `:full` frame's tincture, or nil."
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

  @doc "The desktop frame, or nil."
  @spec desktop(t()) :: frame() | nil
  def desktop(%__MODULE__{} = t), do: Enum.find(list(t), &(&1.placement == :desktop))

  @doc "Whether the live frame `frame` declares the action `operation` (`tool.action`)."
  @spec declares?(frame(), String.t()) :: boolean()
  def declares?(%{actions: actions}, operation) when is_binary(operation),
    do: operation in actions

  def declares?(_frame, _operation), do: false

  @doc "The key a frame of `tincture_id` at `placement` is held under."
  @spec key(placement(), String.t()) :: key()
  def key(:full, tincture_id), do: {:full, tincture_id}
  def key(:desktop, tincture_id), do: {:desktop, tincture_id}
  def key({:slot, slot_id}, _tincture_id), do: {:slot, slot_id}
  def key({:floating, _position}, tincture_id), do: {:floating, tincture_id}

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
  def floats?(%{manifest: manifest}) do
    match?({:ok, %{frame: %{placement: "float"}}}, Compendium.tincture_declaration(manifest))
  end

  def floats?(_card), do: false

  @doc """
  Whether the card's declaration makes it a desktop: its frame declares
  the placement `desktop`. A declaration that does not hold to the rules
  is no desktop.
  """
  @spec desktop?(card()) :: boolean()
  def desktop?(%{manifest: manifest}) do
    match?({:ok, %{frame: %{placement: "desktop"}}}, Compendium.tincture_declaration(manifest))
  end

  def desktop?(_card), do: false

  @doc """
  The listed card a versionless layout reference names, or nil when no
  tincture it names is installed.
  """
  @spec resolve(Prima.Layout.ref(), [card()]) :: card() | nil
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
  The frames an arrangement places, each with the card it opens: every
  `full` slot whose tincture is installed, at `{:slot, id}`, and every
  floating entry whose tincture is installed and declares `float`, at
  `{:floating, position}`. `icon` and `card` slots are drawn, not
  framed; a tincture floated twice floats once, where it is first named.
  """
  @spec placements(Prima.Layout.posture(), [card()]) :: [{placement(), card()}]
  def placements(%{slots: slots, floating: floating}, cards) do
    framed =
      for %{size: :full, id: id, tincture: ref} <- slots,
          card = resolve(ref, cards),
          do: {{:slot, id}, card}

    floated =
      for %{tincture: ref, position: position} <- floating,
          card = resolve(ref, cards),
          floats?(card),
          do: {{:floating, position}, card}

    Enum.uniq_by(framed ++ floated, fn {placement, card} -> key(placement, card.id) end)
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

  @doc "Count one dropped frame message."
  @spec drop_message(t()) :: t()
  def drop_message(%__MODULE__{dropped: dropped} = t), do: %{t | dropped: dropped + 1}

  # ============================================================================
  # Pure: placement and visibility
  # ============================================================================

  @doc """
  Hold `frame`, after every frame already held; a frame under a key
  already held replaces it in place.
  """
  @spec put(t(), frame()) :: t()
  def put(%__MODULE__{} = t, %{key: key} = frame) do
    order = if Map.has_key?(t.frames, key), do: t.order, else: t.order ++ [key]
    %{t | frames: Map.put(t.frames, key, frame), order: order}
  end

  @doc """
  Forget the frame under `key`. When it was the active `:full` frame, the
  first `:full` frame still held becomes active.
  """
  @spec forget(t(), key()) :: t()
  def forget(%__MODULE__{} = t, key) do
    t = %{t | frames: Map.delete(t.frames, key), order: List.delete(t.order, key)}

    if t.active == key,
      do: %{t | active: Enum.find(t.order, &match?({:full, _}, &1))},
      else: t
  end

  @doc "Make the `:full` frame under `key` the active one; any other key changes nothing."
  @spec activate(t(), key()) :: t()
  def activate(%__MODULE__{} = t, {:full, _} = key) do
    if Map.has_key?(t.frames, key), do: %{t | active: key}, else: t
  end

  def activate(%__MODULE__{} = t, _key), do: t

  @doc """
  Move a floating frame to a layout position. Only a floating frame
  moves, and only to where the layout puts it.
  """
  @spec place(t(), key(), placement()) :: t()
  def place(%__MODULE__{} = t, {:floating, _} = key, {:floating, _} = placement) do
    case get(t, key) do
      nil -> t
      frame -> put_frame(t, key, %{frame | placement: placement})
    end
  end

  def place(%__MODULE__{} = t, _key, _placement), do: t

  @doc """
  Each frame's visibility: with a `:full` frame active, it alone is
  visible; with none, every slot and floating frame is.
  """
  @spec visibility(t()) :: t()
  def visibility(%__MODULE__{} = t) do
    frames =
      Map.new(t.frames, fn {key, frame} ->
        {key, %{frame | visible: visible?(frame, t.active)}}
      end)

    %{t | frames: frames}
  end

  defp visible?(%{key: key}, active) when not is_nil(active), do: key == active
  defp visible?(%{placement: placement}, nil), do: placement != :full

  @doc """
  The credential transitions visibility asks for, in frame order: a
  hidden live frame without a background grant is to freeze, and a
  visible frozen frame to thaw.
  """
  @spec plan(t()) :: [{:freeze | :thaw, key()}]
  def plan(%__MODULE__{} = t) do
    t
    |> list()
    |> Enum.flat_map(fn
      %{state: :live, visible: false, background: false, key: key} -> [{:freeze, key}]
      %{state: :frozen, visible: true, key: key} -> [{:thaw, key}]
      _steady -> []
    end)
  end

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

  @doc "The refusal class an open, a resume or a mint refusal is shown as."
  @spec refusal(term()) :: refusal()
  def refusal(reason) when reason in [:unavailable, :not_owner], do: :unavailable
  def refusal({:undeclared_capability, _names}), do: :undeclared
  def refusal({:invalid_tincture, _sentence}), do: :undeclared
  def refusal(:not_a_desktop), do: :undeclared
  def refusal(:unregistered), do: :unregistered
  def refusal(:ungranted), do: :ungranted
  def refusal(_standing), do: :refused

  # ============================================================================
  # Effects
  # ============================================================================

  @doc """
  Open a frame of `card` at `placement`, unless one is already held under
  its key. The open mints the frame's credential; a step that refuses
  holds a `:refused` frame. Visibility is not settled here.
  """
  @spec open(Context.t(), t(), card(), placement()) :: t()
  def open(%Context{} = ctx, %__MODULE__{} = t, card, placement) do
    if Map.has_key?(t.frames, key(placement, card.id)) do
      t
    else
      frame = open_frame(ctx, card, placement)
      t |> put(frame) |> remember_mint(frame)
    end
  end

  @doc """
  Show `card` as the active `:full` frame, opening it first when none is
  held, and settle visibility.
  """
  @spec launch(Context.t(), t(), card()) :: t()
  def launch(%Context{} = ctx, %__MODULE__{} = t, card) do
    t = open(ctx, t, card, :full)
    settle(ctx, activate(t, key(:full, card.id)))
  end

  @doc """
  Discard the frame under `key`: its credential is revoked and the frame
  forgotten, then visibility is settled (the next `:full` frame, if any,
  is shown).
  """
  @spec discard(Context.t(), t(), key()) :: t()
  def discard(%Context{} = ctx, %__MODULE__{} = t, key) do
    settle(ctx, drop(ctx, t, key))
  end

  @doc """
  Hold `card` as the desktop: a desktop of another tincture is discarded
  first, one of the same tincture is kept, and visibility is settled. A
  tincture whose declaration does not name the placement `desktop` is
  held refused (`:undeclared`).
  """
  @spec open_desktop(Context.t(), t(), card()) :: t()
  def open_desktop(%Context{} = ctx, %__MODULE__{} = t, card) do
    t =
      case desktop(t) do
        %{tincture_id: id} when id == card.id -> t
        %{key: key} -> drop(ctx, t, key)
        nil -> t
      end

    settle(ctx, open(ctx, t, card, :desktop))
  end

  @doc """
  Every credential this value minted revoked, and no frame held: the
  answer keeps the count of dropped messages and remembers only the
  credentials whose revocation could not be recorded.
  """
  @spec clear(Context.t(), t()) :: t()
  def clear(%Context{} = ctx, %__MODULE__{} = t) do
    %{minted: unrevoked} = revoke_all(ctx, t)
    %{new() | minted: unrevoked, dropped: t.dropped}
  end

  @doc """
  Hold exactly the slot and floating frames `arrangement` places for the
  listed `cards` (`placements/2`): a frame the arrangement no longer
  places, or whose slot now holds another tincture, is discarded; one it
  places anew is opened; a floating frame moves to its layout position.
  `:full` frames and the desktop are left as they are. Visibility is
  settled.
  """
  @spec arrange(Context.t(), t(), Prima.Layout.posture(), [card()]) :: t()
  def arrange(%Context{} = ctx, %__MODULE__{} = t, arrangement, cards) do
    placed = placements(arrangement, cards)
    wanted = Map.new(placed, fn {placement, card} -> {key(placement, card.id), card.id} end)

    stale =
      for %{key: key, placement: placement, tincture_id: tincture_id} <- list(t),
          placement not in [:full, :desktop],
          Map.get(wanted, key) != tincture_id,
          do: key

    t = Enum.reduce(stale, t, &drop(ctx, &2, &1))

    t =
      Enum.reduce(placed, t, fn {placement, card}, t ->
        moved = place(t, key(placement, card.id), placement)
        open(ctx, moved, card, placement)
      end)

    settle(ctx, t)
  end

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

  defp put_frame(t, key, frame), do: %{t | frames: Map.put(t.frames, key, frame)}

  defp transition(%__MODULE__{} = t, key, fun) do
    case get(t, key) do
      nil -> t
      frame -> put_frame(t, key, fun.(frame))
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

  # One open: the declaration, the attributes it derives, the page's
  # address and the frame's credential.
  defp open_frame(ctx, card, placement) do
    frame_id = new_frame_id()
    reference = %{publisher: card.publisher, name: card.name, version: card.version}

    base = %{
      key: key(placement, card.id),
      id: frame_id,
      tincture_id: card.id,
      reference: reference,
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
      actions: []
    }

    with {:ok, declaration} <- Compendium.tincture_declaration(card.manifest),
         :ok <- placed_as_declared(declaration, placement),
         {:ok, attributes} <- frame_attributes(declaration, declaration.frame.capabilities),
         {:ok, digest} <- version_digest(ctx, card),
         {:ok, src} <- frame_src(ctx, card, digest),
         {:ok, revision} <- grant_revision(ctx, card),
         {:ok, minted} <-
           TinctureAuth.mint_frame_credential(ctx, reference, digest, revision, frame_id) do
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

  # Only a desktop opens at the desktop's placement.
  defp placed_as_declared(%{frame: %{placement: "desktop"}}, :desktop), do: :ok
  defp placed_as_declared(_declaration, :desktop), do: {:error, :not_a_desktop}
  defp placed_as_declared(_declaration, _placement), do: :ok

  # The grant revision the frame's credential binds: the head revision of
  # the tincture's one active owner profile, the consent the shell's
  # invocations root on, or 0 while the tincture holds none. An owner
  # profile that waits for the person to consent again opens nothing.
  defp grant_revision(ctx, card) do
    ref = Prima.ComponentRef.build("tincture", card.publisher, card.name)

    with {:ok, entries} <- Sanctum.Consent.profiles(ctx, ref) do
      case Prima.Authority.RootSelect.select(entries, :default) do
        {:ok, %{id: profile_id}} -> head_revision(ctx, profile_id)
        {:error, {:profile_unavailable, :needs_consent}} -> {:error, :ungranted}
        {:error, _no_active_owner} -> {:ok, 0}
      end
    end
  end

  defp head_revision(ctx, profile_id) do
    case Sanctum.Consent.head_consent(ctx, profile_id) do
      {:ok, %{revision: revision}} -> {:ok, revision}
      {:error, :not_found} -> {:ok, 0}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

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
