# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.IdentityCard do
  @moduledoc """
  The person's name and identity in Settings (`PrismWeb.SettingsLive`). It
  reads where the person stands from `person.status`
  (`Sanctum.Recovery.status/1`) and opens the system layer's recovery
  prompts (`PrismWeb.SystemLayer.Recovery`), which hold every secret and
  recovery code; this component never does.

  | Where the person stands | The card shows |
  |---|---|
  | unread | that it is reading, or why it could not |
  | unfinished: no name recorded, or the first recovery code not saved | screen 2's states (`PrismWeb.AdmissionCard.code_screen/1`), which `registry.register` drives, and once registered "Show your recovery code" |
  | named | the name, the identifier for the command line, "Add another recovery code" and "What losing it costs" |
  | remote | that the name and recovery code are at the person's own CYFR |

  An unfinished person is one whose setup, invitation or sign-in page
  ended before they said their recovery code was saved. The card says
  "Registering" and asks `registry.register` in a task, whose answer it
  takes only for the focus it asked under (`CyfrWeb.ContextGuard.deliver/3`);
  the drive moves their one enrollment on and claims its name: a silent cyfr.run offers Try again,
  a name taken or kept by cyfr.run at the claim offers another name
  (`registry.register` with `name`), and a refused identity or a CYFR
  that reaches no cyfr.run is said, with no way on. Registered, "Show
  your recovery code" opens the "Your recovery code" prompt for the
  attempt `registry.register` answered, under one fresh confirmation,
  whose "I saved it" finishes the person.

  The view that embeds it embeds the system layer, mounts
  `PrismWeb.SystemLayer.Hook`, and hands it the reports of its prompts
  (`prompt?/1`) as `report: {prompt_id, outcome}`; `reload: true` reads
  again after a change the view made itself. The `:named` slot holds the
  view's own controls for a named person whose identity is registered.

  Its controls carry `data-test` names: `identity` (with `data-state`
  `unread`, `unfinished`, `named` or `remote`), `identity-name`,
  `identity-identifier`, `identity-add-code`, `identity-costs`,
  `identity-show-code`, `identity-remote` and `identity-error`, and
  screen 2's own (`admission-*`).
  """

  use PrismWeb, :live_component

  alias PrismWeb.AdmissionCard
  alias PrismWeb.Ops
  alias PrismWeb.SystemLayer
  alias PrismWeb.SystemLayer.Recovery

  @prompt_prefix "identity-recovery-"
  @events ~w(admission_retry admission_rename show_code add_code)

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
       error: nil,
       loaded: false,
       admission_state: nil,
       admission_name: nil,
       admission_error: nil,
       admission_from: nil,
       attempt_id: nil,
       named: []
     )}
  end

  # Every read and act runs on a current context (`CyfrWeb.ContextGuard.guard/2`):
  # a component's callbacks run without the view's hooks.
  @impl true
  def update(%{report: {_prompt_id, _outcome}}, socket) do
    {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, load(&1)})
    {:ok, socket}
  end

  def update(%{reload: true}, socket) do
    {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, load(&1)})
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:report, :reload]))

    if socket.assigns.loaded do
      {:ok, socket}
    else
      {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, load(&1)})
      {:ok, socket}
    end
  end

  # ---- reads ------------------------------------------------------------------

  # Where the person stands. An unfinished person's screen 2 is driven once
  # the card first sees them unfinished, after it said it is registering.
  defp load(%{assigns: %{context: ctx}} = socket) do
    socket = assign(socket, :loaded, true)

    case Ops.call_tool(ctx, "person/status", %{}) do
      {:ok, status} ->
        socket = assign(socket, status: status, error: nil)

        cond do
          state(socket.assigns) != :unfinished ->
            assign(socket, admission_state: nil, admission_error: nil, attempt_id: nil)

          is_nil(socket.assigns.admission_state) ->
            socket
            |> assign(:admission_name, wanted_name(status))
            |> register(%{})

          true ->
            socket
        end

      {:error, reason} ->
        assign(socket, status: nil, error: Ops.error_message(reason))
    end
  end

  # The name the person's enrollment wants registered, or the one recorded.
  defp wanted_name(%{name: name}) when is_binary(name), do: name

  defp wanted_name(%{kits: kits}),
    do: Enum.find_value(kits, fn kit -> kit.kind == "enrollment" && kit[:name] end)

  defp wanted_name(_status), do: nil

  # ---- events -----------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket) when event in @events,
    do: CyfrWeb.ContextGuard.guard(socket, &act(event, params, &1))

  defp act("admission_retry", _params, %{assigns: %{admission_state: :silent}} = socket),
    do: {:noreply, register(socket, %{})}

  defp act("admission_rename", %{"name" => typed}, %{assigns: %{admission_state: from}} = socket)
       when from in [:taken, :reserved] and is_binary(typed) do
    name = String.trim(typed)

    if Prima.ComponentRef.valid_personal_slug?(name),
      do:
        {:noreply,
         socket
         |> assign(admission_from: from, admission_name: name)
         |> register(%{"name" => name})},
      else: {:noreply, assign(socket, :admission_error, AdmissionCard.check_sentence(:invalid))}
  end

  defp act("show_code", %{"attempt" => attempt_id}, socket) when is_binary(attempt_id),
    do: {:noreply, show(socket, &Recovery.recovery_code(&1, attempt_id))}

  defp act("show_code", _params, %{assigns: %{admission_state: :code, attempt_id: id}} = socket)
       when is_binary(id),
       do: {:noreply, show(socket, &Recovery.recovery_code(&1, id))}

  defp act("add_code", _params, socket), do: {:noreply, show(socket, &Recovery.holder/1)}

  defp act(_event, _params, socket), do: {:noreply, socket}

  # ---- the drive --------------------------------------------------------------

  # The card says it is registering while the drive asks cyfr.run.
  defp register(%{assigns: %{context: ctx}} = socket, args) do
    tag = CyfrWeb.ContextGuard.capture(socket)

    socket
    |> assign(admission_state: :registering, admission_error: nil)
    |> start_async(:drive, fn -> {tag, Ops.call_tool(ctx, "registry/register", args)} end)
  end

  @impl true
  def handle_async(:drive, {:ok, {tag, answer}}, socket) do
    CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, registered(&1, answer)})
  end

  def handle_async(:drive, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, admission_state: :silent, admission_error: nil)}

  defp registered(socket, answer) do
    case answer do
      {:ok, %{"attempt_id" => attempt_id, "name" => name}} ->
        assign(socket,
          admission_state: :code,
          admission_name: name,
          admission_error: nil,
          admission_from: nil,
          attempt_id: attempt_id
        )

      {:error, reason} ->
        case AdmissionCard.refused_state(reason) do
          {:invalid, sentence} ->
            assign(socket,
              admission_state: socket.assigns.admission_from || :silent,
              admission_error: sentence
            )

          {state, sentence} ->
            assign(socket, admission_state: state, admission_error: sentence)
        end
    end
  end

  # A recovery prompt, under an id of this card's, in the view's layer.
  defp show(socket, build) do
    prompt_id = @prompt_prefix <> Integer.to_string(System.unique_integer([:positive]))

    case build.(prompt_id) do
      {:ok, prompt} ->
        SystemLayer.show(SystemLayer.layer_id(), prompt)
        socket

      {:error, :invalid_prompt} ->
        assign(socket, :error, "That cannot be shown here.")
    end
  end

  # ---- the state --------------------------------------------------------------

  defp state(%{status: nil}), do: :unread
  defp state(%{status: %{provenance: "remote"}}), do: :remote

  defp state(%{status: %{name: name, kits: kits}}) do
    if is_binary(name) and not Enum.any?(kits, &(&1.kind == "enrollment")),
      do: :named,
      else: :unfinished
  end

  defp state(_assigns), do: :unread

  # An added code whose recovery code waits to be saved: shown again from
  # here, since only it can finish that code.
  defp added(%{kits: kits}), do: Enum.filter(kits, &(&1.kind == "holder" and &1.deliverable))
  defp added(_status), do: []

  # ---- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, state: state(assigns), added: added(assigns.status))

    ~H"""
    <section id={@id} data-test="identity" data-state={@state} class="space-y-3">
      <h3 class="text-sm font-medium text-gray-400">Your name</h3>

      <p :if={@error} role="alert" class="text-sm" data-test="identity-error">{@error}</p>
      <p :if={@state == :unread and is_nil(@error)} class="text-sm text-gray-400">
        Reading your name.
      </p>

      <p :if={@state == :remote} class="text-sm" data-test="identity-remote">
        Your keys are at your CYFR, so your name and recovery code are there.
      </p>

      <div :if={@state == :unfinished} class="space-y-3">
        <p class="text-sm text-gray-300">Your name and recovery code are not finished.</p>
        <AdmissionCard.code_screen
          state={@admission_state}
          name={@admission_name}
          error={@admission_error}
          target={@myself}
        >
          <:code>
            <.button phx-click="show_code" phx-target={@myself} data-test="identity-show-code">
              Show your recovery code
            </.button>
          </:code>
        </AdmissionCard.code_screen>
      </div>

      <div :if={@state == :named} class="space-y-3">
        <p class="text-sm text-gray-300" data-test="identity-name">
          Your name is <span class="font-mono text-white">@{@status.name}</span>.
        </p>
        <p class="text-sm text-gray-400" data-test="identity-identifier">
          Your identifier, for the command line:
          <span class="font-mono break-all text-gray-200">{@status.identifier}</span>
        </p>
        <div class="flex flex-wrap gap-2">
          <.button
            variant="ghost"
            phx-click="add_code"
            phx-target={@myself}
            data-test="identity-add-code"
          >
            Add another recovery code
          </.button>
          <.button
            :for={kit <- @added}
            variant="ghost"
            phx-click="show_code"
            phx-value-attempt={kit.attempt_id}
            phx-target={@myself}
            data-test="identity-show-code"
          >
            Show your recovery code
          </.button>
        </div>
        <div :if={@status.enrollment == "enrolled"}>{render_slot(@named, @status)}</div>
      </div>

      <details
        :if={@state in [:named, :unfinished]}
        id="identity-costs"
        data-test="identity-costs"
        class="text-sm"
      >
        <summary class="cursor-pointer text-indigo-300 hover:text-indigo-200">
          What losing it costs
        </summary>
        <ol class="mt-2 list-decimal space-y-1 pl-5 text-gray-300">
          <li>
            Your identity is registered at cyfr.run. While cyfr.run cannot be reached, changing your keys, bringing your identity back and other CYFRs checking who you are all wait.
          </li>
          <li>
            Your recovery code brings your identity back on a new CYFR. Anyone who holds a copy can replace your keys, so keep it apart from your devices.
          </li>
          <li>
            Add a second recovery code before you rely on one. Only a code you hold can add another.
          </li>
          <li>
            If every recovery code is lost, nothing can add one. Your identity keeps working here, with no way back if this CYFR is lost.
          </li>
          <li>
            If this CYFR and every recovery code are lost, your identity is gone, and you start again with a new name.
          </li>
          <li>
            Bringing your identity back restores you alone, never your private data or the CYFR addresses your devices saved. You add those again from surviving devices or invitations.
          </li>
        </ol>
      </details>
    </section>
    """
  end
end
