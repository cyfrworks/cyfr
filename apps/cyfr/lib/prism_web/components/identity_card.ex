# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.IdentityCard do
  @moduledoc """
  The person's identity and handle, one component for the setup page
  (`PrismWeb.SetupLive`) and Settings (`PrismWeb.SettingsLive`). It reads
  where the person stands from `person.status` (`Sanctum.Recovery.status/1`)
  and their preferences, and drives the existing enrollment ceremony
  (`person.enroll`, `person.enroll_abandon`, the kit and its
  acknowledgement) through the system layer's recovery prompts
  (`PrismWeb.SystemLayer.Recovery`), which hold every seed and kit line;
  this component never does.

  | Where the person stands | The card offers |
  |---|---|
  | not enrolled | choose a handle, then enroll |
  | an enrollment the directory has not accepted, its prompt open here | nothing beside the prompt, which retries under the same request id and seed |
  | the same, with no prompt here holding its seed | "Abandon and start again", then enroll under a new seed |
  | accepted, kit not acknowledged | show the kit again, under a fresh confirmation |
  | kit acknowledged, a handle wanted | "Claim @name" |
  | claimed | the handle, and whether the registry publishes this CYFR's address with it |

  A handle is checked live against the registry's answer for it
  (`Sanctum.Handle.resolve/1`): taken, free, or not answered now. Only a
  free one is chosen, and it is kept in the person's preferences
  (`handle_wanted`) until it is claimed, so a page closed, a registry
  unreachable or a connection lost mid-step resumes at the state the
  card reads. The claim waits for the kit's acknowledgement: it accepts
  the registry's current policies, then claims the handle
  (`registry.legal_accept`, `registry.claim_personal`), and a claim whose
  answer was lost answers success when repeated. A taken handle asks for
  another; the enrollment stands. When this card began the enrollment, the
  acknowledgement claims at once; otherwise "Claim @name" does.

  The view that embeds it embeds the system layer, mounts
  `PrismWeb.SystemLayer.Hook`, and hands it the reports of its prompts
  (`prompt?/1`) as `report: {prompt_id, outcome}`; `reload: true` reads
  again after a change the view made itself. The `:enrolled` slot holds
  the view's own controls for an enrolled person.

  Its controls carry `data-test` names: `identity` (with
  `data-provenance`, `data-enrollment` and `data-state`),
  `identity-identifier`, `identity-directory`, `identity-remote`,
  `identity-handle` (the handle form), `identity-handle-input`,
  `identity-handle-check` (with `data-check`), `identity-choose`,
  `identity-abandon`, `identity-kit` (with `data-attempt` and
  `data-phase`), `identity-kit-show`, `identity-claim`, `identity-claim-error`,
  `identity-claimed`, `identity-publish` (with `data-published`) and
  `identity-error`.
  """

  use PrismWeb, :live_component

  alias PrismWeb.Ops
  alias PrismWeb.SystemLayer
  alias PrismWeb.SystemLayer.Recovery
  alias Sanctum.Tenancy.Users

  @prompt_prefix "identity-recovery-"
  @events ~w(check choose abandon show_kit claim publish)

  @doc "The card's component id."
  @spec id() :: String.t()
  def id, do: "identity-card"

  @doc "Whether `prompt_id` names a recovery prompt this card opened."
  @spec prompt?(term()) :: boolean()
  def prompt?(@prompt_prefix <> _rest), do: true
  def prompt?(_prompt_id), do: false

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       status: nil,
       wanted: nil,
       handle: nil,
       legal_path: nil,
       handle_input: "",
       check: :idle,
       enrolling: nil,
       claim_on_ack: false,
       claim_error: nil,
       choose_another: false,
       published: :unread,
       error: nil,
       loaded: false,
       enrolled: []
     )}
  end

  # Every read and act runs on a current context (`CyfrWeb.ContextGuard.guard/2`):
  # a component's callbacks run without the view's hooks.
  @impl true
  def update(%{report: {prompt_id, outcome}}, socket) do
    socket =
      case {socket.assigns.enrolling, outcome} do
        {_enrolling, {:refused, _reason}} -> socket
        {^prompt_id, _ended} -> assign(socket, :enrolling, nil)
        _other -> socket
      end

    {:ok, guarded(socket, &(&1 |> load() |> claim_when_acknowledged()))}
  end

  def update(%{reload: true}, socket), do: {:ok, guarded(socket, &load/1)}

  def update(assigns, socket) do
    socket = socket |> assign(Map.take(assigns, [:context, :offer, :enrolled, :id]))
    {:ok, if(socket.assigns.loaded, do: socket, else: guarded(socket, &load/1))}
  end

  defp guarded(socket, fun) do
    case CyfrWeb.ContextGuard.guard(socket, &{:noreply, fun.(&1)}) do
      {:noreply, socket} -> socket
    end
  end

  # ---- reads ------------------------------------------------------------------

  defp load(%{assigns: %{context: ctx}} = socket) do
    socket = assign(socket, :loaded, true)

    with {:ok, status} <- Ops.call_tool(ctx, "person/status", %{}),
         {:ok, user} <- Users.get(ctx.user_id) do
      socket
      |> assign(status: status, error: nil)
      |> assign(:wanted, Users.prefs(user)["handle_wanted"])
      |> assign(:handle, user[:namespace])
      |> assign(:legal_path, legal_path(ctx.user_id))
      |> read_publication()
    else
      {:error, reason} -> assign(socket, status: nil, error: Ops.error_message(reason))
    end
  end

  # The registry's own pages are read in CYFR, under the person's athanor.
  defp legal_path(user_id) do
    case Users.personal_athanor_id(user_id) do
      {:ok, athanor_id} -> PrismWeb.Focus.path(athanor_id, "/legal")
      :none -> nil
    end
  end

  # Whether the registry publishes this CYFR's address with the handle:
  # its live answer for the handle (`Sanctum.Handle.resolve/1`).
  defp read_publication(%{assigns: %{handle: handle}} = socket) when is_binary(handle) do
    start_async(socket, :publication, fn -> {handle, Sanctum.Handle.resolve(handle)} end)
  end

  defp read_publication(socket), do: assign(socket, :published, :unread)

  @impl true
  def handle_async(:publication, {:ok, {handle, answer}}, %{assigns: %{handle: handle}} = socket) do
    published =
      case answer do
        {:ok, %{address: address}} -> is_binary(address)
        {:error, _unanswered} -> :unknown
      end

    {:noreply, assign(socket, :published, published)}
  end

  def handle_async(:check, {:ok, {handle, answer}}, %{assigns: %{handle_input: handle}} = socket) do
    check =
      case answer do
        {:ok, _held} -> :taken
        {:error, :not_found} -> :free
        {:error, :invalid_handle} -> :invalid
        {:error, _unanswered} -> :unavailable
      end

    {:noreply, assign(socket, :check, check)}
  end

  def handle_async(_name, _result, socket), do: {:noreply, socket}

  # ---- events -----------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket) when event in @events,
    do: CyfrWeb.ContextGuard.guard(socket, &act(event, params, &1))

  defp act("check", %{"handle" => typed}, socket) when is_binary(typed) do
    handle = String.trim(typed)

    socket = assign(socket, handle_input: handle, claim_error: nil)

    cond do
      handle == "" ->
        {:noreply, assign(socket, :check, :idle)}

      not Prima.ComponentRef.valid_personal_slug?(handle) ->
        {:noreply, assign(socket, :check, :invalid)}

      true ->
        {:noreply,
         socket
         |> assign(:check, :checking)
         |> start_async(:check, fn -> {handle, Sanctum.Handle.resolve(handle)} end)}
    end
  end

  defp act("choose", %{"handle" => typed}, socket) when is_binary(typed) do
    handle = String.trim(typed)

    if handle == socket.assigns.handle_input and socket.assigns.check == :free do
      case want(socket, handle) do
        {:ok, socket} -> {:noreply, after_choice(socket)}
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp act("abandon", _params, socket) do
    case Ops.call_tool(socket.assigns.context, "person/enroll_abandon", %{}) do
      {:ok, _abandoned} -> {:noreply, socket |> load() |> enroll()}
      {:error, reason} -> {:noreply, assign(socket, :error, Ops.error_message(reason))}
    end
  end

  defp act("show_kit", %{"attempt" => attempt_id}, socket),
    do: {:noreply, show(socket, &Recovery.kit(&1, attempt_id))}

  defp act("claim", _params, socket), do: {:noreply, claim(socket)}

  defp act("publish", %{"published" => published}, socket)
       when published in ["true", "false"] do
    case Ops.call_tool(socket.assigns.context, "registry/publish_address", %{
           "published" => published == "true"
         }) do
      {:ok, _answer} -> {:noreply, read_publication(assign(socket, :error, nil))}
      {:error, reason} -> {:noreply, assign(socket, :error, Ops.error_message(reason))}
    end
  end

  defp act(_event, _params, socket), do: {:noreply, socket}

  # ---- the steps --------------------------------------------------------------

  defp want(socket, handle) do
    with {:ok, user} <- Users.get(socket.assigns.context.user_id),
         {:ok, _user} <- Users.put_prefs(user, %{"handle_wanted" => handle}) do
      {:ok,
       assign(socket,
         wanted: handle,
         check: :idle,
         handle_input: "",
         claim_error: nil,
         choose_another: false
       )}
    else
      {:error, reason} -> {:error, assign(socket, :error, Ops.error_message(reason))}
    end
  end

  # A handle chosen before enrolling begins the enrollment; one chosen
  # once the kit is acknowledged (another, after a taken one) is claimed.
  defp after_choice(%{assigns: %{status: %{enrollment: "none"}}} = socket), do: enroll(socket)

  defp after_choice(%{assigns: %{status: %{enrollment: "enrolled"}}} = socket),
    do: claim(socket)

  defp after_choice(socket), do: socket

  defp enroll(%{assigns: %{status: %{directory_url: url}}} = socket) do
    socket
    |> assign(:claim_on_ack, true)
    |> show(&Recovery.enrollment(&1, url), :enrolling)
  end

  defp enroll(socket), do: socket

  # A recovery prompt, under an id of this card's, in the view's layer.
  defp show(socket, build, remember \\ nil) do
    prompt_id = @prompt_prefix <> Integer.to_string(System.unique_integer([:positive]))

    case build.(prompt_id) do
      {:ok, prompt} ->
        SystemLayer.show(SystemLayer.layer_id(), prompt)
        if remember, do: assign(socket, remember, prompt_id), else: socket

      {:error, :invalid_prompt} ->
        assign(socket, :error, "That cannot be shown here.")
    end
  end

  # The enrollment this card began, its kit acknowledged: the handle is
  # claimed at once.
  defp claim_when_acknowledged(%{assigns: %{claim_on_ack: true}} = socket) do
    if state(socket.assigns) == :claim,
      do: socket |> assign(:claim_on_ack, false) |> claim(),
      else: socket
  end

  defp claim_when_acknowledged(socket), do: socket

  defp claim(%{assigns: %{context: ctx, wanted: handle}} = socket) when is_binary(handle) do
    with {:ok, %{"policy_version" => version}} when is_binary(version) <-
           Ops.call_tool(ctx, "registry/legal_version", %{}),
         {:ok, _accepted} <-
           Ops.call_tool(ctx, "registry/legal_accept", %{"policy_version" => version}),
         {:ok, _claimed} <- Ops.call_tool(ctx, "registry/claim_personal", %{"handle" => handle}),
         {:ok, socket} <- want(socket, nil) do
      load(socket)
    else
      {:error, %Phoenix.LiveView.Socket{} = socket} ->
        socket

      {:error, reason} ->
        claim_refused(socket, reason)

      {:ok, _no_version} ->
        assign(socket, :claim_error, "The registry did not name its current policies. Try again.")
    end
  end

  defp claim(socket), do: socket

  defp claim_refused(socket, reason) do
    message = Ops.error_message(reason)

    case refusal_reason(reason) do
      reason when reason in [:handle_taken, :handle_invalid, :namespace_reserved] ->
        assign(socket, claim_error: message, choose_another: true, check: :idle, handle_input: "")

      _retryable ->
        assign(socket, :claim_error, message)
    end
  end

  defp refusal_reason(%Prima.Refusal{reason: reason}), do: reason
  defp refusal_reason({reason, _detail}) when is_atom(reason), do: reason
  defp refusal_reason(reason) when is_atom(reason), do: reason
  defp refusal_reason(_reason), do: nil

  # ---- the state --------------------------------------------------------------

  defp state(%{status: nil}), do: :unread
  defp state(%{status: %{provenance: "remote"}}), do: :remote
  defp state(%{status: %{enrollment: "none"}}), do: :choose
  defp state(%{status: %{enrollment: "pending"}}), do: :pending

  defp state(%{status: %{enrollment: "enrolled", kits: kits}} = assigns) do
    cond do
      Enum.any?(kits, &(&1.kind == "enrollment")) -> :kit
      is_binary(assigns.handle) -> :claimed
      is_binary(assigns.wanted) and not assigns.choose_another -> :claim
      true -> :choose
    end
  end

  defp state(_assigns), do: :unread

  # ---- render -----------------------------------------------------------------

  attr :input, :string, required: true
  attr :check, :atom, required: true
  attr :target, :any, required: true
  attr :legal_path, :string, default: nil
  attr :label, :string, required: true

  defp handle_form(assigns) do
    ~H"""
    <form
      id="identity-handle"
      phx-change="check"
      phx-submit="choose"
      phx-target={@target}
      data-test="identity-handle"
      class="space-y-2"
    >
      <label for="identity-handle-input" class="text-sm text-gray-300">{@label}</label>
      <div class="flex gap-2">
        <span class="self-center text-gray-400">@</span>
        <input
          id="identity-handle-input"
          name="handle"
          type="text"
          value={@input}
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          phx-debounce="400"
          data-test="identity-handle-input"
          class="flex-1 min-w-0 rounded-md bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white"
        />
        <.button type="submit" disabled={@check != :free} data-test="identity-choose">
          Continue
        </.button>
      </div>
      <p class="text-xs text-gray-400" data-test="identity-handle-check" data-check={@check}>
        {check_sentence(@check)}
      </p>
      <p :if={@legal_path} class="text-xs text-gray-500">
        Claiming a handle accepts the registry's <.link navigate={@legal_path} class="underline">terms and policies</.link>.
      </p>
    </form>
    """
  end

  defp check_sentence(:idle), do: "Letters, digits and hyphens."
  defp check_sentence(:checking), do: "Asking the registry."
  defp check_sentence(:free), do: "Free."
  defp check_sentence(:taken), do: "Taken. Choose another."

  defp check_sentence(:invalid),
    do: "A handle is lowercase letters, digits and single hyphens, starting with a letter."

  defp check_sentence(:unavailable),
    do: "The registry does not answer now, so no handle can be chosen. Try again later."

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :state, state(assigns))

    ~H"""
    <section
      id={@id}
      data-test="identity"
      data-provenance={@status && @status.provenance}
      data-enrollment={@status && @status.enrollment}
      data-state={@state}
      class="space-y-3"
    >
      <h3 class="text-sm font-medium text-gray-400">Your identity</h3>

      <p :if={@error} role="alert" class="text-sm" data-test="identity-error">{@error}</p>
      <p :if={@state == :unread and is_nil(@error)} class="text-sm text-gray-400">
        Reading your identity.
      </p>

      <div :if={@status} class="space-y-3">
        <dl :if={@offer == "settings"} class="grid grid-cols-3 gap-2 text-sm">
          <dt class="text-xs text-gray-500 uppercase">Identifier</dt>
          <dd class="col-span-2 font-mono break-all" data-test="identity-identifier">
            {@status.identifier || "not enrolled"}
          </dd>
          <dt class="text-xs text-gray-500 uppercase">Directory</dt>
          <dd class="col-span-2 break-all" data-test="identity-directory">
            {@status.directory_url}
          </dd>
          <dt :if={@status.key_epoch} class="text-xs text-gray-500 uppercase">Key epoch</dt>
          <dd :if={@status.key_epoch} class="col-span-2 font-mono" title={@status.key_epoch}>
            {String.slice(@status.key_epoch, 0, 16) <> "…"}
          </dd>
        </dl>

        <p :if={@state == :remote} class="text-sm" data-test="identity-remote">
          Your keys are held at another CYFR, so your identity is enrolled, rotated and recovered there.
        </p>

        <div :if={@state == :choose} class="space-y-2">
          <p :if={@status.enrollment == "none"} class="text-sm text-gray-300">
            Choose a handle, and CYFR registers your identity at its directory and prints the kit
            that recovers it. The handle is claimed once you say the kit is saved.
          </p>
          <p
            :if={@claim_error}
            role="alert"
            class="text-sm text-red-300"
            data-test="identity-claim-error"
          >
            {@claim_error}
          </p>
          <.handle_form
            input={@handle_input}
            check={@check}
            target={@myself}
            legal_path={@legal_path}
            label={if @choose_another, do: "Choose another handle", else: "Your handle"}
          />
        </div>

        <div :if={@state == :pending} class="space-y-2">
          <p class="text-sm text-gray-300">
            Your enrollment is waiting for the directory's answer.
          </p>
          <div :if={is_nil(@enrolling)} class="space-y-2">
            <p class="text-sm text-gray-300">
              Only the browser that began it holds its kit. If that browser lost it, abandon it and enroll again with a new kit; a registration the directory may already hold stays there unused.
            </p>
            <.button
              variant="ghost"
              phx-click="abandon"
              phx-target={@myself}
              data-test="identity-abandon"
            >
              Abandon and start again
            </.button>
          </div>
        </div>

        <ul :if={@status.kits != []} class="space-y-2">
          <li
            :for={kit <- @status.kits}
            class="flex items-center justify-between gap-2 text-sm"
            data-test="identity-kit"
            data-attempt={kit.attempt_id}
            data-phase={kit.phase}
          >
            <span :if={kit.deliverable}>
              A printed kit ({kit_kind(kit)}) waits for you to say it is saved.
            </span>
            <span :if={not kit.deliverable}>
              A printed kit ({kit_kind(kit)}) is at {kit.phase}; finish it in the prompt that began it.
            </span>
            <.button
              :if={kit.deliverable}
              variant="ghost"
              phx-click="show_kit"
              phx-value-attempt={kit.attempt_id}
              phx-target={@myself}
              data-test="identity-kit-show"
            >
              Show kit
            </.button>
          </li>
        </ul>

        <div :if={@state == :claim} class="space-y-2">
          <p class="text-sm text-gray-300">
            Your kit is saved. Claim your handle at the registry.
          </p>
          <p
            :if={@claim_error}
            role="alert"
            class="text-sm text-red-300"
            data-test="identity-claim-error"
          >
            {@claim_error}
          </p>
          <.button phx-click="claim" phx-target={@myself} data-test="identity-claim">
            Claim @{@wanted}
          </.button>
        </div>

        <div :if={@state == :claimed} class="space-y-2" data-test="identity-claimed">
          <p class="text-sm text-gray-300">
            Your handle is <span class="font-mono text-white">@{@handle}</span>.
          </p>
          <div
            :if={@published in [true, false]}
            class="flex items-center justify-between gap-2 text-sm"
            data-test="identity-publish"
            data-published={to_string(@published)}
          >
            <span :if={@published}>
              The registry publishes this CYFR's address with your handle.
            </span>
            <span :if={not @published}>
              The registry does not publish this CYFR's address with your handle.
            </span>
            <.button
              variant="ghost"
              phx-click="publish"
              phx-value-published={to_string(not @published)}
              phx-target={@myself}
            >
              {if @published, do: "Withdraw it", else: "Publish it"}
            </.button>
          </div>
          <p :if={@published == :unknown} class="text-sm text-gray-400">
            The registry does not answer now, so whether it publishes this CYFR's address is not known.
          </p>
        </div>

        <div :if={@status.enrollment == "enrolled" and @state != :remote}>
          {render_slot(@enrolled, @status)}
        </div>
      </div>
    </section>
    """
  end

  defp kit_kind(%{kind: "enrollment"}), do: "your first"
  defp kit_kind(%{kind: "holder"}), do: "an added one"
  defp kit_kind(_kit), do: "a kit"
end
