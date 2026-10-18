# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.FillWatch do
  @moduledoc """
  The component-facts port as the host installs it, with every fill of a
  watched athanor also told to the test watching it, as
  `{:fill_requested, athanor_id, entry_kind, in_transaction?}` — whether
  an Arca transaction was open in the process that asked.

  `watch!/1` installs it for the calling test and puts the host's port
  back when the test exits, so only a synchronous test may call it.
  """

  @behaviour Sanctum.Consent.Components

  alias Sanctum.Consent.Components

  @real {__MODULE__, :real}

  @doc "Tell the calling test of every fill `athanor_id` is asked for."
  @spec watch!(String.t()) :: :ok
  def watch!(athanor_id) when is_binary(athanor_id) do
    real = :persistent_term.get(@real, nil) || Components.impl!()
    test = self()

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({__MODULE__, athanor_id})
      Components.install!(real)
      :persistent_term.erase(@real)
    end)

    :persistent_term.put(@real, real)
    :persistent_term.put({__MODULE__, athanor_id}, test)
    Components.install!(__MODULE__)
    :ok
  end

  @impl true
  def fill(%{id: athanor_id} = athanor, ctx, entry_kind) do
    case :persistent_term.get({__MODULE__, athanor_id}, nil) do
      nil -> :ok
      test -> send(test, {:fill_requested, athanor_id, entry_kind, Arca.Repo.in_transaction?()})
    end

    real().fill(athanor, ctx, entry_kind)
  end

  @impl true
  def resolve(ctx, component), do: real().resolve(ctx, component)
  @impl true
  def resolve_verified(ctx, component), do: real().resolve_verified(ctx, component)
  @impl true
  def get_component(ctx, name, version, publisher, type),
    do: real().get_component(ctx, name, version, publisher, type)

  @impl true
  def agent_rows(ctx), do: real().agent_rows(ctx)
  @impl true
  def shipped_nodes(ctx, rows), do: real().shipped_nodes(ctx, rows)
  @impl true
  def newer_shipped(ctx, row), do: real().newer_shipped(ctx, row)
  @impl true
  def tincture_placement(ctx, row), do: real().tincture_placement(ctx, row)

  defp real, do: :persistent_term.get(@real)
end
