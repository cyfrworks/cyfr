# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.Section do
  @moduledoc """
  What the AQUA page's sections share.

  Each section of the page (`PrismWeb.AquaLive`) is a `Phoenix.LiveComponent`
  that owns its reads and its writes: it loads itself when the page tells
  it to (`load: true` in `send_update/3`), reloads itself after a write
  that changes only what it shows, and asks the page for a wider refresh
  (`send(self(), {:refresh, section})`) when a write changes what another
  section shows — a restore, a role's provenance. What every section
  wears is here: the provenance chip a card and a scroll both carry, and
  the flash a section shows beside what it changed (a component's flash
  never reaches the page's, so each shows its own).
  """

  use Phoenix.Component

  attr :flash, :map, required: true
  attr :target, :any, required: true

  def section_flash(assigns) do
    ~H"""
    <div
      :for={kind <- [:info, :error]}
      :if={Phoenix.Flash.get(@flash, kind)}
      role="alert"
      class={[
        "flex items-start gap-3 rounded border px-3 py-2 text-xs",
        if(kind == :error,
          do: "border-red-900/60 bg-red-950/40 text-red-200",
          else: "border-emerald-900/60 bg-emerald-950/30 text-emerald-200"
        )
      ]}
    >
      <p class="flex-1">{Phoenix.Flash.get(@flash, kind)}</p>
      <button
        type="button"
        phx-click="dismiss_flash"
        phx-target={@target}
        class="shrink-0 opacity-70 hover:opacity-100"
        aria-label="Dismiss"
      >
        ×
      </button>
    </div>
    """
  end

  attr :state, :any, default: nil

  def provenance_chip(assigns) do
    assigns = assign(assigns, :chip, provenance_label(assigns.state))

    ~H"""
    <span
      :if={@chip}
      class={[
        "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium",
        elem(@chip, 1)
      ]}
    >
      {elem(@chip, 0)}
    </span>
    """
  end

  @doc "What a provenance state reads as on a card: `{label, classes}`, or nil."
  @spec provenance_label(term()) :: {String.t(), String.t()} | nil
  def provenance_label("bundled"), do: {"shipped", "bg-gray-800 text-gray-400"}
  def provenance_label("bundled_modified"), do: {"edited", "bg-amber-900/40 text-amber-300"}
  def provenance_label("user"), do: {"yours", "bg-emerald-900/40 text-emerald-300"}
  def provenance_label(_unknown), do: nil

  @doc "One owner for the aqua call and its key normalization."
  def call_aqua(ctx, args), do: Aqua.AgentConfig.call_aqua(ctx, args)
end
