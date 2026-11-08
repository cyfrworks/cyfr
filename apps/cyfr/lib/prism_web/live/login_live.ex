# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLive do
  @moduledoc """
  The sign-in page, and the return every request this CYFR mints comes
  back to.

  **Sign in with your account.** One button: this CYFR mints a sign-in
  request bound to this browser, by its session's forgery token
  (`Sanctum.SignIn.request/3`), and the page sends the browser to the
  account pages with it (`account:hop`, the system layer's hop). Minting
  is bounded per address, per node, before anything else is read; a
  member that does not hold the cell's slot mints nothing.

  **The return.** The account pages send the browser back to `/login`
  with the answer in the fragment, which never reaches a server. The
  system layer's script on this page (`data-account="return"`) reads the
  fragment, clears it from the address and hands it here
  (`account_answer`), and the page answers it under every binding this
  browser's session cookie holds: its forgery token, and its session when
  it has one (`Sanctum.SignIn.answer/3`). A sign-in hands a one-time
  ticket bound to this browser to `GET /auth/passkey/complete/:ticket`,
  which sets the session's cookie (`PrismWeb.PasskeyController`). A
  confirmation or a registry signature, answered in the tab the system
  layer opened, sends the browser back where its request named, or to `/`.
  A registry signature is completed here first, under the session it was
  bound to (`Compendium.complete_registry/2`): the signed request sent to
  the registry and what its success does done, as the `registry` tool
  completes a terminal's; the outcome is the flash the browser returns
  with.

  A CYFR with no person yet offers nothing but the way to set up.
  """

  use PrismWeb, :live_view

  require Logger

  alias PrismWeb.Ops

  # Requests per address: the page is reached over the LiveView socket,
  # which passes no rate-limit plug, so this is its per-address bound, per
  # node, before any directory is read.
  @starts 30
  @window_ms 60_000
  @ticket_ttl_ms 60_000
  @not_owner "This server is not accepting sign-ins right now. Try again in a moment."
  @lost "This browser no longer holds the sign-in you began here, or a newer one replaced " <>
          "it, so nobody was signed in. Begin again below."
  @unavailable "The server could not sign you in just now. Try again."
  @rate_limited "Too many sign-ins from here. Try again in a minute."

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     # The browser that starts a sign-in is the only one allowed to finish
     # it: the session's CSRF token is the handle this origin already has
     # on that browser, and a person's session the one their requests for
     # a confirmation are bound to.
     |> assign(:bindings, bindings(session))
     # The session a registry signature completes under: the one its
     # request was bound to, which the answer was just taken under.
     |> assign(:session_token, session[to_string(CyfrWeb.SignInResponse.session_key())])
     |> assign(:browser_binding, session["_csrf_token"])
     # `connect_info` is readable only here, so the address a request is
     # charged to is captured at mount and carried.
     |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
     # The browser and system the session it signs in records.
     |> assign(:user_agent, if(connected?(socket), do: get_connect_info(socket, :user_agent)))
     |> assign(:page_title, "Sign in")
     |> assign(:set_up, set_up?())
     |> assign(:error, error_from_params(params)), layout: false}
  end

  # Every binding this browser's session cookie holds.
  defp bindings(session) do
    token = session[to_string(CyfrWeb.SignInResponse.session_key())]

    [{:browser, session["_csrf_token"]}] ++
      if(is_binary(token) and token != "",
        do: [{:session, Sanctum.Session.token_hash(token)}],
        else: []
      )
  end

  @impl true
  def handle_event("sign_in", _params, socket) do
    case minted(socket) do
      {:ok, url} -> {:noreply, push_event(socket, "account:hop", %{url: url})}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("account_answer", %{"answer" => answer}, socket)
      when is_binary(answer) and answer != "" do
    outcome =
      Sanctum.SignIn.answer(answer, socket.assigns.bindings,
        user_agent: socket.assigns.user_agent
      )

    {:noreply, answered(socket, outcome)}
  end

  def handle_event("account_answer", _params, socket), do: {:noreply, socket}

  defp minted(socket) do
    cond do
      not Arca.ControlPlane.held?() ->
        {:error, @not_owner}

      not is_binary(socket.assigns.browser_binding) ->
        {:error, @lost}

      Prima.RateLimiter.check({:sign_in, socket.assigns.client_ip}, @starts, @window_ms) != :ok ->
        {:error, @rate_limited}

      true ->
        case Sanctum.SignIn.request(:sign_in, {:browser, socket.assigns.browser_binding}) do
          {:ok, %{url: url}} -> {:ok, url}
          {:error, reason} -> {:error, sentence(reason)}
        end
    end
  end

  defp answered(socket, {:ok, %{purpose: :sign_in, session_token: token}}) do
    ticket = mint_ticket(token, socket.assigns.browser_binding)
    redirect(socket, to: ~p"/auth/passkey/complete/#{ticket}")
  end

  defp answered(socket, {:ok, %{purpose: :registry} = outcome}) do
    {kind, message} = registered(socket, outcome)
    socket |> put_flash(kind, message) |> redirect(to: outcome.back || ~p"/")
  end

  defp answered(socket, {:ok, %{back: back}}) when is_binary(back),
    do: redirect(socket, to: back)

  defp answered(socket, {:ok, _confirmed}), do: redirect(socket, to: ~p"/")

  defp answered(socket, {:error, reason}), do: assign(socket, :error, sentence(reason))

  defp registered(socket, outcome) do
    with {:ok, ctx} <-
           Sanctum.Caller.establish({:session, socket.assigns.session_token}, refresh: false),
         {:ok, result} <- Compendium.complete_registry(ctx, outcome) do
      {:info, done(outcome.registry_request, result)}
    else
      {:error, reason} -> {:error, "That did not go through: " <> Ops.error_message(reason)}
    end
  end

  # What a completed registry request did, in the person's words.
  defp done(%{operation: "tokens.mint"}, _result), do: "Your push tokens are synced."

  defp done(%{operation: "policy.accept", body: %{"policy_version" => version}}, _result),
    do: "You accepted the policies, version #{version}."

  defp done(%{operation: "appeal.file"}, _result),
    do: "Your appeal is filed. Moderators review every appeal."

  defp done(%{operation: "publisher.claim", body: %{"slug" => slug}}, %{
         "txt_record_key" => key,
         "txt_value" => value
       })
       when is_binary(key) and is_binary(value),
       do:
         "To prove #{slug} is yours, add a DNS TXT record #{key} with the value #{value}, " <>
           "then verify it."

  defp done(%{operation: "publisher.claim", body: %{"slug" => slug}}, _result),
    do: "Your claim of #{slug} is filed."

  defp done(%{operation: "publisher.verify", body: %{"slug" => slug}}, _result),
    do: "#{slug} is verified."

  # What each refusal reads as. A refusal of the answer itself says only
  # that this browser holds no sign-in to finish.
  defp sentence(:answer_refused), do: @lost
  defp sentence({:door, _reason}), do: Sanctum.Door.refusal_message()
  defp sentence(reason) when reason in [:unavailable, :no_directory], do: @unavailable

  defp sentence(reason) do
    if Prima.Refusal.reason?(reason) do
      Prima.Refusal.message(reason)
    else
      Logger.info("[LoginLive] a sign-in was refused: " <> Prima.LoggerContext.shape(reason))
      @unavailable
    end
  end

  # A one-time ticket bound to this browser, which sets the session's
  # cookie (`PrismWeb.PasskeyController`). Without the binding the ticket
  # would be a bearer credential for a whole session.
  defp mint_ticket(token, browser_binding) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:login_passkey_ticket, ticket},
      %{session_token: token, browser_binding: browser_binding},
      @ticket_ttl_ms
    )

    ticket
  end

  # Whether anyone is here yet: a CYFR with no person is set up by its
  # first person, through the setup link. A store that cannot answer shows
  # the sign-in, which answers for itself.
  defp set_up? do
    case Sanctum.Tenancy.Users.list_by_id(limit: 1) do
      {:ok, []} -> false
      _people_or_unanswered -> true
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

        <%!-- The system layer's hop to the account pages, and the return
              that hands this page the answer in the fragment. --%>
        <div id="account-return" phx-hook="SystemLayer" data-account="return" hidden></div>

        <div class="bg-gray-900 rounded-lg shadow-xl p-8 space-y-4">
          <div :if={!@set_up} data-test="not-set-up" class="space-y-3">
            <h2 class="text-lg font-medium text-white text-center">This CYFR is not set up yet</h2>
            <p class="text-sm text-gray-300 leading-relaxed">
              Its first person sets it up, and administers it, by opening the setup link that
              <code class="font-mono text-white">cyfr init</code>
              or <code class="font-mono text-white">cyfr setup</code>
              printed.
            </p>
          </div>

          <div :if={@set_up} class="space-y-4">
            <div
              :if={@error}
              role="alert"
              data-test="sign-in-error"
              class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
            >
              {@error}
            </div>

            <h2 class="text-lg font-medium text-white text-center">Sign in to continue</h2>

            <button
              type="button"
              phx-click="sign_in"
              data-test="sign-in"
              class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-indigo-900/60 hover:bg-indigo-900 text-white rounded-lg border border-indigo-700 transition-colors cursor-pointer"
            >
              Sign in with your account
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
