# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLive do
  @moduledoc """
  The sign-in page. GitHub and Google use device flow on this page
  (`Sanctum.Auth.DeviceFlow`); a configured OIDC issuer still kicks off
  through `GET /auth/oidcc`. A completed device flow hands a one-time
  ticket to `GET /auth/device/complete/:ticket`, which sets the cookie
  session this origin has.

  A passkey registered here signs its person in too: the page holds a
  sign-in challenge (`Sanctum.Passkeys.sign_in_challenge/0`), the browser's
  ceremony (`system_layer/webauthn.js`, through the `SystemLayer` hook in
  its WebAuthn mode) answers it, and `Sanctum.Passkeys.sign_in/2` verifies
  the answer against the challenge, which is spent on the first answer,
  and mints the session. A one-time ticket bound to this browser hands it
  to `GET /auth/passkey/complete/:ticket`, as the device flow's does.

  A person whose keys another home holds signs in through the `cyfr` door
  (`Sanctum.Auth.CyfrDoor`), and the page's script (`hooks/carry.js`)
  carries the exchange between the homes:

    * **The entry.** "Sign in with your CYFR" takes the address of their
      signing home. The page answers `cyfr:expect` with that home's
      origin and where to go: its `/carry`, this home as the destination
      in the fragment, where they begin the sign-in themselves. The
      script keeps `{home, at}` in this tab's `sessionStorage` before it
      goes. When this browser's session already holds an unexpired
      challenge of that home's carry, the same challenge goes back there
      instead, by a new ticket through `GET /auth/cyfr`: the exchange
      resumes under its own action. That answer is `cyfr:go`, which keeps
      no expectation: a resumed exchange comes back with its assertion,
      never a carry, so it opens no window for a carry no gesture asked
      for.
    * **The carry.** Their home sends the browser back here with the
      carry in the fragment (`#carry=`). The script reads and clears it,
      and raises `cyfr_carry` only while the expectation that entry left
      is fresh, once, naming the home as `expected_source`: a carry no
      gesture here asked for signs nobody in, so another home cannot sign
      this browser in as someone else. The page refuses a carry whose
      envelope's `source` is not that home before anything reads a
      directory, then verifies it against the person's directory and
      mints this home's challenge.
    * **The code.** The page shows the challenge's comparison code
      (`Prima.PersonAssertion.comparison_code/1`), which their home's
      confirmation names too, and Continue mints the one-time ticket bound
      to this browser and goes to `GET /auth/cyfr`, which keeps the
      challenge in the browser's session and returns the browser to their
      home.
    * **The callback.** Their home's assertion comes back the same way
      (`#cyfr=`), to `cyfr_assertion`, and the page posts it as
      `fragment`, which the request log redacts (`Prima.Sanitizer`), with
      its CSRF token, to `POST /auth/cyfr/callback`, which reports the
      outcome back to their home.

  A held challenge carries the browser secret its login is bound to. The
  page keeps it whole for the hop, inside `PrismWeb.LoginLive.Held`,
  whose inspection omits that secret, so a crash report that prints the
  page's assigns never prints it.

  The script on this page also keeps a carry fragment meant for this home
  as a signing home (a destination, a challenge or a return that arrived
  at `/carry` before its person signed in here, and was sent here to sign
  in) until `/carry` takes it.

  A refused sign-in never reaches a session — the door answers on the
  poll; a signed-in person who has no athanor yet is told so.

  A member that does not hold its slot in the cell
  (`Arca.ControlPlane.held?/0`) signs nobody in: a flow is not started,
  and a flow already waiting stops at its next poll without asking the
  provider.
  """

  use PrismWeb, :live_view

  alias PrismWeb.LoginLive.Held
  alias Sanctum.Auth.{CyfrDoor, DeviceFlow}
  require Logger

  @ticket_ttl_ms 60_000
  @default_poll_interval_s 5
  # Passkey challenges per address: the page is reached over the LiveView
  # socket, which passes no rate-limit plug, so this is its per-address
  # bound, per node, before any signature is checked.
  @passkey_starts 30
  @passkey_window_ms 60_000
  # A `cyfr` sign-in's carry reads the person's directory before anything
  # else answers, so each address has its own bound here, per node.
  @cyfr_starts 30
  @cyfr_window_ms 60_000
  @not_owner "This server is not accepting sign-ins right now. Try again in a moment."
  @wrong_source "That sign-in came from another home than the one you named, so nobody was " <>
                  "signed in. Name your home below and begin again."
  @unsolicited "A sign-in arrived that this page did not ask for, so nobody was signed in. " <>
                 "To sign in with your CYFR, name your home below."
  @oversized "That sign-in is larger than this home accepts."

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     # The browser that starts the flow is the only one allowed to finish
     # it. The session's CSRF token is the handle this origin already has
     # on that browser; the ticket is bound to it at mint and checked at
     # /auth/device/complete.
     |> assign(:browser_binding, session["_csrf_token"])
     # `connect_info` is readable only here, so the address the device-flow
     # budget is charged to has to be captured at mount and carried. This
     # socket never passes a rate-limit plug — the endpoint handles /live
     # before the router — so this assign IS the per-address bound.
     |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
     |> assign(:page_title, "Sign in")
     |> assign(:providers, available_providers())
     |> assign(:login_state, :idle)
     |> assign(:provider, nil)
     |> assign(:user_code, nil)
     |> assign(:verification_uri, nil)
     |> assign(:device_code, nil)
     |> assign(:poll_interval, @default_poll_interval_s)
     # The passkey sign-in challenge this page holds, answered at most once.
     |> assign(:passkey_challenge, nil)
     # A `cyfr` sign-in's callback fragment, posted once by the form below.
     |> assign(:cyfr_fragment, nil)
     |> assign(:cyfr_trigger, false)
     # How long the script holds an expectation, the carry's lifetime.
     |> assign(:carry_lifetime_ms, CyfrDoor.carry_lifetime_ms())
     # The challenge this browser's session holds from an earlier hop,
     # which an entry naming its home resumes. Server-side only.
     |> assign(:cyfr_held, held_challenge(session))
     # A verified carry's challenge, waiting for the person's Continue.
     |> assign(:cyfr_pending, nil)
     |> assign(:error, error_from_params(params)), layout: false}
  end

  # The person names their signing home; they begin the sign-in there, or
  # resume the exchange this browser already holds a challenge of.
  @impl true
  def handle_event("cyfr_home", %{"home" => address}, socket) when is_binary(address) do
    case CyfrDoor.signing_home(address) do
      {:ok, url} ->
        home = signing_origin(url)

        socket = assign(socket, error: nil, cyfr_pending: nil)

        # A resumed exchange keeps no expectation: what comes back is its
        # assertion, never a carry.
        case resumable(socket.assigns.cyfr_held, home) do
          {:ok, held} ->
            {:noreply,
             push_event(socket, "cyfr:go", %{
               to: challenge_hop(held, socket.assigns.browser_binding)
             })}

          :none ->
            {:noreply, push_event(socket, "cyfr:expect", %{home: home, to: url})}
        end

      {:error, :this_home} ->
        {:noreply,
         assign(
           socket,
           :error,
           "That is this home's address; name the home that holds your keys."
         )}

      {:error, :invalid_home} ->
        {:noreply,
         assign(socket, :error, "That is not a home's address, like https://home.example.")}
    end
  end

  # The carry the person's home sent back with them, raised only after the
  # entry above named that home (`expected_source`): this home's challenge
  # for it, shown as its comparison code until the person continues.
  def handle_event(
        "cyfr_carry",
        %{"fragment" => fragment, "expected_source" => expected},
        socket
      )
      when is_binary(fragment) and is_binary(expected) do
    if Arca.ControlPlane.held?() do
      # Before any directory is read: the carry is from the home the
      # person named here, or it signs nobody in.
      case unexpected_source(fragment, expected) do
        nil -> {:noreply, challenge_carry(socket, fragment, expected)}
        refusal -> {:noreply, assign(socket, error: refusal, cyfr_pending: nil)}
      end
    else
      {:noreply, assign(socket, :error, @not_owner)}
    end
  end

  # A carry no entry here asked for: nothing is checked and nobody signed in.
  def handle_event("cyfr_carry", _params, socket),
    do: {:noreply, assign(socket, error: @unsolicited, cyfr_pending: nil)}

  def handle_event("cyfr_unsolicited", _params, socket),
    do: {:noreply, assign(socket, error: @unsolicited, cyfr_pending: nil)}

  def handle_event("cyfr_oversized", _params, socket),
    do: {:noreply, assign(socket, error: @oversized, cyfr_pending: nil)}

  # The person saw the code and continues: the challenge goes, by a ticket
  # bound to this browser, to the hop that keeps it in the browser's
  # session and returns them to their home.
  def handle_event("cyfr_continue", _params, socket) do
    case socket.assigns.cyfr_pending do
      %{held: held} ->
        if unexpired?(held) do
          {:noreply, redirect(socket, to: challenge_hop(held, socket.assigns.browser_binding))}
        else
          {:noreply,
           assign(socket,
             error: "That sign-in expired. Begin it again from your home.",
             cyfr_pending: nil
           )}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cyfr_cancel", _params, socket),
    do: {:noreply, assign(socket, cyfr_pending: nil)}

  # The assertion the person's home sent back: posted, with this page's
  # CSRF token, to the callback, by the form the trigger submits.
  def handle_event("cyfr_assertion", %{"fragment" => fragment}, socket)
      when is_binary(fragment) do
    if byte_size(fragment) <= Prima.Carry.max_fragment_bytes() do
      {:noreply, assign(socket, cyfr_fragment: fragment, cyfr_trigger: true, error: nil)}
    else
      {:noreply, assign(socket, :error, "That sign-in is larger than this home accepts.")}
    end
  end

  def handle_event("passkey_start", _params, socket) do
    cond do
      not Arca.ControlPlane.held?() ->
        {:reply, %{error: @not_owner}, assign(socket, :error, @not_owner)}

      Prima.RateLimiter.check(
        {:passkey_sign_in, socket.assigns.client_ip},
        @passkey_starts,
        @passkey_window_ms
      ) != :ok ->
        message = "Too many passkey sign-ins from here. Try again in a minute."
        {:reply, %{error: message}, assign(socket, :error, message)}

      true ->
        held = Sanctum.Passkeys.sign_in_challenge()

        {:reply, %{public_key: held.public_key},
         assign(socket, :passkey_challenge, Map.take(held, [:challenge, :expires_at]))}
    end
  end

  def handle_event("passkey_assertion", %{"credential" => credential}, socket)
      when is_map(credential) do
    case socket.assigns.passkey_challenge do
      nil ->
        {:noreply, assign(socket, :error, "That passkey sign-in expired. Please try again.")}

      held ->
        # The challenge is spent on its first answer, whatever it says.
        socket = assign(socket, :passkey_challenge, nil)
        finish_passkey(socket, Sanctum.Passkeys.sign_in(held, credential))
    end
  end

  def handle_event("passkey_assertion", _params, socket),
    do: {:noreply, assign(socket, passkey_challenge: nil, error: passkey_refused())}

  def handle_event("passkey_error", _params, socket) do
    {:noreply,
     assign(socket, passkey_challenge: nil, error: "The passkey sign-in did not finish.")}
  end

  def handle_event("start", %{"provider" => provider}, socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_start_at]

    cond do
      not DeviceFlow.provider?(provider) ->
        {:noreply, socket}

      socket.assigns.login_state == :waiting ->
        {:noreply, socket}

      # Each click mints a device code at the IdP — a double-click or a
      # rage-click should cost one round-trip, not one per click.
      # (Monotonic time is negative on the BEAM — nil is the sentinel,
      # never 0.)
      is_integer(last) and now - last < 2_000 ->
        {:noreply, socket}

      not Arca.ControlPlane.held?() ->
        {:noreply, assign(socket, :error, @not_owner)}

      true ->
        start_device_flow(assign(socket, :last_start_at, now), provider)
    end
  end

  def handle_event("start", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    {:noreply, assign_idle(socket, nil)}
  end

  defp start_device_flow(socket, provider) do
    provider_atom = String.to_existing_atom(provider)

    case DeviceFlow.impl().init_device_flow(provider_atom, socket.assigns.client_ip) do
      {:ok, info} ->
        if connected?(socket), do: schedule_poll(info.interval)

        {:noreply,
         socket
         |> assign(:login_state, :waiting)
         |> assign(:provider, provider_atom)
         |> assign(:user_code, info.user_code)
         |> assign(:verification_uri, info.verification_uri)
         |> assign(:device_code, info.device_code)
         |> assign(:poll_interval, info.interval || @default_poll_interval_s)
         |> assign(:error, nil)}

      {:error, {:client_id_not_configured, p}} ->
        {:noreply, assign(socket, :error, "#{p} is not configured on this server.")}

      {:error, {:device_code_error, code}} ->
        Logger.warning("[LoginLive] device-flow init rejected: #{inspect(code)}")

        {:noreply,
         assign(
           socket,
           :error,
           "Device flow was rejected (#{code}). For Google, the OAuth client must be type \"TV and Limited Input devices\"."
         )}

      {:error, reason} ->
        Logger.warning("[LoginLive] device-flow init failed: #{inspect(reason)}")
        {:noreply, assign(socket, :error, "Couldn't start sign-in. Try again in a moment.")}
    end
  end

  @impl true
  def handle_info(:login_poll, socket) do
    case socket.assigns.login_state do
      :waiting ->
        poll(socket)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp poll(socket) do
    if Arca.ControlPlane.held?() do
      finish_poll(
        socket,
        DeviceFlow.impl().poll_for_session(
          socket.assigns.provider,
          socket.assigns.device_code,
          socket.assigns.client_ip
        )
      )
    else
      {:noreply, assign_idle(socket, @not_owner)}
    end
  end

  defp finish_poll(socket, {:ok, %{status: "pending"} = result}) do
    interval =
      if result[:slow_down],
        do: max(socket.assigns.poll_interval, @default_poll_interval_s) + 5,
        else: socket.assigns.poll_interval

    schedule_poll(interval)
    {:noreply, socket}
  end

  defp finish_poll(socket, {:ok, %{status: "complete", session_token: token} = result})
       when is_binary(token) do
    ticket = mint_ticket(result, socket.assigns.browser_binding)
    {:noreply, redirect(socket, to: ~p"/auth/device/complete/#{ticket}")}
  end

  defp finish_poll(socket, {:ok, %{status: "complete"}}) do
    {:noreply, assign_idle(socket, "Sign-in could not create a session. Please try again.")}
  end

  defp finish_poll(socket, {:ok, %{status: "denied"}}) do
    {:noreply, assign_idle(socket, Sanctum.Door.refusal_message())}
  end

  defp finish_poll(socket, {:ok, %{status: "expired"}}) do
    {:noreply, assign_idle(socket, "Code expired. Please try again.")}
  end

  defp finish_poll(socket, {:ok, %{status: "error", message: message}}) do
    {:noreply, assign_idle(socket, message)}
  end

  defp finish_poll(socket, {:error, {:client_id_not_configured, provider}}) do
    {:noreply, assign_idle(socket, "#{provider} is not configured on this server.")}
  end

  defp finish_poll(socket, {:error, {:door, _reason}}) do
    {:noreply, assign_idle(socket, Sanctum.Door.refusal_message())}
  end

  defp finish_poll(socket, {:error, reason}) do
    Logger.warning("[LoginLive] device-flow poll failed: #{inspect(reason)}")
    {:noreply, assign_idle(socket, "Couldn't complete sign-in. Try again in a moment.")}
  end

  defp finish_passkey(socket, {:ok, result}) do
    ticket = mint_ticket({:login_passkey_ticket, result}, socket.assigns.browser_binding)
    {:noreply, redirect(socket, to: ~p"/auth/passkey/complete/#{ticket}")}
  end

  defp finish_passkey(socket, {:error, {:door, _reason}}),
    do: {:noreply, assign(socket, :error, Sanctum.Door.refusal_message())}

  defp finish_passkey(socket, {:error, :unavailable}),
    do:
      {:noreply, assign(socket, :error, "The server could not sign you in just now. Try again.")}

  defp finish_passkey(socket, {:error, _refused}),
    do: {:noreply, assign(socket, :error, passkey_refused())}

  defp passkey_refused, do: "That passkey did not sign you in here."

  defp cyfr_refused(reason) when reason in [:identity_stale, :unavailable],
    do: "Your identity could not be confirmed with its directory just now. Try again shortly."

  defp cyfr_refused(:wrong_destination),
    do: "That sign-in was begun for another home. Begin it again for this one."

  defp cyfr_refused(_refused),
    do: "That sign-in could not be checked here. Begin it again from your home."

  defp challenge_carry(socket, fragment, expected) do
    if Prima.RateLimiter.check(
         {:cyfr_sign_in, socket.assigns.client_ip},
         @cyfr_starts,
         @cyfr_window_ms
       ) == :ok do
      case CyfrDoor.challenge(fragment) do
        {:ok, %{"source" => ^expected} = held} ->
          assign(socket, error: nil, cyfr_pending: pending(Held.new(held)))

        {:ok, _another} ->
          assign(socket, error: @wrong_source, cyfr_pending: nil)

        {:error, reason} ->
          assign(socket, error: cyfr_refused(reason), cyfr_pending: nil)
      end
    else
      assign(socket, :error, "Too many sign-ins from here. Try again in a minute.")
    end
  end

  # The envelope's source, read from the carry before anything is verified
  # or any directory read: nil when it is the home the person named here,
  # else the sentence that refuses it.
  defp unexpected_source(fragment, expected) do
    case Prima.Carry.parse_fragment(fragment) do
      {:ok, %{envelope: %{source: ^expected}}} -> nil
      {:ok, _another} -> @wrong_source
      {:error, :carry_too_large} -> @oversized
      {:error, _unread} -> cyfr_refused(:invalid_carry)
    end
  end

  # What the page shows while the person compares codes: the home they
  # named and the comparison code of the challenge this home issued, which
  # that home's confirmation names too. The challenge stays in this process
  # until Continue hands it to the hop.
  defp pending(%Held{held: inner} = held) do
    {:ok, challenge} =
      Prima.Identity.Encoding.unb64(inner["challenge"], Prima.PersonAssertion.challenge_bytes())

    %{held: held, home: inner["source"], code: Prima.PersonAssertion.comparison_code(challenge)}
  end

  # The challenge an earlier hop left in this browser's session
  # (`PrismWeb.AuthController.cyfr_challenge_key/0`), if any.
  defp held_challenge(session) do
    case session[PrismWeb.AuthController.cyfr_challenge_key()] do
      %{} = held -> Held.new(held)
      _none -> nil
    end
  end

  # The exchange this browser holds the challenge of resumes when the
  # person names its home again before it expires: the same action and
  # challenge go back, never a new one.
  defp resumable(%Held{held: %{"source" => home}} = held, home),
    do: if(unexpired?(held), do: {:ok, held}, else: :none)

  defp resumable(_held, _home), do: :none

  defp unexpired?(%Held{held: %{"expires_at" => at}}) when is_integer(at),
    do: at > System.os_time(:millisecond)

  defp unexpired?(_held), do: false

  defp challenge_hop(%Held{held: held}, browser_binding) do
    ticket = mint_ticket({:login_cyfr_ticket, held}, browser_binding)
    "/auth/cyfr?" <> URI.encode_query(%{ticket: ticket})
  end

  # The signing home's origin, from the address `signing_home/1` answered:
  # its `/carry` path (`Prima.Carry.return_url/1`) and its fragment off.
  defp signing_origin(url) do
    url |> String.split("#", parts: 2) |> hd() |> String.replace_suffix("/carry", "")
  end

  # A `cyfr` sign-in's challenge, for the hop that keeps it in this
  # browser's session: bound to the browser as the other tickets are.
  defp mint_ticket({:login_cyfr_ticket, held}, browser_binding) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:login_cyfr_ticket, ticket},
      %{held: held, browser_binding: browser_binding},
      @ticket_ttl_ms
    )

    ticket
  end

  defp mint_ticket({:login_passkey_ticket, result}, browser_binding) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:login_passkey_ticket, ticket},
      %{
        session_token: result.session_token,
        outcome: result.outcome,
        browser_binding: browser_binding
      },
      @ticket_ttl_ms
    )

    ticket
  end

  defp mint_ticket(result, browser_binding) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    payload = %{
      session_token: result.session_token,
      access_token: Map.get(result, :access_token),
      outcome: result.outcome,
      # Whose browser this sign-in belongs to. Without it the ticket is a
      # bearer credential for a whole session: whoever opens the URL within
      # its lifetime is signed in as the person who completed the flow, so
      # an attacker could finish their own device flow and hand the link to
      # someone else, landing them in the attacker's account.
      browser_binding: browser_binding
    }

    Arca.Cache.put({:login_device_ticket, ticket}, payload, @ticket_ttl_ms)
    ticket
  end

  defp assign_idle(socket, error) do
    socket
    |> assign(:login_state, :idle)
    |> assign(:provider, nil)
    |> assign(:user_code, nil)
    |> assign(:verification_uri, nil)
    |> assign(:device_code, nil)
    |> assign(:error, error)
  end

  defp schedule_poll(interval_s) do
    ms =
      cond do
        is_integer(interval_s) and interval_s >= 0 -> interval_s * 1_000
        true -> @default_poll_interval_s * 1_000
      end

    Process.send_after(self(), :login_poll, ms)
  end

  # The built-in provider offers GitHub and Google device flow; a deployment
  # with its own OIDC issuer authenticates through `/auth/oidcc`.
  defp available_providers do
    case Cyfr.RuntimeConfig.auth_provider() do
      Sanctum.Auth.OIDC -> [:oidcc]
      _ -> DeviceFlow.configured_providers()
    end
  end

  # Map an auth redirect (`/login?error=<code>`) to a user-facing banner.
  defp error_from_params(%{"error" => "no_athanor"}),
    do:
      "You're signed in, but you have no athanor here yet. If you were just " <>
        "let in, sign in again; otherwise ask the operator."

  defp error_from_params(%{"error" => "unavailable"}),
    do: "The server could not read your account just now. Try again in a moment."

  defp error_from_params(%{"error" => "signed_out"}), do: nil
  defp error_from_params(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <div class="min-h-screen flex items-center justify-center bg-gray-950">
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <p class="text-sm text-indigo-300/70 uppercase tracking-[0.3em] mb-4">
            Dear Alchemist&hellip;
          </p>
          <h1 class="text-3xl md:text-4xl font-extrabold tracking-tight text-indigo-200/80 leading-tight">
            Welcome to <span class="text-indigo-300">CYFR</span>,<br /> your secure personal foundry.
          </h1>
        </div>

        <div class="flex items-start gap-3">
          <img
            src={~p"/images/logo.jpg"}
            alt="AQUA"
            class="h-10 w-10 rounded-full shrink-0 mt-1 ring-2 ring-indigo-400/30"
          />
          <div class="flex-1 min-w-0">
            <div class="text-[10px] text-indigo-300/60 uppercase tracking-wider mb-1.5">AQUA</div>
            <div class="relative bg-gray-900 rounded-lg rounded-tl-none px-4 py-3">
              <div class="absolute -left-2 top-3 w-0 h-0 border-t-[6px] border-t-transparent border-b-[6px] border-b-transparent border-r-[8px] border-r-gray-900">
              </div>
              <p class="text-sm text-gray-300 leading-relaxed">
                <span class="font-semibold text-white">AQUA</span>, your trusted assistant,
                is at your service&mdash;ready to forge your brilliance into reality.
              </p>
            </div>
          </div>
        </div>

        <div class="bg-gray-900 rounded-lg shadow-xl p-8 space-y-4">
          <div
            :if={@error}
            class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
          >
            {@error}
          </div>

          <h2 class="text-lg font-medium text-white text-center mb-4">Sign in to continue</h2>

          <%!-- The carry's script: reads and clears the address's fragment
                and holds the in-flight carry data (`hooks/carry.js`). --%>
          <div
            id="cyfr-carry"
            phx-hook="Carry"
            data-carry="login"
            data-lifetime-ms={@carry_lifetime_ms}
            data-max-fragment={Prima.Carry.max_fragment_bytes()}
            hidden
          >
          </div>

          <div
            :if={@cyfr_pending}
            id="cyfr-code"
            data-test="cyfr-code"
            class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 space-y-3"
          >
            <p class="text-sm text-gray-300">
              Your home, <span class="font-mono text-white">{@cyfr_pending.home}</span>,
              will show this code when it asks you to confirm signing in here:
            </p>
            <p class="text-center font-mono text-2xl tracking-widest text-white" data-test="code">
              {@cyfr_pending.code}
            </p>
            <p class="text-sm text-gray-300">
              Continue, and confirm there only if your home shows the same code.
            </p>
            <div class="flex gap-2 justify-end">
              <button
                type="button"
                phx-click="cyfr_cancel"
                class="px-4 py-2 text-sm text-gray-400 hover:text-white"
              >
                Cancel
              </button>
              <button
                type="button"
                phx-click="cyfr_continue"
                data-test="cyfr-continue"
                class="px-4 py-2 bg-indigo-900/60 hover:bg-indigo-900 text-white rounded-lg border border-indigo-700"
              >
                Continue
              </button>
            </div>
          </div>

          <div :if={@login_state == :waiting} class="space-y-4">
            <p class="text-sm text-gray-300 text-center">
              Open
              <a
                href={@verification_uri}
                target="_blank"
                rel="noopener noreferrer"
                class="text-indigo-400 hover:text-indigo-300"
              >
                {@verification_uri}
              </a>
              and enter:
            </p>
            <div class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-center">
              <span class="font-mono text-2xl tracking-widest text-white">{@user_code}</span>
            </div>
            <.live_loading message="Waiting for authorization…" />
            <button
              type="button"
              phx-click="cancel"
              class="w-full px-4 py-2 text-sm text-gray-400 hover:text-white"
            >
              Cancel
            </button>
          </div>

          <div
            :if={@login_state == :idle && @providers == []}
            class="text-center text-gray-400 text-sm py-4"
          >
            No providers configured. Set CYFR_GITHUB_CLIENT_ID or CYFR_GOOGLE_CLIENT_ID.
          </div>

          <div :if={@login_state == :idle} class="flex flex-col gap-3">
            <.provider_button :for={provider <- @providers} provider={provider} />
          </div>

          <div
            :if={@login_state == :idle}
            id="passkey-sign-in"
            phx-hook="SystemLayer"
            data-webauthn="sign-in"
            class="flex flex-col gap-3"
          >
            <button
              type="button"
              data-webauthn-start
              class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-indigo-900/60 hover:bg-indigo-900 text-white rounded-lg border border-indigo-700 transition-colors cursor-pointer"
            >
              <span>Sign in with a passkey</span>
            </button>
          </div>

          <form
            :if={@login_state == :idle}
            id="cyfr-sign-in"
            phx-submit="cyfr_home"
            class="flex flex-col gap-2 pt-2 border-t border-gray-800"
          >
            <label for="cyfr-home" class="text-sm text-gray-300">
              Sign in with your CYFR: the address of the home that holds your keys
            </label>
            <div class="flex gap-2">
              <input
                id="cyfr-home"
                name="home"
                type="text"
                inputmode="url"
                autocomplete="url"
                placeholder="https://your-home.example"
                class="flex-1 min-w-0 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white"
              />
              <button
                type="submit"
                class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700"
              >
                Continue
              </button>
            </div>
            <p class="text-xs text-gray-500">
              Your home learns this home's address, and this home learns yours.
            </p>
          </form>

          <.form
            :if={@cyfr_trigger}
            for={%{}}
            id="cyfr-callback"
            action={~p"/auth/cyfr/callback"}
            method="post"
            phx-trigger-action={@cyfr_trigger}
          >
            <input type="hidden" name="fragment" value={@cyfr_fragment} />
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp provider_button(%{provider: :github} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="start"
      phx-value-provider="github"
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
    >
      <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
        <path
          fill-rule="evenodd"
          d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"
          clip-rule="evenodd"
        />
      </svg>
      <span>Sign in with GitHub</span>
    </button>
    """
  end

  defp provider_button(%{provider: :google} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="start"
      phx-value-provider="google"
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-white hover:bg-gray-100 text-gray-800 rounded-lg border border-gray-300 transition-colors cursor-pointer"
    >
      <svg class="w-5 h-5" viewBox="0 0 24 24">
        <path
          fill="#4285F4"
          d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
        />
        <path
          fill="#34A853"
          d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
        />
        <path
          fill="#FBBC05"
          d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
        />
        <path
          fill="#EA4335"
          d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
        />
      </svg>
      <span>Sign in with Google</span>
    </button>
    """
  end

  defp provider_button(assigns) do
    ~H"""
    <a
      href={"/auth/#{@provider}"}
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
    >
      <span>Sign in with {@provider}</span>
    </a>
    """
  end
end

defmodule PrismWeb.LoginLive.Held do
  @moduledoc """
  A `cyfr` sign-in's held challenge (`Sanctum.Auth.CyfrDoor`) as the
  sign-in page keeps it: whole, for the hop that keeps it in the
  browser's session, and inspected without its `browser_secret`, the
  secret its login is bound to, so a crash report that prints the page's
  assigns never prints it.
  """

  @enforce_keys [:held]
  defstruct [:held]

  @type t :: %__MODULE__{held: map()}

  @doc "The held challenge `held`, kept for the page."
  @spec new(map()) :: t()
  def new(%{} = held), do: %__MODULE__{held: held}

  defimpl Inspect, for: PrismWeb.LoginLive.Held do
    use Boundary, classify_to: PrismWeb
    import Inspect.Algebra

    def inspect(%{held: held}, opts) do
      concat(["#PrismWeb.LoginLive.Held<", to_doc(Map.delete(held, "browser_secret"), opts), ">"])
    end
  end
end
