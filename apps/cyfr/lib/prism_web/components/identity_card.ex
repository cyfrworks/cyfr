# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.IdentityCard do
  @moduledoc """
  The person's name and their account's identifier in Settings
  (`PrismWeb.SettingsLive`): the name this CYFR recorded for them and the
  identifier the command line names them by. Their account, its keys and
  its recovery code are the account pages', never this CYFR's.

  A person this CYFR has recorded no name for finishes it here: they type
  the name their account holds, and the page records it once cyfr.run
  says it is theirs (`session.name`), or shows the refusal's sentence.

  Its controls carry `data-test` names: `identity`, `identity-name`,
  `identity-identifier`, `identity-name-form`, `identity-name-input` and
  `identity-name-error`.
  """

  use Phoenix.Component

  attr :name, :string, default: nil
  attr :identifier, :string, default: nil
  attr :error, :string, default: nil

  @doc "The card. Its form submits `identity_name` with `name` to the page."
  def card(assigns) do
    ~H"""
    <section data-test="identity" class="space-y-2">
      <h3 class="text-sm font-medium text-gray-400">Your name</h3>
      <p :if={@name} data-test="identity-name" class="text-lg text-white">@{@name}</p>
      <form
        :if={is_nil(@name)}
        phx-submit="identity_name"
        data-test="identity-name-form"
        class="space-y-2"
      >
        <p class="text-sm text-gray-300">
          Your name is not finished here yet. Type the name you chose for your account, and
          CYFR checks it with cyfr.run.
        </p>
        <div class="flex items-center gap-2">
          <span class="text-gray-400">@</span>
          <input
            type="text"
            name="name"
            autocomplete="off"
            spellcheck="false"
            data-test="identity-name-input"
            class="flex-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-1.5 text-sm text-white"
          />
          <button
            type="submit"
            phx-disable-with="Checking…"
            class="px-3 py-1.5 text-xs rounded bg-indigo-900 text-indigo-100 border border-indigo-700 hover:bg-indigo-800"
          >
            Finish your name
          </button>
        </div>
        <p :if={@error} role="alert" data-test="identity-name-error" class="text-sm text-red-300">
          {@error}
        </p>
      </form>
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
