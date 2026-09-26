# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.SafeMode do
  @moduledoc """
  Safe mode: what the system layer (`PrismWeb.SystemLayer`) offers when a
  person's desktop did not start, stopped, or they asked for it. Plain
  data and functions; it holds no process and stops nothing itself.

  Safe mode is entered with the reason and the layout as it was read
  (`Compendium.layout/2`): the document and the revision it was read at.
  It offers two ways out (`offers/1`):

    * `:retry` — try the current desktop again, as the layout names it;
    * `:default` — the shipped default desktop (`tincture:local.desktop`),
      offered only while some posture runs another one.

  Layout references are versionless, so there is no earlier version of a
  desktop to offer.

  `choose/2` answers what a choice does: `:retry` asks for nothing to be
  written, `{:publish, document}` is the person's own document with each
  posture's desktop replaced by the default — slots and floating
  tinctures kept — to be published through `layout.edit` with the
  revision safe mode was entered at (`revision`). A layout published
  since that revision refuses the edit, and nothing is merged.
  """

  @reasons [:not_ready, :crashed, :requested]

  @typedoc "Why safe mode was entered."
  @type reason :: :not_ready | :crashed | :requested

  @typedoc "A way out of safe mode."
  @type offer :: :retry | :default

  @typedoc "The layout as it was read: its document and the revision read."
  @type layout :: %{
          required(:document) => Prima.Layout.t(),
          required(:revision) => non_neg_integer(),
          optional(atom()) => term()
        }

  @typedoc "An offer and the desktops it would run."
  @type offered :: %{offer: offer(), desktops: [Prima.Layout.ref()]}

  @typedoc "Safe mode: the reason, the document and the revision it was read at."
  @type t :: %__MODULE__{
          reason: reason(),
          document: Prima.Layout.t(),
          revision: non_neg_integer()
        }

  @enforce_keys [:reason, :document, :revision]
  defstruct [:reason, :document, :revision]

  @doc "The reasons safe mode is entered for."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  Enter safe mode for `reason` over `layout`, the read `Compendium.layout/2`
  answers (any map with the `document` and the `revision` read).
  """
  @spec enter(reason(), layout()) :: t()
  def enter(reason, %{document: %Prima.Layout{} = document, revision: revision})
      when reason in @reasons and is_integer(revision) and revision >= 0 do
    %__MODULE__{reason: reason, document: document, revision: revision}
  end

  @doc """
  The ways out, `:retry` first: the current desktops (every posture's,
  each once, sorted), and the shipped default while some posture runs
  another desktop.
  """
  @spec offers(t()) :: [offered()]
  def offers(%__MODULE__{} = safe_mode) do
    current = desktops(safe_mode.document)
    retry = %{offer: :retry, desktops: current}

    if Enum.all?(current, &(&1 == default_desktop())),
      do: [retry],
      else: [retry, %{offer: :default, desktops: [default_desktop()]}]
  end

  @doc """
  What choosing `offer` does: `:retry` writes nothing; `{:publish,
  document}` is the document to publish at `revision` through
  `layout.edit`. An offer `offers/1` does not make is
  `{:error, :not_offered}`.
  """
  @spec choose(t(), term()) :: :retry | {:publish, Prima.Layout.t()} | {:error, :not_offered}
  def choose(%__MODULE__{} = safe_mode, offer) do
    if Enum.any?(offers(safe_mode), &(&1.offer == offer)),
      do: chosen(safe_mode, offer),
      else: {:error, :not_offered}
  end

  @doc "Whether `term` is safe mode."
  @spec active?(term()) :: boolean()
  def active?(%__MODULE__{reason: reason, document: %Prima.Layout{}, revision: revision})
      when reason in @reasons and is_integer(revision) and revision >= 0,
      do: true

  def active?(_other), do: false

  @doc "The shipped default desktop every posture of the default layout runs."
  @spec default_desktop() :: Prima.Layout.ref()
  def default_desktop do
    {:ok, posture} = Prima.Layout.posture(Prima.Layout.default(), hd(Prima.Layout.postures()))
    posture.desktop
  end

  defp chosen(_safe_mode, :retry), do: :retry

  defp chosen(%__MODULE__{document: document}, :default) do
    default = default_desktop()

    postures =
      Map.new(document.postures, fn {name, posture} ->
        {name, %{posture | desktop: default}}
      end)

    {:publish, %{document | postures: postures}}
  end

  # Every posture reads as the document's own or the default's, so a
  # posture the document does not name runs the default desktop.
  defp desktops(%Prima.Layout{} = document) do
    Prima.Layout.postures()
    |> Enum.map(fn name ->
      {:ok, posture} = Prima.Layout.posture(document, name)
      posture.desktop
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
