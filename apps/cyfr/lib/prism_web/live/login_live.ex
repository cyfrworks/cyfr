# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLive do
  @moduledoc """
  The sign-in page, and the return every request this CYFR mints comes
  back to.

  **Sign in with your account**, or **Create your account**: this CYFR
  mints a sign-in request bound to this browser, by its session's forgery
  token (`Sanctum.SignIn.request/3`), and the page sends the browser to the
  account pages with it (`account:hop`, the system layer's hop), at the
  sign page or the new-account page. Minting
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
  which sets the session's cookie (`PrismWeb.PasskeyController`). A new
  passkey, which the account pages answer for a browser holding none of
  the account's, is held for a device of the account to add, and the page
  shows its short code with the way on: approve it in Your devices on the
  box, then sign in with it. The page says the same for any account, so
  it tells nobody who has one here. A confirmation or a registry
  signature, answered in the tab the system layer opened, sends the
  browser back where its request named; one that named nowhere says it is
  done and closes its tab (`account:close`), since the page that asked
  goes on by itself.
  A registry signature is completed here first, under the session it was
  bound to (`Compendium.complete_registry/2`): the signed request sent to
  the registry and what its success does done, as the `registry` tool
  completes a terminal's; the outcome is the flash the browser returns
  with. The answer is checked, and a registry signature sent, off the
  event, in one call that outlives the page (`check/2`): the account's
  directory is read for the answer, a registry request has no total
  deadline, and the browser gives up on an event it waits on for 30
  seconds. The page answers the event at once and says it is checking.

  **The registry's terms.** A person accepts them once, when their
  account is made at the account pages; a later version asks nobody to
  accept again, and using the registry is accepting it. After a registry
  signature completes, the registry's current version
  (`registry/legal_version`: `policy_version`, `updated_at`) is held to
  the version this person was last shown, their own preference
  `registry_terms_seen` (`Sanctum.Tenancy.Users.put_prefs/2`). A version
  they were not shown is said in this tab, beside what the act did, with
  the date it changed and the way to read it, and is recorded only when
  the person goes on from it (Continue): a tab closed before that records
  nothing, and the next act says it again. With no version recorded yet,
  the current one is recorded and nothing is said, since the person
  accepted it when they made their account.

  The answer is the account service's word, read as untrusted data after
  the act is done: `policy_version` is 1 to 64 characters of letters,
  digits, `.`, `_` and `-`, starting with a letter or digit, and
  `updated_at` an RFC 3339 time in UTC. Any other answer, or none, is
  unreadable: nothing is said or recorded, and nothing in the read can
  change what the act did. The read runs in a task of its own bounded
  at 3 seconds; one that fails in any way or answers late says and records
  nothing, and the act's success shows. Continue records only for the
  person whose session still stands, checked again as an answer is
  (`session_caller/1`); a session ended meanwhile records nothing and
  goes to the sign-in.

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
  @signed_in_already "This browser is signed in already, from another tab."
  # A terms version the account service names: the module doc's rule.
  # How long the act's success waits for the terms' read before it shows
  # without a notice.
  @terms_read_ms 3_000
  @terms_version ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     # The browser that starts a sign-in is the only one allowed to finish
     # it: the session's CSRF token is the handle this origin already has
     # on that browser, and a person's session the one their requests for
     # a confirmation are bound to.
     |> assign(:bindings, bindings(session))
     |> assign(:browser_binding, session["_csrf_token"])
     # `connect_info` is readable only here, so the address a request is
     # charged to is captured at mount and carried.
     |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
     # The browser and system the session it signs in records.
     |> assign(:user_agent, if(connected?(socket), do: get_connect_info(socket, :user_agent)))
     |> assign(:page_title, "Sign in")
     |> assign(:set_up, set_up?())
     # True while an answer handed here is checked, and a registry
     # signature it carries sent.
     |> assign(:checking, false)
     # The short code of a new passkey this browser offered, while it
     # waits for a device of the account to add it.
     |> assign(:waiting, nil)
     |> assign(:confirmed, false)
     |> assign(:signed_in_already, false)
     |> assign(:notice, notice_from_params(params))
     # A completed registry signature whose terms notice is shown here
     # before the browser goes back (`terms_notice/1`).
     |> assign(:terms_changed, nil)
     |> assign(:error, error_from_params(params)), layout: false}
  end

  # Every binding this browser's session cookie holds. The session is
  # held by its row key (`Sanctum.Session.token_hash/1`), never its token,
  # since a socket's assigns print in its crash reports.
  defp bindings(session) do
    token = session[to_string(CyfrWeb.SignInResponse.session_key())]

    [{:browser, session["_csrf_token"]}] ++
      if(is_binary(token) and token != "",
        do: [{:session, Sanctum.Session.token_hash(token)}],
        else: []
      )
  end

  @impl true
  def handle_event("sign_in", _params, socket), do: {:noreply, hop(socket, :sign)}
  def handle_event("create", _params, socket), do: {:noreply, hop(socket, {:new, nil})}

  # Only what the page holds is used; the event's parameters are not read.
  def handle_event("terms_seen", _params, %{assigns: %{terms_changed: %{} = notice}} = socket) do
    case session_caller(socket.assigns.bindings) do
      {:ok, %{user_id: user_id}} when user_id == notice.user_id ->
        record_seen(user_id, notice.version)
        {:noreply, redirect(socket, to: notice.back)}

      _ended ->
        {:noreply, redirect(socket, to: ~p"/login")}
    end
  end

  def handle_event("terms_seen", _params, socket), do: {:noreply, socket}

  def handle_event("account_answer", _params, %{assigns: %{checking: true}} = socket),
    do: {:noreply, socket}

  def handle_event("account_answer", %{"answer" => answer}, socket)
      when is_binary(answer) and answer != "",
      do: {:noreply, socket |> assign(:checking, true) |> check(answer)}

  def handle_event("account_answer", _params, socket), do: {:noreply, socket}

  defp hop(socket, page) do
    case minted(socket, page) do
      {:ok, url} -> push_event(socket, "account:hop", %{url: url})
      {:error, message} -> assign(socket, :error, message)
    end
  end

  defp minted(socket, page) do
    cond do
      not Arca.ControlPlane.held?() ->
        {:error, @not_owner}

      not is_binary(socket.assigns.browser_binding) ->
        {:error, @lost}

      Prima.RateLimiter.check({:sign_in, socket.assigns.client_ip}, @starts, @window_ms) != :ok ->
        {:error, @rate_limited}

      true ->
        case Sanctum.SignIn.request(:sign_in, {:browser, socket.assigns.browser_binding},
               page: page
             ) do
          {:ok, %{url: url}} -> {:ok, url}
          {:error, reason} -> {:error, sentence(reason)}
        end
    end
  end

  defp answered(socket, {:ok, %{purpose: :sign_in, session_token: token}}) do
    ticket = mint_ticket(token, socket.assigns.browser_binding)
    redirect(socket, to: ~p"/auth/passkey/complete/#{ticket}")
  end

  defp answered(socket, {:ok, %{purpose: :sign_in, waiting: code}}),
    do: socket |> assign(:waiting, code) |> assign(:error, nil)

  defp answered(socket, {:ok, %{back: back}}) when is_binary(back),
    do: redirect(socket, to: back)

  defp answered(socket, {:ok, %{purpose: :confirm}}),
    do: socket |> assign(:confirmed, true) |> push_event("account:close", %{})

  defp answered(socket, {:ok, _done}), do: redirect(socket, to: ~p"/")

  defp answered(socket, {:error, :signed_in_already}),
    do: socket |> assign(:signed_in_already, true) |> assign(:error, @signed_in_already)

  defp answered(socket, {:error, reason}), do: assign(socket, :error, sentence(reason))

  @impl true
  def handle_async(:answer, {:ok, {:registered, back, {kind, message}, nil}}, socket),
    do: {:noreply, socket |> put_flash(kind, message) |> redirect(to: back)}

  # A notice comes only with a completed act (`registered/2`).
  def handle_async(:answer, {:ok, {:registered, back, {:info, message}, notice}}, socket) do
    {:noreply,
     socket
     |> assign(:checking, false)
     |> assign(:terms_changed, Map.merge(notice, %{back: back, message: message}))}
  end

  def handle_async(:answer, {:ok, outcome}, socket),
    do: {:noreply, socket |> assign(:checking, false) |> answered(outcome)}

  # Only the node's shutdown stops it (`run_to_end/1`).
  def handle_async(:answer, {:exit, reason}, socket) do
    Logger.warning("[LoginLive] an answer's check exited: " <> Prima.LoggerContext.shape(reason))
    {:noreply, socket |> assign(:checking, false) |> assign(:error, @unavailable)}
  end

  # The answer, checked off the event against the request it answers,
  # under the bindings the page read from this browser's cookie at mount,
  # and what its purpose does done (`Sanctum.SignIn.answer/3`). It acts as
  # no session: the request it answers, taken from the store when the
  # check begins, is bound to this browser and names whose answer it must
  # be. A registry signature it carries is completed in the same call
  # (`registered/2`), under the session the request was bound to. It runs
  # to its end whether or not the page is still there (`run_to_end/1`):
  # the request is spent when the check begins, so everything it asked
  # for is done here or not at all. Stopped in flight, a mint the registry
  # made would be a live token this CYFR never stored, which the registry
  # reaps only after a year idle. Only the page's own steps wait for the
  # page: the sign-in's one-time ticket and the redirect, which only a
  # browser still there can use.
  defp check(socket, answer) do
    bindings = socket.assigns.bindings
    user_agent = socket.assigns.user_agent

    start_async(
      socket,
      :answer,
      fn -> run_to_end(fn -> checked(answer, bindings, user_agent) end) end,
      supervisor: Prism.TaskSupervisor
    )
  end

  defp checked(answer, bindings, user_agent) do
    case Sanctum.SignIn.answer(answer, bindings, user_agent: user_agent) do
      {:ok, %{purpose: :registry} = outcome} ->
        {result, notice} = registered(bindings, outcome)
        {:registered, outcome.back || ~p"/", result, notice}

      # A sign-in begun in a tab whose binding another tab's sign-in
      # replaced: this browser holds a session now, which is said.
      {:error, :answer_refused} = refused ->
        if match?({:ok, _}, session_caller(bindings)),
          do: {:error, :signed_in_already},
          else: refused

      outcome ->
        outcome
    end
  end

  defp registered(bindings, outcome) do
    with {:ok, ctx} <- session_caller(bindings),
         {:ok, result} <- Compendium.complete_registry(ctx, outcome) do
      {{:info, done(outcome.registry_request, result)}, terms_notice(ctx)}
    else
      {:error, reason} ->
        {{:error, "That did not go through: " <> Ops.error_message(reason)}, nil}
    end
  end

  # The account service's current terms held to the version this person
  # was last shown (the module doc): `%{user_id, version, changed_on,
  # read}` when it is one they were not shown, or nil. The act is done by
  # now, so this answers only "show this" or "show nothing": the read runs
  # in its own task, which reads and decides and writes nothing, and a
  # task that raises, throws, exits or outlives `@terms_read_ms` shows and
  # records nothing. Only a decision that arrived inside the bound is
  # acted on here: a silent first record is written by this process.
  defp terms_notice(ctx) do
    # Not linked to this process or the page: the task's end reaches here
    # only as its monitor's message. Past the bound it is killed, and the
    # shutdown takes its reply and monitor message from the mailbox, so a
    # late answer is dropped, never read as anything else.
    task = Task.Supervisor.async_nolink(Prism.TaskSupervisor, fn -> read_terms(ctx) end)

    case Task.yield(task, @terms_read_ms) do
      {:ok, {:show, notice}} ->
        notice

      {:ok, {:record, user_id, version}} ->
        record_seen(user_id, version)
        nil

      {:ok, :nothing} ->
        nil

      {:exit, _reason} ->
        nil

      nil ->
        Task.shutdown(task, :brutal_kill)
        nil
    end
  end

  # What the terms call for: `{:show, notice}`, `{:record, user_id,
  # version}` for a person with no version recorded, or `:nothing`.
  defp read_terms(ctx) do
    with {:ok, answer} <- Ops.call_tool(ctx, "registry/legal_version", %{}),
         {:ok, version, changed} <- terms(answer),
         {:ok, user} <- Sanctum.Tenancy.Users.get(ctx.user_id) do
      case Sanctum.Tenancy.Users.prefs(user)["registry_terms_seen"] do
        ^version -> :nothing
        nil -> {:record, user.id, version}
        _older -> {:show, notice(ctx, version, changed)}
      end
    else
      _unread -> :nothing
    end
  end

  defp terms(%{"policy_version" => version, "updated_at" => at})
       when is_binary(version) and is_binary(at) do
    with true <- Regex.match?(@terms_version, version),
         {:ok, changed, 0} <- DateTime.from_iso8601(at) do
      {:ok, version, changed}
    else
      _unreadable -> :unreadable
    end
  end

  defp terms(_answer), do: :unreadable

  defp notice(ctx, version, changed) do
    %{
      user_id: ctx.user_id,
      version: version,
      changed_on: Calendar.strftime(changed, "%-d %B %Y"),
      read: if(route = PrismWeb.Focus.route_of(ctx), do: PrismWeb.Focus.path(route, "/legal"))
    }
  end

  # The person's own record of the version they were shown; one not
  # written is said again at their next act.
  defp record_seen(user_id, version) do
    with {:ok, user} <- Sanctum.Tenancy.Users.get(user_id),
         {:ok, _user} <-
           Sanctum.Tenancy.Users.put_prefs(user, %{"registry_terms_seen" => version}) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[LoginLive] the account service's terms version shown was not recorded: " <>
            Prima.LoggerContext.shape(reason)
        )
    end
  end

  # The caller a registry signature completes under: the session its
  # request was bound to, read from the store when the answer arrives, as
  # a holder of a session's row key reads it (`Sanctum.Session.load_by_hash/1`),
  # then established and held to the person's standing as a session is.
  defp session_caller(bindings) do
    with {:session, hash} <- List.keyfind(bindings, :session, 0, {:error, :unauthenticated}),
         {:ok, stored} <- stored_session(hash),
         {:ok, ctx} <- Sanctum.Caller.establish_context(stored) do
      Sanctum.Caller.revalidate_session(ctx)
    end
  end

  defp stored_session(hash) do
    case Sanctum.Session.load_by_hash(hash) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, :invalid_session} -> {:error, :unauthenticated}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # What a completed registry request did, in the person's words.
  defp done(%{operation: "tokens.mint"}, _result), do: "Your push tokens are synced."

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

  defp sentence(:too_many_waiting),
    do:
      "Too many browsers already ask to add a passkey to this account. Each is forgotten " <>
        "five minutes after it was asked: try again then."

  defp sentence({:door, _reason}), do: Sanctum.Door.refusal_message()
  defp sentence(:unavailable), do: @unavailable

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

  defp error_from_params(_), do: nil

  defp notice_from_params(%{"error" => "signed_out"}), do: "You signed out."
  defp notice_from_params(_), do: nil

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

          <p
            :if={@checking}
            role="status"
            data-test="answer-checking"
            class="text-sm text-gray-300 text-center"
          >
            Checking what you signed. You will see the answer when it comes.
          </p>

          <div :if={@terms_changed} data-test="terms-changed" class="space-y-4">
            <p
              role="status"
              data-test="registry-done"
              class="text-sm text-gray-200"
            >
              {@terms_changed.message}
            </p>
            <p
              role="status"
              data-test="terms-notice"
              class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-sm text-gray-200"
            >
              The account service's terms changed on {@terms_changed.changed_on}. They are now version {@terms_changed.version}, and using the account service means you accept them.
              <a
                :if={@terms_changed.read}
                href={@terms_changed.read}
                data-test="terms-read"
                class="underline"
              >
                Read the terms
              </a>
            </p>
            <button
              type="button"
              phx-click="terms_seen"
              data-test="terms-continue"
              class="block w-full text-center px-4 py-3 bg-indigo-900/60 hover:bg-indigo-900 text-white rounded-lg border border-indigo-700 transition-colors cursor-pointer"
            >
              Continue
            </button>
          </div>

          <div :if={@confirmed} role="status" data-test="confirmed" class="space-y-2 text-center">
            <h2 class="text-lg font-medium text-white">Confirmed</h2>
            <p class="text-sm text-gray-300">
              This tab closes by itself. If it stays open, close it: the page that asked goes on.
            </p>
          </div>

          <div :if={@set_up and !@checking and !@confirmed and !@terms_changed} class="space-y-4">
            <p
              :if={@notice}
              role="status"
              data-test="sign-in-notice"
              class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-sm text-gray-200"
            >
              {@notice}
            </p>
            <div
              :if={@error}
              role="alert"
              data-test="sign-in-error"
              class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
            >
              {@error}
              <.link :if={@signed_in_already} navigate={~p"/"} class="underline">Go to CYFR</.link>
            </div>

            <div
              :if={@waiting}
              role="status"
              data-test="passkey-waiting"
              class="rounded-lg border border-indigo-700 px-4 py-3 text-sm text-gray-300 space-y-2"
            >
              <p class="font-medium text-white">Approve this browser's passkey on your box</p>
              <p>
                On your CYFR box's screen, open Your devices, check that it shows the code
                <span class="font-mono text-white" data-test="passkey-code">{@waiting}</span>
                and approve it. Then sign in below with your passkey. If nobody approves it
                within five minutes it is forgotten, and nothing is added.
              </p>
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
            <button
              type="button"
              phx-click="create"
              data-test="create-account"
              class="w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
            >
              Create your account
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
