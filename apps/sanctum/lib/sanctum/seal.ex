# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Seal do
  @moduledoc """
  The person's seal: a short text, with an optional glyph, that the system
  layer shows first in every prompt it draws, so a prompt a frame forges,
  which cannot know it, looks wrong. Its row (`Arca.PersonSeals`) sits
  beside the person's `users` row and never in it, so no read of the
  person carries it; this module is its one owner.

  ## Who reads it

  `for_system_layer/1` answers only the person's own interactive client
  rendering the system layer: a browser session (`auth_method: :oidc`,
  holding its session and no key, client or frame) or a paired device
  (`:device`, naming a paired client that still stands), on the external
  plane, admitted on the interactive path (`origin: :interactive`). Every
  other context reads `:none`, whatever is stored: a frame, a key, a
  webhook, a schedule, the command line (admitted as `:programmatic`), the
  guest plane, the system and an anonymous caller. A store that cannot
  answer reads `:none` too, so the prompt says no seal is chosen rather
  than showing anything else.

  No operation reads or writes the seal, so it is never in an operation's
  result, a data route's answer, a frame's payload or a model's context,
  and the command line has nothing to print: it tells the person to
  confirm on their screen. Nothing here logs it, and a `t:t/0` inspects
  without its words or glyph.

  ## Choosing and changing it

  A seal is made of words from a fixed list (`words/0`): one word, or a
  pair the home draws (`generate/0`), and optionally one glyph from a
  fixed set (`glyphs/0`). Nothing else is a seal, so it never holds
  anything a person typed.

    * `choose/2` sets the first seal, at the person's first interactive
      sign-in at this home, and only while none is set: of two first
      choices one is written and the other is `:already_set`. It needs no
      fresh confirmation, since nothing it replaces could be taken over.
    * `change/2` replaces it, a sensitive change (`seal_change`,
      `Sanctum.Pairing`'s action table) whose fresh confirmation is asked
      first (`Sanctum.Consent.Authz.check/3`) and consumed inside the
      transaction that writes the row (`Sanctum.Consent.Authz.consume/2`).
      Its record binds the new seal by its keyed argument digest and its
      preview names nothing of the seal, so neither the record nor its
      listing carries it. A person with no seal yet is `:not_set`, and no
      confirmation is opened for it.

  Both are ordinary writes under the storage reserve
  (`Sanctum.Catalog.undeclared_write_admission/0`): while it is depleted
  a choice or a change is refused `{:unavailable, :storage_reserve}`
  before any row is written or any confirmation opened, and admitted
  again once it clears.
  """

  alias Arca.PersonSeals
  alias Sanctum.{Catalog, Context, DeviceCerts}
  alias Sanctum.Consent.Authz

  @operation "seal.change"

  @words ~w(
    amber anchor aspen badger birch bramble cedar clover comet coral cricket dune
    ember falcon fern fjord garnet glacier harbor hazel heron indigo iris juniper
    kestrel lagoon lantern linden lotus maple marble meadow mesa moss nectar nimbus
    oak onyx orchid otter pebble pepper pine plum quartz quill raven reef
    ridge river saffron sage sparrow spruce summit thistle tundra umber valley velvet
    walnut willow wren zephyr
  )

  @glyphs ~w(★ ☾ ☀ ☁ ♣ ♦ ♥ ♠ ✿ ❄ ⚓ ☂ ♫ ✈ ⚑ ☘)

  @typedoc """
  A person's seal: its `text`, its `glyph` or nil, and when it was set.
  Inspecting one shows only when it was set.
  """
  @type t :: %__MODULE__{text: String.t(), glyph: String.t() | nil, set_at: DateTime.t()}

  @derive {Inspect, only: [:set_at]}
  @enforce_keys [:text, :glyph, :set_at]
  defstruct [:text, :glyph, :set_at]

  @typedoc """
  Why a seal was not chosen or changed, beside a fresh confirmation's
  signal and refusals (`Sanctum.Consent.Authz`):

    * `:refused` — the context is not the person's own interactive client;
    * `:invalid_seal` — the text is not one listed word or a pair of them,
      or the glyph is not one of the set;
    * `:already_set` — a first choice when a seal is set;
    * `:not_set` — a change when none is;
    * `:unavailable` — the store could not answer, or this member no
      longer owns its slot;
    * the storage reserve's refusal (`Prima.Refusal`) — the home's
      storage reserve is depleted.
  """
  @type refusal ::
          :refused | :invalid_seal | :already_set | :not_set | :unavailable | Prima.Refusal.t()

  @doc "The words a seal is made of."
  @spec words() :: [String.t()]
  def words, do: @words

  @doc "The glyphs a seal may carry, one at most."
  @spec glyphs() :: [String.t()]
  def glyphs, do: @glyphs

  @doc "A seal's text the home draws: two different words of the list, at random."
  @spec generate() :: String.t()
  def generate do
    @words
    |> Enum.sort_by(fn _word -> :crypto.strong_rand_bytes(8) end)
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  @doc """
  The seal of the person behind `ctx`, for the system layer that `ctx`
  renders: `{:ok, seal}` for the person's own interactive client when one
  is set, and `:none` otherwise, for every other context (the module doc)
  and when the store cannot answer.
  """
  @spec for_system_layer(Context.t()) :: {:ok, t()} | :none
  def for_system_layer(%Context{} = ctx) do
    with :ok <- interactive(ctx),
         {:ok, row} <- PersonSeals.get(Context.actor(ctx), ctx.user_id) do
      {:ok, seal(row)}
    else
      _none -> :none
    end
  end

  def for_system_layer(_ctx), do: :none

  @doc """
  Set the first seal of the person behind `ctx` to `attrs` (`text:`, and
  optionally `glyph:`), from their own interactive client, while none is
  set.
  """
  @spec choose(Context.t(), map()) :: {:ok, t()} | {:error, refusal()}
  def choose(%Context{} = ctx, attrs) when is_map(attrs) do
    with :ok <- interactive(ctx),
         {:ok, fields} <- fields(attrs),
         :ok <- Catalog.undeclared_write_admission() do
      ctx
      |> Context.actor()
      |> PersonSeals.choose(ctx.user_id, fields)
      |> written()
    end
  end

  def choose(_ctx, _attrs), do: {:error, :refused}

  @doc """
  Replace the seal of the person behind `ctx` with `attrs`, as `choose/2`
  takes them, from their own interactive client, under a fresh
  `seal_change` confirmation: answered its signal until a proof is given
  and the change repeated with its secret (`ctx.confirmation_id`).
  """
  @spec change(Context.t(), map()) ::
          {:ok, t()} | {:error, refusal() | Authz.refusal() | {:confirmation_required, map()}}
  def change(%Context{} = ctx, attrs) when is_map(attrs) do
    with :ok <- interactive(ctx),
         {:ok, fields} <- fields(attrs),
         :ok <- set(ctx),
         :ok <- Catalog.undeclared_write_admission(),
         change = %{operation: @operation, arguments: arguments(fields)},
         :ok <- Authz.check(ctx, :seal_change, change) do
      also = fn -> Authz.consume(ctx, {:seal_change, change}) end

      case PersonSeals.change(Context.actor(ctx), ctx.user_id, fields, also: also) do
        {:ok, row} ->
          Authz.consumed(ctx)
          {:ok, seal(row)}

        refused ->
          written(refused)
      end
    end
  end

  def change(_ctx, _attrs), do: {:error, :refused}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # The person's own interactive client: a browser session holding no key,
  # client or frame, or a paired device whose client stands, admitted on
  # the interactive path.
  defp interactive(
         %Context{
           plane: :external,
           authenticated: true,
           anonymous: false,
           origin: :interactive,
           frame: nil,
           api_key_id: nil
         } = ctx
       ) do
    if Prima.PersonId.person?(ctx.user_id) and client?(ctx), do: :ok, else: {:error, :refused}
  end

  defp interactive(%Context{}), do: {:error, :refused}

  defp client?(%Context{auth_method: :oidc, client_id: nil, session_token_hash: hash}),
    do: is_binary(hash) and hash != ""

  defp client?(%Context{auth_method: :device, client_id: client_id} = ctx)
       when is_binary(client_id),
       do: DeviceCerts.client_standing(ctx) == :ok

  defp client?(%Context{}), do: false

  # A change needs a seal to replace, read before any confirmation opens.
  defp set(ctx) do
    case PersonSeals.get(Context.actor(ctx), ctx.user_id) do
      {:ok, _row} -> :ok
      {:error, :not_found} -> {:error, :not_set}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp fields(attrs) do
    text = field(attrs, :text)
    glyph = field(attrs, :glyph)

    if text?(text) and glyph?(glyph),
      do: {:ok, %{text: text, glyph: glyph}},
      else: {:error, :invalid_seal}
  end

  defp field(attrs, key) do
    case Map.get(attrs, key) do
      "" -> nil
      value -> value
    end
  end

  defp text?(text) when is_binary(text) do
    case String.split(text, " ") do
      [word] -> word in @words
      [first, second] -> first != second and first in @words and second in @words
      _other -> false
    end
  end

  defp text?(_text), do: false

  defp glyph?(nil), do: true
  defp glyph?(glyph), do: glyph in @glyphs

  defp arguments(%{text: text, glyph: glyph}), do: %{"text" => text, "glyph" => glyph}

  defp seal(%{text: text, glyph: glyph, set_at: set_at}),
    do: %__MODULE__{text: text, glyph: glyph, set_at: set_at}

  defp written({:ok, row}), do: {:ok, seal(row)}
  defp written({:error, reason}) when reason in [:already_set, :not_set], do: {:error, reason}
  defp written({:error, :cross_tenant}), do: {:error, :refused}
  defp written({:error, {:invalid, _errors}}), do: {:error, :invalid_seal}

  defp written({:error, reason}) when reason in [:database_error, :not_owner],
    do: {:error, :unavailable}

  # A confirmation's own refusal, from the consumption the change ran.
  defp written({:error, reason}), do: {:error, reason}
end
