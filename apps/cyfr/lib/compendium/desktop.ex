# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Desktop do
  @moduledoc """
  What a desktop (a tincture with the `tincture.desktop` block) asks of
  the component domain while the shell runs it: the call a declared
  control makes when the person presses it, and the person's preferences
  document for one of their canvases.

  ## Controls

  `control/4` reads a press of control `id`, with the value it picked, as
  the operation it runs and the arguments it runs with, or refuses it.
  The control must be one the served version's declaration carries,
  direct-eligible by the rule publish holds every control to
  (`Compendium.Tincture.Rules.check_desktop/2`, read again here against
  today's operation table, so a declaration that somehow carries another
  is refused at the press too), and, when it has a pick, pressed with a
  value the picked stream publishes now: the stream's current state is
  read at the press, under the caller's context and only once the gate
  admits the caller to open that stream (`Sanctum.Catalog.authorize_stream/2`),
  and the value must be one of the strings at the pick's field in it. A
  value is never substituted, and a control without a pick takes none.
  Which resource the operation reaches, and whether the caller owns it,
  is the gate's to decide when the caller runs the call; nothing is run
  here.

  ## Preferences

  The document is `Prima.CanvasPrefs`', kept by `Arca.CanvasPrefs`: one
  per person and canvas id in the athanor. `prefs/3` reads the caller's
  own for a canvas, reduced to what the version's schema declares now;
  `put_prefs/5` writes the caller's own over the revision the caller
  read, validated against the schema, and answers a stale revision with
  the current document. Only the caller's own document is ever read or
  written: the person is the context's, never an argument.
  """

  alias Prima.Manifest.Tincture
  alias Sanctum.Context

  @typedoc "A control's call: the operation as a tool path (`tool/action`) and its arguments."
  @type call :: {String.t(), map()}

  @typedoc "A preferences document and the revision it is stored at."
  @type stored_prefs :: %{document: map(), revision: non_neg_integer()}

  # ---- controls --------------------------------------------------------------

  @doc """
  The call control `id` of `desktop` makes when pressed with `value`
  (nil for none), or the refusal: `{:invalid_argument, sentence}` for a
  control the desktop does not declare or that is not direct-eligible,
  a value a control without a pick was handed, a picked control pressed
  with none, or a value the stream does not publish now; a refusal of
  the stream's open as the gate answers it; and `{:unavailable, what}`
  when its current state cannot be read.
  """
  @spec control(Context.t(), Tincture.Desktop.t() | nil, String.t(), String.t() | nil) ::
          {:ok, call()} | {:error, term()}
  def control(%Context{} = ctx, %Tincture.Desktop{} = desktop, id, value) do
    with {:ok, control} <- declared(desktop, id),
         :ok <- direct(desktop, control),
         {:ok, args} <- arguments(ctx, control, value) do
      {:ok, {String.replace(control.operation, ".", "/", global: false), args}}
    end
  end

  def control(%Context{}, _not_a_desktop, _id, _value),
    do: {:error, {:invalid_argument, "This page declares no controls."}}

  defp declared(desktop, id) do
    case Enum.find(desktop.controls, &(&1.id == id)) do
      %Tincture.Control{} = control -> {:ok, control}
      nil -> {:error, {:invalid_argument, "This desktop declares no control #{id}."}}
    end
  end

  # The rule publish holds the control to, read against today's table.
  defp direct(desktop, control) do
    declaration = %Tincture{desktop: %{desktop | controls: [control]}}

    case Compendium.tincture_check_desktop(declaration, Sanctum.Catalog.streams()) do
      :ok -> :ok
      {:error, {:invalid_tincture, sentence}} -> {:error, {:invalid_argument, sentence}}
    end
  end

  defp arguments(_ctx, %Tincture.Control{pick: nil, args: args}, nil), do: {:ok, args}

  defp arguments(_ctx, %Tincture.Control{pick: nil, id: id}, _value),
    do: {:error, {:invalid_argument, "Control #{id} takes no value."}}

  defp arguments(_ctx, %Tincture.Control{id: id}, nil),
    do: {:error, {:invalid_argument, "Control #{id} is pressed with a value it picks."}}

  defp arguments(ctx, %Tincture.Control{pick: pick, args: args, id: id}, value) do
    with {:ok, published} <- published(ctx, pick) do
      if value in published,
        do: {:ok, Map.put(args, pick.arg, value)},
        else:
          {:error,
           {:invalid_argument,
            "Control #{id} was pressed with a value #{pick.stream} does not publish now."}}
    end
  end

  # The strings the pick's field holds across the stream's current state,
  # read as the stream's refresh reads it for a subscriber: each item
  # projected to the stream's fields and, for a filtering stream, only
  # those its subject selects.
  defp published(ctx, %Tincture.Pick{stream: name, subject: subject, field: field}) do
    with :ok <- authorized(name, ctx),
         {:ok, stream} <- refreshing(name),
         {:ok, items} <- current(stream, ctx, subject),
         {:ok, segments} <- Tincture.pointer_segments(field) do
      {:ok,
       items
       |> Enum.map(&project(stream, &1))
       |> Enum.filter(&selected?(stream, subject, &1))
       |> Enum.flat_map(&strings_at(&1, segments))
       |> Enum.uniq()}
    else
      :error -> {:error, {:unavailable, "The stream's current state"}}
      {:error, _} = refused -> refused
    end
  end

  defp authorized(name, ctx) do
    case Sanctum.Catalog.authorize_stream(name, ctx) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp refreshing(name) do
    case Sanctum.Catalog.lookup_stream(name) do
      {:ok, {_provider, %Prima.Provider.Stream{refresh: {_m, _f}} = stream}} -> {:ok, stream}
      _none -> :error
    end
  end

  defp current(%Prima.Provider.Stream{refresh: {module, function}}, ctx, subject) do
    case apply(module, function, [ctx, subject]) do
      {:ok, items} when is_list(items) -> {:ok, items}
      _unread -> :error
    end
  end

  defp project(%Prima.Provider.Stream{projection: fields}, item) when is_map(item) do
    for field <- fields, {:ok, value} <- [fetch(item, field)], into: %{}, do: {field, value}
  end

  defp project(_stream, _item), do: %{}

  # A struct payload is keyed by atoms the module already named, a plain
  # one by strings.
  defp fetch(item, field) do
    case Map.fetch(item, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(item, String.to_existing_atom(field))
    end
  rescue
    ArgumentError -> :error
  end

  defp selected?(%Prima.Provider.Stream{filter: nil}, _subject, _item), do: true

  defp selected?(%Prima.Provider.Stream{filter: filter}, subject, item),
    do: item[filter] == subject

  defp strings_at(value, []) when is_binary(value), do: [value]
  defp strings_at(values, []) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp strings_at(%{} = value, [segment | rest]), do: strings_at(Map.get(value, segment), rest)
  defp strings_at(_value, _segments), do: []

  # ---- preferences -----------------------------------------------------------

  @doc """
  The caller's preferences for their canvas `canvas_id`, reduced to what
  `desktop`'s schema declares (`Prima.CanvasPrefs.project/2`), with the
  revision they are stored at: the empty document at revision 0 where
  none was written. A store that cannot answer is refused as it answers.
  """
  @spec prefs(Context.t(), String.t(), Tincture.Desktop.t()) ::
          {:ok, stored_prefs()} | {:error, term()}
  def prefs(%Context{user_id: user_id} = ctx, canvas_id, %Tincture.Desktop{prefs: schema}) do
    case Arca.CanvasPrefs.get(Context.actor(ctx), user_id, canvas_id) do
      {:ok, %{document: document, revision: revision}} ->
        {:ok, %{document: Prima.CanvasPrefs.project(document, schema), revision: revision}}

      {:error, :not_found} ->
        {:ok, %{document: Prima.CanvasPrefs.empty(), revision: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Write `incoming` into the caller's preferences for their canvas
  `canvas_id` over `revision`, the revision the caller holds:
  `{:ok, stored}` once written; `{:error, {:stale, stored}}` with the
  current document when another write came first, nothing merged;
  `{:error, {:invalid_argument, sentence}}` for a document the schema
  refuses or one past the cap, nothing written; or the store's refusal.
  """
  @spec put_prefs(Context.t(), String.t(), Tincture.Desktop.t(), map(), non_neg_integer()) ::
          {:ok, stored_prefs()} | {:error, term()}
  def put_prefs(
        %Context{user_id: user_id} = ctx,
        canvas_id,
        %Tincture.Desktop{prefs: schema},
        incoming,
        revision
      )
      when is_map(incoming) and is_integer(revision) and revision >= 0 do
    actor = Context.actor(ctx)

    case Arca.CanvasPrefs.write(actor, user_id, canvas_id, incoming, schema, revision) do
      {:ok, %{document: document, revision: written}} ->
        {:ok, %{document: document, revision: written}}

      {:error, {:stale, %{document: document, revision: current}}} ->
        {:error, {:stale, %{document: document, revision: current}}}

      {:error, {:invalid, sentence}} ->
        {:error, {:invalid_argument, sentence}}

      {:error, :too_large} ->
        {:error,
         {:invalid_argument,
          "The preferences are over #{Prima.CanvasPrefs.max_bytes()} bytes; nothing was written."}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
