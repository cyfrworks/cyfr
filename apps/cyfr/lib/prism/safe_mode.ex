# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.SafeMode do
  @moduledoc """
  Safe mode: what the system layer (`PrismWeb.SystemLayer`) offers when
  the person's visible canvas did not start, stopped, has no version to
  show, or they asked for it. Plain data and functions; it holds no
  process and stops nothing itself. Safe mode runs with no tincture at
  all.

  It is entered with its reason and the visible canvas (`enter/2`): the
  canvas's id in the layout, the tincture it runs, and the version its
  versions document keeps (`kept`, read from `Compendium.canvas_versions/2`
  as safe mode is entered, or nil). Its reasons (`reasons/0`):

    * `:not_ready` — the canvas did not send `ready` in time, or was
      refused at its open;
    * `:crashed` — the live canvas reported a failure;
    * `:not_validated` — its new version did not start, and it has no
      earlier version to show;
    * `:requested` — the person asked for it.

  Its ways out (`offers/1`):

    * `:retry` — show the canvas again, as it now stands;
    * `:kept` — go back to the kept version, offered while there is one:
      `canvas.restore` of the canvas, under today's grant;
    * `:shipped` — show the shipped canvas (`tincture:local.canvas`) on this
      glass, offered while a canvas is visible: no layout and no versions
      document is written.

  `choose/2` answers what a choice asks for: `:retry`, `{:restore, name}`
  (the canvas's component name, which `canvas.restore` takes) or
  `:shipped`.
  """

  @reasons [:not_ready, :crashed, :not_validated, :requested]
  @shipped "tincture:local.canvas"

  @typedoc "Why safe mode was entered."
  @type reason :: :not_ready | :crashed | :not_validated | :requested

  @typedoc "A way out of safe mode."
  @type offer :: :retry | :kept | :shipped

  @typedoc "The visible canvas as safe mode is entered over it."
  @type canvas :: %{
          required(:canvas) => String.t() | nil,
          required(:tincture) => Prima.Layout.ref() | nil,
          required(:kept) => String.t() | nil
        }

  @typedoc "An offer, and the version it would show where it names one."
  @type offered :: %{offer: offer(), version: String.t() | nil}

  @typedoc "Safe mode: the reason, and the visible canvas, its tincture and its kept version."
  @type t :: %__MODULE__{
          reason: reason(),
          canvas: String.t() | nil,
          tincture: Prima.Layout.ref() | nil,
          kept: String.t() | nil
        }

  @enforce_keys [:reason, :canvas, :tincture, :kept]
  defstruct [:reason, :canvas, :tincture, :kept]

  @doc "The reasons safe mode is entered for."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "The shipped canvas the `:shipped` offer shows."
  @spec shipped_canvas() :: Prima.Layout.ref()
  def shipped_canvas, do: @shipped

  @doc """
  Enter safe mode for `reason` over the visible canvas: its `canvas` id,
  the `tincture` it runs and its `kept` version, each nil where there is
  none.
  """
  @spec enter(reason(), canvas()) :: t()
  def enter(reason, %{canvas: canvas, tincture: tincture, kept: kept})
      when reason in @reasons and (is_nil(canvas) or is_binary(canvas)) and
             (is_nil(tincture) or is_binary(tincture)) and (is_nil(kept) or is_binary(kept)) do
    %__MODULE__{reason: reason, canvas: canvas, tincture: tincture, kept: kept}
  end

  @doc """
  The ways out, `:retry` first: the kept version while the canvas keeps
  one, and the shipped canvas while a canvas is visible.
  """
  @spec offers(t()) :: [offered()]
  def offers(%__MODULE__{} = safe_mode) do
    [%{offer: :retry, version: nil}] ++
      if(is_binary(safe_mode.kept) and is_binary(name(safe_mode)),
        do: [%{offer: :kept, version: safe_mode.kept}],
        else: []
      ) ++
      if(is_binary(safe_mode.canvas), do: [%{offer: :shipped, version: nil}], else: [])
  end

  @doc """
  What choosing `offer` asks for: `:retry`; `{:restore, name}`, the
  canvas's component name for `canvas.restore`; or `:shipped`. An offer
  `offers/1` does not make is `{:error, :not_offered}`.
  """
  @spec choose(t(), term()) :: :retry | {:restore, String.t()} | :shipped | {:error, :not_offered}
  def choose(%__MODULE__{} = safe_mode, offer) do
    if Enum.any?(offers(safe_mode), &(&1.offer == offer)),
      do: chosen(safe_mode, offer),
      else: {:error, :not_offered}
  end

  @doc "Whether `term` is safe mode."
  @spec active?(term()) :: boolean()
  def active?(%__MODULE__{reason: reason, canvas: canvas, tincture: tincture, kept: kept})
      when reason in @reasons,
      do:
        (is_nil(canvas) or is_binary(canvas)) and (is_nil(tincture) or is_binary(tincture)) and
          (is_nil(kept) or is_binary(kept))

  def active?(_other), do: false

  defp chosen(_safe_mode, :retry), do: :retry
  defp chosen(safe_mode, :kept), do: {:restore, name(safe_mode)}
  defp chosen(_safe_mode, :shipped), do: :shipped

  # A canvas is a local tincture, named by its component name.
  defp name(%__MODULE__{tincture: tincture}) when is_binary(tincture) do
    case Prima.ComponentRef.parse(tincture) do
      {:ok, %Prima.ComponentRef{type: "tincture", namespace: "local", name: name}} -> name
      _other -> nil
    end
  end

  defp name(_safe_mode), do: nil
end
