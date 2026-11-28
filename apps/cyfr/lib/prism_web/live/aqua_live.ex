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
  (`AgentsComponent`), whose soul's card holds what Aqua may use with the
  scrolls (`ScrollsComponent`) as one of its groups, the pinned page and
  the notes (`NotesComponent`), and the shipped files
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
  account answer sets. It keeps no copy of that: each render reads it, so
  what `Opus.Brain` let go of is not shown. Signed out is said of that
  alone. A program whose row stands and of which nothing is known is
  installed, and is offered.

  A program is asked for its list (`Aqua.program_listing/2`) only by a
  press: an editor's opening, another program chosen in one, its Try
  again, and a Sign in, asked when its terminal ends. One thing is out
  at a time. A Sign in waits for an ask already out, then its terminal
  comes before any other ask, and the page asks nothing until it ends.
  An ask that failed, or whose task was lost, says so and changes nothing
  it knows.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  @behaviour PrismWeb.TerminalComponent
  on_mount PrismWeb.TerminalComponent

  alias PrismWeb.AquaLive.{
    AgentsComponent,
    NotesComponent,
    RestoreComponent,
    ScrollsComponent
  }

  alias PrismWeb.{SystemLayer, TerminalComponent}

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
      # What a provider that listed no models said instead, by provider:
      # one that refused the key, and any other.
      |> assign(:model_refused, %{})
      |> assign(:model_errors, %{})
      # The page's asks, numbered: each ask, a catalogue's or a grant's
      # of one brain, carries its number and its answer comes back with
      # it; `answered_at` is the number of the ask whose answer the page
      # last applied for a provider, and only an answer to a later ask
      # replaces it.
      |> assign(:asks, 0)
      |> assign(:answered_at, %{})
      |> assign(:models_loaded, false)
      # The grant prompt this page asked its system layer for: its id and
      # the component it grants, and the count prompt ids are numbered by.
      |> assign(:grant_prompt, nil)
      |> assign(:prompt_seq, 0)
      # Aqua's setup: whether the address asked for it and for whom, the
      # brains it offers, the ones ticked, how the
      # roster's brains stand, the program brains, each one's listing once a press asked for it, the programs
      # waiting to be asked, the one task out, the Sign in waiting on its
      # terminal and why the last was refused, what the form that makes a
      # crew member holds, and whether its last step leads to the
      # administrator's own setup.
      |> assign(:setup_asked, false)
      |> assign(:setup_toggled, nil)
      |> assign(:providers, nil)
      |> assign(:ticked, MapSet.new())
      |> assign(:asking, %{})
      |> assign(:agents_read, nil)
      |> assign(:programs, nil)
      |> assign(:listings, %{})
      |> assign(:waiting, [])
      |> assign(:out, nil)
      |> assign(:sign_in, nil)
      |> assign(:sign_in_refused, %{})
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

  # A press in an editor asks these programs for their lists.
  def handle_info({:ask_programs, names}, socket), do: {:noreply, ask_listings(socket, names)}

  # A Sign in: the terminal first, shown in the panel where the person
  # pressed (a card by its name, or the setup), and the program asked when
  # that terminal ends.
  def handle_info({:sign_in, program, panel}, %{assigns: %{sign_in: nil}} = socket) do
    {:noreply,
     socket
     |> assign(:sign_in, {program, panel})
     |> update(:sign_in_refused, &Map.delete(&1, program))
     |> ask_listings([program])}
  end

  def handle_info({:sign_in, _program, _panel}, socket), do: {:noreply, socket}

  # What the one task out answered, taken only under the focus it was
  # asked under.
  def handle_info({:program_listing, tag, results}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, all_listed(&1, results)})

  def handle_info({:sign_in_terminal, tag, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, terminal_opened(&1, result)})

  # The task out ended with no answer taken (it was lost, or answered
  # under another focus): what it was doing failed.
  def handle_info(
        {:DOWN, task, :process, _pid, _reason},
        %{assigns: %{out: %{task: task, doing: doing}}} = socket
      ),
      do: {:noreply, socket |> assign(:out, nil) |> lost(doing)}

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
  def handle_info({:list_models_result, tag, ask, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &models_loaded(&1, ask, result))

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
    |> asked()
    |> then(
      &update(&1, :asking, fn asking -> Map.put(asking, identity(ref), &1.assigns.asks) end)
    )
  end

  # The one answer stands for the brain it came from, found by its
  # identity, publisher kept and version aside, as the catalogue's answer
  # for it would: a models list replaces what the picker held for it, and
  # a refusal takes its models away and is kept as what the provider said,
  # since a key the provider refused offers none of them.
  defp answered(socket, ref, result) do
    provider = provider_of(socket, ref)
    {at, asking} = Map.pop(socket.assigns.asking, identity(ref))
    socket = assign(socket, :asking, asking)

    # An answer no ask of this page is waiting on was asked now.
    {at, socket} = if at, do: {at, socket}, else: {socket.assigns.asks + 1, asked(socket)}

    socket =
      case result do
        {:ok, ids} ->
          put_flash(socket, :info, "#{brain_name(ref)} answered with #{count(ids)}.")

        {_refused_or_error, sentence} ->
          put_flash(socket, :error, "#{brain_name(ref)} answered: #{sentence}")
      end

    {:noreply, picked(socket, provider, result, ref, at)}
  end

  # One more ask of this page.
  defp asked(socket), do: update(socket, :asks, &(&1 + 1))

  defp picked(socket, nil, _answer, _ref, _at), do: socket

  defp picked(socket, provider, answer, ref, at) do
    if at <= Map.get(socket.assigns.answered_at, provider, 0) do
      socket
    else
      {models, refused, errors} =
        case answer do
          {:ok, ids} ->
            {&Map.put(&1, provider, ids), &Map.delete(&1, provider), &Map.delete(&1, provider)}

          {:refused, sentence} ->
            {&Map.delete(&1, provider), &Map.put(&1, provider, sentence),
             &Map.delete(&1, provider)}

          {:error, sentence} ->
            {&Map.delete(&1, provider), &Map.delete(&1, provider),
             &Map.put(&1, provider, sentence)}
        end

      socket
      |> update(:models_by_provider, models)
      |> update(:model_refused, refused)
      |> update(:model_errors, errors)
      |> update(:answered_at, &Map.put(&1, provider, at))
      |> then(fn socket ->
        if match?({:ok, _}, answer),
          do: update(socket, :catalyst_refs, &Map.put(&1, provider, identity(ref))),
          else: socket
      end)
    end
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

  # Shape: %{"models" => %{provider => [ids]}, "refs" => %{...}}. The
  # catalogue asked at `ask` is applied provider by provider: one whose
  # held answer came from that ask or a later one keeps it, so of two
  # catalogues out at once, or a catalogue and a grant's answer, the one
  # asked last stands whichever arrives last.
  defp models_loaded(socket, ask, {:ok, result}) do
    parsed = PrismWeb.ModelCatalog.parse(result)
    at = socket.assigns.answered_at

    parts =
      [models_by_provider: parsed.models, catalyst_refs: parsed.refs] ++
        [model_errors: parsed.errors, model_refused: parsed.refused]

    named =
      Enum.flat_map(parts, fn {key, read} -> Map.keys(read) ++ Map.keys(socket.assigns[key]) end)

    later = for provider <- Enum.uniq(named), Map.get(at, provider, 0) >= ask, do: provider

    socket =
      Enum.reduce(parts, socket, fn {key, read}, socket ->
        held = Map.take(socket.assigns[key], later)
        assign(socket, key, read |> Map.drop(later) |> Map.merge(held))
      end)

    applied = Map.new(Enum.uniq(named) -- later, &{&1, ask})

    {:noreply,
     socket
     |> update(:answered_at, &Map.merge(&1, applied))
     |> assign(:models_loaded, true)}
  end

  defp models_loaded(socket, _ask, {:error, _reason}),
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

  # The programs whose row stands, shipped or named by a member: all that
  # anything is known of.
  defp standing(programs, read) do
    shipped = for %{state: :ready, name: name} <- programs || [], do: name
    Enum.uniq(shipped ++ ((read || %{})[:listable] || []))
  end

  # ============================================================================
  # One thing at a time
  # ============================================================================

  # An ask authorizes nothing until it answered, so asking takes the last
  # answer away.
  defp ask_listings(socket, names) do
    socket
    |> update(:listings, &Map.merge(&1, Map.new(names, fn name -> {name, :asking} end)))
    |> update(:waiting, &Enum.uniq(&1 ++ names))
    |> next()
  end

  # What runs next once nothing is out: a Sign in's terminal before any
  # ask, and no ask while that terminal runs. The programs asked while one
  # ask was out are the next one's, so one row never runs two at once.
  defp next(%{assigns: %{out: nil}} = socket) do
    %{sign_in: sign_in, waiting: waiting, terminal: terminal} = socket.assigns

    cond do
      sign_in != nil -> open_terminal(socket, sign_in)
      waiting == [] or held?(sign_in, terminal) -> socket
      true -> start_listing(socket, waiting)
    end
  end

  defp next(socket), do: socket

  defp held?(sign_in, terminal), do: sign_in != nil or match?(%{ended: nil}, terminal)

  # An editor's line for an ask that waits on the terminal.
  defp shown_listings(listings, waiting, sign_in, terminal) do
    if held?(sign_in, terminal),
      do: Map.merge(listings, Map.new(waiting, &{&1, :held})),
      else: listings
  end

  defp start_listing(socket, names) do
    socket
    |> assign(:waiting, [])
    |> start({:ask, names}, fn ctx, page, tag ->
      results = while_shown(page, fn -> Map.new(names, &{&1, listing(ctx, &1)}) end)
      {:program_listing, tag, results}
    end)
  end

  # The person's own running terminal of the row of that name, the one its
  # install opened among them, so one kept folder never runs two of the
  # program at once from here; only when none runs is one opened, through
  # the gate like the Programs page's Open, at a default size the frame
  # corrects when it attaches. That call runs to its end.
  defp open_terminal(socket, {program, _panel}) do
    start(socket, :sign_in, fn ctx, _page, tag ->
      opened =
        running_terminal(ctx, program) ||
          run_to_end(fn ->
            PrismWeb.Ops.call_tool(ctx, "mcp_servers/open", %{
              "name" => program,
              "rows" => 24,
              "cols" => 80
            })
          end)

      {:sign_in_terminal, tag, opened}
    end)
  end

  # The person's own running terminal of the row named `program`, the
  # oldest, as the open that started it answers; nil when none runs or
  # the sessions cannot be read, and then Sign in opens one.
  defp running_terminal(ctx, program) do
    case Opus.Programs.running(ctx) do
      {:ok, sessions} ->
        Enum.find_value(sessions, fn
          %{by: :person, name: ^program, session: session} -> {:ok, %{session: session}}
          _other -> nil
        end)

      {:error, _unread} ->
        nil
    end
  end

  # The one task out, off the page's process and watched, so a lost one
  # ends what it was doing.
  defp start(socket, doing, work) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    page = self()

    {:ok, task} =
      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        send(page, work.(ctx, page, tag))
      end)

    assign(socket, :out, %{task: Process.monitor(task), doing: doing})
  end

  # `fun`, ended with a page that goes as a link would end it: a page that
  # stops normally lets it finish, so no query is cut short there. The
  # link is the watcher's alone: the task's loss is the page's to say, and
  # never takes the page along.
  defp while_shown(page, fun) do
    watcher =
      spawn_link(fn ->
        watched = Process.monitor(page)

        receive do
          {:DOWN, ^watched, :process, ^page, :normal} -> :ok
          {:DOWN, ^watched, :process, ^page, _gone} -> exit(:shutdown)
        end
      end)

    result = fun.()
    Process.unlink(watcher)
    Process.exit(watcher, :kill)
    result
  end

  # One program's listing; one that raised or exited did not answer.
  defp listing(ctx, name) do
    Aqua.program_listing(ctx, %{"program" => name})
  rescue
    _raised -> {:error, :lost}
  catch
    :exit, _reason -> {:error, :lost}
  end

  defp answered(%{assigns: %{out: %{task: task}}} = socket) do
    Process.demonitor(task, [:flush])
    assign(socket, :out, nil)
  end

  defp answered(socket), do: socket

  defp all_listed(socket, results) do
    results
    |> Enum.reduce(answered(socket), fn {name, result}, acc -> listed(acc, name, result) end)
    |> next()
  end

  # An answer to an ask since asked again authorizes nothing: the one that
  # waits is the one to take.
  defp listed(socket, name, result) do
    answer =
      case result do
        {:ok, %{models: _models} = listing} ->
          {:ok, listing}

        {:error, reason} ->
          {:error, unlisted_words(socket, reason, AgentsComponent.program_title(name))}
      end

    if name in socket.assigns.waiting,
      do: socket,
      else: update(socket, :listings, &Map.put(&1, name, answer))
  end

  defp lost(socket, {:ask, names}) do
    names
    |> Enum.reduce(socket, fn name, acc -> listed(acc, name, {:error, :lost}) end)
    |> next()
  end

  defp lost(socket, :sign_in), do: no_terminal(socket, "Its terminal did not open. Try again.")

  defp terminal_opened(socket, result) do
    socket = answered(socket)

    case {result, socket.assigns.sign_in} do
      {{:ok, %{session: session}}, {program, panel}} ->
        shown = %{session: session, name: program, panel: panel, back: nil}
        socket |> assign(:sign_in, nil) |> TerminalComponent.show(shown) |> next()

      {{:error, reason}, _sign_in} ->
        no_terminal(socket, error_message(reason))
    end
  end

  # A Sign in whose terminal did not open says why where it was pressed and
  # asks nothing.
  defp no_terminal(socket, why) do
    {program, panel} = socket.assigns.sign_in

    socket =
      socket
      |> assign(:sign_in, nil)
      |> update(:waiting, &List.delete(&1, program))
      |> update(:listings, &Map.delete(&1, program))

    socket =
      if panel,
        do: update(socket, :sign_in_refused, &Map.put(&1, program, why)),
        else: put_flash(socket, :error, why)

    next(socket)
  end

  # Why a list did not come, said as that: the program's sentence, signed
  # out only where its driver read that, no room, packs not made ready
  # (the refusal's own sentence), or no answer.
  defp unlisted_words(_socket, {:signed_out, sentence}, _title), do: sentence

  defp unlisted_words(_socket, packs, _title) when packs in [:packs_unready, :packs_moved],
    do: Prima.Refusal.message(packs)

  defp unlisted_words(_socket, {:refused, sentence}, _title) when is_binary(sentence),
    do: sentence

  # No room: what holds the memory, the person's own programs by name.
  defp unlisted_words(socket, {:refused, {:capacity, held}, _boot}, title),
    do: no_room(socket, title, held)

  defp unlisted_words(socket, {:refused, :capacity, _boot}, title),
    do: no_room(socket, title, nil)

  defp unlisted_words(_socket, _unanswered, title),
    do: "#{title} did not answer, so its list of models is not shown."

  defp no_room(socket, title, held) do
    actor = Sanctum.Context.actor(socket.assigns.context)
    Prima.Refusal.message(Opus.Programs.full(actor, title, held))
  end

  # The person may have signed in there: what waited on the terminal, its
  # program first among it, is asked.
  @impl PrismWeb.TerminalComponent
  def terminal_ended(socket, %{}), do: next(socket)
  def terminal_ended(socket, nil), do: socket

  @impl PrismWeb.TerminalComponent
  def terminal_dismissed(socket), do: socket |> TerminalComponent.detach() |> next()

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

  # The catalogue asked, under the number of its ask.
  defp load_models(socket) do
    socket = asked(socket)

    case PrismWeb.ModelCatalog.load(socket.assigns.context, socket.assigns.asks) do
      :ok -> socket
      :unavailable -> assign(socket, :models_loaded, true)
    end
  end

  # The sentence for a consent that no longer answers, named by its source;
  # each action it lacks by the words the action is declared with.
  defp consent_warning(ref, {:drifted, missing}) do
    shown = missing |> Enum.take(4) |> Enum.map_join(", ", &action_words/1)
    rest = if length(missing) > 4, do: " and #{length(missing) - 4} more", else: ""

    count =
      case missing do
        [_one] -> "one action the shipped manifest grants is"
        _many -> "#{length(missing)} actions the shipped manifest grants are"
      end

    "This athanor consented to an older #{short_ref(ref)}: #{count} not in its consent " <>
      "(#{shown}#{rest}), so a call to one is refused until you consent again."
  end

  defp consent_warning(ref, :stale) do
    "What #{short_ref(ref)} uses changed since this athanor consented — a capability, the " <>
      "model it runs on or a component it calls — so it cannot run until you consent again."
  end

  defp action_words(name) do
    case String.split(name, ".", parts: 2) do
      [tool, action] -> Aqua.action_title(tool, action)
      [_undotted] -> name
    end
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
    <%!-- A capability, the model or a component a source calls moves the
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
  step for each one ticked; a brain whose key is saved as its provider
  answered its `models` call (`brain_state/1`): connected once it listed
  models, no models when it listed none, not connected with what it said
  once it refused the key, no answer when it listed nothing for another
  reason, and only "key saved" until it answered; and a program as what
  is known of it says: signed in,
  signed out, or installed while nothing is known, which completes the
  step and still offers its sign-in once ticked. The crew: the form that
  makes a crew member (`AgentsComponent.member_form/1`), and the members
  made, each ready or what it waits on, a member whose program is known
  signed out, or whose key's provider is not connected, not ready, the
  second in the row's words. Aqua: which crew member it runs on, done once
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
  attr :asking, :any, required: true
  attr :model_errors, :map, required: true
  attr :model_refused, :map, required: true
  attr :models_loaded, :boolean, required: true
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

    providers = Enum.map(providers, &Map.put(&1, :answer, answer(&1, assigns)))

    # A member on a key is as its brain's row reads: one whose provider is
    # not connected is not ready, and says so in the row's words.
    members =
      for member <- read[:members] || [] do
        out? = AgentsComponent.signed_out?(known, member.agent["program"])
        down = down_line(member.agent, providers)

        Map.merge(member, %{
          ready: member.ready and not out? and is_nil(down),
          signed_out: out?,
          down: down
        })
      end

    soul_ready? =
      read[:soul_ready] == true and
        not AgentsComponent.signed_out?(known, read[:soul_program]) and
        not Enum.any?(members, &(&1.name == read[:member] and &1.down))

    assigns =
      assigns
      |> assign(:brains, providers)
      |> assign(:programs, programs)
      |> assign(:steps, Enum.filter(providers, &step?(&1, assigns.ticked)))
      |> assign(:program_steps, Enum.filter(programs, &program_step?(&1, assigns)))
      |> assign(
        :connected?,
        Enum.any?(providers, &(&1.state == :ready and not down?(brain_state(&1)))) or
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
            Tick what you have: a key from a model provider, or {program_titles(@programs, :required) ||
              "a coding program"} on your own plan.{free_line(@programs)}
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
              <span
                :if={brain.state == :ready and standing_line(brain)}
                data-test="setup-standing"
                class={standing_class(brain_state(brain))}
              >
                {standing_line(brain)}
              </span>
              <span
                :if={brain.state in [:consent_damaged, :consent_unavailable, :model_unavailable]}
                class="text-amber-300"
              >
                {unready_line(brain.state)}
              </span>
              <span
                :if={brain.state == :ready and brain.answer}
                data-test="setup-answer"
                class={answer_class(brain_state(brain))}
              >
                {answer_line(brain.provider, brain.answer)}
              </span>
              <%!-- The listing's failure keeps a sentence and not its
                    cause, so the row does not say the key is wrong; only
                    the person's own key is theirs to replace. --%>
              <span
                :if={(brain_state(brain) == :not_connected and brain.need) && !brain.shared}
                data-test="setup-replace-key"
              >
                If the key is wrong,
                <.link
                  navigate={PrismWeb.Focus.path(@athanor, "/vault")}
                  class="text-blue-400 hover:underline"
                >replace it in the Vault</.link>
                with its Rotate button.
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
                {install_line(program)}
                <.link
                  navigate={install_path(@athanor, program)}
                  data-test="install-program"
                  class="text-blue-400 hover:underline"
                >
                  install {program.name}
                </.link>
              <% else %>
                {program_step_line(program, @known)}
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
            :if={@terminal && is_nil(@terminal.panel)}
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
                <%= if member.down do %>
                  {member.title}:
                  <span data-test="setup-member-down" class="text-amber-300">not ready — {member.down}</span>
                <% else %>
                  {member.title}: not ready yet — its card below says why.
                <% end %>
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
                disabled={member.signed_out or not is_nil(member.down)}
                class={(member.signed_out or member.down) && "text-gray-500"}
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

  # The programs of one kind (`Opus.Programs.Definition.brains/0`'s
  # `sign_in`), by title: "A, B or C", or nil for none.
  defp program_titles(programs, sign_in) do
    case for(%{sign_in: ^sign_in, title: title} <- programs, do: title) do
      [] -> nil
      [one] -> one
      titles -> Enum.join(Enum.drop(titles, -1), ", ") <> " or " <> List.last(titles)
    end
  end

  # The route that needs no key and no sign-in, where a program offers one.
  defp free_line(programs) do
    case program_titles(programs, :optional) do
      nil -> nil
      titles -> " With neither, tick #{titles}: its own free models need no key and no sign-in."
    end
  end

  defp program_need_line(%{sign_in: :optional, title: title}),
    do:
      "runs in its own folder on #{title}'s free models, with no key or sign-in; " <>
        "sign in only to use a provider of yours"

  defp program_need_line(_program), do: "runs in its own folder, signed in to your own plan"

  defp install_line(%{sign_in: :optional, title: title}), do: "#{title}: install its program."
  defp install_line(%{title: title}), do: "#{title}: install its program, then sign it in."

  # A program that answers unsigned is no step to take while nothing says
  # it is signed out: its sign-in is offered, not asked.
  defp program_step_line(%{sign_in: :optional, title: title} = program, known) do
    if program_state(program, known) == "installed",
      do: "#{title}: ready on its free models. Sign in only to use a provider of yours.",
      else: "#{title}: sign it in on its terminal."
  end

  defp program_step_line(%{title: title}, _known), do: "#{title}: sign it in on its terminal."

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

  # What the provider of a brain whose key is saved answered its `models`
  # call: its models, what it said instead (refusing the key, or for any
  # other reason), `:asking` while a grant here or the page's first
  # listing is out, and nil when the listing came back with nothing for
  # it.
  defp answer(%{state: :ready, ref: ref, provider: provider}, assigns) do
    cond do
      Map.has_key?(assigns.asking, identity(ref)) -> :asking
      ids = assigns.models_by_provider[provider] -> {:ok, ids}
      sentence = assigns.model_refused[provider] -> {:refused, sentence}
      sentence = assigns.model_errors[provider] -> {:error, sentence}
      not assigns.models_loaded -> :asking
      true -> nil
    end
  end

  defp answer(_brain, _assigns), do: nil

  # How a brain whose key is saved stands, the one reading every step of
  # the setup takes: a key bound is not a key the provider takes, and
  # only models to choose from say connected.
  defp brain_state(%{answer: {:ok, [_ | _]}}), do: :connected
  defp brain_state(%{answer: {:ok, []}}), do: :no_models
  defp brain_state(%{answer: {:refused, _sentence}}), do: :not_connected
  defp brain_state(%{answer: {:error, _sentence}}), do: :no_answer
  defp brain_state(%{answer: :asking}), do: :asking
  defp brain_state(_unasked), do: :unasked

  # The states no crew member can work on.
  defp down?(state), do: state in [:no_models, :not_connected, :no_answer]

  # One state at a time: while its provider is asked, only a key of the
  # person's own says more than the asking.
  defp standing_line(brain) do
    case {brain_state(brain), brain} do
      {:connected, _brain} -> "connected"
      {:no_models, _brain} -> "no models"
      {:not_connected, _brain} -> "not connected"
      {:no_answer, _brain} -> "no answer"
      {:asking, %{shared: nil, need: need}} when not is_nil(need) -> "key saved"
      {:asking, _brain} -> nil
      {:unasked, %{shared: shared}} when not is_nil(shared) -> "not asked yet"
      {:unasked, %{need: nil}} -> "granted"
      {:unasked, _brain} -> "key saved"
    end
  end

  defp standing_class(:connected), do: "text-emerald-400"
  defp standing_class(state), do: if(down?(state), do: "text-amber-300", else: "text-gray-400")

  defp answer_line(provider, :asking), do: "Asking #{provider}…"
  defp answer_line(provider, {:ok, []}), do: "#{provider} answered with no models."
  defp answer_line(provider, {:ok, [_one]}), do: "#{provider} answered with one model."
  defp answer_line(provider, {:ok, ids}), do: "#{provider} answered with #{length(ids)} models."
  defp answer_line(provider, {_said, sentence}), do: "#{provider} answered: #{sentence}"

  defp answer_class(:not_connected), do: "text-red-300"
  defp answer_class(_state), do: "text-gray-400"

  # Why a member on a key cannot work, in its brain's row's words; nil
  # for a member on a program, or whose brain's row reads none of them.
  defp down_line(%{"catalyst_ref" => ref}, providers) when is_binary(ref) do
    with %{provider: provider} = brain <-
           Enum.find(providers, &(identity(&1.ref) == identity(ref))),
         true <- brain.state == :ready do
      case brain_state(brain) do
        :not_connected -> "#{provider} is not connected."
        :no_models -> "#{provider} answered with no models."
        :no_answer -> "#{provider} gave no answer."
        _up -> nil
      end
    else
      _none -> nil
    end
  end

  defp down_line(_agent, _providers), do: nil

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
    standing = standing(assigns.programs, assigns.agents_read)
    known = AgentsComponent.known(assigns.context, standing)

    # `rendered` has the roster render, and so read what is known, whenever
    # the page does.
    assigns =
      assigns
      |> assign(:standing, standing)
      |> assign(:known, known)
      |> assign(:runnable, AgentsComponent.runnable(standing, known))
      |> assign(:rendered, make_ref())
      |> assign(
        :shown,
        shown_listings(assigns.listings, assigns.waiting, assigns.sign_in, assigns.terminal)
      )

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
        runnable={@runnable}
        listings={@shown}
        terminal={@terminal}
        ticked={@ticked}
        asking={@asking}
        model_errors={@model_errors}
        model_refused={@model_refused}
        models_loaded={@models_loaded}
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
        standing={@standing}
        rendered={@rendered}
        program_listings={@shown}
        setting_up={@sign_in && elem(@sign_in, 0)}
        set_up_refused={@sign_in_refused}
        terminal={@terminal}
        providers={@providers}
      />

      <.live_component module={NotesComponent} id="aqua-notes-section" context={@context} />

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
