# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.Components do
  @moduledoc """
  The component-facts port for a suite with no component domain.

  The host installs `Compendium.ConsentFacts` at its boot. This suite
  boots Arca and Sanctum alone, and an uninstalled port raises where an
  athanor is filled (`Sanctum.Consent.Components.fill/3`), which every
  sign-in asks for. So the suite installs this one when nothing is
  installed: it answers every fact unavailable, as an uninstalled port
  answers them, and fills nothing.
  """

  @behaviour Sanctum.Consent.Components

  @doc "Install this port unless a boot already installed one."
  @spec install!() :: :ok
  def install! do
    Sanctum.Consent.Components.impl!()
    :ok
  rescue
    Sanctum.Consent.Components.NotInstalledError ->
      Sanctum.Consent.Components.install!(__MODULE__)
      :ok
  end

  @impl true
  def resolve(_ctx, _component), do: unavailable()
  @impl true
  def resolve_verified(_ctx, _component), do: unavailable()
  @impl true
  def get_component(_ctx, _name, _version, _publisher, _type), do: unavailable()
  @impl true
  def agent_rows(_ctx), do: unavailable()
  @impl true
  def shipped_nodes(_ctx, _rows), do: unavailable()
  @impl true
  def newer_shipped(_ctx, _row), do: unavailable()
  @impl true
  def tincture_placement(_ctx, _row), do: unavailable()

  @impl true
  def fill(_athanor, _ctx, "provision"), do: {:error, :unavailable}
  def fill(_athanor, _ctx, _entry_kind), do: :ok

  defp unavailable, do: {:error, :component_facts_unavailable}
end
