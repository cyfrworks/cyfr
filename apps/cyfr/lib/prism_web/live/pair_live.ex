# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PairLive do
  @moduledoc """
  `/pair`: where a pairing link opens in a browser, sessionless.

  A pairing link (`pairing.begin`'s `invitation_url`, `/pair#code=…`) is
  for a device that keeps its key under a local unlock: a command line
  (`cyfr login`, `cyfr pair`) or a box's own screen, which takes the link
  pasted or scanned and completes the pairing itself
  (`tests/fixtures/device_unlock.json`). A browser holds no such key: it
  signs in with a passkey here, or, for a person whose keys are at another
  CYFR, from that CYFR, and confirms with its passkey or its home's
  certified assertion. So this page pairs nothing and reads nothing: it
  says where the link goes. The code stays in the fragment, which the
  browser never sends.
  """

  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :page_title, "Pair a device"), layout: false}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-md space-y-4 p-6 text-gray-100">
      <h1 class="text-xl font-semibold">Pair a device</h1>
      <p class="text-sm text-gray-300" data-test="pair-elsewhere">
        This pairing link is for a CYFR command line or a box's own screen. Paste it into
        <span class="font-mono">cyfr login</span>
        or <span class="font-mono">cyfr pair</span>
        on that device, which keeps its key under its own PIN or passphrase.
      </p>
      <p class="text-sm text-gray-300">
        A browser needs no pairing: sign in to this CYFR with a passkey, or from your own
        CYFR if your identity is kept there.
      </p>
    </main>
    """
  end
end
