# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Fallback do
  @moduledoc """
  The fallback: the shipped canvas (`tincture:local.canvas`) shown in the
  place of a canvas of the person's that did not start or stopped, while
  every window, tile and the assistant stay as they are. Plain data and
  functions; it holds no process and stops nothing itself.

  It stands for one canvas of the layout (`enter/2`): the canvas's id, the
  tincture the layout names for it, and the version its versions document
  keeps (`kept`, read from `Compendium.canvas_versions/2` as the fallback
  begins, or nil). Its reasons:

    * `:not_ready` — the canvas did not send `ready` in time, failed before
      it, or could not be opened;
    * `:gone` — its frame died: the page loaded a second time;
    * `:not_validated` — its new version did not start, and it has no
      earlier version to show.

  Its offers (`offers/1`), on the one line the system layer draws:

    * `:retry` — open the canvas again, as it now stands;
    * `:kept` — go back to the kept version, offered while there is one:
      `canvas.restore` of the canvas, under today's grant.

  `choose/2` answers what a choice asks for: `:retry`, or `{:restore,
  name}` (the canvas's component name, which `canvas.restore` takes).
  """

  @reasons [:not_ready, :gone, :not_validated]
  @shipped "tincture:local.canvas"

  @typedoc "Why the canvas fell back."
  @type reason :: :not_ready | :gone | :not_validated

  @typedoc "A way back to the person's canvas."
  @type offer :: :retry | :kept

  @typedoc "The canvas as the fallback begins."
  @type canvas :: %{
          required(:canvas) => String.t(),
          required(:tincture) => Prima.Layout.ref(),
          required(:kept) => String.t() | nil
        }

  @typedoc "An offer, and the version it would show where it names one."
  @type offered :: %{offer: offer(), version: String.t() | nil}

  @typedoc "The fallback: the reason, and the canvas, its tincture and its kept version."
  @type t :: %__MODULE__{
          reason: reason(),
          canvas: String.t(),
          tincture: Prima.Layout.ref(),
          kept: String.t() | nil
        }

  @enforce_keys [:reason, :canvas, :tincture, :kept]
  defstruct [:reason, :canvas, :tincture, :kept]

  @doc "The shipped canvas the fallback shows."
  @spec shipped_canvas() :: Prima.Layout.ref()
  def shipped_canvas, do: @shipped

  @doc """
  The fallback for `reason` over a canvas: its `canvas` id, the `tincture`
  the layout names for it and its `kept` version, nil where there is none.
  """
  @spec enter(reason(), canvas()) :: t()
  def enter(reason, %{canvas: canvas, tincture: tincture, kept: kept})
      when reason in @reasons and is_binary(canvas) and is_binary(tincture) and
             (is_nil(kept) or is_binary(kept)) do
    %__MODULE__{reason: reason, canvas: canvas, tincture: tincture, kept: kept}
  end

  @doc """
  The ways back, `:retry` first, then the kept version while the canvas
  keeps one.
  """
  @spec offers(t()) :: [offered()]
  def offers(%__MODULE__{} = fallback) do
    [%{offer: :retry, version: nil}] ++
      if(is_binary(fallback.kept) and is_binary(name(fallback)),
        do: [%{offer: :kept, version: fallback.kept}],
        else: []
      )
  end

  @doc """
  What choosing `offer` asks for: `:retry`, or `{:restore, name}`, the
  canvas's component name for `canvas.restore`. An offer `offers/1` does
  not make is `{:error, :not_offered}`.
  """
  @spec choose(t(), term()) :: :retry | {:restore, String.t()} | {:error, :not_offered}
  def choose(%__MODULE__{} = fallback, offer) do
    cond do
      not Enum.any?(offers(fallback), &(&1.offer == offer)) -> {:error, :not_offered}
      offer == :kept -> {:restore, name(fallback)}
      true -> :retry
    end
  end

  # A canvas is a local tincture, named by its component name.
  defp name(%__MODULE__{tincture: tincture}) do
    case Prima.ComponentRef.parse(tincture) do
      {:ok, %Prima.ComponentRef{type: "tincture", namespace: "local", name: name}} -> name
      _other -> nil
    end
  end
end
