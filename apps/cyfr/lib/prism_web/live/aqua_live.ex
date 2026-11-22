# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive do
  @moduledoc """
  The athanor's Aqua, at `/a/<athanor>/aqua`: the soul and the crew it
  hands jobs to — the soul with its prompt, the capability allowlist the
  crew runs under too and the crew member whose brain it runs on, a crew
  member with a brain, what it is good at and what to avoid, and no
  prompt — the athanor's own
  (`Compendium.AquaTemplate` seeds the soul), edited by its
  person through the `aqua` tool — beside the page the soul reads first
  (`about-you`, pinned through the `notes` tool), the notes kept here, and the scrolls it can
  read on demand. Every write from this page goes through the tool Aqua
  calls in a thread, so one gate answers for both.

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

  This is also where a person sets Aqua up, at the top of the page
  (`/a/<athanor>/aqua?setup=1` opens it, and it is open while Aqua's
  brain is not connected), in three steps. The programs and keys: every
  installed catalyst that speaks `model/chat@1` (`Aqua.providers/1`), a
  key someone shared with the person first, then each program brain CYFR
  ships (`Opus.Programs.Definition.brains/0`), with what each needs; one
  step for each one ticked — its grant, asked in the page's system layer
  (`PrismWeb.SystemLayer`), whose sheet takes the key in CYFR's own
  credential prompt, the grant alone for a brain that needs nothing else
  of the person, or, for a program brain, the Programs page's form,
  prefilled from its definition, then its terminal, where the person
  signs it in — reachable in `lite`, so a box that never opens `dev`
  still gets its key in. A grant for a brain ends in one `models` call
  (`Aqua.models/2`) whose answer the page shows, so a key the provider
  refuses reads as the provider says. The crew: the form that makes a
  crew member (`AgentsComponent.member_form/1`), under the name the
  person gives it, on a program or key, with a model and the options
  that one lists; Make asks nothing, and as many members run on one
  program as the person makes. Aqua: which crew member it runs on, whose
  brain, model and options Aqua takes, which asks nothing either. A
  source whose consent moved is consented again in the page's system
  layer.

  ## What the page knows of a program

  A read of the page asks no program: it shows the stored settings and
  what is known (`Aqua.known_program/2`), which only the driver's own
  account answer sets. Signed out is said of that alone. A program whose
  row stands and of which nothing is known is installed, and is offered.
  A program is asked for its list (`Aqua.program_listing/2`) only by a
  press: an editor's opening, another program chosen in one, its Try
  again, and the end of the terminal a Sign in showed here. An ask that
  failed says why and changes nothing it knows.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.AquaLive.{
    AgentsComponent,
    NotesComponent,
    RestoreComponent,
    ScrollsComponent
  }

  alias PrismWeb.{SystemLayer, TerminalComponent}

  # What a program's terminal frame sends while the session it shows is
  # being closed, which answers nothing until its close has.
  @asked_of_session ~w(terminal_input terminal_written terminal_resize terminal_keep terminal_close)

  # Each section reloads on its own message, so a write refreshes what it
  # changed and nothing else: a note kept here does not re-read the
  # roster, a crew member renamed does not re-index the scrolls.
  @sections [:agents, :about, :notes, :skills, :setup]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Aqua")
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
      # its `models` call, how the roster's brains stand, the program
      # brains, what is known of each program, each one's listing once a
      # press asked for it, what the form that makes a crew member holds,
      # and whether its last step leads to the administrator's own setup.
      |> assign(:setup_asked, false)
      |> assign(:setup_toggled, nil)
      |> assign(:providers, nil)
      |> assign(:ticked, MapSet.new())
      |> assign(:answers, %{})
      |> assign(:agents_read, nil)
      |> assign(:programs, nil)
      |> assign(:known, %{})
      |> assign(:listings, %{})
      |> assign(:listing, :idle)
      # The terminal a Sign in showed, and the last delivery its frame
      # was handed, kept apart so no delivery renders the cards again.
      |> assign(:terminal, nil)
      |> assign(:terminal_delivery, nil)
      |> assign(:member_draft, AgentsComponent.empty_draft())
      |> assign(:admin_next, admin_next?(socket.assigns[:context]))

    # Subscribe before the load asks whether the athanor is ready: a fill
    # that finishes in between must still reach this page.
    if connected?(socket) and socket.assigns[:context] do
      actor = Sanctum.Context.actor(socket.assigns.context)
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
      user_id = socket.assigns.context.user_id

      if is_binary(user_id) and user_id != "",
        do: Cyfr.Bus.subscribe(actor, Cyfr.Bus.programs(actor, user_id))

      # Paint first, load after: five tool reads and a registry walk stand
      # between the mount and the roster, and the frame shows its spinner
      # while they run.
      send(self(), :load)
    end

    {:ok, socket}
  end

  # `?setup=1` opens Aqua's setup.
  @impl true
  def handle_params(params, _uri, socket) do
    asked? = params["setup"] == "1"
    socket = assign(socket, :setup_asked, asked?)
    {:noreply, if(asked?, do: assign(socket, :setup_toggled, nil), else: socket)}
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

  # The person opened or closed the setup: the page keeps it so, since a
  # render would otherwise close what they opened to press in it.
  def handle_event("setup_toggle", %{"open" => open}, socket) when open in ["true", "false"],
    do: {:noreply, assign(socket, :setup_toggled, open != "true")}

  # The frame of the terminal a Sign in showed (`TerminalComponent`), whose
  # events answer to the page that shows it. A session being closed is
  # asked nothing meanwhile.
  def handle_event(
        event,
        %{"session" => session},
        %{assigns: %{terminal: %{session: session, closing: true}}} = socket
      )
      when event in @asked_of_session,
      do: {:reply, %{}, socket}

  def handle_event("terminal_ready", %{"session" => session} = params, socket) do
    with %{session: ^session, ended: nil} = terminal <- socket.assigns.terminal,
         {:ok, %{tail: %{bytes: tail}, kept: kept}} <-
           Opus.Programs.attach(socket.assigns.context, session) do
      _ = resized(socket, session, params)
      terminal = %{terminal | kept: kept, attached: true}
      {:reply, %{data: Base.encode64(tail)}, assign(socket, :terminal, terminal)}
    else
      {:error, reason} -> {:reply, %{}, ended(socket, session, reason)}
      _another_session -> {:reply, %{}, socket}
    end
  end

  def handle_event("terminal_input", %{"session" => session, "terminal_input" => data}, socket)
      when is_binary(data) do
    case Opus.Programs.input(socket.assigns.context, session, data) do
      :ok ->
        {:reply, %{}, socket}

      {:error, reason} when reason in [:unavailable, :too_large] ->
        {:reply, %{}, put_flash(socket, :error, "The program did not take that; type it again.")}

      {:error, reason} ->
        {:reply, %{}, ended(socket, session, reason)}
    end
  end

  def handle_event("terminal_written", %{"session" => session, "delivery" => delivery}, socket)
      when is_binary(delivery) do
    with %{session: ^session} <- socket.assigns.terminal,
         ^delivery <- socket.assigns.terminal_delivery,
         {:error, reason} <- Opus.Programs.taken(socket.assigns.context, session, delivery) do
      {:noreply, ended(socket, session, reason)}
    else
      _taken_or_not_the_last -> {:noreply, socket}
    end
  end

  def handle_event("terminal_resize", %{"session" => session} = params, socket) do
    _ = resized(socket, session, params)
    {:noreply, socket}
  end

  def handle_event("terminal_keep", %{"session" => session} = params, socket) do
    kept = params["kept"] == "true"

    case {Opus.Programs.keep(socket.assigns.context, session, kept), socket.assigns.terminal} do
      {:ok, %{session: ^session} = terminal} ->
        {:noreply, assign(socket, :terminal, %{terminal | kept: kept})}

      {{:error, reason}, _terminal} ->
        {:noreply, ended(socket, session, reason)}

      {:ok, _another_session} ->
        {:noreply, socket}
    end
  end

  def handle_event("terminal_dismiss", _params, socket),
    do: {:noreply, assign(socket, :terminal, nil)}

  def handle_event(
        "terminal_close",
        %{"session" => session},
        %{assigns: %{terminal: %{session: session} = terminal}} = socket
      ) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)

    {:noreply,
     socket
     |> assign(:terminal, %{terminal | closing: true})
     |> start_async(
       :close_terminal,
       fn ->
         {tag, session, PrismWeb.Ops.run_to_end(fn -> Opus.Programs.close(ctx, session) end)}
       end,
       supervisor: Prism.TaskSupervisor
     )}
  end

  def handle_event("terminal_close", _params, socket), do: {:noreply, socket}

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

  # The programs' listings, for the focus they were asked under: each
  # one's models and access choices, or why none came; then what is known
  # as that answer left it, and the programs asked meanwhile.
  # A listing that answers under another focus is dropped, and so are the
  # programs asked meanwhile. A program's ask that raised or exited
  # answered as one unread (`listing/2`), so the task always answers.
  @impl true
  def handle_async(:program_listing, {:ok, {tag, results}}, socket) do
    waiting = socket.assigns.listing
    socket = assign(socket, :listing, :idle)

    CyfrWeb.ContextGuard.deliver(socket, tag, fn socket ->
      socket =
        Enum.reduce(results, socket, fn {name, result}, acc -> listed(acc, name, result) end)

      {:noreply, socket |> load_known() |> ask_listings(waiting)}
    end)
  end

  def handle_async(:program_listing, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:close_terminal, {:ok, {tag, session, result}}, socket) do
    socket = not_closing(socket)
    CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, closed(&1, session, result)})
  end

  # Only the node's shutdown stops a Close (`PrismWeb.Ops.run_to_end/1`).
  def handle_async(:close_terminal, {:exit, _reason}, socket), do: {:noreply, socket}

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
    do: {:noreply, socket |> assign(:agents_read, read) |> load_known()}

  # A press in an editor asks these programs for their lists.
  def handle_info({:ask_programs, names}, socket), do: {:noreply, ask_listings(socket, names)}

  # The terminal a Sign in started or found running, shown on this page,
  # in the card of the member whose Sign in it was, or in the setup.
  def handle_info({:sign_in_terminal, program, member, session}, socket),
    do: {:noreply, show_terminal(socket, program, member, session)}

  def handle_info({Opus.Programs, session, {kind, delivery, %{bytes: bytes}}}, socket)
      when kind in [:bytes, :tail] do
    case socket.assigns.terminal do
      %{session: ^session} ->
        event = if kind == :tail, do: "terminal_tail", else: "terminal_output"
        data = %{session: session, delivery: delivery, data: Base.encode64(bytes)}
        {:noreply, socket |> assign(:terminal_delivery, delivery) |> push_event(event, data)}

      _another_session ->
        {:noreply, socket}
    end
  end

  def handle_info({Opus.Programs, session, {:ended, reason}}, socket),
    do: {:noreply, ended(socket, session, reason)}

  # The shown session ended, though its end never reached this page as
  # attached (it died, or was not attached yet).
  def handle_info(%Cyfr.Bus.Program{kind: :ended, session: session, reason: reason}, socket),
    do: {:noreply, ended(socket, session, reason)}

  def handle_info(%Cyfr.Bus.Program{}, socket), do: {:noreply, socket}

  # What the form that makes a crew member holds, as the roster keeps it:
  # the setup shows the same form.
  def handle_info({:member_draft, draft}, socket),
    do: {:noreply, assign(socket, :member_draft, draft)}

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
    do: socket |> put_flash(:info, "#{name} consented.") |> load_models()

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

  # The one answer fills the picker for the brain it came from, found by
  # its identity, publisher kept and version aside: a models list replaces
  # what the picker held for it, and a refusal takes its models away, since
  # a key the provider refused offers none of them.
  defp answered(socket, ref, result) do
    provider = provider_of(socket, ref)

    socket =
      case result do
        {:ok, ids} ->
          socket
          |> put_flash(:info, "#{brain_name(ref)} answered with #{count(ids)}.")
          |> picked(provider, ids, ref)

        {:error, sentence} ->
          socket
          |> put_flash(:error, "#{brain_name(ref)} answered: #{sentence}")
          |> picked(provider, nil, ref)
      end

    {:noreply, update(socket, :answers, &Map.put(&1, ref, result))}
  end

  defp picked(socket, nil, _ids, _ref), do: socket

  defp picked(socket, provider, nil, _ref),
    do: update(socket, :models_by_provider, &Map.delete(&1, provider))

  defp picked(socket, provider, ids, ref) do
    socket
    |> update(:models_by_provider, &Map.put(&1, provider, ids))
    |> update(:catalyst_refs, &Map.put(&1, provider, identity(ref)))
  end

  # The picker's name for the brain `ref`: the provider the setup lists, or
  # the catalogue last named, for the same component. nil when neither
  # names it, and then the picker is left as it is.
  defp provider_of(socket, ref) do
    id = identity(ref)

    listed =
      case socket.assigns.providers do
        {:ok, providers} -> Enum.map(providers, &{&1.provider, &1.ref})
        _unread -> []
      end

    Enum.find_value(listed ++ Map.to_list(socket.assigns.catalyst_refs), fn {provider, named} ->
      if id != nil and identity(named) == id, do: provider
    end)
  end

  # A component's identity: its reference without a version.
  defp identity(ref) when is_binary(ref) do
    case Prima.ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> name_ref
      {:error, _} -> nil
    end
  end

  defp identity(_none), do: nil

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

  defp load_section(socket, :setup) do
    ctx = socket.assigns.context

    socket
    |> assign(:providers, Aqua.providers(ctx))
    |> assign(:programs, program_brains(ctx))
    |> load_known()
  end

  # The program brains CYFR ships (`Opus.Programs.Definition.brains/0`),
  # each with how the row of its name stands, as a crew member on it
  # reads it (`Aqua.model_status/2`).
  defp program_brains(ctx) do
    brains = Opus.Programs.Definition.brains()
    status = Aqua.model_status(ctx, Enum.map(brains, &%{"name" => &1.name, "program" => &1.name}))

    for brain <- brains do
      {state, _name} = Map.get(status, brain.name, {:model_unavailable, brain.name})
      Map.put(brain, :state, state)
    end
  end

  # What is known of each program the setup or a card names: a read of
  # what was said before, which asks no program.
  defp load_known(socket) do
    ctx = socket.assigns.context
    shipped = Enum.map(socket.assigns.programs || [], & &1.name)
    named = (socket.assigns.agents_read || %{})[:programs] || []

    known =
      Map.new(Enum.uniq(shipped ++ named), &{&1, Aqua.known_program(ctx, %{"program" => &1})})

    assign(socket, :known, known)
  end

  # The programs a member can be put on: each whose row stands, shipped or
  # named by a member, less one known signed out.
  defp runnable(programs, read, known) do
    shipped = for %{state: :ready, name: name} <- programs || [], do: name
    named = (read || %{})[:listable] || []

    for name <- Enum.uniq(shipped ++ named),
        not AgentsComponent.signed_out?(known, name),
        do: name
  end

  # One listing task runs at a time, off the page's process and ended with
  # it, so one row never runs two listings at once; a program asked while
  # it runs is asked by the next. The list a program gave stays shown
  # until its next answer comes, and a failure gives way to the asking.
  defp ask_listings(socket, names) do
    socket =
      update(socket, :listings, fn listings ->
        Enum.reduce(names, listings, fn name, asked ->
          Map.update(asked, name, :asking, fn
            {:ok, _listing} = held -> held
            _failed_or_asking -> :asking
          end)
        end)
      end)

    case socket.assigns.listing do
      :idle -> start_listing(socket, Enum.uniq(names))
      waiting -> assign(socket, :listing, Enum.uniq(waiting ++ names))
    end
  end

  defp start_listing(socket, []), do: assign(socket, :listing, :idle)

  defp start_listing(socket, names) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)

    socket
    |> assign(:listing, [])
    |> start_async(:program_listing, fn -> {tag, Map.new(names, &{&1, listing(ctx, &1)})} end)
  end

  # One program's listing; one that raised or exited did not answer.
  defp listing(ctx, name) do
    Aqua.program_listing(ctx, %{"program" => name})
  rescue
    _raised -> {:error, :lost}
  catch
    :exit, _reason -> {:error, :lost}
  end

  defp listed(socket, name, result) do
    answer =
      case result do
        {:ok, %{models: _models} = listing} -> {:ok, listing}
        {:error, reason} -> {:error, unlisted_words(reason, AgentsComponent.program_title(name))}
      end

    update(socket, :listings, &Map.put(&1, name, answer))
  end

  # Why a list did not come, said as that: the program's sentence, signed
  # out only where its driver read that, no room, or no answer.
  defp unlisted_words({:signed_out, sentence}, _title), do: sentence
  defp unlisted_words({:refused, sentence}, _title) when is_binary(sentence), do: sentence

  defp unlisted_words({:refused, :capacity, _boot}, _title),
    do: "This CYFR has no room for another running program right now."

  defp unlisted_words(_unanswered, title),
    do: "#{title} did not answer, so its list of models is not shown."

  # ============================================================================
  # The terminal a Sign in showed
  # ============================================================================

  defp show_terminal(
         %{assigns: %{terminal: %{session: session}}} = socket,
         _program,
         _member,
         session
       ),
       do: socket

  defp show_terminal(socket, program, member, session) do
    socket = detach(socket)

    assign(socket,
      terminal_delivery: nil,
      terminal: %{
        session: session,
        name: program,
        member: member,
        kept: false,
        ended: nil,
        attached: false,
        closing: false,
        back: nil
      }
    )
  end

  defp detach(%{assigns: %{terminal: %{session: session, ended: nil}}} = socket) do
    Opus.Programs.detach(socket.assigns.context, session)
    socket
  end

  defp detach(socket), do: socket

  defp resized(socket, session, %{"rows" => rows, "cols" => cols})
       when is_integer(rows) and is_integer(cols),
       do: Opus.Programs.resize(socket.assigns.context, session, rows, cols)

  defp resized(_socket, _session, _params), do: {:error, :invalid_size}

  defp not_closing(%{assigns: %{terminal: %{} = terminal}} = socket),
    do: assign(socket, :terminal, %{terminal | closing: false})

  defp not_closing(socket), do: socket

  defp closed(socket, session, {:ok, _closed_or_gone}), do: ended(socket, session, :closed)
  defp closed(socket, session, {:error, :unanswered}), do: ended(socket, session, :unanswered)

  defp closed(socket, _session, {:error, reason}),
    do: put_flash(socket, :error, "Failed: #{error_message(reason)}")

  # The first ending of the shown session is the one said, and the person
  # may have signed in there, so its program is asked again.
  defp ended(
         %{assigns: %{terminal: %{session: session, ended: nil} = terminal}} = socket,
         session,
         reason
       ) do
    reason =
      if reason in [:exited, :closed, :idle, :row_changed, :standing, :unanswered],
        do: reason,
        else: :not_found

    socket
    |> detach()
    |> assign(:terminal, %{terminal | ended: reason})
    |> push_event("terminal_ended", %{session: session})
    |> ask_listings([terminal.name])
  end

  defp ended(socket, _session, _reason), do: socket

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
      "(#{shown}#{rest}), so a call to one is refused until you consent again."
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
  Aqua's setup, in three steps a person reads as three. The programs and
  keys: every brain the athanor can connect, a key shared with them
  first, then the program brains CYFR ships
  (`Opus.Programs.Definition.brains/0`), each with what it needs; one
  step for each one ticked; each connected brain's answer to its
  `models` call, and a program as what is known of it says: signed in,
  signed out, or installed while nothing is known, which completes the
  step and still offers its sign-in once ticked. The crew: the form that
  makes a crew member (`AgentsComponent.member_form/1`), and the members
  made, each ready or what it waits on, a member whose program is known
  signed out not ready. Aqua: which crew member it runs on, done once
  Aqua reads ready, and until then the state of the crew's grant it waits
  on, with its Grant (`AgentsComponent.grant_line/1`). Then the crew
  members whose brain is not connected and, for an administrator who has
  not seen it, their own setup next.
  """
  attr :open, :boolean, required: true
  attr :providers, :any, required: true
  attr :programs, :any, required: true
  attr :known, :map, required: true
  attr :runnable, :list, required: true
  attr :listings, :map, required: true
  attr :terminal, :any, required: true
  attr :ticked, :any, required: true
  attr :answers, :map, required: true
  attr :agents_read, :any, required: true
  attr :models_by_provider, :map, required: true
  attr :catalyst_refs, :map, required: true
  attr :member_draft, :map, required: true
  attr :athanor, :any, required: true
  attr :admin_next, :boolean, required: true

  def setup(assigns) do
    providers =
      case assigns.providers do
        {:ok, providers} -> providers
        _unread -> []
      end

    read = assigns.agents_read || %{}
    programs = assigns.programs || []
    known = assigns.known

    members =
      for member <- read[:members] || [] do
        out? = AgentsComponent.signed_out?(known, member.agent["program"])
        Map.merge(member, %{ready: member.ready and not out?, signed_out: out?})
      end

    soul_ready? =
      read[:soul_ready] == true and
        not AgentsComponent.signed_out?(known, read[:soul_program])

    assigns =
      assigns
      |> assign(:brains, providers)
      |> assign(:programs, programs)
      |> assign(:steps, Enum.filter(providers, &step?(&1, assigns.ticked)))
      |> assign(:program_steps, Enum.filter(programs, &program_step?(&1, assigns)))
      |> assign(
        :connected?,
        Enum.any?(providers, &(&1.state == :ready)) or
          Enum.any?(programs, &(program_state(&1, known) in ["signed_in", "installed"]))
      )
      |> assign(
        :crew_brains,
        AgentsComponent.brains(
          assigns.models_by_provider,
          assigns.catalyst_refs,
          assigns.runnable,
          assigns.providers
        )
      )
      |> assign(:unconnected, read[:unconnected] || [])
      |> assign(:soul, read[:soul])
      |> assign(:member, read[:member])
      |> assign(:soul_ready, soul_ready?)
      |> assign(:soul_state, read[:soul_state])
      |> assign(:members, members)
      |> assign(:member_title, Enum.find_value(members, &(&1.name == read[:member] && &1.title)))

    ~H"""
    <details
      id="aqua-setup"
      open={@open}
      class="rounded-lg border border-gray-800 bg-gray-900/60 p-4"
    >
      <summary
        phx-click="setup_toggle"
        phx-value-open={to_string(@open)}
        class="cursor-pointer text-sm font-medium text-gray-200"
      >
        {if @soul_ready, do: "Aqua's setup", else: "Set up Aqua"}
      </summary>
      <div class="mt-3 space-y-5 text-xs text-gray-300">
        <p>
          Aqua runs on a crew member: connect the programs and keys you have, make a crew
          member on one, and choose the one Aqua runs on.
        </p>

        <section id="aqua-setup-step-brains" data-done={to_string(@connected?)} class="space-y-2">
          <h4 class="text-[11px] uppercase tracking-wider text-gray-400">1. Programs and keys</h4>

          <p
            :if={match?({:error, _}, @providers)}
            data-test="setup-unavailable"
            class="text-amber-300"
          >
            The keys this CYFR can connect cannot be read right now — try again.
          </p>

          <p
            :if={not @connected? and MapSet.size(@ticked) == 0}
            data-test="setup-needs"
            class="text-amber-300"
          >
            Tick what you have: a key from a model provider, or {program_titles(@programs)} on your own plan.
          </p>

          <ul id="aqua-setup-brains" class="space-y-1.5">
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
                  <span class="text-gray-400">{row_line(brain)}</span>
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
            <%!-- A program brain runs in the program row of its name,
                  signed in on its own terminal: signed in, or out, only as
                  its driver said, and installed while nothing is known. --%>
            <li
              :for={program <- @programs}
              id={"aqua-setup-brain-" <> program.name}
              data-state={program_state(program, @known)}
              class="flex flex-wrap items-center gap-2"
            >
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@ticked, program_tick(program))}
                  phx-click="setup_tick"
                  phx-value-provider={program_tick(program)}
                  class="rounded bg-gray-900 border-gray-600"
                />
                <span class="font-medium text-gray-100">{program.title}</span>
                <span class="text-gray-400">{program_need_line(program)}</span>
              </label>
              <%= case {program.state, program_state(program, @known)} do %>
                <% {:ready, "signed_in"} -> %>
                  <span class="text-emerald-400">signed in</span>
                <% {:ready, "signed_out"} -> %>
                  <span data-test="setup-signed-out" class="text-amber-300">signed out</span>
                <% {:ready, _installed} -> %>
                  <span class="text-gray-400">installed</span>
                <% {state, _shown} when state in [:program_disabled, :program_unfit, :model_unavailable] -> %>
                  <span class="text-amber-300">{plan_line(state)}</span>
                <% _missing -> %>
              <% end %>
            </li>
          </ul>

          <ol
            :if={@steps != [] or @program_steps != []}
            id="aqua-setup-steps"
            class="space-y-1.5 list-decimal pl-5"
          >
            <li :for={brain <- @steps} id={"aqua-setup-step-" <> brain.provider}>
              <%= cond do %>
                <% brain.state == :needs_grant -> %>
                  {brain.provider}: grant it to connect.
                  <button
                    type="button"
                    phx-click="open_consent"
                    phx-value-ref={brain.ref}
                    class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-0.5 text-[11px] font-medium text-white"
                  >
                    Grant
                  </button>
                <% true -> %>
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
            <li :for={program <- @program_steps} id={"aqua-setup-step-program-" <> program.name}>
              <%= if program.state == :program_missing do %>
                {program.title}: install its program, then sign it in.
                <.link
                  navigate={install_path(@athanor, program)}
                  data-test="install-program"
                  class="text-blue-400 hover:underline"
                >
                  install {program.name}
                </.link>
              <% else %>
                {program.title}: sign it in on its terminal.
                <button
                  type="button"
                  phx-click="sign_in"
                  phx-value-program={program.name}
                  phx-target="#aqua-agents"
                  data-test="sign-in"
                  class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-0.5 text-[11px] font-medium text-white"
                >
                  Sign in
                </button>
              <% end %>
            </li>
          </ol>

          <TerminalComponent.frame
            :if={@terminal && is_nil(@terminal.member)}
            terminal={@terminal}
          />
        </section>

        <section
          id="aqua-setup-step-crew"
          data-done={to_string(Enum.any?(@members, & &1.ready))}
          class="space-y-2"
        >
          <h4 class="text-[11px] uppercase tracking-wider text-gray-400">2. Crew</h4>

          <p :if={not @connected?} data-test="setup-crew-waits" class="text-gray-400">
            Connect a program or key first.
          </p>

          <%!-- A member is made only when the person presses Make, under
                the name they give it; connecting a brain makes none. --%>
          <AgentsComponent.member_form
            id="aqua-setup-new-member"
            brains={@crew_brains}
            listings={@listings}
            draft={@member_draft}
          />

          <ul :if={@members != []} id="aqua-setup-members" class="space-y-1">
            <li :for={member <- @members} id={"aqua-setup-made-" <> member.name}>
              <%= if member.ready do %>
                {member.title}: <span class="text-emerald-400">ready.</span>
              <% else %>
                {member.title}: not ready yet — its card below says why.
              <% end %>
            </li>
          </ul>
        </section>

        <section id="aqua-setup-step-aqua" data-done={to_string(@soul_ready)} class="space-y-2">
          <h4 class="text-[11px] uppercase tracking-wider text-gray-400">3. Aqua</h4>

          <p :if={@members == []} data-test="setup-aqua-waits" class="text-gray-400">
            Make a crew member first.
          </p>

          <%!-- Aqua runs on a crew member, whose brain it takes: the setup
                names which, and choosing asks nothing. --%>
          <form
            :if={@members != [] and is_binary(@soul)}
            id="aqua-setup-member"
            phx-change="editor_set_member"
            phx-target="#aqua-agents"
            phx-auto-recover="ignore"
          >
            <label class="block text-gray-400 mb-1">Which crew member does Aqua run on?</label>
            <select
              name="member"
              aria-label="Runs on"
              class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
            >
              <option value="" selected={is_nil(@member)}>Choose a crew member</option>
              <option
                :for={member <- @members}
                value={member.name}
                selected={member.name == @member}
                disabled={member.signed_out}
                class={member.signed_out && "text-gray-500"}
              >
                {AgentsComponent.runs_on_label(member.agent, @known)}
              </option>
            </select>
            <p class="mt-1 text-gray-500">
              Aqua answers with that member's program or key, model and options.
            </p>
          </form>

          <p :if={@soul_ready and @member_title} data-test="setup-aqua-done" class="text-emerald-400">
            Aqua runs on {@member_title}.
          </p>

          <%!-- Choosing grants nothing: with a member chosen, the step is
                done only once Aqua reads ready, and while the crew's grant
                is what it waits on, the step says so with what to do. --%>
          <p
            :if={@member && AgentsComponent.grant_sentence(@soul_state)}
            data-test="setup-aqua-grant"
            class="flex flex-wrap items-center gap-2"
          >
            <AgentsComponent.grant_line state={@soul_state} />
          </p>
        </section>

        <p :if={@unconnected != []} data-test="setup-unconnected" class="text-gray-400">
          No connected program or key yet for {Enum.join(@unconnected, ", ")}. Pick one on its card below.
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
    do: state in [:needs_grant, :needs_key] and MapSet.member?(ticked, provider)

  # A program brain ticked is a step while its program is to install, or
  # stands and is not known signed in. Its tick is kept apart from the
  # catalysts', which may share a name.
  defp program_step?(%{state: :program_missing} = program, assigns),
    do: MapSet.member?(assigns.ticked, program_tick(program))

  defp program_step?(%{state: :ready} = program, assigns),
    do:
      program_state(program, assigns.known) != "signed_in" and
        MapSet.member?(assigns.ticked, program_tick(program))

  defp program_step?(_program, _assigns), do: false

  defp program_tick(%{name: name}), do: "program:" <> name

  # A program whose row stands is what its driver last said of its
  # account, and installed while it said nothing.
  defp program_state(%{state: :ready, name: name}, known) do
    case get_in(known, [name, :account]) do
      nil -> "installed"
      account -> to_string(account)
    end
  end

  defp program_state(%{state: state}, _known), do: to_string(state)

  defp program_titles(programs) do
    case Enum.map(programs, & &1.title) do
      [] -> "a coding program"
      [one] -> one
      titles -> Enum.join(Enum.drop(titles, -1), ", ") <> " or " <> List.last(titles)
    end
  end

  defp program_need_line(%{title: title}),
    do: "a plan: to run #{title} in its own folder, signed in to your own plan"

  defp plan_line(:program_disabled), do: "it is disabled — enable it on the Programs page"

  defp plan_line(:program_unfit),
    do:
      "it is not one Aqua can run on — on the Programs page, make it a driven program " <>
        "with a kept folder whose command starts with its driver"

  defp plan_line(:model_unavailable), do: unready_line(:model_unavailable)

  # The Programs page's install form for a program brain, prefilled from
  # its definition, as a card's install is.
  defp install_path(athanor, %{name: name}),
    do:
      PrismWeb.Focus.path(
        athanor,
        "/programs?" <> URI.encode_query(%{"add" => name, "from" => "aqua"})
      )

  defp shared_line(%{owner: owner, person_daily: cap}) when is_integer(cap),
    do: "#{owner}'s key, shared with you, up to #{cap} requests a day"

  defp shared_line(%{owner: owner}), do: "#{owner}'s key, shared with you"

  # A brain whose grant is all it asks says so; any other row says what
  # connecting it needs.
  defp row_line(%{state: :needs_grant}), do: "needs only your grant"
  defp row_line(%{need: need}), do: need_line(need)

  defp need_line(nil), do: "needs nothing to connect"

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

  defp short_ref("formula:local." <> name), do: name
  defp short_ref("agent:local." <> name), do: name
  defp short_ref(ref), do: ref

  # The soul is read and its brain is not connected: the setup is the
  # page's first step.
  defp soul_unconnected?(%{soul: soul, soul_ready: false}) when is_binary(soul), do: true
  defp soul_unconnected?(_read), do: false

  defp setup_open?(nil, asked?, read), do: asked? or soul_unconnected?(read)
  defp setup_open?(toggled?, _asked?, _read), do: toggled?

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h3 class="text-sm font-medium text-gray-200">Aqua</h3>
        <p class="text-[11px] text-gray-500 mt-0.5">
          One assistant, Aqua, and its crew: who it hands a job to, each on a program or key of its own. Aqua runs on the crew member you choose. How a job is done is a scroll any of them reads.
        </p>
      </div>

      <.live_loading :if={@loading} message="Loading Aqua…" />

      <.consent_status stale_consents={@stale_consents} />

      <.setup
        open={setup_open?(@setup_toggled, @setup_asked, @agents_read)}
        providers={@providers}
        programs={@programs}
        known={@known}
        runnable={runnable(@programs, @agents_read, @known)}
        listings={@listings}
        terminal={@terminal}
        ticked={@ticked}
        answers={@answers}
        agents_read={@agents_read}
        models_by_provider={@models_by_provider}
        catalyst_refs={@catalyst_refs}
        member_draft={@member_draft}
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
        known={@known}
        runnable={runnable(@programs, @agents_read, @known)}
        program_listings={@listings}
        terminal={@terminal}
        providers={@providers}
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
