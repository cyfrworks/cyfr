# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Arrangement do
  @moduledoc """
  The person's gestures on their screen, as data, and what each makes of
  their layout (`Prima.Layout`): one canvas's apps in one posture moved,
  resized, tiled, made full, minimised, restored, raised, closed or
  opened. A plain function of a document; it reads and writes no store.

  A gesture names an app by its versionless tincture reference:

    * `{:move, ref, geometry}` — the app stands as a window at `geometry`;
    * `{:resize, ref, geometry}` — a window takes `geometry`, and
      `{:resize, ref, share}` a tile takes `share` of the width;
    * `{:tile, ref, side, share}` — the app stands as a tile;
    * `{:full, ref}` — the app takes the whole area while it is shown;
    * `{:minimise, ref}`, `{:restore, ref}` — the app leaves the screen
      keeping its placement, and comes back raised;
    * `{:raise, ref}` — the app goes above every other;
    * `{:close, ref}` — the app leaves the canvas;
    * `{:open, ref, app}` — an app not placed is placed as `app` (`open/2`
      names a default), above every other; one placed and minimised is
      restored, and one shown is raised.

  `apply/4` answers the document with the gesture made, or a refusal: an
  app the canvas does not place (`:not_placed`), a placement gesture in
  the hand, where every app is full (`:hand`), a canvas the document does
  not have (`:no_canvas`), or a document the layout refuses
  (`{:invalid, sentence}`) — every bound is `Prima.Layout`'s, so a
  geometry, a share or a side outside it is refused there. A gesture
  renumbers the posture's apps `0..n-1` in stacking order, the app it
  raises or opens last, so `order` never grows past the apps placed.
  Each gesture states where the app ends up, so making one twice gives
  the document making it once does; a close made again is refused, its
  app already gone.
  """

  alias Prima.Layout

  @default_tile_share 3000
  @window %{w: 4000, h: 6000}
  @cascade 300

  @typedoc "A gesture on one app."
  @type t ::
          {:move, Layout.ref(), Layout.geometry()}
          | {:resize, Layout.ref(), Layout.geometry() | pos_integer()}
          | {:tile, Layout.ref(), Layout.side(), pos_integer()}
          | {:full, Layout.ref()}
          | {:minimise, Layout.ref()}
          | {:restore, Layout.ref()}
          | {:raise, Layout.ref()}
          | {:close, Layout.ref()}
          | {:open, Layout.ref(), Layout.app()}

  @typedoc "Why a gesture was refused."
  @type refusal :: :not_placed | :hand | :no_canvas | {:invalid, String.t()}

  @doc "The app a gesture names."
  @spec ref(t()) :: Layout.ref()
  def ref(gesture), do: elem(gesture, 1)

  @doc """
  The document with `gesture` made on canvas `canvas_id` in `posture`, or
  why not. The document a refusal leaves is the one given.
  """
  @spec apply(Layout.t(), String.t(), Layout.posture_name(), t()) ::
          {:ok, Layout.t()} | {:error, refusal()}
  def apply(%Layout{} = layout, canvas_id, posture, gesture) do
    with {:ok, canvas} <- canvas(layout, canvas_id),
         :ok <- posture_allows(posture, gesture),
         apps = get_in(canvas, [:postures, posture, :apps]) || [],
         {:ok, apps} <- made(apps, gesture) do
      canvas = put_in(canvas, [:postures, posture], %{apps: renumber(apps, gesture)})

      checked(%{
        layout
        | canvases: Enum.map(layout.canvases, &if(&1.id == canvas_id, do: canvas, else: &1))
      })
    end
  end

  @doc """
  The app a canvas opens `ref` as when the layout does not place it yet:
  full in the hand; on the desk a tile at the edge the tincture's size
  hint prefers (`frame.size.tile`), or else a window cascaded from the
  apps already there. `placed` is how many apps the posture places.
  """
  @spec open(
          Layout.ref(),
          Prima.Manifest.Tincture.Size.t() | nil,
          Layout.posture_name(),
          non_neg_integer()
        ) ::
          Layout.app()
  def open(ref, _size, "hand", _placed), do: app(ref, :full, %{})

  def open(ref, %{tile: tile}, _desk, _placed) when tile in ["left", "right"],
    do: app(ref, :tile, %{side: String.to_existing_atom(tile), share: @default_tile_share})

  def open(ref, _size, _desk, placed) do
    step = rem(placed, 10) * @cascade
    app(ref, :window, %{geometry: Map.merge(@window, %{x: 1000 + step, y: 800 + step})})
  end

  # ---- the gestures ----------------------------------------------------------

  defp made(apps, {:open, ref, app}) do
    case find(apps, ref) do
      nil -> {:ok, apps ++ [app]}
      _placed -> {:ok, update(apps, ref, &%{&1 | minimised: false})}
    end
  end

  defp made(apps, gesture) do
    ref = ref(gesture)

    case find(apps, ref) do
      nil -> {:error, :not_placed}
      _placed -> {:ok, gestured(apps, ref, gesture)}
    end
  end

  defp gestured(apps, ref, {:close, _}), do: Enum.reject(apps, &(&1.tincture == ref))

  defp gestured(apps, ref, gesture), do: update(apps, ref, &stand(&1, gesture))

  defp stand(app, {:move, _, geometry}), do: placed(app, :window, %{geometry: geometry})

  defp stand(%{placement: :window} = app, {:resize, _, %{} = geometry}),
    do: placed(app, :window, %{geometry: geometry})

  defp stand(%{placement: :tile} = app, {:resize, _, share}) when is_integer(share),
    do: placed(app, :tile, %{side: app.side, share: share})

  defp stand(app, {:resize, _, _size}), do: app
  defp stand(app, {:tile, _, side, share}), do: placed(app, :tile, %{side: side, share: share})
  defp stand(app, {:full, _}), do: placed(app, :full, %{})
  defp stand(app, {:minimise, _}), do: %{app | minimised: true}
  defp stand(app, {:restore, _}), do: %{app | minimised: false}
  defp stand(app, {:raise, _}), do: app

  defp placed(app, placement, fields),
    do:
      Map.merge(app(app.tincture, placement, fields), %{
        order: app.order,
        minimised: app.minimised
      })

  defp app(ref, placement, fields) do
    Map.merge(
      %{
        tincture: ref,
        placement: placement,
        order: 0,
        geometry: nil,
        side: nil,
        share: nil,
        minimised: false
      },
      fields
    )
  end

  # The posture's apps in stacking order, `0..n-1`: an app raised, restored
  # or opened goes last; a gesture that raises nothing keeps the order.
  defp renumber(apps, gesture) do
    {top, rest} =
      apps
      |> Enum.sort_by(&{&1.order, &1.tincture})
      |> Enum.split_with(&(raises?(gesture) and &1.tincture == ref(gesture)))

    (rest ++ top)
    |> Enum.with_index()
    |> Enum.map(fn {app, index} -> %{app | order: index} end)
  end

  defp raises?({kind, _}) when kind in [:raise, :restore], do: true
  defp raises?({:open, _, _}), do: true
  defp raises?(_gesture), do: false

  # In the hand every app is full: there is nothing to move, size or tile.
  defp posture_allows("hand", {kind, _, _}) when kind in [:move, :resize], do: {:error, :hand}
  defp posture_allows("hand", {:tile, _, _, _}), do: {:error, :hand}
  defp posture_allows("hand", {:full, _}), do: {:error, :hand}
  defp posture_allows(_posture, _gesture), do: :ok

  defp canvas(%Layout{canvases: canvases}, canvas_id) do
    case Enum.find(canvases, &(&1.id == canvas_id)) do
      nil -> {:error, :no_canvas}
      canvas -> {:ok, canvas}
    end
  end

  # The document held to the layout's shape and bounds, as the layout tool
  # will hold it.
  defp checked(layout) do
    case Layout.validate(Layout.to_json(layout)) do
      {:ok, layout} -> {:ok, layout}
      {:error, {:invalid_layout, sentence}} -> {:error, {:invalid, sentence}}
    end
  end

  defp find(apps, ref), do: Enum.find(apps, &(&1.tincture == ref))

  defp update(apps, ref, fun),
    do: Enum.map(apps, &if(&1.tincture == ref, do: fun.(&1), else: &1))
end
