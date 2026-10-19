# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CliLive do
  @moduledoc """
  `/cli`: where a person approves a command line's sign-in
  (`Sanctum.CliSignIn`). `cyfr login` prints this page's address with the
  approval secret in the fragment's `code`, which a browser never sends;
  the page's script (`hooks/command_line.js`) reads it, clears it from
  the address at once, and hands it to the page.

  The page shows what the secret names, read from the pending sign-in
  (`Sanctum.CliSignIn.describe/1`): "Approve the command line on
  <machine>?" and the code that command line shows, for the person to
  check against their terminal. Nothing happens until they press
  Approve, which calls `session.cli_approve`. Approving is a sensitive
  change, so the page asks for its fresh confirmation through its system
  layer (`PrismWeb.SystemLayer.call/5`), whose preview names the machine
  and the code again, and repeats the approval once it is confirmed,
  wherever the person proved it. The secret stays in the page's process
  and is never rendered.

  It is session-only: a person not signed in here is sent through
  `/login`, whose script clears the fragment the redirect carried there,
  and opens the link again once signed in; the command line waits for
  the five minutes its sign-in lives.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.SystemLayer

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Approve a command line")
     |> assign(:active_nav, nil)
     # What the link names, once the script handed its secret over:
     # `:reading`, `:none` for an address that carried none, or the
     # pending sign-in as `Sanctum.CliSignIn.describe/1` read it.
     |> assign(:sign_in, :reading)
     |> assign(:secret, nil)
     |> assign(:waiting, false)
     |> assign(:notice, nil)}
  end

  # The fragment's `code`, or nil when the address carried none.
  @impl true
  def handle_event("cli_code", %{"code" => code}, socket) when is_binary(code) do
    case Sanctum.CliSignIn.describe(code) do
      {:ok, sign_in} ->
        {:noreply, assign(socket, sign_in: sign_in, secret: code, notice: nil)}

      {:error, :not_found} ->
        {:noreply, unknown(socket)}

      {:error, :unavailable} ->
        {:noreply,
         notice(
           socket,
           :error,
           "This home cannot read the sign-in right now; open the link again."
         )}
    end
  end

  def handle_event("cli_code", _params, socket), do: {:noreply, assign(socket, :sign_in, :none)}

  def handle_event("approve", _params, %{assigns: %{secret: secret}} = socket)
      when is_binary(secret) do
    {:noreply, approve(socket, %{"approval_secret" => secret})}
  end

  def handle_event("approve", _params, socket), do: {:noreply, socket}

  # A change this page asked for was confirmed: asked again, once.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat(:cli_approve, _tool, args, socket),
    do: {:noreply, approve(socket, args)}

  # The approval's confirmation ended unconfirmed (cancelled, put away,
  # voided or expired) while this page waited on it: the layer lets its
  # secret go as it always does, and the sign-in, still pending, can be
  # approved again.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_report(id, outcome, %{assigns: %{waiting: true}} = socket)
      when outcome != :confirmed do
    {:ok, socket} = SystemLayer.reported(socket, {:system_layer, id, outcome})

    {:noreply,
     socket
     |> assign(:waiting, false)
     |> reread(socket.assigns.secret)
     |> notice(:error, unconfirmed(outcome))}
  end

  def system_layer_report(_id, _outcome, _socket), do: :pass

  defp unconfirmed({:refused, :expired}),
    do: "The confirmation expired before it was given. Approve again to ask for a new one."

  defp unconfirmed({:refused, :voided}),
    do: "The confirmation no longer stands. Approve again to ask for a new one."

  defp unconfirmed(_cancelled),
    do:
      "The confirmation was cancelled, so nothing was approved. Approve again to ask for a new one."

  @impl true
  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp approve(socket, args) do
    case SystemLayer.call(socket, :cli_approve, "session/cli_approve", args) do
      {:ok, _approved, socket} ->
        socket
        |> assign(:sign_in, %{socket.assigns.sign_in | status: "approved"})
        |> assign(secret: nil, waiting: false)
        |> notice(:info, "The command line is signed in. You can close this page.")

      {:asked, socket} ->
        assign(socket, :waiting, true)

      {:error, reason, socket} ->
        socket
        |> assign(:waiting, false)
        |> reread(args["approval_secret"])
        |> notice(:error, PrismWeb.Ops.error_message(reason))
    end
  end

  # What the link names now, after an approval was refused: expired, used
  # or withdrawn meanwhile, it offers no approval any more.
  defp reread(socket, nil), do: socket

  defp reread(socket, secret) do
    case Sanctum.CliSignIn.describe(secret) do
      {:ok, sign_in} -> assign(socket, :sign_in, sign_in)
      {:error, _unread} -> socket
    end
  end

  defp unknown(socket) do
    socket
    |> assign(sign_in: :none, secret: nil)
    |> notice(
      :error,
      "This link is not one this home knows, or it expired: run cyfr login again for a new one."
    )
  end

  defp notice(socket, kind, text), do: assign(socket, :notice, {kind, text})

  @impl true
  def render(assigns) do
    ~H"""
    <div id="command-line" phx-hook="CommandLine" class="max-w-2xl space-y-6">
      <.page_header title="Approve a command line" />

      <div
        :if={@notice}
        data-test="cli-notice"
        role={if elem(@notice, 0) == :error, do: "alert", else: "status"}
        class={[
          "rounded-lg px-4 py-3 text-sm border",
          if(elem(@notice, 0) == :error,
            do: "bg-red-900/50 border-red-800 text-red-300",
            else: "bg-gray-800 border-gray-700 text-gray-200"
          )
        ]}
      >
        {elem(@notice, 1)}
      </div>

      <%= case @sign_in do %>
        <% :reading -> %>
          <p class="text-sm text-gray-300" data-test="cli-reading">Reading the link.</p>
        <% :none -> %>
          <p :if={is_nil(@notice)} class="text-sm text-gray-300" data-test="cli-none">
            Open the link <span class="font-mono">cyfr login</span>
            printed, on this device or another, to approve that command line here.
          </p>
        <% sign_in -> %>
          <div
            class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 space-y-3"
            data-test="cli-sign-in"
            data-status={sign_in.status}
          >
            <p class="text-sm text-gray-200">
              Approve the command line on <span class="font-mono" data-test="cli-machine">{sign_in.machine}</span>?
            </p>
            <p class="text-sm text-gray-200">
              Check that it shows this code:
              <span class="font-mono text-lg text-white" data-test="cli-code">{sign_in.user_code}</span>
            </p>
            <p class="text-xs text-gray-400">{status_line(sign_in)}</p>
            <div :if={sign_in.status == "pending"} class="flex justify-end">
              <.button phx-click="approve" disabled={@waiting} data-test="cli-approve">
                {if @waiting, do: "Waiting for your confirmation", else: "Approve"}
              </.button>
            </div>
          </div>
      <% end %>
    </div>

    <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    """
  end

  defp status_line(%{status: "pending", expires_at: at}),
    do:
      "Only if the code matches. Approving signs that command line in as you until you revoke it under Devices. " <>
        "The link expires at #{Calendar.strftime(at, "%H:%M UTC")}."

  defp status_line(%{status: "approved"}), do: "This command line is signed in."

  defp status_line(%{status: "expired"}),
    do: "This link expired before it was approved: run cyfr login again."

  defp status_line(%{status: "cancelled"}),
    do: "The command line stopped waiting: run cyfr login again."
end
