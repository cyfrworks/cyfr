# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive do
  @moduledoc """
  The athanor's AQUA, at `/a/<athanor>/aqua`: the soul and the crew it
  hands jobs to — each with a prompt and a brain, the soul with the
  capability allowlist the crew runs under too, a crew member with what
  it is good at and what to avoid — the athanor's own
  (`Compendium.AquaTemplate` seeds them), edited by its
  person through the `aqua` tool — beside the page the soul reads first
  (`about-you`, pinned through the `notes` tool), the notes kept here, and the scrolls it can
  read on demand. Every write from this page goes through the tool a
  card in chat goes through, so one gate answers for both.

  The page shows the tree of the athanor in focus and nothing else: a
  person's own athanor page edits their own tree. The soul reads only the
  tree it lives in.

  Four sections, each a `Phoenix.LiveComponent` that owns its reads and
  its writes (`PrismWeb.AquaLive.Section` states the contract): the roster
  (`AgentsComponent`), the pinned page and the notes (`NotesComponent`),
  the scrolls (`ScrollsComponent`) and the shipped files
  (`RestoreComponent`). The page holds what they share — the provenance
  of every file in the tree, the model catalogue, the grant it asked its
  system layer for — and loads one section per message, so a child
  LiveView's mount (the topbar, the panel) is answered between them
  rather than after them all.

  This is also where a person connects a brain, in Aqua's setup, at the
  top of the page (`/a/<athanor>/aqua?setup=1` opens it, and it is open
  while the soul has no connected brain): every installed catalyst that
  speaks `model/chat@1` (`Aqua.providers/1`), a key someone shared with
  the person first, a checklist of what each needs, then one step for
  each brain ticked — its grant, asked in the page's system layer
  (`PrismWeb.SystemLayer`), whose sheet takes the key in CYFR's own
  credential prompt, or the Programs page for a plan — reachable in
  `lite`, so a box that never opens `dev` still gets its key in. A grant
  for a brain ends in one `models` call (`Aqua.models/2`) whose answer the
  page shows, so a key the provider refuses reads as the provider says.
  The setup then picks which connected brain is the soul's own (or, with
  `agent=<name>`, a crew member's), a change of shape whose consent is
  asked at once. A source whose consent moved is consented again the
  same way.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.AquaLive.{AgentsComponent, NotesComponent, RestoreComponent, ScrollsComponent}
  alias PrismWeb.SystemLayer

  # Each section reloads on its own message, so a write refreshes what it
  # changed and nothing else: a note kept here does not re-read the
  # roster, a crew member renamed does not re-index the scrolls.
  @sections [:agents, :about, :notes, :skills, :setup]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "AQUA")
      |> assign(:active_nav, "aqua")
      |> assign(:loading, true)
      |> assign(:provenance, %{})
      |> assign(:stale_consents, {:ok, []})
      |> assign(:models_by_provider, %{})
      |> assign(:catalyst_refs, %{})
      |> assign(:models_loaded, false)
      # The grant prompt this page asked its system layer for: its id and
      # the component it grants, and the count prompt ids are numbered by.
      |> assign(:grant_prompt, nil)
      |> assign(:prompt_seq, 0)
      # Aqua's setup: whether the address asked for it and for whom, the
      # brains it offers, the ones ticked, each connected brain's answer to
      # its `models` call, how the roster's brains stand, and whether its
      # last step leads to the administrator's own setup.
      |> assign(:setup_asked, false)
      |> assign(:setup_for, nil)
      |> assign(:providers, nil)
      |> assign(:ticked, MapSet.new())
      |> assign(:answers, %{})
      |> assign(:agents_read, nil)
      |> assign(:admin_next, admin_next?(socket.assigns[:context]))

    # Subscribe before the load asks whether the athanor is ready: a fill
    # that finishes in between must still reach this page.
    if connected?(socket) and socket.assigns[:context] do
      actor = Sanctum.Context.actor(socket.assigns.context)
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))

      # Paint first, load after: five tool reads and a registry walk stand
      # between the mount and the roster, and the frame shows its spinner
      # while they run.
      send(self(), :load)
    end

    {:ok, socket}
  end

  # `?setup=1` opens Aqua's setup; `agent` names the crew member whose
  # brain it picks, the soul's otherwise.
  @impl true
  def handle_params(params, _uri, socket) do
    agent = params["agent"]

    {:noreply,
     socket
     |> assign(:setup_asked, params["setup"] == "1")
     |> assign(:setup_for, if(is_binary(agent) and agent != "", do: agent))}
  end

  @impl true
  def handle_event("open_consent", %{"ref" => ref}, socket) when is_binary(ref) and ref != "" do
    {:noreply, ask_grant(socket, ref)}
  end

  def handle_event("setup_tick", %{"provider" => provider}, socket) when is_binary(provider) do
    ticked = socket.assigns.ticked

    ticked =
      if MapSet.member?(ticked, provider),
        do: MapSet.delete(ticked, provider),
        else: MapSet.put(ticked, provider)

    {:noreply, assign(socket, :ticked, ticked)}
  end

  # The grant for `ref`, asked in the page's system layer, whose sheet
  # binds the key; a walk that cannot be read is said instead.
  defp ask_grant(socket, ref) do
    seq = socket.assigns.prompt_seq + 1
    id = "grant-#{seq}"
    socket = assign(socket, :prompt_seq, seq)

    case SystemLayer.grant_prompt(socket, id, ref) do
      {:ok, prompt} ->
        SystemLayer.show(prompt)
        assign(socket, :grant_prompt, {id, ref})

      {:error, reason} ->
        put_flash(socket, :error, "Cannot ask for this grant: #{error_message(reason)}")
    end
  end

  # ============================================================================
  # Loads and refreshes
  # ============================================================================

  # The grant this page asked for. Granted, the model got its key: the
  # kept catalogue predates the key, so it is dropped before the re-read —
  # a key bound here shows in the picker now, not when the entry lapses.
  # The same prompt binds a model's key and re-consents a formula whose
  # closure moved, so what it says names what was consented. A refused
  # commit leaves the prompt open; anything else ended it.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_report(id, outcome, %{assigns: %{grant_prompt: {id, ref}}} = socket) do
    case outcome do
      :confirmed ->
        {:noreply, socket |> assign(:grant_prompt, nil) |> granted(ref)}

      {:refused, reason} when reason != :invalid_prompt ->
        {:noreply, socket}

      _ended ->
        {:noreply, assign(socket, :grant_prompt, nil)}
    end
  end

  def system_layer_report(_id, _outcome, _socket), do: :pass

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
    send(self(), {:refresh, :setup})
    send(self(), :loaded)
    {:noreply, load_models(socket)}
  end

  def handle_info(:loaded, socket), do: {:noreply, assign(socket, :loading, false)}

  # The roster read how its brains stand: the setup is open while the
  # soul's is not connected, and names the crew members whose is not.
  def handle_info({:agents_read, read}, socket),
    do: {:noreply, assign(socket, :agents_read, read)}

  # A brain or model picked for an agent moved its consent's shape, which
  # is asked again at once.
  def handle_info({:ask_grant, ref}, socket), do: {:noreply, ask_grant(socket, ref)}

  # A connected brain's answer to its one `models` call, for the focus it
  # was asked under.
  def handle_info({:setup_answer, tag, ref, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &answered(&1, ref, result))

  # A model catalyst arrived (or did not): the agents section reads its
  # status again either way, and the picker's kept catalogue is dropped so
  # the new provider is offered.
  def handle_info({:catalyst_installed, tag, ref, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &installed(&1, ref, result))

  # The athanor's row changed. A fill completing mints the consents the
  # page reports on, so it is read again.
  def handle_info(%Cyfr.Bus.Notify{kind: :athanor_changed}, socket) do
    if connected?(socket) and not socket.assigns.loading, do: send(self(), :load)
    {:noreply, socket}
  end

  def handle_info({:refresh, section}, socket) when section in @sections do
    {:noreply, load_section(socket, section)}
  end

  # The catalogue, async, for the focus it was read under.
  def handle_info({:list_models_result, tag, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &models_loaded(&1, result))

  def handle_info({:task_timeout, :models}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # A brain's grant is answered by its one `models` call, which also fills
  # the picker for that brain (`answered/3`): the catalogue is not asked
  # again, which would ask the same brain a second time.
  defp granted(socket, ref) do
    PrismWeb.ModelCatalog.forget(socket.assigns.context.athanor_id)

    socket =
      case ref do
        "formula:local." <> name -> consented(socket, name)
        "agent:local." <> name -> consented(socket, name)
        brain -> ask_models(socket, brain)
      end

    socket
    |> load_section(:agents)
    |> load_section(:setup)
  end

  defp consented(socket, name),
    do: socket |> put_flash(:info, "#{name} consented again.") |> load_models()

  # Connecting a brain makes one `models` call, run off the page's process,
  # and shows what the provider answered: a key that is bound is not yet a
  # key the provider takes.
  defp ask_models(socket, ref) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    lv = self()
    logger_metadata = Prima.LoggerContext.capture()

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      Prima.LoggerContext.restore(logger_metadata)
      send(lv, {:setup_answer, tag, ref, Aqua.models(ctx, ref)})
    end)

    socket
    |> put_flash(:info, "Saved. Asking #{brain_name(ref)} whether it takes the key…")
    |> update(:answers, &Map.put(&1, ref, :asking))
  end

  defp answered(socket, ref, result) do
    socket =
      case result do
        {:ok, ids} ->
          provider = provider_of(socket, ref)

          socket
          |> put_flash(:info, "#{brain_name(ref)} answered with #{count(ids)}.")
          |> update(:models_by_provider, &Map.put(&1, provider, ids))
          |> update(:catalyst_refs, &Map.put(&1, provider, ref))

        {:error, sentence} ->
          put_flash(socket, :error, "#{brain_name(ref)} answered: #{sentence}")
      end

    {:noreply, update(socket, :answers, &Map.put(&1, ref, result))}
  end

  # The picker's name for the brain `ref`: the provider the setup lists it
  # under, else the catalyst's name.
  defp provider_of(socket, ref) do
    with {:ok, providers} <- socket.assigns.providers,
         %{provider: provider} <- Enum.find(providers, &(&1.ref == ref)) do
      provider
    else
      _unlisted -> brain_name(ref)
    end
  end

  defp count([_one]), do: "one model"
  defp count(ids), do: "#{length(ids)} models"

  defp brain_name(ref) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %{name: name}} -> name
      _ -> ref
    end
  end

  # The administrator's own setup follows Aqua's until they have seen it
  # (`users.prefs`' `admin_setup_seen`, which Settings writes).
  defp admin_next?(%Sanctum.Context{platform_admin: true, user_id: user_id})
       when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, user} -> Sanctum.Tenancy.Users.prefs(user)["admin_setup_seen"] != true
      _unread -> false
    end
  end

  defp admin_next?(_ctx), do: false

  # Shape: %{"models" => %{provider => [ids]}, "refs" => %{...}}.
  defp models_loaded(socket, {:ok, result}) do
    %{models: models, refs: refs} = PrismWeb.ModelCatalog.parse(result)

    {:noreply,
     socket
     |> assign(:models_by_provider, models)
     |> assign(:catalyst_refs, refs)
     |> assign(:models_loaded, true)}
  end

  defp models_loaded(socket, {:error, _reason}),
    do: {:noreply, assign(socket, :models_loaded, true)}

  defp installed(socket, ref, result) do
    socket =
      case result do
        {:ok, _} ->
          PrismWeb.ModelCatalog.forget(socket.assigns.context.athanor_id)
          put_flash(socket, :info, "Installed #{ref}.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not install #{ref}: #{error_message(reason)}")
      end

    # The section that owns the button hears which install ended, so an
    # unrelated reload cannot re-enable it mid-download.
    send_update(AgentsComponent, id: "aqua-agents", installed: ref)
    send(self(), {:refresh, :agents})
    send(self(), {:refresh, :setup})
    {:noreply, load_models(socket)}
  end

  # A section's own reload. The roster and the scrolls both read their
  # provenance from one `status` call, so each re-reads it first — a
  # revert changes what the card may offer.
  defp load_section(socket, :agents), do: socket |> load_provenance() |> load_agents()
  defp load_section(socket, :skills), do: socket |> load_provenance() |> load_skills()
  defp load_section(socket, section) when section in [:about, :notes], do: load_notes(socket)

  defp load_section(socket, :setup),
    do: assign(socket, :providers, Aqua.providers(socket.assigns.context))

  # Every unit's provenance, keyed by its path in the tree: shipped and
  # unedited, shipped but edited here, or the athanor's own. What a card
  # may offer — delete, revert, nothing — is read from this, never guessed
  # from a name.
  defp load_provenance(socket) do
    provenance =
      case PrismWeb.AquaLive.Section.call_aqua(socket.assigns.context, %{"action" => "status"}) do
        {:ok, %{files: files}} when is_list(files) ->
          Map.new(files, fn %{path: path, state: state} -> {path, state} end)

        _ ->
          %{}
      end

    socket
    |> assign(:provenance, provenance)
    |> assign(:stale_consents, Aqua.stale_consent_refs(socket.assigns.context))
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

  # The sentence for a consent that no longer answers, named by its source.
  defp consent_warning(ref, {:drifted, missing}) do
    shown = missing |> Enum.take(4) |> Enum.join(", ")
    rest = if length(missing) > 4, do: ", …", else: ""

    count =
      case missing do
        [_one] -> "one action the shipped manifest grants is"
        _many -> "#{length(missing)} actions the shipped manifest grants are"
      end

    "This athanor consented to an older #{short_ref(ref)}: #{count} not in its consent " <>
      "(#{shown}#{rest}), so a card for one is denied on Approve until you consent again."
  end

  defp consent_warning(ref, :stale) do
    "What #{short_ref(ref)} uses changed since this athanor consented — a capability, a " <>
      "brain or a component it calls — so it cannot run until you consent again."
  end

  @doc """
  What the athanor's consent status says: one row per formula or agent
  whose consent no longer answers, each with its re-consent button, or —
  when the status could not be read — one line that says so and offers
  nothing to press, so an outage never reads as "all consents current".
  """
  attr :stale_consents, :any, required: true

  def consent_status(%{stale_consents: {:error, _refused}} = assigns) do
    ~H"""
    <div
      id="aqua-consent-status-unavailable"
      role="status"
      class="rounded border border-amber-800/60 bg-amber-950/30 px-3 py-2 text-xs text-amber-200"
    >
      <p>Consent status unavailable — try again shortly.</p>
    </div>
    """
  end

  def consent_status(%{stale_consents: {:ok, stale}} = assigns) do
    assigns = assign(assigns, :stale, stale)

    ~H"""
    <%!-- A capability, a brain or a component a source calls moves the
          shape it was consented against, so recovery is per source. --%>
    <div
      :for={{ref, state} <- @stale}
      id={"aqua-consent-drift-" <> ref}
      role="status"
      class="rounded border border-amber-800/60 bg-amber-950/30 px-3 py-2 text-xs text-amber-200 flex items-start justify-between gap-3"
    >
      <p>{consent_warning(ref, state)}</p>
      <button
        type="button"
        phx-click="open_consent"
        phx-value-ref={ref}
        class="shrink-0 rounded bg-amber-700 hover:bg-amber-600 px-2 py-1 text-[11px] font-medium text-white"
      >
        Re-consent
      </button>
    </div>
    """
  end

  @doc """
  Aqua's setup: what the person has, as a checklist of every brain the
  athanor can connect, a key shared with them first; one step for each
  brain ticked; each connected brain's answer to its `models` call; which
  connected brain the agent the setup is for runs on; the crew members
  whose brain is not connected; and, for an administrator who has not
  seen it, their own setup next.
  """
  attr :open, :boolean, required: true
  attr :providers, :any, required: true
  attr :ticked, :any, required: true
  attr :answers, :map, required: true
  attr :agents_read, :any, required: true
  attr :setup_for, :string, default: nil
  attr :models_by_provider, :map, required: true
  attr :athanor, :any, required: true
  attr :admin_next, :boolean, required: true

  def setup(assigns) do
    providers =
      case assigns.providers do
        {:ok, providers} -> providers
        _unread -> []
      end

    target = assigns.setup_for || (assigns.agents_read && assigns.agents_read.soul)

    assigns =
      assigns
      |> assign(:brains, providers)
      |> assign(:target, target)
      |> assign(:steps, Enum.filter(providers, &step?(&1, assigns.ticked)))
      |> assign(:connected?, Enum.any?(providers, &(&1.state == :ready)))
      |> assign(:unconnected, (assigns.agents_read && assigns.agents_read.unconnected) || [])

    ~H"""
    <details
      id="aqua-setup"
      open={@open}
      class="rounded-lg border border-gray-800 bg-gray-900/60 p-4"
    >
      <summary class="cursor-pointer text-sm font-medium text-gray-200">Set up Aqua</summary>
      <div class="mt-3 space-y-4 text-xs text-gray-300">
        <p>
          Aqua answers with a model you bring: a key from a model provider, or a plan you
          already pay for. Tick what you have.
        </p>

        <p
          :if={match?({:error, _}, @providers)}
          data-test="setup-unavailable"
          class="text-amber-300"
        >
          The brains installed here cannot be read right now — try again.
        </p>

        <p
          :if={match?({:ok, []}, @providers)}
          data-test="setup-none"
          class="text-amber-300"
        >
          No brain is installed in this athanor yet. One installed from Components shows here.
        </p>

        <ul :if={@brains != []} id="aqua-setup-brains" class="space-y-1.5">
          <li
            :for={brain <- @brains}
            id={"aqua-setup-brain-" <> brain.provider}
            data-state={brain.state}
            class="flex flex-wrap items-center gap-2"
          >
            <%= if brain.shared do %>
              <span class="font-medium text-gray-100">{brain.provider}</span>
              <span data-test="setup-shared">
                {shared_line(brain.shared)}
              </span>
            <% else %>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@ticked, brain.provider)}
                  phx-click="setup_tick"
                  phx-value-provider={brain.provider}
                  class="rounded bg-gray-900 border-gray-600"
                />
                <span class="font-medium text-gray-100">{brain.provider}</span>
                <span class="text-gray-400">{need_line(brain.need)}</span>
              </label>
            <% end %>
            <span :if={brain.state == :ready} class="text-emerald-400">connected</span>
            <span
              :if={brain.state in [:consent_damaged, :consent_unavailable, :model_unavailable]}
              class="text-amber-300"
            >
              {unready_line(brain.state)}
            </span>
            <span
              :if={@answers[brain.ref]}
              data-test="setup-answer"
              class={answer_class(@answers[brain.ref])}
            >
              {answer_line(brain.provider, @answers[brain.ref])}
            </span>
          </li>
        </ul>

        <p
          :if={@brains != [] and MapSet.size(@ticked) == 0 and not @connected?}
          data-test="setup-needs"
          class="text-amber-300"
        >
          Aqua needs a key or a plan to answer: tick one you have.
        </p>

        <ol :if={@steps != []} id="aqua-setup-steps" class="space-y-1.5 list-decimal pl-5">
          <li :for={brain <- @steps} id={"aqua-setup-step-" <> brain.provider}>
            <%= if brain.need && brain.need.kind == "login" do %>
              {brain.provider}: sign in to {brain.need.program || "its program"} on the Programs page.
              <.link
                navigate={programs_path(@athanor, brain)}
                class="text-blue-400 hover:underline"
              >
                Open Programs
              </.link>
            <% else %>
              {brain.provider}: enter your key.
              <button
                type="button"
                phx-click="open_consent"
                phx-value-ref={brain.ref}
                class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-0.5 text-[11px] font-medium text-white"
              >
                Enter the key
              </button>
            <% end %>
          </li>
        </ol>

        <form
          :if={@connected? and @target}
          id="aqua-setup-pick"
          phx-change="editor_set_model"
          phx-target="#aqua-agents"
          phx-auto-recover="ignore"
        >
          <input type="hidden" name="name" value={@target} />
          <label class="block text-gray-400 mb-1">
            {pick_label(@target, @agents_read)}
          </label>
          <select
            name="value"
            aria-label="Brain"
            class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
          >
            <option value="-" selected>Choose a connected brain</option>
            <%= for {provider, models} <- @models_by_provider, models != [] do %>
              <optgroup label={provider}>
                <option :for={m <- models} value={"#{provider}::#{m}"}>{m}</option>
              </optgroup>
            <% end %>
          </select>
        </form>

        <p :if={@unconnected != []} data-test="setup-unconnected" class="text-gray-400">
          No connected brain yet for {Enum.join(@unconnected, ", ")}. Pick one on its card below.
        </p>

        <p :if={@admin_next} data-test="setup-admin-next">
          <.link
            navigate={PrismWeb.Focus.path(@athanor, "/settings?setup=1")}
            class="text-blue-400 hover:underline"
          >
            Next: set up this CYFR for the people you let in
          </.link>
        </p>
      </div>
    </details>
    """
  end

  # A brain ticked that is not yet connected is a step; a damaged or
  # unreadable consent is no step the person can take here.
  defp step?(%{state: state, provider: provider}, ticked),
    do: state in [:needs_key, :needs_sign_in] and MapSet.member?(ticked, provider)

  defp shared_line(%{owner: owner, person_daily: cap}) when is_integer(cap),
    do: "#{owner}'s key, shared with you, up to #{cap} requests a day"

  defp shared_line(%{owner: owner}), do: "#{owner}'s key, shared with you"

  defp need_line(nil), do: "needs nothing to connect"

  defp need_line(%{kind: "login", reason: reason}) when is_binary(reason),
    do: "a plan: " <> reason

  defp need_line(%{kind: "login"}), do: "a plan you sign in to"
  defp need_line(%{reason: reason}) when is_binary(reason), do: "a key: " <> reason
  defp need_line(%{qualifier: provider}) when is_binary(provider), do: "a key from " <> provider
  defp need_line(_need), do: "a key"

  defp unready_line(:consent_damaged),
    do: "its consent is damaged: revoke it on Components and grant it again"

  defp unready_line(:consent_unavailable), do: "its consent cannot be read right now — try again"
  defp unready_line(:model_unavailable), do: "it cannot be read right now — try again"

  defp answer_line(provider, :asking), do: "Asking #{provider}…"
  defp answer_line(provider, {:ok, [_one]}), do: "#{provider} answered with one model."
  defp answer_line(provider, {:ok, ids}), do: "#{provider} answered with #{length(ids)} models."
  defp answer_line(provider, {:error, sentence}), do: "#{provider} answered: #{sentence}"

  defp answer_class({:error, _}), do: "text-red-300"
  defp answer_class(_answer), do: "text-gray-400"

  defp pick_label(target, %{soul: target}), do: "Which connected brain is Aqua's own?"
  defp pick_label(target, _read), do: "Which connected brain does #{target} run on?"

  defp programs_path(athanor, %{ref: ref, need: %{name: need}}),
    do:
      PrismWeb.Focus.path(
        athanor,
        "/programs?" <> URI.encode_query(%{"install" => ref, "need" => need})
      )

  defp short_ref("formula:local." <> name), do: name
  defp short_ref("agent:local." <> name), do: name
  defp short_ref(ref), do: ref

  # The soul is read and its brain is not connected: the setup is the
  # page's first step.
  defp soul_unconnected?(%{soul: soul, soul_ready: false}) when is_binary(soul), do: true
  defp soul_unconnected?(_read), do: false

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
          One assistant — the soul — and its crew: who it hands a job to, each on a brain of its own. How a job is done is a scroll any of them reads.
        </p>
      </div>

      <.live_loading :if={@loading} message="Loading AQUA…" />

      <.consent_status stale_consents={@stale_consents} />

      <.setup
        open={@setup_asked or soul_unconnected?(@agents_read)}
        providers={@providers}
        ticked={@ticked}
        answers={@answers}
        agents_read={@agents_read}
        setup_for={@setup_for}
        models_by_provider={@models_by_provider}
        athanor={@athanor}
        admin_next={@admin_next}
      />

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

      <%!-- A grant is asked here, the one place a consent is shown: a
            model's key, a formula consented again. --%>
      <.live_component
        module={SystemLayer}
        id={SystemLayer.layer_id()}
        context={@context}
        athanor_route={@athanor_route}
        athanor_name={@athanor && @athanor.name}
      />
    </div>
    """
  end
end
