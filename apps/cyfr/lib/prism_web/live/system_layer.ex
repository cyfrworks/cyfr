# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer do
  @moduledoc """
  The system layer: what Prism alone draws above every frame — grant,
  unlock, sign-in and credential-entry prompts, and safe mode. It presents
  a prompt and never decides one: the operation a confirmation dispatches
  is decided where the change is, in Sanctum, which checks the caller's
  standing and any fresh confirmation the change needs.

  The shell mounts it once, as `id: "system-layer"` with the page's
  `context`. A prompt (`PrismWeb.SystemLayer.Prompt`) arrives only by
  `send_update(PrismWeb.SystemLayer, id: "system-layer", prompt: prompt)`;
  `prompt: nil` clears the open one. A prompt that arrives while another
  is open waits behind it in arrival order; one whose id is already open
  or waiting is the same prompt and is taken once.

  Each prompt's outcome goes to the parent LiveView as
  `{:system_layer, id, :confirmed | :dismissed | {:refused, reason}}`. A
  malformed prompt is not drawn and is `{:refused, :invalid_prompt}`. A
  refused confirmation shows its sentence, reports `{:refused, reason}`
  and stays open, so the person can dismiss it.

  A prompt that confirms an action (`Sanctum.Pairing`'s action table) is
  shown with a confirm control only to a client with a person behind it
  who can give a proof (`Sanctum.Pairing.can_confirm?/1`); any other
  client is told to confirm it from a signed-in browser. That is a
  display rule and decides nothing: a confirmation that arrives anyway is
  dispatched like any other, and the operation answers it. No client
  holds a rank.

  What a confirmation dispatches, through `PrismWeb.Ops.call_tool/3`:

    * a grant — `profile.commit` with the commit arguments the consent
      sheet (`PrismWeb.ConsentSheetComponent`) sends;
    * a credential entry — `vault.create`, an `api_key` entry under the
      subject's name holding the one value typed, which travels on the
      shell's LiveView socket, is never assigned, rendered or logged, and
      never reaches a frame (its parameter name is on the redaction
      roster, `Prima.Sanitizer`);
    * safe mode's default desktop — `layout.edit` at the revision safe mode
      was entered at; a layout published since is reported and nothing is
      merged. Trying again dispatches nothing. Safe mode has no dismissal;
      its `:confirmed` tells the parent the person chose, and the parent
      runs frames again from the layout. The layer stops and starts no
      frame itself;
    * a sign-in — nothing: identity is established at the authentication
      boundary, so confirming leaves for the sign-in page;
    * an unlock — no operation unlocks the vault, so an unlock prompt has
      no confirm control and can only be dismissed.

  The browser half (`assets/js/system_layer/`) draws the prompt in the
  top layer after leaving fullscreen and pointer lock, moves focus into it
  and returns focus on close; Escape dismisses every prompt but safe mode.
  Every prompt but safe mode is modal and holds focus. Safe mode is a
  top-layer popover that leaves the page operable, so the assistant's
  panel, which Prism draws, is neither covered nor disabled by it.
  """

  use PrismWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Prism.SafeMode
  alias PrismWeb.Ops
  alias PrismWeb.SystemLayer.Prompt
  alias Sanctum.Pairing

  @sign_in_path "/login"

  @impl true
  def mount(socket) do
    {:ok, assign(socket, current: nil, queue: [], error: nil)}
  end

  @impl true
  def update(%{prompt: prompt} = assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :prompt))
    {:ok, arrive(socket, prompt)}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # ---------------------------------------------------------------------------
  # Arrival and the queue
  # ---------------------------------------------------------------------------

  defp arrive(socket, nil), do: advance(socket)

  defp arrive(socket, prompt) do
    case Prompt.validate(prompt) do
      {:ok, prompt} ->
        cond do
          known?(socket, prompt.id) -> socket
          is_nil(socket.assigns.current) -> assign(socket, current: prompt, error: nil)
          true -> assign(socket, queue: socket.assigns.queue ++ [prompt])
        end

      {:error, :invalid_prompt} ->
        report(Prompt.id_of(prompt), {:refused, :invalid_prompt})
        socket
    end
  end

  defp known?(%{assigns: %{current: current, queue: queue}}, id) do
    match?(%{id: ^id}, current) or Enum.any?(queue, &(&1.id == id))
  end

  defp advance(%{assigns: %{queue: [next | rest]}} = socket),
    do: assign(socket, current: next, queue: rest, error: nil)

  defp advance(socket), do: assign(socket, current: nil, queue: [], error: nil)

  defp report(id, outcome), do: send(self(), {:system_layer, id, outcome})

  defp settle(socket, prompt, :confirmed) do
    report(prompt.id, :confirmed)
    advance(socket)
  end

  defp refuse(socket, prompt, reason, sentence) do
    report(prompt.id, {:refused, reason})
    assign(socket, :error, sentence)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    case socket.assigns.current do
      %{id: ^id} = prompt ->
        if dismissable?(prompt) do
          report(id, :dismissed)
          {:noreply, advance(socket)}
        else
          {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("confirm", %{"id" => id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, [:grant, :sign_in]) do
        {:ok, prompt} -> confirm(socket, prompt)
        :none -> {:noreply, socket}
      end
    end)
  end

  # The value is read out of the event's parameters and handed to the
  # dispatch; nothing here assigns, renders or logs it.
  def handle_event("enter_credential", %{"prompt_id" => id} = params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, [:credential_entry]) do
        {:ok, prompt} -> {:noreply, enter_credential(socket, prompt, Map.get(params, "secret"))}
        :none -> {:noreply, socket}
      end
    end)
  end

  def handle_event("choose", %{"id" => id, "offer" => offer}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, prompt} <- open(socket, id, [:safe_mode]),
           {:ok, offer} <- offer(offer) do
        {:noreply, choose(socket, prompt, offer)}
      else
        _none -> {:noreply, socket}
      end
    end)
  end

  # An event names the prompt it was drawn for, so a late click or Escape
  # meant for a prompt already settled never acts on the next one.
  defp open(socket, id, kinds) do
    case socket.assigns.current do
      %{id: ^id, kind: kind} = prompt -> if kind in kinds, do: {:ok, prompt}, else: :none
      _other -> :none
    end
  end

  defp offer("retry"), do: {:ok, :retry}
  defp offer("default"), do: {:ok, :default}
  defp offer(_other), do: :error

  # ---------------------------------------------------------------------------
  # Confirmations
  # ---------------------------------------------------------------------------

  defp confirm(socket, %{kind: :sign_in} = prompt) do
    {:noreply, socket |> settle(prompt, :confirmed) |> redirect(to: @sign_in_path)}
  end

  defp confirm(socket, %{kind: :grant, subject: subject} = prompt) do
    args = %{
      "decisions" => subject.decisions,
      "plan_token" => subject.plan.plan_token,
      "proof" => subject.preview.proof,
      "commit_digest" => subject.preview.commit_digest,
      "expected_consent_revision" => Map.get(subject.plan, :expected_consent_revision)
    }

    {:noreply, dispatched(socket, prompt, Ops.call_tool(socket, "profile/commit", args))}
  end

  defp enter_credential(socket, %{subject: subject} = prompt, secret) do
    case present(secret) do
      :ok ->
        args = %{
          "name" => subject.name,
          "kind" => "api_key",
          "fields" => %{subject.field => secret}
        }

        dispatched(socket, prompt, Ops.call_tool(socket, "vault/create", args))

      :blank ->
        assign(socket, :error, "Enter the credential to save it.")
    end
  end

  defp choose(socket, %{subject: safe_mode} = prompt, offer) do
    case SafeMode.choose(safe_mode, offer) do
      :retry ->
        settle(socket, prompt, :confirmed)

      {:publish, document} ->
        args = %{"document" => Prima.Layout.to_json(document), "revision" => safe_mode.revision}
        dispatched(socket, prompt, Ops.call_tool(socket, "layout/edit", args))

      {:error, :not_offered} ->
        socket
    end
  end

  defp dispatched(socket, prompt, {:ok, _result}), do: settle(socket, prompt, :confirmed)

  defp dispatched(socket, %{kind: :safe_mode} = prompt, {:error, {:conflict, _} = reason}) do
    refuse(
      socket,
      prompt,
      reason,
      "Your layout changed since safe mode opened, so nothing was changed. " <>
        "Try again to load the layout as it is now."
    )
  end

  defp dispatched(socket, prompt, {:error, reason}),
    do: refuse(socket, prompt, reason, Ops.error_message(reason))

  defp present(secret) when is_binary(secret) do
    if String.trim(secret) == "", do: :blank, else: :ok
  end

  defp present(_secret), do: :blank

  # ---------------------------------------------------------------------------
  # Who can confirm
  # ---------------------------------------------------------------------------

  defp dismissable?(%{kind: kind}), do: kind != :safe_mode

  # A display rule: it hides a control and never decides. A prompt that
  # confirms no action offers its control to every client; one that does,
  # to a client with a person behind it who can give a proof.
  defp may_confirm?(_context, %{action: nil}), do: true
  defp may_confirm?(%Sanctum.Context{} = context, _prompt), do: Pairing.can_confirm?(context)
  defp may_confirm?(_context, _prompt), do: false

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        may: assigns.current && may_confirm?(assigns[:context], assigns.current),
        safe_mode: match?(%{kind: :safe_mode}, assigns.current)
      )

    ~H"""
    <div
      id={@id}
      phx-hook="SystemLayer"
      class="contents"
      data-open={to_string(not is_nil(@current))}
      data-prompt-id={@current && @current.id}
      data-dismissable={to_string(not is_nil(@current) and dismissable?(@current))}
      data-mode={if @safe_mode, do: "popover", else: "modal"}
    >
      <dialog
        id={"#{@id}-dialog"}
        phx-mounted={JS.ignore_attributes(["open"])}
        popover={@safe_mode && "manual"}
        role={if @safe_mode, do: "alertdialog", else: "dialog"}
        aria-modal={to_string(not @safe_mode)}
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        class={[
          "m-auto w-full max-w-lg rounded-lg border border-gray-700 bg-gray-900 p-6 text-gray-100 shadow-xl",
          not @safe_mode && "backdrop:bg-black/70"
        ]}
      >
        <div :if={@current} class="space-y-4" data-kind={@current.kind}>
          <h2 id={"#{@id}-title"} class="text-lg font-semibold">
            {title(@current)}
          </h2>
          <p id={"#{@id}-description"} class="text-sm text-gray-300">
            {description(@current)}
          </p>

          <.standing prompt={@current} may={@may} />

          <.body prompt={@current} may={@may} myself={@myself} id={@id} />

          <p :if={@error} role="alert" class="rounded border border-red-500 p-2 text-sm">
            <span class="font-semibold">Not done:</span> {@error}
          </p>

          <.controls prompt={@current} may={@may} myself={@myself} id={@id} />

          <p :if={@queue != []} class="text-xs text-gray-400">
            {waiting(@queue)}
          </p>
        </div>
      </dialog>
    </div>
    """
  end

  attr :prompt, :map, required: true
  attr :may, :boolean, required: true

  # Said only where the control is hidden: a client with no person behind
  # it cannot give a proof, and the person confirms from a signed-in browser.
  defp standing(%{prompt: %{action: nil}} = assigns), do: ~H""
  defp standing(%{may: true} = assigns), do: ~H""

  defp standing(assigns) do
    ~H"""
    <p class="text-sm" data-standing="none">
      This client has no person behind it, so it cannot confirm this. Confirm it from a
      signed-in browser.
    </p>
    """
  end

  attr :prompt, :map, required: true
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  defp body(%{prompt: %{kind: :grant}} = assigns) do
    ~H"""
    <section aria-labelledby={"#{@id}-grant-summary"}>
      <h3 id={"#{@id}-grant-summary"} class="text-sm font-medium">You are approving</h3>
      <ul class="mt-1 list-disc pl-5 text-sm">
        <li :for={line <- @prompt.subject.preview.summary}>{line}</li>
      </ul>
    </section>
    """
  end

  defp body(%{prompt: %{kind: :credential_entry}, may: true} = assigns) do
    ~H"""
    <form
      id={"#{@id}-credential"}
      phx-submit="enter_credential"
      phx-target={@myself}
      class="space-y-2"
    >
      <input type="hidden" name="prompt_id" value={@prompt.id} />
      <label for={"#{@id}-secret"} class="block text-sm font-medium">
        {@prompt.subject.field} for {@prompt.subject.name}
      </label>
      <input
        id={"#{@id}-secret"}
        name="secret"
        type="password"
        autocomplete="off"
        required
        class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400"
      />
    </form>
    """
  end

  defp body(%{prompt: %{kind: :safe_mode}} = assigns) do
    ~H"""
    <p class="text-sm">No app runs while safe mode is on. Choose how to go on.</p>
    """
  end

  defp body(assigns), do: ~H""

  attr :prompt, :map, required: true
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  defp controls(%{prompt: %{kind: :safe_mode}} = assigns) do
    assigns = assign(assigns, :offers, SafeMode.offers(assigns.prompt.subject))

    ~H"""
    <div class="flex flex-wrap justify-end gap-2">
      <button
        :for={offered <- @offers}
        type="button"
        phx-click="choose"
        phx-target={@myself}
        phx-value-id={@prompt.id}
        phx-value-offer={offered.offer}
        class={[button_class(offered.offer == :retry)]}
      >
        {offer_label(offered)}
      </button>
    </div>
    """
  end

  defp controls(assigns) do
    ~H"""
    <div class="flex flex-wrap justify-end gap-2">
      <button
        type="button"
        phx-click="dismiss"
        phx-target={@myself}
        phx-value-id={@prompt.id}
        class={button_class(false)}
      >
        Dismiss
      </button>
      <button
        :if={@may and @prompt.kind in [:grant, :sign_in]}
        type="button"
        phx-click="confirm"
        phx-target={@myself}
        phx-value-id={@prompt.id}
        class={button_class(true)}
      >
        {confirm_label(@prompt)}
      </button>
      <button
        :if={@may and @prompt.kind == :credential_entry}
        type="submit"
        form={"#{@id}-credential"}
        class={button_class(true)}
      >
        Save to vault
      </button>
    </div>
    """
  end

  defp button_class(primary?) do
    [
      "rounded-md px-3 py-2 text-sm font-semibold focus:outline-none focus-visible:ring-2",
      "focus-visible:ring-blue-300 focus-visible:ring-offset-2 focus-visible:ring-offset-gray-900",
      if(primary?,
        do: "bg-blue-600 text-white hover:bg-blue-500",
        else: "border border-gray-600 text-gray-100 hover:bg-gray-800"
      )
    ]
  end

  defp title(%{kind: :grant, subject: %{ref: ref}}), do: "Grant #{ref}"
  defp title(%{kind: :unlock}), do: "Unlock the vault"
  defp title(%{kind: :sign_in}), do: "Sign in"

  defp title(%{kind: :credential_entry, subject: %{name: name}}),
    do: "Enter a credential for #{name}"

  defp title(%{kind: :safe_mode}), do: "Safe mode"

  defp description(%{kind: :grant}),
    do:
      "Approve what this app may use and reach, as listed below. Nothing is granted until you do."

  defp description(%{kind: :unlock, subject: subject}) do
    concerning = if name = subject[:name], do: " for #{name}", else: ""

    "An app asks to unlock the vault#{concerning}. Nothing on this server unlocks the " <>
      "vault, so there is nothing to confirm here."
  end

  defp description(%{kind: :sign_in, subject: subject}),
    do: subject[:message] || "Sign in to go on. You leave this page to do it."

  defp description(%{kind: :credential_entry}),
    do:
      "The value goes straight to your vault, sealed at rest. No app sees it, and it is " <>
        "never shown again."

  defp description(%{kind: :safe_mode, subject: %SafeMode{reason: :not_ready}}),
    do: "Your desktop did not start."

  defp description(%{kind: :safe_mode, subject: %SafeMode{reason: :crashed}}),
    do: "Your desktop stopped working."

  defp description(%{kind: :safe_mode, subject: %SafeMode{reason: :requested}}),
    do: "You turned safe mode on."

  defp confirm_label(%{kind: :grant}), do: "Grant"
  defp confirm_label(%{kind: :sign_in}), do: "Sign in"

  defp offer_label(%{offer: :retry}), do: "Try again"
  defp offer_label(%{offer: :default}), do: "Use the default desktop"

  defp waiting([_one]), do: "One more prompt is waiting."
  defp waiting(queue), do: "#{length(queue)} more prompts are waiting."
end
