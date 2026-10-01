# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PairLive do
  @moduledoc """
  `/pair`: the glass's own page at this home, sessionless.

  A pairing code opens it with the invitation's secret in the URL's
  fragment (`#code=…`, `pairing.begin`'s `invitation_url`), which a
  browser never sends: the page's script (`assets/js/system_layer/`,
  `data-glass="pair"`) reads it, clears it from the address, makes the
  glass's key pair, non-extractable and kept across reloads
  (`device_key.js`), and completes the pairing in two steps through this
  view: `pair_start` with the secret and the device key, answered with
  the `pair` challenge to sign, then `pair_proof` with the signature,
  answered with the paired client's id and its first certificate. The
  script then connects the device channel under that certificate.

  Each step is `pairing.complete` through `PrismWeb.Ops.call_tool/3`
  under a context this view builds itself (`Sanctum.Context.build/1`):
  no person, no athanor, no permissions, no auth method, not
  authenticated, as the anonymous surface's, and the caller's address
  from the socket's connect info, so a completion counts against its own
  source's bound. The view reads nothing from the browser's session, so a
  session cookie the browser still holds never chooses the person: the
  invitation names them.

  Opened again with no fragment, by a glass that holds its key and
  certificate, the page connects the device channel directly, renewing
  first when the certificate has expired. The script draws the glass's
  confirmation prompts itself, from `confirmation.pending` and the
  `confirmation.changes` stream read over the channel.

  A pairing whose answer never reached the glass — the browser closed
  between the proof and the answer — was issued once; the same code then
  answers that it was already used, and the person shows a new one.
  """

  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pair this device")
     |> assign(:context, unauthenticated(socket))
     |> assign(:paired, false)
     |> assign(:error, nil), layout: false}
  end

  # The anonymous surface's context, built here and never from a session:
  # who completes a pairing is the invitation's to say.
  defp unauthenticated(socket) do
    Sanctum.Context.build(
      user_id: nil,
      athanor_id: nil,
      permissions: [],
      scope: :athanor,
      auth_method: nil,
      authenticated: false,
      client_ip: PrismWeb.AuthHelpers.socket_client_ip(socket)
    )
  end

  @impl true
  def handle_event(
        "pair_start",
        %{"invitation_secret" => secret, "device_key" => device_key},
        socket
      )
      when is_binary(secret) and is_binary(device_key) do
    complete(socket, %{"invitation_secret" => secret, "device_key" => device_key})
  end

  def handle_event(
        "pair_proof",
        %{"invitation_secret" => secret, "device_key" => device_key, "proof" => proof},
        socket
      )
      when is_binary(secret) and is_binary(device_key) and is_map(proof) do
    complete(socket, %{
      "invitation_secret" => secret,
      "device_key" => device_key,
      "proof" => proof
    })
  end

  defp complete(socket, args) do
    case PrismWeb.Ops.call_tool(socket.assigns.context, "pairing/complete", args) do
      {:ok, %{challenge: challenge}} ->
        {:reply, %{challenge: challenge}, assign(socket, :error, nil)}

      {:ok, %{client_id: client_id, certificate: certificate}} ->
        {:reply, %{client_id: client_id, certificate: certificate},
         assign(socket, paired: true, error: nil)}

      {:error, reason} ->
        sentence = PrismWeb.Ops.error_message(reason)
        {:reply, %{error: sentence}, assign(socket, :error, sentence)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-md space-y-4 p-6 text-gray-100">
      <h1 class="text-xl font-semibold">Pair this device</h1>
      <p class="text-sm text-gray-300">
        This device pairs with this home under the code another of your devices showed. It
        keeps a key of its own that never leaves it, and connects under the certificate this
        home issues for that key.
      </p>

      <p :if={@paired} class="text-sm" data-test="pair-paired">
        This device is paired.
      </p>
      <p
        :if={@error}
        role="alert"
        class="rounded border border-red-500 p-2 text-sm"
        data-test="pair-error"
      >
        {@error}
      </p>

      <div id="glass" phx-hook="SystemLayer" data-glass="pair" phx-update="ignore">
        <p class="text-sm" data-test="glass-status" data-state="starting">Starting…</p>
        <noscript>
          <p class="text-sm">This page needs JavaScript to pair and connect this device.</p>
        </noscript>
      </div>
    </main>
    """
  end
end
