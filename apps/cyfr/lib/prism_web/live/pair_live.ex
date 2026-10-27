# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PairLive do
  @moduledoc """
  `/pair`: the glass's own page at this home, sessionless.

  Opened with no fragment by a glass that holds no device, the page's
  script (`assets/js/system_layer/`, `data-glass="pair"`) makes the
  glass's key pair first, non-extractable and kept across reloads
  (`device_key.js`), before any invitation exists, and sends this view
  the key's digest (`prepared`), which the page shows as the key's code
  (`Prima.Device.key_code/1`) and a QR code of it: the person types it on
  a client of theirs, where `pairing.begin` opens an invitation for that
  key alone.

  The invitation's link opens the page again with its secret in the URL's
  fragment (`#code=…`, `pairing.begin`'s `invitation_url`), which a
  browser never sends: the script reads it, clears it from the address,
  and completes the pairing with the key it made, in two steps through
  this view: `pair_start` with the secret, the device key and its digest,
  answered with the `pair` challenge to sign, then `pair_proof` with the
  signature, answered with the paired client's id and its first
  certificate. The script then connects the device channel under that
  certificate. A code opened on a browser that made no key, or another
  key, pairs nothing: the invitation names the key it is for.

  A person whose identity is at another home pairs under the certificate
  their own home issues. Their first `pair_start`, with no certificate, is
  answered beside the challenge `certify: {audience, athanor,
  client_id}`, what their home is to certify. The script keeps the code
  and the key pair for at most the invitation's five minutes, asks for
  their home's address, and goes there (`<home>/carry#certify=…`), where
  they confirm the certification; their home sends the browser back here
  with the certificate in the fragment (`/pair#certificate=…`), and both
  steps are made again with it.

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
  first when the certificate has expired: at this home for a certificate
  it issued, and at the person's own home for one that home issued. The script draws the glass's
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
     |> assign(:key, nil)
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

  # The key the glass made before any invitation: its code, to type on a
  # client of the person's, and a QR code of it. A digest this page cannot
  # read draws nothing.
  @impl true
  def handle_event("prepared", %{"key_digest" => key_digest}, socket) do
    if Prima.Device.key_digest?(key_digest) do
      code = Prima.Device.key_code(key_digest)

      svg =
        case PrismWeb.QR.svg(code, label: "This device's code", class: "h-48 w-48") do
          {:ok, svg} -> svg
          {:error, :too_long} -> nil
        end

      {:reply, %{}, assign(socket, :key, %{code: code, svg: svg})}
    else
      {:reply, %{error: "This device's key could not be read."}, assign(socket, :key, nil)}
    end
  end

  def handle_event(
        "pair_start",
        %{"invitation_secret" => secret, "device_key" => device_key, "key_digest" => digest} =
          params,
        socket
      )
      when is_binary(secret) and is_binary(device_key) and is_binary(digest) do
    complete(
      socket,
      certified(params, %{
        "invitation_secret" => secret,
        "device_key" => device_key,
        "key_digest" => digest
      })
    )
  end

  def handle_event(
        "pair_proof",
        %{
          "invitation_secret" => secret,
          "device_key" => device_key,
          "key_digest" => digest,
          "proof" => proof
        } = params,
        socket
      )
      when is_binary(secret) and is_binary(device_key) and is_binary(digest) and is_map(proof) do
    complete(
      socket,
      certified(params, %{
        "invitation_secret" => secret,
        "device_key" => device_key,
        "key_digest" => digest,
        "proof" => proof
      })
    )
  end

  # A person whose identity is at another home pairs under the certificate
  # their own home issued for this device, which the glass brings with both
  # steps; anyone else's pairing carries none.
  defp certified(%{"certificate" => certificate}, args) when is_map(certificate),
    do: Map.put(args, "certificate", certificate)

  defp certified(_params, args), do: args

  defp complete(socket, args) do
    case PrismWeb.Ops.call_tool(socket.assigns.context, "pairing/complete", args) do
      # A remote person's glass with no certificate yet is told what their
      # own home is to certify beside the challenge.
      {:ok, %{challenge: _challenge} = answer} ->
        {:reply, Map.take(answer, [:challenge, :certify]), assign(socket, :error, nil)}

      {:ok, %{client_id: client_id, certificate: certificate}} ->
        {:reply, %{client_id: client_id, certificate: certificate},
         assign(socket, paired: true, key: nil, error: nil)}

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
        This device makes a key of its own that never leaves it, and connects under the
        certificate this CYFR issues for that key. Approve its code on a device of yours signed
        in to this CYFR, then open the pairing link that device shows here.
      </p>

      <section :if={@key && !@paired} class="space-y-2" data-test="pair-key">
        <p class="text-sm">
          Type this code under Pair a device on a device of yours signed in to this CYFR:
        </p>
        <p class="font-mono text-lg" data-test="pair-key-code">{@key.code}</p>
        <div :if={@key.svg} class="w-fit rounded bg-white p-2" data-test="pair-key-qr">
          {Phoenix.HTML.raw(@key.svg)}
        </div>
      </section>

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
