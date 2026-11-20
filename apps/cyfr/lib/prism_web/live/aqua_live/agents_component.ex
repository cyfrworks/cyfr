# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.AgentsComponent do
  @moduledoc """
  The soul and its crew. The soul has a prompt, a brain and the tools
  every crew member is offered too; a crew member has a prompt, a brain,
  what it is good at and what to avoid. Each of them has a mode,
  read-only or auto, which decides what of its offered tools it runs; the
  read-only choice is closed, with the reason beneath it, for a member
  whose brain CYFR cannot keep read-only (`Aqua.read_only_unheld/3`).
  Each brain's models come from the model catalogue and its options from
  the brain's own `describe` (`Aqua.brain_options/2`); a brain that is a
  program, named by its row's name, offers the models and efforts its
  program lists (`Aqua.program_listing/2`) and no other brain, and its
  card offers to install the program while the athanor has no row of
  that name, prefilled from the member's file, then to set it up, where
  the person signs it in. Every write goes
  through the `aqua` tool, the gate every writer of an agent file goes
  through; a write that changes a file's provenance asks the page to
  re-read it (`{:refresh, :agents}`), since the chips and the removal
  verbs come off that read.

  Beside the soul's tools stands the person's browser setting, read and
  written through the `browser` tool as the person: the browser's own
  actions follow it, so the capability list leaves them out. While
  either of Aqua's browsers, the person's or the second for work kept
  apart, is not added, the section offers to add it on the Programs
  page, where its definition is confirmed as any program's is.
  """

  use PrismWeb, :live_component

  import PrismWeb.AquaLive.Section

  alias Phoenix.LiveView.JS
  alias PrismWeb.AquaLive.Catalog

  # `field` names exactly what the forms edit — never an arbitrary map key.
  # An unconstrained key could shadow the "action" verb (a later duplicate
  # key wins in a map literal) or write any field, the system prompt
  # included, from an event the templates never send.
  @editable_fields ~w(title description avoid)

  # Each mode a member may be in, as its file spells it, with the words
  # its choice on the card reads.
  @modes [
    {"read-only", "Read-only: runs only reads, then answers; every other call is refused"},
    {"auto", "Auto: runs every tool it is offered, deleting included"}
  ]
  @mode_names Enum.map(@modes, &elem(&1, 0))

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded, false)
     |> assign(:agents, [])
     |> assign(:soul, nil)
     |> assign(:agents_unread, nil)
     |> assign(:crew, [])
     |> assign(:tool_actions, nil)
     |> assign(:browser, nil)
     |> assign(:model_status, %{})
     |> assign(:brain_options, %{})
     |> assign(:program_models, %{})
     |> assign(:program_offers, %{})
     |> assign(:signs_in, MapSet.new())
     |> assign(:unheld, %{})
     |> assign(:installing, nil)
     |> assign(:setting_up, nil)
     |> assign(:set_up_refused, %{})
     |> assign(:editor_editing_prompt, nil)
     |> assign(:editor_prompt_content, "")
     |> assign(:editor_prompt_digest, nil)}
  end

  @impl true
  # The install this section is showing ended — the parent says so when the
  # fetch answers, landed or refused. Named by its ref, because an ordinary
  # section reload (an edit, a member created) must not re-enable a button
  # whose download is still running and invite a second one.
  def update(%{installed: ref}, socket) do
    {:ok,
     if(socket.assigns.installing == ref,
       do: assign(socket, :installing, nil),
       else: socket
     )}
  end

  def update(%{load: true} = assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :load))

    {:noreply, socket} =
      CyfrWeb.ContextGuard.guard(
        socket,
        &{:noreply, &1 |> load_agents() |> assign(:loaded, true)}
      )

    {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("dismiss_flash", _params, socket), do: {:noreply, clear_flash(socket)}

  # Installing a model catalyst is an OCI fetch that can take seconds, so it
  # runs as a supervised task and answers into the page's mailbox — never
  # inline in the click, which would hold the LiveView.
  def handle_event("install_catalyst", %{"ref" => ref}, socket) when is_binary(ref) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context
      tag = CyfrWeb.ContextGuard.capture(ctx)
      lv = self()
      logger_metadata = Prima.LoggerContext.capture()

      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        Prima.LoggerContext.restore(logger_metadata)

        result =
          PrismWeb.Ops.call_tool(ctx, "component/pull", %{"reference" => ref})

        send(lv, {:catalyst_installed, tag, ref, result})
      end)

      {:noreply, assign(socket, :installing, ref)}
    end)
  end

  # A new crew member starts with a name and nothing else: it holds the
  # soul's hands like every member, and its brain is picked on its card.
  def handle_event("editor_create_member", _params, %{assigns: %{loading: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Still loading — try again in a moment.")}
  end

  def handle_event("editor_create_member", %{"name" => name}, socket) when name != "" do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case call_aqua(socket.assigns.context, %{
             "action" => "create",
             "name" => name,
             "title" => name,
             "content" => "# #{name}\n\nYou are #{name}, a crew member of this athanor's Aqua."
           }) do
        {:ok, _created} ->
          send(self(), {:refresh, :agents})

          {:noreply,
           put_flash(
             socket,
             :info,
             "Added '#{name}' to the crew — pick its brain and say what it is good at."
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Create failed: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("editor_create_member", _params, socket), do: {:noreply, socket}

  def handle_event(
        "editor_update_field",
        %{"name" => name, "field" => field, "value" => value},
        socket
      )
      when field in @editable_fields do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      args = Map.merge(%{field => value}, %{"action" => "update", "name" => name})

      case call_aqua(socket.assigns.context, args) do
        {:ok, _} ->
          send(self(), {:refresh, :agents})
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("editor_update_field", _params, socket), do: {:noreply, socket}

  # The tool owns the disposition: a member this athanor made is deleted, an
  # edited copy of a shipped one is restored. The card offers the verb
  # only where one of those applies (`removal/1`).
  def handle_event("editor_delete", %{"name" => name}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case call_aqua(socket.assigns.context, %{"action" => "delete", "name" => name}) do
        {:ok, _} ->
          send(self(), {:refresh, :agents})
          {:noreply, put_flash(socket, :info, "Deleted the crew member '#{name}'.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("editor_revert", %{"name" => name}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case call_aqua(socket.assigns.context, %{"action" => "reset", "name" => name}) do
        {:ok, _} ->
          send(self(), {:refresh, :agents})

          {:noreply,
           put_flash(socket, :info, "Reverted '#{name}' to what ships with the server.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Revert failed: #{error_message(reason)}")}
      end
    end)
  end

  # Taking a crew member out of the crew — and putting it back — without
  # touching its file's content. This is how a shipped member is set
  # aside, since the athanor does not own it and cannot delete it.
  def handle_event("editor_set_disabled", %{"name" => name, "disabled" => flag}, socket)
      when flag in ["true", "false"] do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      disabled? = flag == "true"

      case call_aqua(socket.assigns.context, %{
             "action" => "update",
             "name" => name,
             "disabled" => disabled?
           }) do
        {:ok, _} ->
          send(self(), {:refresh, :agents})
          verb = if disabled?, do: "Disabled", else: "Enabled"
          {:noreply, put_flash(socket, :info, "#{verb} the crew member '#{name}'.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  # A member's mode, the soul's or a crew member's: what of its offered
  # tools it runs from its next turn on. Only the two modes are written;
  # any other value is no edit.
  def handle_event("editor_set_mode", %{"name" => name, "mode" => mode}, socket)
      when mode in @mode_names do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case call_aqua(socket.assigns.context, %{
             "action" => "update",
             "name" => name,
             "mode" => mode
           }) do
        {:ok, _} ->
          send(self(), {:refresh, :agents})
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("editor_set_mode", _params, socket), do: {:noreply, socket}

  # Offer one tool to the soul, or take it off: a `tool.action`, or the
  # provider's own `native_search`. The direction is read from the soul's
  # list as it is NOW, just before the write, never the copy this page
  # loaded, and the edit names the one tool, which the `aqua` door adds to
  # or takes off the list as it stands when the write lands, so a toggle
  # made elsewhere at the same moment on another tool is kept.
  def handle_event("editor_toggle_capability", %{"name" => name, "key" => key}, socket)
      when is_binary(key) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context

      result =
        with {:ok, agent} <- call_aqua(ctx, %{"action" => "get", "name" => name}) do
          edit = if key in (agent.tools || []), do: "tools_remove", else: "tools_add"
          call_aqua(ctx, %{"action" => "update", "name" => name, edit => [key]})
        end

      case result do
        {:ok, _} ->
          send(self(), {:refresh, :agents})
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  # The person's browser setting, set through the gate as the person:
  # turning it on or off on this page is their own act, which asks
  # nothing more.
  def handle_event("browser_set", %{"on" => on}, socket) when on in ["true", "false"] do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context
      action = if on == "true", do: "browser/turn_on", else: "browser/turn_off"

      case PrismWeb.Ops.call_tool(ctx, action, %{}) do
        {:ok, _set} ->
          {:noreply, assign(socket, :browser, browser_status(ctx))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, Sanctum.Refusals.render(reason))}
      end
    end)
  end

  # The editor opens on the prompt as it is now, with the digest `get`
  # names for it, so a save over a prompt changed elsewhere since is
  # refused as a conflict.
  def handle_event("editor_edit_prompt", %{"name" => name}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case call_aqua(socket.assigns.context, %{"action" => "get", "name" => name}) do
        {:ok, agent} ->
          {:noreply,
           socket
           |> assign(:editor_editing_prompt, name)
           |> assign(:editor_prompt_content, agent.content)
           |> assign(:editor_prompt_digest, agent[:content_digest])}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not open the prompt: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("editor_cancel_prompt", _params, socket) do
    {:noreply, assign(socket, :editor_editing_prompt, nil)}
  end

  def handle_event("editor_save_prompt", %{"content" => content}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      name = socket.assigns.editor_editing_prompt

      # The digest names the version this editor opened: a save over a
      # prompt changed elsewhere since is refused as a conflict, and
      # the editor stays open with the draft.
      case call_aqua(socket.assigns.context, %{
             "action" => "update",
             "name" => name,
             "content" => content,
             "expected_digest" => socket.assigns.editor_prompt_digest
           }) do
        {:ok, _} ->
          send(self(), {:refresh, :agents})
          {:noreply, assign(socket, :editor_editing_prompt, nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Save failed: #{error_message(reason)}")}
      end
    end)
  end

  # A program brain's model is one its program lists, written alone: its
  # brain stays the program the member names.
  def handle_event(
        "editor_set_model",
        %{"name" => name, "brain" => "program", "value" => value},
        socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      model = if value == "", do: nil, else: value

      result =
        call_aqua(socket.assigns.context, %{
          "action" => "update",
          "name" => name,
          "model" => model
        })

      send(self(), {:refresh, :agents})

      case result do
        {:ok, _} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Model update failed: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("editor_set_model", %{"name" => name, "value" => value}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context

      choice = Catalog.decode_model_choice(value)

      result =
        case choice do
          {:inherit} ->
            call_aqua(ctx, %{
              "action" => "update",
              "name" => name,
              "model" => nil,
              "catalyst_ref" => nil
            })

          {:model, provider, model} ->
            # No hardcoded publisher fallback. A ref built from a personal
            # namespace resolves to nothing on any other deployment, so the
            # model choice failed silently there; the refs the page loaded are
            # the only ones that exist. A brain is a catalyst or a program, so
            # a program the agent named, and its install, go.
            catalyst_ref =
              case socket.assigns[:catalyst_refs][provider] do
                nil -> nil
                ref -> Regex.replace(~r/:\d+\.\d+\.\d+$/, ref, "")
              end

            call_aqua(ctx, %{
              "action" => "update",
              "name" => name,
              "model" => model,
              "catalyst_ref" => catalyst_ref,
              "program" => nil,
              "install" => nil
            })

          # A plan the setup offers: the program a crew member names, with
          # that member's install, and a model its program lists.
          {:program, program, model} ->
            call_aqua(ctx, %{
              "action" => "update",
              "name" => name,
              "model" => model,
              "catalyst_ref" => nil,
              "program" => program,
              "install" => plan_install(socket.assigns.crew, program)
            })

          :noop ->
            {:ok, :noop}
        end

      send(self(), {:refresh, :agents})

      case result do
        # A brain or model picked moves the agent's consent's shape, so its
        # consent is asked again at once, in the page's system layer.
        {:ok, _} when is_tuple(choice) and elem(choice, 0) in [:model, :program] ->
          send(self(), {:ask_grant, Prima.AgentRef.ref(name)})
          {:noreply, socket}

        {:ok, _} ->
          {:noreply, socket}

        {:error, reason} ->
          # A discarded refusal made the select box appear to work — the
          # refresh then quietly snapped it back.
          {:noreply, put_flash(socket, :error, "Model update failed: #{error_message(reason)}")}
      end
    end)
  end

  # One brain option set, or taken off (an empty value: the brain's own
  # default). The value is cast to the kind the brain declares — the
  # declaration the page read, never the wire's word — and sent as a
  # one-option patch the `aqua` door applies under its lock, so an edit of
  # another option made elsewhere at the same moment is kept.
  def handle_event(
        "editor_set_option",
        %{"name" => name, "option" => option, "value" => value},
        socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context
      declared = declared_option(socket, name, option)

      with {:ok, cast} <- cast_option(declared, value),
           {:ok, _} <-
             call_aqua(ctx, %{
               "action" => "update",
               "name" => name,
               "options_patch" => %{option => cast}
             }) do
        send(self(), {:refresh, :agents})
        {:noreply, socket}
      else
        {:refused, sentence} ->
          {:noreply, put_flash(socket, :error, sentence)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  # Set up on the card is the person's start of the program: it shows the
  # person's own running terminal of the row of that name, the one its
  # install opened among them, so one kept folder never runs two of the
  # program at once from here; only when none runs does it open one,
  # through the gate like the Programs page's Open, at a default size the
  # frame corrects when it attaches. Either way it shows the terminal
  # with the way back here. A refusal stays on the card in the gate's
  # words.
  def handle_event("set_up_program", %{"program" => program}, socket)
      when is_binary(program) do
    CyfrWeb.ContextGuard.guard(socket, fn
      %{assigns: %{setting_up: nil}} = socket ->
        ctx = socket.assigns.context
        tag = CyfrWeb.ContextGuard.capture(ctx)
        params = %{"name" => program, "rows" => 24, "cols" => 80}

        {:noreply,
         socket
         |> assign(:setting_up, program)
         |> assign(:set_up_refused, Map.delete(socket.assigns.set_up_refused, program))
         |> start_async(
           :set_up_program,
           fn ->
             {tag, program,
              running_terminal(ctx, program) ||
                PrismWeb.Ops.run_to_end(fn ->
                  PrismWeb.Ops.call_tool(ctx, "mcp_servers/open", params)
                end)}
           end,
           supervisor: Prism.TaskSupervisor
         )}

      socket ->
        {:noreply, socket}
    end)
  end

  # The person's own running terminal of the row named `program`, the
  # oldest, as the open that started it answers; nil when none runs or
  # the sessions cannot be read, and then Set up opens one.
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

  @impl true
  def handle_async(:set_up_program, {:ok, {tag, program, result}}, socket) do
    socket = assign(socket, :setting_up, nil)
    CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, set_up(&1, program, result)})
  end

  # Only the node's shutdown stops a start (`PrismWeb.Ops.run_to_end/1`).
  def handle_async(:set_up_program, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:brain_options, {:ok, {tag, options, models}}, socket) do
    CyfrWeb.ContextGuard.deliver(socket, tag, fn socket ->
      send(self(), {:plan_models, plan_models(socket.assigns.crew, models)})
      {:noreply, socket |> assign(:brain_options, options) |> assign(:program_models, models)}
    end)
  end

  def handle_async(:brain_options, {:exit, _reason}, socket), do: {:noreply, socket}

  # ============================================================================
  # The roster
  # ============================================================================

  defp load_agents(socket) do
    ctx = socket.assigns.context
    provenance = socket.assigns.provenance
    types = [Compendium.agent_soul_type(), Compendium.agent_crew_type()]

    # One call: list with detail carries every field the cards show, and
    # the members set aside — `list` leaves them out of the crew; a member
    # disabled from this page must stay on it to be put back.
    # A list that cannot be read is not a room with no agents: the page
    # says so in place of the agent cards, the new-member form and the
    # missing soul's note, and no model can be installed or connected. A
    # soul whose file still holds the retired `tool_policy` is refused as
    # a conflict whose sentence says what to change, which stands there
    # instead of a fault's words.
    {listed, unread} =
      case call_aqua(ctx, %{"action" => "list", "detail" => true, "include_disabled" => true}) do
        {:ok, %{guides: guides}} when is_list(guides) ->
          {Enum.filter(guides, &(&1.type in types)), nil}

        {:error, {:conflict, sentence}} when is_binary(sentence) ->
          {[], sentence}

        _unread ->
          {[], "Aqua and its crew members cannot be read right now — try again."}
      end

    # Each card reads its agent in the roster's string-keyed projection,
    # which `Aqua.model_status/2` reads too.
    agents =
      for g <- listed do
        %{
          "name" => g.name,
          "title" => g.title || g.name,
          "type" => g.type,
          "description" => g.description || "",
          "avoid" => g[:avoid] || "",
          "model" => g.model,
          "catalyst_ref" => g.catalyst_ref,
          "program" => g[:program],
          "install" => g[:install],
          "options" => g[:options] || %{},
          "mode" => g[:mode] || "auto",
          "tools" => g[:tools] || [],
          "disabled" => g.disabled == true,
          "provenance" => Map.get(provenance, Enum.join(Compendium.agent_file_path(g.name), "/"))
        }
      end

    soul_type = Compendium.agent_soul_type()
    soul = Enum.find(agents, &(&1["type"] == soul_type))
    crew = agents |> Enum.reject(&(&1["type"] == soul_type)) |> Enum.sort_by(& &1["name"])
    status = Aqua.model_status(ctx, agents)

    # The page's setup is open while the soul's brain is not connected and
    # names the crew members whose brain is not; a roster that could not
    # be read tells it nothing.
    if is_nil(unread) do
      send(self(), {:agents_read, brains_read(soul, crew, status)})
    end

    socket
    |> assign(:agents, agents)
    |> assign(:agents_unread, unread)
    |> assign(:soul, soul)
    |> assign(:crew, crew)
    |> assign(:model_status, status)
    |> assign_plans(ctx, agents, listed)
    |> load_brain_options(agents, status)
    |> ensure_tool_actions_loaded()
    |> assign(:browser, browser_status(ctx))
  end

  # The browser setting, whether each of Aqua's browsers is added and
  # whether either runs, as `browser.status` answers them; nil when it
  # cannot be read.
  defp browser_status(ctx) do
    case PrismWeb.Ops.call_tool(ctx, "browser/status", %{}) do
      {:ok, status} -> status
      {:error, _unread} -> nil
    end
  end

  defp brains_read(soul, crew, status) do
    ready? = &match?({:ready, _}, status[&1])

    %{
      soul: soul && soul["name"],
      soul_ready: soul != nil and ready?.(soul["name"]),
      unconnected: for(m <- crew, not m["disabled"], not ready?.(m["name"]), do: m["name"]),
      plans: plans(crew, status)
    }
  end

  # The plans the page's setup offers: each program the crew's files
  # name, once, by the first member by name that names it, with that
  # member's title and install, and how the row of that name stands, as
  # that member's status reads it (`Aqua.Models`). A program row no crew
  # file names is no plan.
  defp plans(crew, status) do
    crew
    |> Enum.filter(&is_binary(program_of(&1)))
    |> Enum.uniq_by(&program_of/1)
    |> Enum.map(fn %{"name" => member} = m ->
      {state, _name} = status[member] || {:model_unavailable, nil}

      %{
        program: m["program"],
        install: m["install"],
        member: member,
        title: m["title"] || member,
        state: state
      }
    end)
    |> Enum.sort_by(& &1.program)
  end

  # Each program a crew member names with the models its listing gave
  # that member's card, for the setup's picker.
  defp plan_models(crew, models) do
    for %{"name" => member} = m <- crew,
        is_binary(program_of(m)),
        is_list(models[member]),
        into: %{},
        do: {m["program"], models[member]}
  end

  # Each ready brain's options, from its own `describe` — a catalyst run
  # each, so read off the page's process and delivered for the focus they
  # were read under; a program brain's models and efforts from its
  # program's own listing (`Aqua.program_listing/2`), its efforts the one
  # option it offers. A brain that is not ready, or whose `describe` or
  # listing does not answer, offers none.
  defp load_brain_options(socket, agents, status) do
    case Enum.filter(agents, &match?({:ready, _}, status[&1["name"]])) do
      [] -> socket |> assign(:brain_options, %{}) |> assign(:program_models, %{})
      ready -> describe_brains(socket, ready)
    end
  end

  defp describe_brains(socket, ready) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(socket)

    start_async(socket, :brain_options, fn ->
      read = Map.new(ready, &{&1["name"], described(ctx, &1)})

      {tag, Map.new(read, fn {name, {options, _models}} -> {name, options} end),
       for({name, {_options, models}} <- read, is_list(models), into: %{}, do: {name, models})}
    end)
  end

  # A brain's options, and for a program brain the models its program
  # lists (nil for a catalyst's, whose models the catalogue lists).
  defp described(ctx, %{"program" => program} = agent) when is_binary(program) do
    case Aqua.program_listing(ctx, agent) do
      {:ok, %{models: models, efforts: efforts}} -> {efforts_option(efforts), models}
      {:error, _unlisted} -> {[], []}
    end
  end

  defp described(ctx, agent) do
    case Aqua.brain_options(ctx, agent) do
      {:ok, options} -> {options, nil}
      {:error, _unread} -> {[], nil}
    end
  end

  defp efforts_option([]), do: []
  defp efforts_option(efforts), do: [%{"name" => "effort", "kind" => "enum", "values" => efforts}]

  # Each agent's catalyst, read once through its setup plan: the programs
  # its login needs offer to install, and whether it runs on a program's
  # own sign-in (`Aqua.brain_signs_in?/1`), whose binding is the one row
  # named as its program, so its card offers no other to change to; and
  # which members' brains CYFR cannot keep read-only
  # (`Aqua.read_only_unheld/3`). A plan
  # that cannot be read offers nothing.
  defp assign_plans(socket, ctx, agents, listed) do
    plans =
      for ref <- agents |> Enum.map(& &1["catalyst_ref"]) |> Enum.uniq(),
          is_binary(ref),
          {:ok, plan} <- [
            PrismWeb.Ops.call_tool(ctx, "component", %{
              "action" => "setup_plan",
              "reference" => ref
            })
          ],
          do: {ref, plan}

    socket
    |> assign(:program_offers, program_offers(ctx, plans))
    |> assign(
      :signs_in,
      for({ref, plan} <- plans, Aqua.brain_signs_in?(plan), into: MapSet.new(), do: ref)
    )
    |> assign(:unheld, Aqua.read_only_unheld(ctx, listed, Map.new(plans)))
  end

  # The program offers a card shows: a catalyst's, from its login needs
  # (`program_offers/2`); a program brain's, from the row of its name as
  # its status reads it: none of that name is offered to install, through
  # the Programs page's form prefilled from the member's file, and one
  # that stands as a brain's to set up, its press starting it in a
  # terminal where the person signs it in. A row of that name that stands
  # disabled, unfit or unread offers neither: its status says why.
  defp offers(_offers, {:program_missing, _name}, %{"program" => program} = agent)
       when is_binary(program) do
    query = %{"install_for" => agent["name"], "from" => "aqua"}
    [%{program: program, installed?: false, query: URI.encode_query(query)}]
  end

  defp offers(_offers, {:ready, _name}, %{"program" => program}) when is_binary(program),
    do: [%{program: program, installed?: true}]

  defp offers(_offers, _status, %{"program" => program}) when is_binary(program), do: []

  defp offers(program_offers, _status, agent),
    do: Map.get(program_offers, agent["catalyst_ref"], [])

  # A brain that runs on a program's own sign-in is bound to the one row
  # named as its program, so its card offers no other to change to.
  defp signs_in?(_signs_in, %{"program" => program}) when is_binary(program), do: true
  defp signs_in?(signs_in, agent), do: MapSet.member?(signs_in, agent["catalyst_ref"])

  # For each catalyst, the programs its login needs name: one the athanor
  # has no row for is offered to install (the Programs page's install
  # form), and one it has is offered to set up: its press starts it in a
  # terminal (`set_up_program`), where the person signs it in; either
  # comes back to Aqua.
  defp program_offers(ctx, plans) do
    plans = for {ref, plan} <- plans, do: {ref, login_programs(plan)}

    names =
      if Enum.any?(plans, fn {_ref, needs} -> needs != [] end) do
        case PrismWeb.Ops.call_tool(ctx, "mcp_servers/list", %{}) do
          {:ok, %{servers: servers}} -> Enum.map(servers, & &1[:name])
          _ -> []
        end
      else
        []
      end

    for {ref, needs} <- plans, into: %{} do
      offers =
        for need <- needs, need.program in names or need.install? do
          query = %{"install" => ref, "need" => need.name, "from" => "aqua"}

          %{
            program: need.program,
            installed?: need.program in names,
            query: URI.encode_query(query)
          }
        end

      {ref, offers}
    end
  end

  defp set_up(socket, _program, {:ok, %{session: session}}) do
    query = URI.encode_query(%{"terminal" => session, "from" => "aqua"})
    push_navigate(socket, to: PrismWeb.Focus.path(socket.assigns.athanor, "/programs?" <> query))
  end

  defp set_up(socket, program, {:error, reason}) do
    refused = Map.put(socket.assigns.set_up_refused, program, error_message(reason))
    assign(socket, :set_up_refused, refused)
  end

  # Aqua's setup, for the agent whose card links to it: the soul's by
  # default, a crew member's named.
  defp setup_path(athanor, _agent, true), do: PrismWeb.Focus.path(athanor, "/aqua?setup=1")

  defp setup_path(athanor, agent, false),
    do:
      PrismWeb.Focus.path(
        athanor,
        "/aqua?" <> URI.encode_query(%{"setup" => "1", "agent" => agent["name"]})
      )

  defp login_programs(plan) do
    for need <- plan[:needs] || [],
        need[:kind] == "login",
        is_binary(need[:program]),
        do: %{name: need[:name], program: need[:program], install?: is_map(need[:install])}
  end

  # Enumerate `(tool, [actions...])` from the live MCP registry — populated
  # once per page open, so the matrix UI can render real (tool, action)
  # pairs the user can toggle. native_search is included as a bare key
  # (no actions enum); its own checkbox stands for it.
  defp ensure_tool_actions_loaded(socket) do
    if socket.assigns[:tool_actions] do
      socket
    else
      assign(socket, :tool_actions, without_setting(Catalog.enumerate_tool_actions()))
    end
  end

  # The actions that follow the person's browser setting have no checkbox:
  # the browser section stands for them.
  defp without_setting(tool_actions) do
    for {tool, actions} <- tool_actions do
      kept =
        if is_list(actions),
          do:
            Enum.reject(actions, fn {action, _kind} ->
              Sanctum.Catalog.follows_setting?(tool, action)
            end),
          else: actions

      {tool, kept}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # The option as the brain's `describe` declared it on this page's read.
  defp declared_option(socket, name, option) do
    socket.assigns.brain_options
    |> Map.get(name, [])
    |> Enum.find(&(&1["name"] == option))
  end

  # An empty value takes the option off; any other is cast to its kind.
  defp cast_option(nil, _value), do: {:refused, "The brain does not declare that option"}
  defp cast_option(_declared, ""), do: {:ok, nil}

  defp cast_option(%{"kind" => "boolean"}, value) when value in ["true", "false"],
    do: {:ok, value == "true"}

  defp cast_option(%{"kind" => "integer"}, value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:refused, "That option takes a whole number"}
    end
  end

  defp cast_option(%{"kind" => "enum", "values" => values}, value) do
    if value in values, do: {:ok, value}, else: {:refused, "Pick one of the brain's values"}
  end

  defp cast_option(%{"kind" => "string"}, value), do: {:ok, value}
  defp cast_option(_declared, _value), do: {:refused, "That value does not fit the option"}

  # The install the first crew member by name that names `program` gives.
  defp plan_install(crew, program),
    do: Enum.find_value(crew, &(program_of(&1) == program && &1["install"]))

  # The program a member's brain is, by its row's name, or nil.
  defp program_of(%{"program" => program}) when is_binary(program) and program != "",
    do: program

  defp program_of(_agent), do: nil

  # The models a program brain's card offers: the ones its program lists,
  # and the member's own model when the listing does not name it (or was
  # not read), so the choice shows what the file holds.
  defp program_choices(listed, model) do
    listed = listed || []

    if is_binary(model) and not Enum.any?(listed, &(&1.id == model)),
      do: listed ++ [%{id: model, name: model}],
      else: listed
  end

  defp agent_provider_for_select(agent) do
    detect_provider_from_ref(agent["catalyst_ref"])
  end

  defp detect_provider_from_ref(nil), do: nil
  defp detect_provider_from_ref(""), do: nil

  defp detect_provider_from_ref(ref) when is_binary(ref) do
    # The grammar's own parser. `~r/catalyst:[^.]+\\.([^:]+)/` reads up to the
    # FIRST dot, so a publisher with one in it — `stripe.com` — gave
    # "com.api" as the provider. `Prima.ComponentRef` exists because the
    # split is the last dot, not the first.
    case Prima.ComponentRef.parse(ref) do
      {:ok, %{type: "catalyst", name: name}} -> name
      _ -> nil
    end
  end

  # The one removal verb a card may offer — label, confirm prefix, event —
  # read from its provenance: the athanor's own member is deleted, an
  # edited copy of a shipped one is restored, an unedited shipped member
  # and the soul offer nothing. A provenance the page could not read
  # offers nothing either.
  defp removal(agent) do
    cond do
      agent["type"] == Compendium.agent_soul_type() ->
        nil

      agent["provenance"] == "user" ->
        {"Delete", "Delete the crew member '", "editor_delete"}

      agent["provenance"] == "bundled_modified" ->
        {"Revert to shipped", "Revert the crew member '", "editor_revert"}

      true ->
        nil
    end
  end

  # How many of a kind's rows the soul's tools name.
  defp count_in_list(tools, rows),
    do: Enum.count(rows, fn {t, a} -> "#{t}.#{a}" in tools end)

  # What each mode does with a kind: a read-only member runs reads alone.
  defp kind_hint(:read), do: "runs in either mode"
  defp kind_hint(_kind), do: "runs only in auto"

  # Kind sections in fixed display order, with their visual treatment:
  # read = calm green, write = near-neutral slate, execute = amber,
  # destructive = red.
  # Tuple: {atom_kind, label, pill-classes, summary-strip-classes}.
  defp kind_sections do
    [
      {:read, "Read", "bg-emerald-900/60 text-emerald-200", "bg-emerald-900/10"},
      {:write, "Write", "bg-slate-700/70 text-slate-200", "bg-slate-800/20"},
      {:execute, "Execute", "bg-amber-900/60 text-amber-200", "bg-amber-900/10"},
      {:destructive, "Destructive", "bg-red-900/60 text-red-200", "bg-red-900/10"}
    ]
  end

  # Flatten `[{tool, [{action, kind}]}]` to `[{tool, action}]` for a given kind.
  defp rows_for_kind(tool_actions, target_kind) do
    Enum.flat_map(tool_actions, fn {tool, actions} ->
      actions
      |> Enum.flat_map(fn
        {action, ^target_kind} -> [{tool, action}]
        _ -> []
      end)
    end)
    |> Enum.sort()
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="aqua-agents" phx-target={@myself} class="space-y-6">
      <.section_flash flash={@flash} target={@myself} />

      <%!-- Offered once the roster is read: a new member is a name, then
            its card. --%>
      <div class="flex justify-end">
        <form
          :if={@loaded and is_nil(@agents_unread)}
          phx-submit="editor_create_member"
          phx-target={@myself}
          class="flex items-center gap-2"
        >
          <input
            type="text"
            name="name"
            placeholder="new-member"
            pattern="[a-z0-9_-]+"
            required
            class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-blue-500 w-44 font-mono"
          />
          <button
            type="submit"
            class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
          >
            + New crew member
          </button>
        </form>
      </div>

      <%!-- Why the roster could not be read: a fault's words, or the
            sentence that says what to change in a soul still holding
            `tool_policy`. --%>
      <div
        :if={@loaded and @agents_unread != nil}
        data-test="agents-unavailable"
        class="text-xs text-amber-300 py-8 px-4 text-center border border-dashed border-gray-800 rounded"
      >
        {@agents_unread}
      </div>

      <div
        :if={@loaded and @soul == nil and is_nil(@agents_unread)}
        class="text-xs text-gray-500 py-8 text-center border border-dashed border-gray-800 rounded"
      >
        No soul here. The soul ships with the server — restore the shipped files below to bring it back.
      </div>

      <.agent_card
        :if={@soul}
        myself={@myself}
        agent={@soul}
        models_by_provider={@models_by_provider}
        tool_actions={@tool_actions || []}
        is_soul={true}
        model_status={Map.get(@model_status, @soul["name"])}
        brain_options={Map.get(@brain_options, @soul["name"], [])}
        installing={@installing}
        setting_up={@setting_up}
        set_up_refused={@set_up_refused}
        athanor={@athanor}
        offers={offers(@program_offers, Map.get(@model_status, @soul["name"]), @soul)}
        signs_in?={signs_in?(@signs_in, @soul)}
        program_models={Map.get(@program_models, @soul["name"])}
        unheld={Map.get(@unheld, @soul["name"])}
        browser={@browser}
      />

      <div :if={@crew != []} class="space-y-3 border-l border-gray-800 pl-4 ml-2">
        <.agent_card
          :for={member <- @crew}
          myself={@myself}
          agent={member}
          models_by_provider={@models_by_provider}
          tool_actions={@tool_actions || []}
          is_soul={false}
          model_status={Map.get(@model_status, member["name"])}
          brain_options={Map.get(@brain_options, member["name"], [])}
          installing={@installing}
          setting_up={@setting_up}
          set_up_refused={@set_up_refused}
          athanor={@athanor}
          offers={offers(@program_offers, Map.get(@model_status, member["name"]), member)}
          signs_in?={signs_in?(@signs_in, member)}
          program_models={Map.get(@program_models, member["name"])}
          unheld={Map.get(@unheld, member["name"])}
        />
      </div>

      <!-- Prompt editor modal — shared by the soul and the crew -->
      <.modal
        id="prompt-editor"
        show={not is_nil(@editor_editing_prompt)}
        size="wide"
        on_cancel={JS.push("editor_cancel_prompt", target: @myself)}
      >
        <div class="flex items-center justify-between border-b border-gray-800 px-4 py-3">
          <h3 class="text-sm font-medium text-gray-200">
            Edit prompt — <code class="font-mono text-blue-400">{@editor_editing_prompt}</code>
          </h3>
          <button
            type="button"
            phx-click="editor_cancel_prompt"
            phx-target={@myself}
            class="text-gray-500 hover:text-gray-300"
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <form
          phx-submit="editor_save_prompt"
          phx-target={@myself}
          class="flex-1 flex flex-col p-4 gap-3"
        >
          <textarea
            name="content"
            class="flex-1 rounded bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-gray-200 font-mono resize-none focus:border-blue-500 focus:outline-none"
            rows="20"
          >{@editor_prompt_content}</textarea>
          <div class="flex items-center justify-end gap-2">
            <button
              type="button"
              phx-click="editor_cancel_prompt"
              phx-target={@myself}
              class="rounded px-3 py-1.5 text-xs text-gray-300 hover:bg-gray-800"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1.5 text-xs font-medium text-white"
            >
              Save
            </button>
          </div>
        </form>
      </.modal>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :agent, :map, required: true
  attr :models_by_provider, :map, required: true
  attr :tool_actions, :list, required: true
  attr :is_soul, :boolean, default: false
  attr :model_status, :any, default: nil
  attr :brain_options, :list, default: []
  attr :installing, :any, default: nil
  attr :setting_up, :any, default: nil
  attr :set_up_refused, :map, default: %{}
  attr :athanor, :any, default: nil
  attr :offers, :list, default: []
  attr :signs_in?, :boolean, default: false
  attr :program_models, :list, default: nil
  attr :unheld, :string, default: nil
  attr :browser, :map, default: nil

  defp agent_card(assigns) do
    assigns =
      assigns
      |> assign(:current_provider, agent_provider_for_select(assigns.agent))
      |> assign(:tools, assigns.agent["tools"] || [])
      |> assign(:mode, assigns.agent["mode"] || "auto")
      |> assign(:removal, removal(assigns.agent))
      |> assign(:disabled?, assigns.agent["disabled"] == true)
      |> assign(:program, program_of(assigns.agent))

    ~H"""
    <div
      id={"aqua-card-#{@agent["name"]}"}
      class={[
        "rounded-lg border border-gray-800 bg-gray-900/60 p-4 space-y-3",
        @disabled? && "opacity-60"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1 min-w-0">
          <form
            id={"aqua-card-#{@agent["name"]}-title"}
            phx-change="editor_update_field"
            phx-submit="editor_update_field"
            phx-target={@myself}
            class="space-y-1"
          >
            <input type="hidden" name="name" value={@agent["name"]} />
            <input type="hidden" name="field" value="title" />
            <input
              type="text"
              name="value"
              value={@agent["title"]}
              phx-debounce="blur"
              class="w-full bg-transparent border-none text-sm font-medium text-gray-100 focus:ring-1 focus:ring-blue-500 rounded px-1 -ml-1"
            />
          </form>
          <div class="flex items-center gap-2 mt-0.5">
            <span class={[
              "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium",
              if(@is_soul,
                do: "bg-purple-900/40 text-purple-300",
                else: "bg-blue-900/40 text-blue-300"
              )
            ]}>
              {@agent["type"]}
            </span>
            <code class="text-[11px] text-gray-500 font-mono">{@agent["name"]}</code>
            <.provenance_chip state={@agent["provenance"]} />
            <span
              :if={@disabled?}
              class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-gray-800 text-gray-400"
              title="Out of the crew — the soul does not see this member until it is enabled"
            >
              disabled
            </span>
          </div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            type="button"
            phx-click="editor_edit_prompt"
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
          >
            Edit prompt
          </button>
          <button
            :if={not @is_soul}
            type="button"
            phx-click="editor_set_disabled"
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            phx-value-disabled={if @disabled?, do: "false", else: "true"}
            class="rounded px-2 py-1 text-[11px] text-gray-400 hover:bg-gray-800 hover:text-gray-200"
          >
            {if @disabled?, do: "Enable", else: "Disable"}
          </button>
          <button
            :if={@removal}
            type="button"
            phx-click={elem(@removal, 2)}
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            data-confirm={elem(@removal, 1) <> @agent["name"] <> "'?"}
            class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
          >
            {elem(@removal, 0)}
          </button>
        </div>
      </div>

      <form
        :for={
          {field, label, placeholder} <- [
            {"description", "Good at", "What the soul hands this member…"},
            {"avoid", "Avoid", "What the soul should never hand it…"}
          ]
        }
        :if={!@is_soul}
        id={"aqua-card-#{@agent["name"]}-#{field}"}
        phx-change="editor_update_field"
        phx-submit="editor_update_field"
        phx-target={@myself}
        class="space-y-1"
      >
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="field" value={field} />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500">{label}</label>
        <input
          type="text"
          name="value"
          value={@agent[field]}
          phx-debounce="blur"
          placeholder={placeholder}
          class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
      </form>

      <div
        :if={Enum.any?(@offers, &(!&1.installed?))}
        class="flex flex-wrap items-center gap-2 text-[11px]"
      >
        <span class="text-amber-300">Its brain runs a program you have not installed:</span>
        <.link
          :for={offer <- @offers}
          :if={!offer.installed?}
          navigate={PrismWeb.Focus.path(@athanor, "/programs?" <> offer.query)}
          class="text-blue-400 hover:underline"
          data-test="install-program"
        >
          install {offer.program}
        </.link>
      </div>
      <div
        :if={Enum.any?(@offers, & &1.installed?)}
        class="flex flex-wrap items-center gap-2 text-[11px]"
      >
        <span class="text-gray-400">Its brain runs in a program's own folder; sign it in there:</span>
        <button
          :for={offer <- @offers}
          :if={offer.installed?}
          type="button"
          phx-click="set_up_program"
          phx-value-program={offer.program}
          phx-target={@myself}
          disabled={@setting_up != nil}
          class="text-blue-400 hover:underline disabled:opacity-50"
          data-test="set-up-program"
        >
          {if @setting_up == offer.program,
            do: "Opening #{offer.program}…",
            else: "Set up #{offer.program}"}
        </button>
        <span
          :for={offer <- @offers}
          :if={offer.installed? and Map.has_key?(@set_up_refused, offer.program)}
          class="text-red-400"
          data-test="set-up-refused"
        >
          {Map.fetch!(@set_up_refused, offer.program)}
        </span>
      </div>

      <%!-- A member with no brain yet is connected through the setup like
           any other. --%>
      <div
        :if={@agent["catalyst_ref"] in [nil, ""] and is_nil(@program)}
        class="flex flex-wrap items-center gap-2 text-[11px]"
      >
        <span class="text-amber-300">No brain yet</span>
        <.link
          patch={setup_path(@athanor, @agent, @is_soul)}
          data-test="connect"
          class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] font-medium text-white"
        >
          Connect
        </.link>
      </div>

      <div :if={@model_status} class="flex flex-wrap items-center gap-2 text-[11px]">
        <span :if={match?({:ready, _}, @model_status)} class="text-emerald-400">
          Model connected
        </span>
        <span :if={match?({:consent_stale, _}, @model_status)} class="text-amber-300">
          Its consent is out of date: what it runs on changed since it was consented.
        </span>
        <button
          :if={match?({:consent_stale, _}, @model_status)}
          type="button"
          phx-click="open_consent"
          phx-value-ref={Prima.AgentRef.ref(@agent["name"])}
          class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] font-medium text-white"
        >
          Consent again
        </button>
        <span :if={match?({:needs_key, _}, @model_status)} class="text-amber-300">
          Not connected — the model has no key yet
        </span>
        <span :if={match?({:needs_grant, _}, @model_status)} class="text-amber-300">
          Not connected — it needs only your grant
        </span>
        <span :if={match?({:needs_program, _}, @model_status)} class="text-amber-300">
          Not connected — set up its program on the Programs page, then grant it
        </span>
        <%!-- A consent that exists but is damaged, or could not be read, is
             no key to connect: no Connect button is offered over it. --%>
        <span :if={match?({:consent_damaged, _}, @model_status)} class="text-red-300">
          A consent this model runs under is damaged and cannot be used — revoke the damaged profile and grant it again.
        </span>
        <span :if={match?({:consent_unavailable, _}, @model_status)} class="text-amber-300">
          A consent this model runs under cannot be read right now — try again.
        </span>
        <span :if={match?({:missing, _}, @model_status)} class="text-amber-300">
          The model's catalyst is not installed here yet
        </span>
        <%!-- A program row of the member's program's name that stands
             but is no brain's is never one to install: it is said as a
             turn on it is refused (`Prima.Refusal`), with the row to open
             on the Programs page. --%>
        <span
          :if={match?({state, _} when state in [:program_disabled, :program_unfit], @model_status)}
          class="text-amber-300"
        >
          {Prima.Refusal.message(
            {:crew_unready, @agent["title"] || @agent["name"], elem(@model_status, 0)}
          )}
        </span>
        <.link
          :if={match?({state, _} when state in [:program_disabled, :program_unfit], @model_status)}
          navigate={
            PrismWeb.Focus.path(@athanor, "/programs?" <> URI.encode_query(%{"name" => @program}))
          }
          data-test="open-program"
          class="text-blue-400 hover:underline"
        >
          open {@program}
        </.link>
        <%!-- A model whose catalysts or setup could not be read may well be
             installed: nothing is offered but to try again. --%>
        <span :if={match?({:model_unavailable, _}, @model_status)} class="text-amber-300">
          This model cannot be read right now — try again.
        </span>
        <button
          :if={match?({:missing, _}, @model_status)}
          type="button"
          phx-click="install_catalyst"
          phx-value-ref={elem(@model_status, 1)}
          phx-target={@myself}
          disabled={@installing != nil}
          class="rounded bg-blue-600 hover:bg-blue-500 disabled:opacity-50 px-2 py-1 text-[11px] font-medium text-white"
        >
          {if @installing, do: "Installing…", else: "Install"}
        </button>
        <.link
          :if={
            match?(
              {status, _} when status in [:needs_key, :needs_grant, :needs_program],
              @model_status
            )
          }
          patch={setup_path(@athanor, @agent, @is_soul)}
          data-test="connect"
          class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] font-medium text-white"
        >
          Connect
        </.link>
        <%!-- A ready brain changes its key here; one that runs a program is
             bound to the one row named as its program, changed on the
             Programs page. --%>
        <button
          :if={match?({:ready, _}, @model_status) and not @signs_in?}
          type="button"
          phx-click="open_consent"
          phx-value-ref={elem(@model_status, 1)}
          class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] font-medium text-white"
        >
          Change the key
        </button>
      </div>

      <%!-- Each change writes the agent's model, so a reconnect replays no
            change: the choice the page held may be older than the model
            another session wrote meanwhile. --%>
      <%!-- A program brain's models are the ones its program lists, and
            none other: its brain is the program it names. While its row is
            not there to list them, the member's model stands alone. --%>
      <form
        :if={@program}
        id={"aqua-card-#{@agent["name"]}-model"}
        phx-change="editor_set_model"
        phx-auto-recover="ignore"
        phx-target={@myself}
      >
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="brain" value="program" />
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</p>
        <select
          name="value"
          aria-label="Model"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option value="" selected={is_nil(@agent["model"])}>
            The program's default
          </option>
          <option
            :for={m <- program_choices(@program_models, @agent["model"])}
            value={m.id}
            selected={@agent["model"] == m.id}
          >
            {m.name}
          </option>
        </select>
      </form>

      <form
        :if={is_nil(@program)}
        id={"aqua-card-#{@agent["name"]}-model"}
        phx-change="editor_set_model"
        phx-auto-recover="ignore"
        phx-target={@myself}
      >
        <input type="hidden" name="name" value={@agent["name"]} />
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</p>
        <select
          name="value"
          aria-label="Model"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option value="" selected={is_nil(@agent["model"])}>
            No model
          </option>
          <%= for {provider, models} <- @models_by_provider, models != [] do %>
            <optgroup label={provider}>
              <option
                :for={m <- models}
                value={Catalog.model_choice(provider, m)}
                selected={@agent["model"] == m and @current_provider == provider}
              >
                {m}
              </option>
            </optgroup>
          <% end %>
        </select>
      </form>

      <div :if={@brain_options != []} id={"aqua-card-#{@agent["name"]}-options"}>
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">
          Brain options
          <span class="normal-case text-gray-600">
            — what the brain lets every request set; empty keeps its default.
          </span>
        </p>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
          <form
            :for={option <- @brain_options}
            id={"aqua-card-#{@agent["name"]}-option-#{option["name"]}"}
            phx-change="editor_set_option"
            phx-auto-recover="ignore"
            phx-target={@myself}
            class="flex items-center gap-2"
          >
            <input type="hidden" name="name" value={@agent["name"]} />
            <input type="hidden" name="option" value={option["name"]} />
            <label class="text-[11px] font-mono text-gray-400 w-32 shrink-0">{option["name"]}</label>
            <.option_input option={option} value={Map.get(@agent["options"] || %{}, option["name"])} />
          </form>
        </div>
      </div>

      <%!-- The member's mode. A brain CYFR cannot keep read-only closes
            the read-only choice, and a file set to it by hand shows it
            chosen with the same reason, since its turns are refused. --%>
      <div
        id={"aqua-card-#{@agent["name"]}-mode"}
        role="radiogroup"
        aria-label="Mode"
      >
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Mode</p>
        <div class="flex flex-col md:flex-row gap-2">
          <button
            :for={{mode, words} <- modes()}
            type="button"
            role="radio"
            aria-checked={to_string(@mode == mode)}
            phx-click="editor_set_mode"
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            phx-value-mode={mode}
            disabled={mode == "read-only" and @unheld != nil}
            class={[
              "flex-1 rounded border px-2 py-1 text-left text-[11px] disabled:cursor-not-allowed disabled:opacity-60",
              if(@mode == mode,
                do: "border-blue-500 bg-blue-950/40 text-gray-100",
                else: "border-gray-700 bg-gray-950 text-gray-400 hover:border-gray-500"
              )
            ]}
          >
            {words}
          </button>
        </div>
        <p :if={@unheld} data-test="read-only-unheld" class="mt-1 text-[11px] text-amber-300">
          {@unheld}
        </p>
      </div>

      <p :if={!@is_soul} class="text-[11px] text-gray-500">
        Offered the soul's tools; a hand-off may narrow them for one job.
      </p>

      <div :if={@is_soul}>
        <div class="flex items-center justify-between mb-1">
          <p class="block text-[10px] uppercase tracking-wider text-gray-500">
            Capabilities
            <span class="normal-case text-gray-600">
              — the tools Aqua and every crew member are offered; each one's mode decides which of them it runs.
            </span>
          </p>
        </div>

        <div class="border border-gray-800 rounded divide-y divide-gray-800/60 max-h-[28rem] overflow-y-auto">
          <%= for {kind, kind_label, kind_chip, kind_strip} <- kind_sections() do %>
            <% rows = rows_for_kind(@tool_actions, kind) %>
            <%= if rows != [] do %>
              <details class="group" open={kind == :write}>
                <summary class={[
                  "flex items-center gap-2 px-2 py-1.5 text-xs cursor-pointer hover:bg-gray-800/40",
                  kind_strip
                ]}>
                  <span class={[
                    "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider",
                    kind_chip
                  ]}>
                    {kind_label}
                  </span>
                  <span class="text-[10px] text-gray-600">{kind_hint(kind)}</span>
                  <span class="ml-auto text-[10px] text-gray-600">
                    {count_in_list(@tools, rows)}/{length(rows)}
                  </span>
                </summary>

                <%= for {tool, action} <- rows do %>
                  <% key = "#{tool}.#{action}" %>
                  <div class="px-3 py-1 flex items-center gap-2 bg-gray-950/40">
                    <label class="flex items-center gap-1.5 flex-1 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={key in @tools}
                        phx-click="editor_toggle_capability"
                        phx-target={@myself}
                        phx-value-name={@agent["name"]}
                        phx-value-key={key}
                        class="rounded bg-gray-900 border-gray-600"
                      />
                      <span class="text-[11px] font-mono text-gray-400">
                        <span class="text-gray-500">{tool}.</span>{action}
                      </span>
                    </label>
                  </div>
                <% end %>
              </details>
            <% end %>
          <% end %>
        </div>
        <label class="flex items-center gap-2 mt-2 text-[11px] text-gray-400 cursor-pointer">
          <input
            type="checkbox"
            checked={"native_search" in @tools}
            phx-click="editor_toggle_capability"
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            phx-value-key="native_search"
            class="rounded bg-gray-900 border-gray-600"
          /> Native search (model-side web grounding) — runs inside the provider
        </label>
        <.browser_setting :if={@browser} myself={@myself} athanor={@athanor} browser={@browser} />
      </div>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :athanor, :any, default: nil
  attr :browser, :map, required: true

  # The person's browser setting, and adding Aqua's browser while it is
  # not added.
  defp browser_setting(assigns) do
    ~H"""
    <div
      id="aqua-browser"
      data-test="aqua-browser"
      class="mt-3 border border-gray-800 rounded p-3 space-y-2"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="text-[11px] text-gray-400">
          <span class="text-gray-200">Browser</span>
          — Aqua has a Chrome of its own that is yours alone, with a window for each thread. While this is on, Aqua opens, reads and acts on sites in it without asking. Off, Aqua cannot use it and its windows close; your sign-ins in it stay.
        </p>
        <button
          type="button"
          role="switch"
          aria-checked={to_string(@browser[:on] == true)}
          data-test="aqua-browser-switch"
          phx-click="browser_set"
          phx-value-on={to_string(@browser[:on] != true)}
          phx-target={@myself}
          class={[
            "shrink-0 rounded px-3 py-1 text-xs font-medium",
            if(@browser[:on] == true,
              do: "bg-emerald-700 text-white hover:bg-emerald-600",
              else: "bg-gray-800 text-gray-300 hover:bg-gray-700"
            )
          ]}
        >
          {if @browser[:on] == true, do: "On", else: "Off"}
        </button>
      </div>
      <p class="text-[11px] text-gray-500">
        Aqua is told never to send, submit, buy or publish on a site without your word; that is its instruction, not a lock. A site you sign in to in this Chrome is open to Aqua too.
      </p>
      <p
        :if={@browser[:browser] == "not_added"}
        class="text-[11px] text-gray-400"
        data-test="aqua-browser-add"
      >
        Aqua's browser is not added yet.
        <.link
          :if={@athanor}
          navigate={PrismWeb.Focus.path(@athanor, "/programs?add=browser&from=aqua")}
          class="text-blue-400 hover:underline"
        >
          Add Aqua's browser
        </.link>
      </p>
      <p :if={@browser[:browser] == "disabled"} class="text-[11px] text-amber-300">
        Aqua's browser is disabled on the Programs page; enable it there.
      </p>
      <p :if={@browser[:browser] == "not_browser"} class="text-[11px] text-amber-300">
        A program named aqua-browser is not Aqua's browser; rename or remove it on the Programs page.
      </p>
      <p
        :if={@browser[:apart] == "not_added"}
        class="text-[11px] text-gray-400"
        data-test="aqua-browser-add-apart"
      >
        Work you ask Aqua to keep apart uses a second Chrome, with none of your sign-ins in it. It is not added yet.
        <.link
          :if={@athanor}
          navigate={PrismWeb.Focus.path(@athanor, "/programs?add=browser-apart&from=aqua")}
          class="text-blue-400 hover:underline"
        >
          Add the second browser
        </.link>
      </p>
      <p :if={@browser[:apart] == "disabled"} class="text-[11px] text-amber-300">
        Aqua's second browser is disabled on the Programs page; enable it there.
      </p>
      <p :if={@browser[:apart] == "not_browser"} class="text-[11px] text-amber-300">
        A program named aqua-browser-apart is not Aqua's second browser; rename or remove it on the Programs page.
      </p>
    </div>
    """
  end

  attr :option, :map, required: true
  attr :value, :any, default: nil

  # One option's input, by the kind the brain declares: a choice for an
  # enum or a boolean, a field for a string or an integer. Empty is the
  # brain's own default.
  defp option_input(%{option: %{"kind" => kind}} = assigns) when kind in ["enum", "boolean"] do
    assigns =
      assign(
        assigns,
        :choices,
        if(kind == "enum", do: assigns.option["values"], else: ["true", "false"])
      )

    ~H"""
    <select
      name="value"
      aria-label={@option["name"]}
      class="flex-1 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
    >
      <option value="" selected={is_nil(@value)}>default{default_label(@option)}</option>
      <option :for={choice <- @choices} value={choice} selected={to_string(@value) == choice}>
        {choice}
      </option>
    </select>
    """
  end

  defp option_input(assigns) do
    ~H"""
    <input
      type={if @option["kind"] == "integer", do: "number", else: "text"}
      name="value"
      value={@value}
      phx-debounce="blur"
      aria-label={@option["name"]}
      placeholder={"default" <> default_label(@option)}
      class="flex-1 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
    />
    """
  end

  defp default_label(%{"default" => default}), do: " (#{default})"
  defp default_label(_option), do: ""

  defp modes, do: @modes
end
