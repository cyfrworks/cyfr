# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AdmissionCard do
  @moduledoc """
  The two screens a new local person meets, by setup (`PrismWeb.SetupLive`),
  an invitation (`PrismWeb.InviteLive`) or open sign-in
  (`PrismWeb.LoginLive`), and the steps those pages share. Settings'
  identity card (`PrismWeb.IdentityCard`) draws screen 2's states for a
  person who resumes.

  **Screen 1** (`name_screen/1`) takes the name. Each change of the field
  is checked (`check/3`): its spelling, then cyfr.run's answer for that
  one name (`Sanctum.Handle.resolve/1`), asked in a message the page sends
  itself, so the field says it is asking before the answer comes, and
  asked only for the name still typed. "Create a
  passkey" is disabled while the name is taken, misspelled or empty; a
  free name, and a name cyfr.run did not answer for, may go on, since
  the claim on screen 2 decides. The tap draws the recovery secret and
  its request id in the browser (`system_layer/index.js`), which sends
  them with the passkey's registration in the page's `<mode>_passkey`
  event; the page adds the name it holds (`identity/2`) and admits the
  person (`Sanctum.Newcomer.admit/2`), who exists from that commit.

  **Screen 2** (`code_screen/1`) runs before the browser holds a session.
  The page keeps the admission's session token, attempt id and recovery
  code in its own process (`admitted/2`; the socket's private storage,
  inspected without the token or the code), and acts as that person
  through the gate: `registry.register` registers the identity at
  cyfr.run and claims the name, in a message the page sends itself once
  the screen says it is registering, and its answer or refusal is the
  screen's state. The page's process runs the two asks itself: no task
  outlives it, and a page that ends asks nothing more. Once registered, the code goes to
  the page's hook once, in a push (`admission_code`), never in an
  assign, and the hook draws it into the screen's own place. "I saved
  it" runs `person.recovery_code_saved` and hands the browser the
  passkey sign-in's one-time ticket (`ticket/3`), marked
  `notice: :recovery_code_saved`, so the person lands in CYFR signed in
  with the offer of another code. A readmission whose code was saved
  earlier answers no code, and goes on once registered.

  Where each refusal leaves the person: cyfr.run silent (directory or
  registry) is `silent`, with Try again; the name taken or kept by
  cyfr.run at the claim is `taken` or `reserved`, with a field for
  another name (`registry.register` with `name`); a refused identity is
  `refused` and a CYFR that reaches no cyfr.run is `no_registry`, with
  no way on from here. A reload or a lost socket ends the process, and
  the person resumes in Settings after signing in with the passkey.

  The screens' controls carry `data-test` names: `admission-name` (the
  form), `admission-name-input`, `admission-name-check` (with
  `data-check`), `admission-create`, `admission-error`, `admission-code`
  (with `data-state`), `recovery-code` (empty in this markup),
  `admission-copy`, `admission-saved`, `admission-retry`,
  `admission-rename-input` and `admission-rename`.
  """

  use PrismWeb, :html

  import Phoenix.LiveView, only: [put_private: 3, push_event: 3, redirect: 2]

  alias PrismWeb.Ops

  @ticket_ttl_ms 60_000
  @held :cyfr_admission

  @no_registry "This CYFR does not reach cyfr.run, so it cannot make your name. Ask whoever " <>
                 "runs this CYFR."
  @invalid "A name is lowercase letters and digits joined by single hyphens, at most 39 " <>
             "characters."

  @typedoc "Where the name typed on screen 1 stands."
  @type check :: :idle | :checking | :free | :taken | :invalid | :unavailable

  @typedoc "Screen 2's state."
  @type state :: :registering | :code | :silent | :taken | :reserved | :refused | :no_registry

  defmodule Admitted do
    @moduledoc """
    What the page that admitted a person keeps of the admission while
    screen 2 runs: their session token, their enrollment's attempt id,
    identifier and name, and the recovery code until it went to the
    browser (`pushed`). It is inspected without the token or the code, so
    a crash report that prints the socket never prints them.
    """

    @enforce_keys [:session_token, :attempt_id, :identifier, :name]
    defstruct [:session_token, :attempt_id, :identifier, :name, :code, pushed: false]

    @type t :: %__MODULE__{
            session_token: String.t(),
            attempt_id: String.t(),
            identifier: String.t(),
            name: String.t() | nil,
            code: String.t() | nil,
            pushed: boolean()
          }

    defimpl Inspect, for: PrismWeb.AdmissionCard.Admitted do
      use Boundary, classify_to: PrismWeb
      import Inspect.Algebra

      def inspect(held, opts) do
        shown = Map.take(held, [:attempt_id, :identifier, :name, :pushed])
        concat(["#PrismWeb.AdmissionCard.Admitted<", to_doc(shown, opts), ">"])
      end
    end
  end

  # ---- the page's state --------------------------------------------------------

  @doc "Screen 1 with nothing typed: the assigns the screens read."
  @spec mount(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket) do
    assign(socket,
      admission_name: "",
      admission_check: :idle,
      admission_state: nil,
      admission_from: nil,
      admission_error: nil
    )
  end

  @doc "Whether a passkey may be created for the name typed now."
  @spec startable?(Phoenix.LiveView.Socket.t()) :: boolean()
  def startable?(%{assigns: %{admission_state: nil, admission_check: check}})
      when check in [:taken, :invalid, :idle],
      do: false

  def startable?(%{assigns: %{admission_state: nil, admission_name: name}}),
    do: Prima.ComponentRef.valid_personal_slug?(name)

  def startable?(_socket), do: false

  @doc """
  The name typed on screen 1 (`params["name"]`), checked: its spelling at
  once, then cyfr.run's answer, asked when the page hands this card its
  own message (`handle_info/2`). `limit:` is `{key, count, window_ms}`, the page's
  per-address bound on asking; past it the name is not asked, and is
  checked at the claim as one cyfr.run did not answer for.
  """
  @spec check(Phoenix.LiveView.Socket.t(), map(), keyword()) :: Phoenix.LiveView.Socket.t()
  def check(socket, params, opts \\ [])

  def check(%{assigns: %{admission_state: nil}} = socket, %{"name" => typed}, opts)
      when is_binary(typed) do
    name = String.trim(typed)
    socket = assign(socket, admission_name: name, admission_error: nil)

    cond do
      name == "" ->
        assign(socket, :admission_check, :idle)

      not Prima.ComponentRef.valid_personal_slug?(name) ->
        assign(socket, :admission_check, :invalid)

      not within(Keyword.get(opts, :limit)) ->
        assign(socket, :admission_check, :unavailable)

      true ->
        send(self(), {:admission_check, name})
        assign(socket, :admission_check, :checking)
    end
  end

  def check(socket, _params, _opts), do: socket

  defp within(nil), do: true

  defp within({key, count, window_ms}),
    do: Prima.RateLimiter.check(key, count, window_ms) == :ok

  # cyfr.run's answer for one name: someone holds it, or no one does. A
  # name it keeps for itself reads as free here and is refused at the
  # claim; anything unanswered reads as silent.
  defp ask(name) do
    case Sanctum.Handle.resolve(name) do
      {:ok, _held} -> :taken
      {:error, :not_found} -> :free
      {:error, :invalid_handle} -> :invalid
      {:error, _unanswered} -> :unavailable
    end
  end

  @doc """
  The new person's identity from the page's `<mode>_passkey` event
  (`recovery_secret` and `request_id`, drawn by the browser) and the name
  the page holds (`Sanctum.Newcomer.identity/1`).
  """
  @spec identity(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Sanctum.Newcomer.identity()} | {:error, {:invalid_argument, String.t()}}
  def identity(socket, params) do
    params
    |> Map.take(["recovery_secret", "request_id"])
    |> Map.put("name", socket.assigns.admission_name)
    |> Sanctum.Newcomer.identity()
  end

  @doc """
  The sentence an admission's refusal reads as on screen 1. A deployment
  that pins no directory admits no local person (`:no_directory`), which
  reads as a CYFR that reaches no cyfr.run. A page answers its own
  refusals (a closed setup link, an invitation that admits no one, a
  closed door) before it asks this.
  """
  @spec refusal(term()) :: String.t()
  def refusal(:no_directory), do: @no_registry

  def refusal(:registration_refused),
    do: "That passkey could not be registered here. Try again."

  def refusal(reason), do: Ops.error_message(reason)

  @doc "The sentence a ceremony that did not finish reads as on screen 1."
  @spec ceremony_failed() :: String.t()
  def ceremony_failed, do: "The passkey was not created, so nothing was saved. Try again."

  @doc """
  The person an admission made, held for screen 2, whose drive begins:
  `registry.register` as that person.
  """
  @spec admitted(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def admitted(socket, %{session_token: token, recovery: recovery}) when is_binary(token) do
    held = %Admitted{
      session_token: token,
      attempt_id: recovery.attempt_id,
      identifier: recovery.identifier,
      name: recovery.name,
      code: recovery[:code]
    }

    socket
    |> put_private(@held, held)
    |> assign(admission_name: recovery.name || socket.assigns.admission_name)
    |> register(%{})
  end

  # ---- screen 2's events -------------------------------------------------------

  @doc """
  Screen 2's events, on the page that admitted: `admission_retry` asks
  cyfr.run again, `admission_rename` claims another name, and
  `admission_saved` says the code is saved and signs the person in, by
  a ticket bound to the page's `browser_binding` assign. Any other event,
  or one the screen's state does not offer, changes nothing.
  """
  @spec event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def event("admission_retry", _params, %{assigns: %{admission_state: :silent}} = socket),
    do: register(socket, %{})

  def event("admission_rename", %{"name" => typed}, %{assigns: %{admission_state: from}} = socket)
      when from in [:taken, :reserved] and is_binary(typed) do
    name = String.trim(typed)

    if Prima.ComponentRef.valid_personal_slug?(name),
      do:
        socket
        |> assign(admission_from: from, admission_name: name)
        |> register(%{"name" => name}),
      else: assign(socket, :admission_error, @invalid)
  end

  def event("admission_saved", _params, %{assigns: %{admission_state: :code}} = socket) do
    case held(socket) do
      %Admitted{} = held ->
        saved =
          as_person(held.session_token, fn ctx ->
            Ops.call_tool(ctx, "person/recovery_code_saved", %{"attempt_id" => held.attempt_id})
          end)

        case saved do
          {:ok, _saved} -> signed_in(socket, held, :recovery_code_saved)
          {:error, reason} -> assign(socket, :admission_error, Ops.error_message(reason))
        end

      nil ->
        socket
    end
  end

  def event(_event, _params, socket), do: socket

  @doc """
  The messages the page sent itself, for its `handle_info/2`: screen 1's
  check of the name, asked only while that name is still the one typed,
  and screen 2's drive; `:pass` for a message that is not theirs.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()} | :pass
  def handle_info({:admission_check, name}, socket) do
    if socket.assigns.admission_name == name and socket.assigns.admission_state == nil,
      do: {:noreply, assign(socket, :admission_check, ask(name))},
      else: {:noreply, socket}
  end

  def handle_info(
        {:admission_register, args},
        %{assigns: %{admission_state: :registering}} = socket
      ) do
    %Admitted{session_token: token} = held(socket)

    {:noreply,
     registered(socket, as_person(token, &Ops.call_tool(&1, "registry/register", args)))}
  end

  def handle_info({:admission_register, _args}, socket), do: {:noreply, socket}
  def handle_info(_message, _socket), do: :pass

  # ---- the drive ----------------------------------------------------------------

  defp held(socket), do: socket.private[@held]

  # The screen says it is registering, then the page asks.
  defp register(socket, args) do
    send(self(), {:admission_register, args})
    assign(socket, admission_state: :registering, admission_error: nil)
  end

  defp as_person(token, call) do
    case Sanctum.Caller.establish({:session, token}, refresh: false) do
      {:ok, ctx} -> call.(ctx)
      {:error, _refused} = refused -> refused
    end
  end

  defp registered(socket, {:ok, %{"attempt_id" => attempt_id, "name" => name} = answer}) do
    held = %{
      held(socket)
      | attempt_id: attempt_id,
        identifier: answer["identifier"],
        name: name
    }

    socket =
      socket |> put_private(@held, held) |> assign(admission_name: name, admission_from: nil)

    case held do
      # A readmission whose code was saved before: nothing is left to save.
      %Admitted{code: nil, pushed: false} ->
        signed_in(socket, held, nil)

      %Admitted{code: code} when is_binary(code) ->
        socket
        |> put_private(@held, %{held | code: nil, pushed: true})
        |> push_event("admission_code", %{code: code})
        |> assign(admission_state: :code, admission_error: nil)

      %Admitted{} ->
        assign(socket, admission_state: :code, admission_error: nil)
    end
  end

  defp registered(socket, {:error, reason}) do
    case refused_state(reason) do
      {:invalid, sentence} ->
        assign(socket,
          admission_state: socket.assigns.admission_from || :silent,
          admission_error: sentence
        )

      {state, sentence} ->
        assign(socket, admission_state: state, admission_error: sentence)
    end
  end

  @doc """
  The state `registry.register`'s refusal leaves screen 2 in, and the
  sentence the error line shows beside it, if any: `{:invalid, sentence}`
  for another name the server refused, which leaves the screen where it
  was.
  """
  @spec refused_state(term()) :: {state() | :invalid, String.t() | nil}
  def refused_state(reason) do
    case reason_of(reason) do
      silent when silent in [:directory_unavailable, :registry_unavailable] -> {:silent, nil}
      :name_taken -> {:taken, nil}
      :name_reserved -> {:reserved, nil}
      :directory_refused -> {:refused, nil}
      :no_registry -> {:no_registry, nil}
      :invalid_argument -> {:invalid, Ops.error_message(reason)}
      _other -> {:silent, Ops.error_message(reason)}
    end
  end

  defp reason_of(%Prima.Refusal{reason: reason}), do: reason
  defp reason_of({reason, _detail}) when is_atom(reason), do: reason
  defp reason_of(reason) when is_atom(reason), do: reason
  defp reason_of(_reason), do: nil

  # The person goes in, signed in by the passkey sign-in's ticket.
  defp signed_in(socket, held, notice) do
    ticket = ticket(held.session_token, socket.assigns.browser_binding, notice)
    redirect(socket, to: ~p"/auth/passkey/complete/#{ticket}")
  end

  @doc """
  The passkey sign-in's one-time ticket for `session_token`, bound to
  this browser (`browser_binding`, the session's forgery token), with
  the flash its landing shows (`notice`, `PrismWeb.PasskeyController`).
  """
  @spec ticket(String.t(), String.t() | nil, :recovery_code_saved | nil) :: String.t()
  def ticket(session_token, browser_binding, notice \\ nil) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    payload =
      %{session_token: session_token, browser_binding: browser_binding}
      |> then(&if(notice, do: Map.put(&1, :notice, notice), else: &1))

    Arca.Cache.put({:login_passkey_ticket, ticket}, payload, @ticket_ttl_ms)
    ticket
  end

  # ---- screen 1 -----------------------------------------------------------------

  attr :name, :string, required: true
  attr :check, :atom, required: true
  attr :error, :string, default: nil
  slot :inner_block

  @doc """
  Screen 1: the page's own sentences (`inner_block`), the name field and
  its check, and "Create a passkey", which the page's hook takes
  (`data-webauthn-start`).
  """
  def name_screen(assigns) do
    assigns = assign(assigns, :disabled, assigns.check in [:taken, :invalid, :idle])

    ~H"""
    <div class="space-y-4">
      {render_slot(@inner_block)}
      <form
        id="admission-name"
        phx-change="admission_check"
        phx-submit="admission_check"
        data-test="admission-name"
        class="space-y-2"
      >
        <label for="admission-name-input" class="text-sm text-gray-300">Your name</label>
        <div class="flex gap-2">
          <span class="self-center text-gray-400">@</span>
          <input
            id="admission-name-input"
            name="name"
            type="text"
            value={@name}
            maxlength="39"
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            phx-debounce="400"
            data-test="admission-name-input"
            class="flex-1 min-w-0 rounded-md bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white"
          />
        </div>
        <p class="text-xs text-gray-400" data-test="admission-name-check" data-check={@check}>
          {check_sentence(@check)}
        </p>
      </form>
      <p class="text-sm text-gray-300 leading-relaxed">
        People find you by this name on every CYFR. It is yours for life and cannot be changed.
      </p>
      <p
        :if={@error}
        role="alert"
        data-test="admission-error"
        class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
      >
        {@error}
      </p>
      <button
        type="button"
        data-webauthn-start
        data-test="admission-create"
        disabled={@disabled}
        class="w-full px-4 py-3 bg-indigo-700 hover:bg-indigo-600 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors cursor-pointer"
      >
        Create a passkey
      </button>
      <p class="text-xs text-gray-500">This creates your name at cyfr.run under its terms.</p>
    </div>
    """
  end

  @doc "What the check under the name field says."
  @spec check_sentence(check()) :: String.t()
  def check_sentence(:idle), do: "Lowercase letters, digits and hyphens."
  def check_sentence(:checking), do: "Asking cyfr.run."
  def check_sentence(:free), do: "Free. Lowercase letters, digits and hyphens."
  def check_sentence(:taken), do: "Taken. Choose another."
  def check_sentence(:invalid), do: @invalid

  def check_sentence(:unavailable),
    do: "cyfr.run did not answer, so your name is checked again when you create it."

  # ---- screen 2 -----------------------------------------------------------------

  attr :state, :atom, required: true
  attr :name, :string, default: nil
  attr :error, :string, default: nil
  attr :target, :any, default: nil
  slot :code

  @doc """
  Screen 2 in `state`. Its `code` state shows, by default, the place the
  hook draws the code into, Copy and "I saved it"; the `code` slot
  replaces them (Settings' "Show your recovery code").
  """
  def code_screen(assigns) do
    ~H"""
    <section data-test="admission-code" data-state={@state} class="space-y-4">
      <h2 class="text-lg font-medium text-white">Your recovery code</h2>
      <p
        :if={@error}
        role="alert"
        data-test="admission-error"
        class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
      >
        {@error}
      </p>

      <p :if={@state == :registering and is_binary(@name)} class="text-sm text-gray-300">
        Registering @{@name} at cyfr.run.
      </p>
      <p :if={@state == :registering and is_nil(@name)} class="text-sm text-gray-300">
        Registering at cyfr.run.
      </p>

      <div :if={@state == :code} class="space-y-4">
        <%= if @code != [] do %>
          {render_slot(@code)}
        <% else %>
          <.drawn_code target={@target} />
        <% end %>
      </div>

      <div :if={@state == :silent} class="space-y-3">
        <p :if={is_nil(@error)} class="text-sm text-gray-300">
          cyfr.run did not answer. Try again.
        </p>
        <.button phx-click="admission_retry" phx-target={@target} data-test="admission-retry">
          Try again
        </.button>
      </div>

      <div :if={@state in [:taken, :reserved]} class="space-y-3">
        <p :if={@state == :taken} class="text-sm text-gray-300">
          Someone took @{@name} a moment ago. Choose another name.
        </p>
        <p :if={@state == :reserved} class="text-sm text-gray-300">
          cyfr.run keeps @{@name} for itself. Choose another name.
        </p>
        <form
          id="admission-rename"
          phx-submit="admission_rename"
          phx-target={@target}
          class="space-y-2"
        >
          <label for="admission-rename-input" class="text-sm text-gray-300">Your name</label>
          <div class="flex gap-2">
            <span class="self-center text-gray-400">@</span>
            <input
              id="admission-rename-input"
              name="name"
              type="text"
              value=""
              maxlength="39"
              autocomplete="off"
              autocapitalize="none"
              spellcheck="false"
              data-test="admission-rename-input"
              class="flex-1 min-w-0 rounded-md bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white"
            />
            <.button type="submit" data-test="admission-rename">Use this name</.button>
          </div>
        </form>
      </div>

      <p :if={@state == :refused} class="text-sm text-gray-300">
        cyfr.run refused this identity. Ask whoever runs this CYFR.
      </p>
      <p :if={@state == :no_registry} class="text-sm text-gray-300">
        {no_registry()}
      </p>
    </section>
    """
  end

  @doc "The sentence a CYFR that reaches no cyfr.run reads as."
  @spec no_registry() :: String.t()
  def no_registry, do: @no_registry

  attr :target, :any, default: nil

  # The code's place, the browser's alone (`phx-update="ignore"`), so no
  # render of the server's carries or erases the code the hook drew, nor
  # the Copy button's "Copied.".
  defp drawn_code(assigns) do
    ~H"""
    <div
      id="admission-code-slot"
      data-recovery-code="admission"
      phx-update="ignore"
      class="flex items-center gap-3"
    >
      <p data-test="recovery-code" class="flex-1 font-mono text-lg break-all text-white"></p>
      <button
        type="button"
        data-test="admission-copy"
        class="rounded-md border border-gray-600 px-2 py-1 text-xs font-semibold hover:bg-gray-800"
      >
        Copy
      </button>
    </div>
    <p class="text-sm text-gray-300 leading-relaxed">
      If this CYFR is ever lost, this is the one thing that brings you back. Save it in your password manager, or print this page. Once you say you saved it, CYFR forgets it.
    </p>
    <.button phx-click="admission_saved" phx-target={@target} data-test="admission-saved">
      I saved it
    </.button>
    """
  end
end
