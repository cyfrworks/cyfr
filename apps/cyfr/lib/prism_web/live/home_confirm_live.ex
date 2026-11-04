# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.HomeConfirmLive do
  @moduledoc """
  `/confirm`: where a person whose keys are at another home comes back
  from confirming a change of theirs at that home.

  Their pending confirmation here offered `home` (`confirmation.pending`):
  the confirmation panel carried its `at_home` to their own home's
  `/carry#confirm=…`, where a passkey or a device of theirs confirmed it
  and their home signed the certified assertion
  (`Prima.ConfirmationAssertion`). That home sends the browser here with
  the assertion in the fragment (`#home_assertion=…`), which a browser
  never sends; the page's script (`hooks/home_confirm.js`) reads it,
  clears it from the address at once, and hands it to the page, which
  confirms the record the assertion names through `confirmation.confirm`
  with `home_assertion`, under this session. This home checks it against
  the person's head read live from their directory
  (`Sanctum.RemoteCertification.verify_confirmation/3`); the client that
  asked repeats its change once the record is confirmed, as for any proof.

  It is session-only: a person not signed in here is sent through
  `/login`, which clears the fragment, and they confirm again from the
  request.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.SystemLayer

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Confirm from your CYFR")
     |> assign(:active_nav, nil)
     |> assign(:outcome, :waiting)}
  end

  @impl true
  def handle_event("home_assertion", %{"assertion" => text}, socket) when is_binary(text) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      {:noreply, assign(socket, :outcome, confirm(socket, text))}
    end)
  end

  def handle_event("home_assertion", _params, socket),
    do: {:noreply, assign(socket, :outcome, {:error, "This address carried no confirmation."})}

  defp confirm(socket, text) do
    with {:ok, text} <- Prima.Carry.bounded(text),
         {:ok, %{"ref" => ref} = assertion} when is_binary(ref) <-
           Prima.Carry.decode_object(text) do
      case PrismWeb.Ops.call_tool(socket, "confirmation/confirm", %{
             "ref" => ref,
             "home_assertion" => assertion
           }) do
        {:ok, _confirmed} -> :confirmed
        {:error, reason} -> {:error, PrismWeb.Ops.error_message(reason)}
      end
    else
      _unread -> {:error, "That confirmation could not be read; nothing was confirmed."}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="home-confirm" phx-hook="HomeConfirm" class="max-w-2xl space-y-6">
      <.page_header title="Confirm from your CYFR" />
      <p :if={@outcome == :waiting} class="text-sm text-gray-300" data-test="home-confirm-waiting">
        Reading your CYFR's answer…
      </p>
      <p :if={@outcome == :confirmed} role="status" class="text-sm" data-test="home-confirm-done">
        Confirmed. The page that asked for this change goes on with it.
      </p>
      <p
        :if={match?({:error, _}, @outcome)}
        role="alert"
        class="rounded border border-red-500 p-2 text-sm"
        data-test="home-confirm-error"
      >
        {elem(@outcome, 1)}
      </p>
    </div>

    <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    """
  end
end
