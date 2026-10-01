# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CarryLive do
  @moduledoc """
  `/carry`: the sign-in carry at the person's own home, their signing home
  (`ARCHITECTURE.md` §9.2), the same page at every home. A person whose
  keys this home holds signs in at another home, the destination, through
  that home's `cyfr` door; this page is where they begin it, confirm it and
  read how it ended. It is session-only: a person not signed in here is
  sent through `/login`, whose script keeps the carry's fragment until this
  page takes it (`hooks/carry.js`).

  The page's script reads the address's fragment and clears it, and hands
  the page one of three things:

    * **A destination** (`#destination=<home>`, from the destination's
      sign-in entry): it only fills the form. Nothing begins until the
      person presses Begin, which calls `person.carry_begin` for that one
      destination and hands the script the carry to take there
      (`<destination>/login#carry=<fragment>`) with the action and its
      `key_epoch`, which the script keeps as an action this tab began.
    * **A challenge** (the destination's, from its `/auth/cyfr` hop): it
      must name a pending action of the person's (`person.carry_list`)
      whose destination is the challenge's audience, or nothing happens. For
      an action this tab began, the page asks for the assertion at once
      (`person.assert`, under the action's own `key_epoch`); for any other,
      a resumed or a crafted one, it shows the action and a Continue first,
      and attaches nothing before the person's click. The assertion needs a
      fresh `remote_sign_in` confirmation, which the system layer asks for
      (`PrismWeb.SystemLayer.call/5`): its preview names the destination,
      that it learns this home's address, and the code the destination
      shows. Once confirmed, the page repeats the request and the script
      takes the assertion to the destination's callback.
    * **A return** (`Prima.Carry.Return`, from the destination's callback):
      the navigation outcome, recorded once through `person.carry_complete`.
      An admitted one then goes to the destination this home's row records,
      never to an address the fragment named; a refused one says so.

  It lists the person's own unexpired pending actions, from
  `person.carry_list`, for Resume or Cancel, telling a carry sent and not
  yet answered from one waiting for its challenge. That is no history of
  the homes they visited, and no page here keeps a list of saved homes.
  Resume asks again for an action whose challenge this page holds;
  otherwise it opens the destination's sign-in page, whose entry sends an
  exchange it holds a challenge of back here. Cancel ends the action
  through `person.carry_cancel`; a session the destination already
  admitted stands.
  """

  use PrismWeb, :live_view

  alias Prima.Identity.Encoding
  alias PrismWeb.SystemLayer
  alias Sanctum.Auth.CyfrDoor

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: send(self(), :load)

    {:ok,
     socket
     |> assign(:page_title, "Sign in at another home")
     |> assign(:active_nav, nil)
     |> assign(:lifetime_ms, CyfrDoor.carry_lifetime_ms())
     |> assign(:destination, "")
     |> assign(:actions, [])
     # The assertion requests of the challenges this page received, by
     # action id: what Resume and the confirmed repeat ask again.
     |> assign(:asserts, %{})
     # A challenge for an action this tab did not begin, until the person
     # continues.
     |> assign(:continue, nil)
     |> assign(:finished, nil)
     |> assign(:notice, nil)}
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, load(socket)}

  # A change this page asked for was confirmed: asked again, once.
  def handle_info({:system_layer, _id, _outcome} = report, socket) do
    case SystemLayer.reported(socket, report) do
      {:repeat, {:assert, _action_id}, _tool, args, socket} -> {:noreply, assert(socket, args)}
      {:ok, socket} -> {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ---- what the script hands the page ------------------------------------------

  # A destination the destination's own sign-in entry named: the form is
  # filled, and nothing else happens.
  @impl true
  def handle_event("carry_destination", %{"destination" => destination}, socket)
      when is_binary(destination) do
    if Encoding.home?(destination) do
      {:noreply, assign(socket, destination: destination, notice: nil)}
    else
      {:noreply, notice(socket, :error, "That link names no home; type the home to sign in at.")}
    end
  end

  def handle_event("carry_challenge", %{"fragment" => fragment} = params, socket)
      when is_binary(fragment) do
    socket = load(socket)

    with {:ok, challenge} <- read_challenge(fragment),
         {:ok, action} <- pending_action(socket, challenge) do
      args = %{
        "audience" => action.destination,
        "challenge" => challenge["challenge"],
        "action_id" => action.action_id,
        "key_epoch" => action.key_epoch
      }

      socket = assign(socket, :asserts, Map.put(socket.assigns.asserts, action.action_id, args))

      if params["own"] == true do
        {:noreply, assert(socket, args)}
      else
        {:noreply,
         assign(socket,
           continue: %{action_id: action.action_id, destination: action.destination},
           notice: nil
         )}
      end
    else
      {:error, message} -> {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("carry_return", %{"fragment" => fragment}, socket) when is_binary(fragment) do
    case Prima.Carry.Return.parse_fragment(fragment) do
      {:ok, %Prima.Carry.Return{action_id: action_id, outcome: outcome}} ->
        {:noreply, complete(socket, action_id, Atom.to_string(outcome))}

      {:error, _unread} ->
        {:noreply, notice(socket, :error, "That answer from the other home could not be read.")}
    end
  end

  def handle_event("carry_oversized", _params, socket) do
    {:noreply,
     notice(socket, :error, "That sign-in is larger than a carry may be, so nothing was sent.")}
  end

  # ---- the person's own controls -----------------------------------------------

  def handle_event("begin", %{"destination" => destination}, socket)
      when is_binary(destination) do
    destination = String.trim(destination)

    case call_tool(socket, "person/carry_begin", %{
           "destination" => destination,
           "operation" => "join"
         }) do
      {:ok, began} ->
        {:noreply,
         socket
         |> assign(destination: "", finished: nil, notice: nil)
         |> load()
         |> push_event("carry:begun", %{
           action_id: began.action_id,
           destination: began.destination,
           key_epoch: began.envelope["key_epoch"],
           to: began.destination <> "/login#carry=" <> began.fragment
         })}

      {:error, reason} ->
        {:noreply,
         socket |> assign(:destination, destination) |> notice(:error, error_message(reason))}
    end
  end

  def handle_event("continue", %{"action_id" => action_id}, socket) when is_binary(action_id) do
    case {socket.assigns.continue, socket.assigns.asserts} do
      {%{action_id: ^action_id}, %{^action_id => args}} ->
        {:noreply, socket |> assign(:continue, nil) |> assert(args)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :continue, nil)}

  def handle_event("resume", %{"action_id" => action_id}, socket) when is_binary(action_id) do
    case {Map.fetch(socket.assigns.asserts, action_id), listed(socket, action_id)} do
      {{:ok, args}, _listed} ->
        {:noreply, assert(socket, args)}

      {:error, %{destination: destination}} ->
        {:noreply, push_event(socket, "carry:go", %{to: destination <> "/login"})}

      {:error, nil} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("cancel", %{"action_id" => action_id}, socket) when is_binary(action_id) do
    case call_tool(socket, "person/carry_cancel", %{"action_id" => action_id}) do
      {:ok, _cancelled} ->
        {:noreply,
         socket
         |> assign(
           asserts: Map.delete(socket.assigns.asserts, action_id),
           continue: nil,
           notice: {:info, "That sign-in is cancelled; nothing more is sent for it."}
         )
         |> load()
         |> push_event("carry:forget", %{action_id: action_id})}

      {:error, reason} ->
        {:noreply, socket |> load() |> notice(:error, error_message(reason))}
    end
  end

  # ---- the work ----------------------------------------------------------------

  defp load(socket) do
    case fetch_list(socket, "person/carry_list", :actions) do
      {:ok, actions} -> assign(socket, :actions, actions)
      {:error, message} -> notice(socket, :error, message)
    end
  end

  # The assertion for one challenge, asked through the system layer: a
  # session alone is answered `confirmation_required`, which the layer
  # shows as this page's own request and reports once confirmed.
  defp assert(socket, %{"action_id" => action_id, "audience" => audience} = args) do
    case SystemLayer.call(socket, {:assert, action_id}, "person/assert", args) do
      {:ok, %{callback: callback}, socket} ->
        if String.starts_with?(callback, audience <> "/login#cyfr=") do
          socket
          |> assign(:notice, {:info, "Signing you in at #{audience}…"})
          |> push_event("carry:go", %{to: callback})
        else
          notice(socket, :error, "The assertion came back for another home; nothing was sent.")
        end

      {:asked, socket} ->
        assign(
          socket,
          :notice,
          {:info,
           "Confirm signing in at #{audience}. It shows a code; confirm only if your " <>
             "confirmation names the same one."}
        )

      {:error, reason, socket} ->
        socket |> load() |> notice(:error, error_message(reason))
    end
  end

  defp complete(socket, action_id, outcome) do
    case call_tool(socket, "person/carry_complete", %{
           "action_id" => action_id,
           "outcome" => outcome
         }) do
      {:ok, %{outcome: recorded, destination: destination}} ->
        socket =
          socket
          |> assign(
            asserts: Map.delete(socket.assigns.asserts, action_id),
            finished: %{outcome: recorded, destination: destination},
            notice: nil
          )
          |> load()
          |> push_event("carry:forget", %{action_id: action_id})

        # Admitted, the person goes on to the home they signed in at, as
        # this home's own row names it.
        if recorded == "admitted",
          do: push_event(socket, "carry:go", %{to: destination <> "/"}),
          else: socket

      {:error, reason} ->
        socket |> load() |> notice(:error, error_message(reason))
    end
  end

  # The destination's challenge: `{protocol, action_id, audience,
  # challenge}`, as `Sanctum.Auth.CyfrDoor.challenge_fragment/1` writes it,
  # bounded before it is decoded.
  defp read_challenge(fragment) do
    with {:ok, fragment} <- Prima.Carry.bounded(fragment),
         {:ok,
          %{"protocol" => protocol, "action_id" => id, "audience" => audience, "challenge" => c} =
            object}
         when map_size(object) == 4 <- Prima.Carry.decode_object(fragment),
         true <- protocol == Prima.Carry.protocol(),
         true <- Encoding.id?(id) and Encoding.home?(audience),
         {:ok, _bytes} <- Encoding.unb64(c, Prima.PersonAssertion.challenge_bytes()) do
      {:ok, object}
    else
      {:error, :carry_too_large} ->
        {:error, "That sign-in is larger than a carry may be, so nothing was sent."}

      _unread ->
        {:error, "That sign-in could not be read; nothing was signed."}
    end
  end

  # A challenge stands only for a pending action of the person's whose
  # destination is the challenge's audience: a link naming none begins and
  # signs nothing.
  defp pending_action(socket, %{"action_id" => action_id, "audience" => audience}) do
    case listed(socket, action_id) do
      %{destination: ^audience} = action ->
        {:ok, action}

      _none ->
        {:error,
         "No sign-in of yours is waiting for #{audience}, so nothing was signed. Begin one below."}
    end
  end

  defp listed(socket, action_id),
    do: Enum.find(socket.assigns.actions, &(&1.action_id == action_id))

  defp notice(socket, kind, message), do: assign(socket, :notice, {kind, message})

  defp phase_label("delivered"), do: "Sent there; waiting for it to answer"
  defp phase_label(_pending), do: "Waiting for you to continue"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="carry"
      phx-hook="Carry"
      data-carry="source"
      data-lifetime-ms={@lifetime_ms}
      data-max-fragment={Prima.Carry.max_fragment_bytes()}
      class="max-w-2xl space-y-6"
    >
      <.page_header title="Sign in at another home" />

      <div
        :if={@notice}
        data-test="carry-notice"
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

      <div
        :if={@finished}
        data-test="carry-finished"
        data-outcome={@finished.outcome}
        class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-sm text-gray-200"
      >
        <%= if @finished.outcome == "admitted" do %>
          {@finished.destination} signed you in.
        <% else %>
          {@finished.destination} did not sign you in.
        <% end %>
        <a href={@finished.destination <> "/"} class="text-indigo-400 hover:text-indigo-300">
          Go to {@finished.destination}
        </a>
      </div>

      <div
        :if={@continue}
        data-test="carry-continue"
        class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 space-y-3"
      >
        <p class="text-sm text-gray-200">
          {@continue.destination} is asking to sign you in, for a sign-in you began.
          Continue only if you are signing in there now.
        </p>
        <div class="flex gap-2 justify-end">
          <button type="button" phx-click="dismiss" class="px-4 py-2 text-sm text-gray-400">
            Not now
          </button>
          <.button phx-click="continue" phx-value-action_id={@continue.action_id}>
            Continue
          </.button>
        </div>
      </div>

      <form id="carry-begin" phx-submit="begin" class="space-y-2">
        <label for="carry-destination" class="text-sm text-gray-300">
          The home to sign in at
        </label>
        <div class="flex gap-2">
          <input
            id="carry-destination"
            name="destination"
            type="text"
            inputmode="url"
            autocomplete="off"
            value={@destination}
            placeholder="https://hub.example"
            class="flex-1 min-w-0 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white"
          />
          <.button type="submit">Begin</.button>
        </div>
        <p class="text-xs text-gray-500">
          The home you sign in at learns this home's address, and this home learns that one's.
        </p>
      </form>

      <div :if={@actions != []} class="space-y-2" data-test="carry-pending">
        <h2 class="text-sm font-medium text-gray-300">Sign-ins waiting</h2>
        <ul class="divide-y divide-gray-800 rounded-lg border border-gray-800">
          <li
            :for={action <- @actions}
            id={"carry-" <> action.action_id}
            data-phase={action.phase}
            class="flex items-center justify-between gap-3 px-4 py-3"
          >
            <div class="min-w-0">
              <p class="text-sm text-white truncate">{action.destination}</p>
              <p class="text-xs text-gray-500">{phase_label(action.phase)}</p>
            </div>
            <div class="flex gap-2">
              <button
                type="button"
                phx-click="resume"
                phx-value-action_id={action.action_id}
                class="px-3 py-1 text-sm text-indigo-300 hover:text-indigo-200"
              >
                Resume
              </button>
              <button
                type="button"
                phx-click="cancel"
                phx-value-action_id={action.action_id}
                class="px-3 py-1 text-sm text-gray-400 hover:text-white"
              >
                Cancel
              </button>
            </div>
          </li>
        </ul>
      </div>
    </div>

    <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    """
  end
end
