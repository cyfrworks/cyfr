# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive do
  @moduledoc """
  The estate's AQUA, at `/a/<athanor>/aqua`: the soul and the roles it
  clones into — each with a prompt, a model and a capability allowlist,
  the estate's own (`Compendium.AquaTemplate` seeds them), edited by any
  member through the `aqua` tool — beside the page the soul reads first
  (`about-you` in a person's athanor, `about-us` in a group's, pinned
  through the `notes` tool), the notes kept here, and the scrolls it can
  read on demand. Every write from this page goes through the tool a
  card in chat goes through, so one gate answers for both.

  The page shows the tree of the estate in focus and nothing else: a
  person's own estate page edits their own tree, a group's page the
  group's. The soul reads only the tree it lives in, so a role in
  someone's private closet is not the group's to offer.

  Four sections, each a `Phoenix.LiveComponent` that owns its reads and
  its writes (`PrismWeb.AquaLive.Section` states the contract): the roster
  (`AgentsComponent`), the pinned page and the notes (`NotesComponent`),
  the scrolls (`ScrollsComponent`) and the shipped files
  (`RestoreComponent`). The page holds what they share — the provenance
  of every file in the tree, the model catalogue, the consent sheet — and
  loads one section per message, so a child LiveView's mount (the topbar,
  the panel) is answered between them rather than after them all.

  This is also where a person connects a model: the soul's catalyst
  needs an API key bound to it before AQUA can answer, and "Connect a
  model" opens the consent sheet for that catalyst — reachable in `lite`,
  so a box that never opens `dev` still gets its key in.
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PrismWeb.AquaLive.{AgentsComponent, NotesComponent, RestoreComponent, ScrollsComponent}
  alias PrismWeb.ConsentSheetComponent

  # Each section reloads on its own message, so a write refreshes what it
  # changed and nothing else: a note kept here does not re-read the
  # roster, a role renamed does not re-index the scrolls.
  @sections [:agents, :about, :notes, :skills]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "AQUA")
      |> assign(:active_nav, "aqua")
      |> assign(:loading, true)
      |> assign(:provenance, %{})
      |> assign(:consent_missing, [])
      |> assign(:models_by_provider, %{})
      |> assign(:catalyst_refs, %{})
      |> assign(:models_loaded, false)
      |> assign(:consent_sheet_ref, nil)

    # Subscribe before the load asks whether the estate is ready: a fill
    # that finishes in between must still reach this page.
    if connected?(socket) and socket.assigns[:context] do
      Phoenix.PubSub.subscribe(
        Emissary.PubSub,
        Cyfr.Topics.notify(socket.assigns.context.athanor_id)
      )

      # Paint first, load after: five tool reads and a registry walk stand
      # between the mount and the roster, and the frame shows its spinner
      # while they run.
      send(self(), :load)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("open_consent", %{"ref" => ref}, socket) when is_binary(ref) and ref != "" do
    {:noreply, assign(socket, :consent_sheet_ref, ref)}
  end

  # The dialog's backdrop and Escape; the sheet's own Cancel arrives as a message.
  def handle_event("close_consent", _params, socket) do
    {:noreply, assign(socket, :consent_sheet_ref, nil)}
  end

  # ============================================================================
  # Loads and refreshes
  # ============================================================================

  @impl true
  # Everything the load needs is queued from this one message: the
  # provenance is read here, each section's read is the `send_update/3`
  # message its component serves, and `:loaded` is queued last. Queued at
  # once, so a render asked for after this message is served is behind
  # them all — the settled page — while each read is still its own message,
  # so a child LiveView's mount (the topbar, the panel) is answered between
  # them rather than after them all.
  def handle_info(:load, socket) do
    socket = load_provenance(socket)
    load_agents(socket)
    load_notes(socket)
    load_skills(socket)
    send(self(), :loaded)
    {:noreply, load_models(socket)}
  end

  def handle_info(:loaded, socket), do: {:noreply, assign(socket, :loading, false)}

  # A model catalyst arrived (or did not): the agents section reads its
  # status again either way, and the picker's kept catalogue is dropped so
  # the new provider is offered.
  def handle_info({:catalyst_installed, ref, result}, socket) do
    socket =
      case result do
        {:ok, _} ->
          PrismWeb.ModelCatalog.forget(socket.assigns.context.athanor_id)
          put_flash(socket, :info, "Installed #{ref}.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not install #{ref}: #{error_message(reason)}")
      end

    send(self(), {:refresh, :agents})
    {:noreply, load_models(socket)}
  end

  # The estate's row changed. A fill completing mints the consents the
  # page reports on, so it is read again.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    if connected?(socket) and not socket.assigns.loading, do: send(self(), :load)
    {:noreply, socket}
  end

  def handle_info({:refresh, section}, socket) when section in @sections do
    {:noreply, load_section(socket, section)}
  end

  # The consent sheet for the soul's catalyst: the model got its key. The
  # kept catalogue predates the key, so it is dropped before the re-read —
  # a key bound here shows in the picker now, not when the entry lapses.
  def handle_info({:consent_granted, _ref, _result}, socket) do
    PrismWeb.ModelCatalog.forget(socket.assigns.context.athanor_id)

    {:noreply,
     socket
     |> assign(:consent_sheet_ref, nil)
     |> put_flash(:info, "Model connected.")
     |> load_section(:agents)
     |> load_models()}
  end

  def handle_info({:consent_sheet_closed, _ref}, socket) do
    {:noreply, assign(socket, :consent_sheet_ref, nil)}
  end

  # list-models async result. Shape: %{"models" => %{provider => [ids]}, "refs" => %{...}}.
  def handle_info({:list_models_result, {:ok, result}}, socket) do
    %{models: models, refs: refs} = PrismWeb.ModelCatalog.parse(result)

    {:noreply,
     socket
     |> assign(:models_by_provider, models)
     |> assign(:catalyst_refs, refs)
     |> assign(:models_loaded, true)}
  end

  def handle_info({:list_models_result, {:error, _reason}}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info({:task_timeout, :models}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # A section's own reload. The roster and the scrolls both read their
  # provenance from one `status` call, so each re-reads it first — a
  # revert changes what the card may offer.
  defp load_section(socket, :agents), do: socket |> load_provenance() |> load_agents()
  defp load_section(socket, :skills), do: socket |> load_provenance() |> load_skills()
  defp load_section(socket, section) when section in [:about, :notes], do: load_notes(socket)

  # Every unit's provenance, keyed by its path in the tree: shipped and
  # unedited, shipped but edited here, or the estate's own. What a card
  # may offer — delete, revert, nothing — is read from this, never guessed
  # from a name.
  defp load_provenance(socket) do
    provenance =
      case Aqua.AgentConfig.call_aqua(socket.assigns.context, %{"action" => "status"}) do
        {:ok, %{"files" => files}} when is_list(files) ->
          Map.new(files, fn %{"path" => path, "state" => state} -> {path, state} end)

        _ ->
          %{}
      end

    missing =
      case Cyfr.ConsentDrift.missing(socket.assigns.context) do
        {:ok, missing} -> missing
        :unknown -> []
      end

    socket
    |> assign(:provenance, provenance)
    |> assign(:consent_missing, missing)
  end

  # Each section reads itself when told, with the provenance as it is now.
  defp load_agents(socket) do
    send_update(AgentsComponent,
      id: "aqua-agents",
      provenance: socket.assigns.provenance,
      load: true
    )

    socket
  end

  defp load_notes(socket) do
    send_update(NotesComponent, id: "aqua-notes-section", load: true)
    socket
  end

  defp load_skills(socket) do
    send_update(ScrollsComponent,
      id: "aqua-scrolls-section",
      provenance: socket.assigns.provenance,
      load: true
    )

    socket
  end

  defp load_models(socket) do
    case PrismWeb.ModelCatalog.load(socket.assigns.context) do
      :ok -> socket
      :unavailable -> assign(socket, :models_loaded, true)
    end
  end

  defp consent_drift_sentence(missing) do
    shown = missing |> Enum.take(4) |> Enum.join(", ")
    rest = if length(missing) > 4, do: ", …", else: ""

    count =
      case missing do
        [_one] -> "one action the shipped manifest grants is"
        _many -> "#{length(missing)} actions the shipped manifest grants are"
      end

    "This estate consented to an older AQUA formula: #{count} not in its consent " <>
      "(#{shown}#{rest}), so a card for one is denied on Approve until a member re-consents."
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h3 class="text-sm font-medium text-gray-200">AQUA</h3>
        <p class="text-[11px] text-gray-500 mt-0.5">
          One assistant — the soul — and the roles it clones into: a stance and a set of hands for one kind of work.
        </p>
      </div>

      <.live_loading :if={@loading} message="Loading AQUA…" />

      <%!-- The consent this estate froze for the formula is behind the
            shipped manifest: a policy may name an action the chain
            authority will deny on the click. Re-consenting is the fix,
            and the sheet is one click away. --%>
      <div
        :if={@consent_missing != []}
        id="aqua-consent-drift"
        role="status"
        class="rounded border border-amber-800/60 bg-amber-950/30 px-3 py-2 text-xs text-amber-200 flex items-start justify-between gap-3"
      >
        <p>{consent_drift_sentence(@consent_missing)}</p>
        <button
          type="button"
          phx-click="open_consent"
          phx-value-ref={Aqua.VirtualTools.aqua_formula()}
          class="shrink-0 rounded bg-amber-700 hover:bg-amber-600 px-2 py-1 text-[11px] font-medium text-white"
        >
          Re-consent
        </button>
      </div>

      <.live_component
        module={AgentsComponent}
        id="aqua-agents"
        context={@context}
        athanor={@athanor}
        provenance={@provenance}
        models_by_provider={@models_by_provider}
        catalyst_refs={@catalyst_refs}
      />

      <.live_component module={NotesComponent} id="aqua-notes-section" context={@context} />

      <.live_component
        module={ScrollsComponent}
        id="aqua-scrolls-section"
        context={@context}
        provenance={@provenance}
      />

      <.live_component
        module={RestoreComponent}
        id="aqua-restore-section"
        context={@context}
        loaded={not @loading}
      />

      <%!-- The consent sheet for a model's key: the house dialog. --%>
      <ConsentSheetComponent.consent_sheet_modal
        ref={@consent_sheet_ref}
        context={@context}
        athanor_route={@athanor_route}
        athanor_name={@athanor && @athanor.name}
        on_cancel={JS.push("close_consent")}
      />
    </div>
    """
  end
end
