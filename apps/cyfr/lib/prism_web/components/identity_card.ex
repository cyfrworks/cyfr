# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.IdentityCard do
  @moduledoc """
  The person's name and their account's identifier in Settings
  (`PrismWeb.SettingsLive`): the name this CYFR recorded for them and the
  identifier the command line names them by. Their account, its keys and
  its recovery code are the account pages', never this CYFR's.

  Its controls carry `data-test` names: `identity`, `identity-name` and
  `identity-identifier`.
  """

  use Phoenix.Component

  attr :name, :string, default: nil
  attr :identifier, :string, default: nil

  @doc "The card."
  def card(assigns) do
    ~H"""
    <section data-test="identity" class="space-y-2">
      <h3 class="text-sm font-medium text-gray-400">Your name</h3>
      <p :if={@name} data-test="identity-name" class="text-lg text-white">@{@name}</p>
      <p :if={@identifier} class="text-xs text-gray-500">
        Your account's identifier:
        <span data-test="identity-identifier" class="font-mono break-all text-gray-300">
          {@identifier}
        </span>
      </p>
    </section>
    """
  end
end
