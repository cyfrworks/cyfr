# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.AgentsComponent do
  @moduledoc """
  The soul and its crew. The soul has a prompt and the tools every crew
  member is offered too, and runs on the crew member its card names,
  whose brain, model and options it takes; while that member does
  not stand, the card says why in the sentence Aqua's turn is refused
  with. Every member runs under the crew's one grant, Aqua's
  (`Compendium.AgentSource`): choosing Aqua's member, making a member or
  picking its brain or model asks nothing, and a member is ready once its
  brain is connected. A crew member has a brain, what it is good at and
  what to avoid, and no prompt: CYFR briefs it and the job says what to
  do. A crew member whose file still holds a prompt is
  refused, and the sentence that says what to change stands in place of
  its card.
  An editor is what a press opens: New crew member, or Edit on a card for
  what the member runs on, its model, effort and access. A closed card
  shows the stored values, a model and an access by the name last known
  and by its id while none is known, so reading the page asks nothing.
  A crew member is made in the one form (`member_form/1`), shown in the
  setup's step for the crew and above the cards alike: the name the
  person gives it, the program or key it runs on (`brains/4`), a model
  that one lists, each option it declares for that model, a program's
  access, and what it is good at and should avoid. CYFR names no member.
  A card's editor offers the same. Another program or key chosen there is
  asked for its list and writes nothing until a model of it is picked,
  which moves the member in one write that takes off each option that
  model does not list.
  Each key's models come from the model catalogue and its options from
  the brain's own `describe` (`Aqua.brain_options/2`), read for an open
  editor and for the model picked in the form; a program's editor offers
  what its program lists when asked (`Aqua.program_listing/2`): its
  models, the efforts of the one chosen, and its access choices in the
  driver's words, closed while the driver offers one.

  A write is decided on the member as it is stored then, read at the
  write, and on a list asked in this opening of its editor. The model and
  the options that list allows are checked together and written
  together. An earlier opening's list names what is shown and authorizes
  nothing, and neither does an ask pending or failed: the edit is refused
  with Try again, and what is stored stands.

  A card is greyed, with Sign in and Change, only while its program is
  known signed out (`Aqua.known_program/2`), and offers to install the
  program while the athanor has no row of that name, prefilled from the
  program brain's definition (`Opus.Programs.Definition.brains/0`). A
  Sign in's terminal stands in the card it was pressed on, and below the
  crew once that card is gone. Every write goes
  through the `aqua` tool, the gate every writer of an agent file goes
  through; a write that changes a file's provenance asks the page to
  re-read it (`{:refresh, :agents}`), since the chips and the removal
  verbs come off that read.

  The soul's card holds what Aqua and every crew member may use, one
  block in groups (`PrismWeb.AquaLive.Catalog.groups/4`): each of CYFR's
  tool families, Search, Scrolls (`ScrollsComponent`, rendered inside its
  group) and each MCP server of the athanor. An entry's switch adds or
  takes off its one key, and a group's adds or takes off its keys in one
  `update`, each decided on the list as it is at the write. The page
  renders the block from what CYFR holds and asks nobody for it: the
  servers' names come from their rows (`mcp_servers.list`), and what each
  offers comes after the render (`Aqua.offerings/3`), asked again after
  every write of the list and on Ask again, so a reason a turn would give
  follows the list as it stands. Aqua's grant, which any switch moves, is
  said once at the block's top. The Browser group's switch is the
  person's browser setting, read and written through the `browser` tool
  as the person: the browser's own actions follow it, so the group leaves
  them out. While either of Aqua's browsers, the person's or the second
  for work kept apart, is not added, the group offers to add it on the
  Programs page, where its definition is confirmed as any program's is.
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

  @not_connected "That program or key is not connected here."
  @not_offered "That program or key does not offer what was chosen — choose again."
  @unlisted "Its list of choices did not come, so nothing was changed. Try again."

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded, false)
     |> assign(:agents, [])
     |> assign(:soul, nil)
     |> assign(:agents_unread, nil)
     |> assign(:crew, [])
     |> assign(:refused, [])
     |> assign(:tool_actions, nil)
     |> assign(:servers, [])
     |> assign(:offerings, nil)
     |> assign(:browser, nil)
     |> assign(:model_status, %{})
     |> assign(:brain_options, %{})
     # What the form that makes a crew member holds, as its last change
     # sent it, once a press opened it: the options of a model picked on a
     # key are read with the open editors'.
     |> assign(:making, false)
     |> assign(:draft, %{})
     # The editors a press opened, by member: each with the program or key
     # chosen in it to move the member to (`to`, or nil) and the programs
     # this opening asked, whose lists alone authorize its writes.
     |> assign(:editing, %{})
     |> assign(:standing, [])
     |> assign(:terminal, nil)
     |> assign(:program_listings, %{})
     |> assign(:installing, nil)
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

  # New crew member: the form is open, and a program it already names is
  # asked for its list.
  def handle_event("new_member", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ask_chosen(socket.assigns.draft["brain"])
      {:noreply, socket |> assign(:making, true) |> drafted()}
    end)
  end

  # Edit, and Change on a card greyed for a sign-out.
  def handle_event("open_editor", %{"name" => name}, socket) when is_binary(name) do
    CyfrWeb.ContextGuard.guard(socket, &{:noreply, open_editor(&1, name)})
  end

  def handle_event("close_editor", %{"name" => name}, socket),
    do: {:noreply, update(socket, :editing, &Map.delete(&1, name))}

  # Try again, the opening's own ask in the editor it was pressed in.
  def handle_event("list_again", %{"program" => program} = params, socket)
      when is_binary(program) and program != "" do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      send(self(), {:ask_programs, [program]})
      name = params["member"]

      socket =
        case socket.assigns.editing[name] do
          %{asked: asked} = editor ->
            update(socket, :editing, &Map.put(&1, name, %{editor | asked: [program | asked]}))

          nil ->
            socket
        end

      {:noreply, socket}
    end)
  end

  # The form that makes a crew member changed: what it holds is kept, so a
  # render shows it again. Another program or key lists other models and
  # options, so the model and the options chosen are dropped with the one
  # they were chosen on, and a program chosen is asked for its list; a
  # program's other model drops an option it does not list; a model picked
  # on a key has its options read from the key's own `describe`.
  def handle_event("draft_member", params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      was = socket.assigns.draft
      draft = Map.take(params, ~w(name brain model options description avoid))

      draft =
        cond do
          draft["brain"] != was["brain"] ->
            ask_chosen(draft["brain"])
            Map.merge(draft, %{"model" => "", "options" => %{}})

          draft["model"] != was["model"] ->
            kept_options(draft, socket.assigns.program_listings)

          true ->
            draft
        end

      socket = assign(socket, :draft, draft)

      if picked(draft) == picked(was),
        do: {:noreply, drafted(socket)},
        else:
          {:noreply,
           socket
           |> drafted()
           |> load_brain_options(socket.assigns.agents, socket.assigns.model_status)}
    end)
  end

  # Make: the member written once, under the name the person gave it (a
  # name a member holds already is refused as a member that exists), on
  # the program or key chosen, with a model that one lists and each option
  # picked from that one's own listing and what the person wrote it is
  # good at and should avoid. A member holds no grant of its own, so
  # making one asks nothing. Each option must be one the brain declares
  # for that model, cast to its kind and checked as a turn checks the
  # options a member sets (`Prima.Model.check_chat_request/2`): an effort
  # another model offered, an access its program does not list, or one
  # asked before the brain's own choices answered, writes nothing, and the
  # form then shows the brain's own choices.
  def handle_event("make_member", params, socket) do
    name = String.trim(params["name"] || "")
    brain = params["brain"] || ""
    model = params["model"] || ""

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Give the crew member a name first.")}

      brain == "" ->
        {:noreply, put_flash(socket, :error, "Choose a program or key first.")}

      model == "" ->
        {:noreply, put_flash(socket, :error, "Choose a model first.")}

      true ->
        CyfrWeb.ContextGuard.guard(socket, &make(&1, name, brain, model, params))
    end
  end

  # Another program or key chosen in an editor: a program is asked for its
  # list, and nothing is written until a model of it is picked. One that
  # is not connected here is not chosen.
  def handle_event("editor_set_harness", %{"name" => name, "harness" => harness}, socket)
      when is_binary(harness) and harness != "" do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      stored? = harness == harness_of(member(socket, name))

      # Back to what the member is on moves nothing, so needs no connection.
      if stored? or match?({:ok, _named}, named(harness, socket)) do
        ask_chosen(harness)
        editor = Map.get(socket.assigns.editing, name, %{to: nil, asked: []})

        asked =
          case harness do
            "program:" <> program -> [program | editor.asked]
            _key -> editor.asked
          end

        editor = %{to: if(stored?, do: nil, else: harness), asked: asked}
        {:noreply, update(socket, :editing, &Map.put(&1, name, editor))}
      else
        send(self(), {:refresh, :setup})
        {:noreply, put_flash(socket, :error, @not_connected)}
      end
    end)
  end

  def handle_event("editor_set_harness", _params, socket), do: {:noreply, socket}

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

  # A group's switch: every key it switches on the list, or off when the
  # list holds them all, in one `update`, decided on the list as it is
  # now, never the copy this page loaded.
  def handle_event("group_toggle", %{"group" => id}, socket) when is_binary(id) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context

      result =
        with %{keys: [_ | _] = keys} <- shown_group(socket, id),
             {:ok, agent} <- call_aqua(ctx, %{"action" => "get", "name" => "aqua"}) do
          tools = agent.tools || []

          edit =
            if Catalog.switch(keys, tools) == :on,
              do: %{"tools_remove" => keys},
              else: %{"tools_add" => keys -- tools}

          call_aqua(ctx, Map.merge(%{"action" => "update", "name" => "aqua"}, edit))
        else
          _no_such_group -> {:ok, :nothing}
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

  # Read the servers' rows again and ask every MCP server that is on what
  # it offers.
  def handle_event("offerings_again", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      {:noreply,
       socket |> assign(:servers, mcp_servers(socket.assigns.context)) |> ask_offerings()}
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

  # The editor opens on the soul's prompt as it is now, with the digest
  # `get` names for it, so a save over a prompt changed elsewhere since is
  # refused as a conflict. Only the soul has a prompt.
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

  # The crew member Aqua runs on, or none: the crew's grant does not follow
  # it, so choosing asks nothing.
  def handle_event("editor_set_member", %{"member" => value}, socket) when is_binary(value) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      member = if value == "", do: nil, else: value

      result =
        call_aqua(socket.assigns.context, %{
          "action" => "update",
          "name" => Prima.AgentRef.soul_name(),
          "member" => member
        })

      send(self(), {:refresh, :agents})

      case result do
        {:ok, _} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  # A model picked is one the program or key lists. A program's pick
  # names its whole brain, the program its form showed (the form's own
  # field, not the page's copy of the member, which may have moved since),
  # beside the model, so the member is left on the brain and model the
  # person saw and chose, and an option that model does not list is taken
  # off in the same write (`moved/4`).
  def handle_event(
        "editor_set_model",
        %{"name" => name, "brain" => "program", "program" => program, "value" => value},
        socket
      )
      when is_binary(program) and program != "" and value != "-" do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      model = if value == "", do: nil, else: value
      {:noreply, set_model(socket, name, "program:" <> program, model)}
    end)
  end

  # A program's pick that names no program, or no model yet, is no pick:
  # it never reaches the picker below, where its value would read as
  # another brain's.
  def handle_event("editor_set_model", %{"brain" => "program"}, socket), do: {:noreply, socket}

  # A key's model chosen in a member's editor.
  def handle_event("editor_set_model", %{"name" => name, "value" => value}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case Catalog.decode_model_choice(value) do
        {:model, provider, model} ->
          {:noreply, set_model(socket, name, "catalyst:" <> provider, model)}

        :noop ->
          {:noreply, socket}
      end
    end)
  end

  # One brain option set, or taken off (an empty value: the brain's own
  # default). The member is read as it is stored, the value checked
  # against what the opening's list, or the brain's `describe`, declares
  # for that model and cast to its kind, never the wire's word, and the
  # two written together: the brain and model read with a one-option patch
  # the `aqua` door applies under its lock, so an edit of another option
  # made elsewhere at the same moment is kept.
  def handle_event(
        "editor_set_option",
        %{"name" => name, "option" => option, "value" => value},
        socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      ctx = socket.assigns.context

      result =
        with {:ok, stored} <- stored_member(ctx, name),
             {:ok, cast} <- cast_option(declared_option(socket, name, stored, option), value) do
          call_aqua(ctx, %{
            "action" => "update",
            "name" => name,
            "program" => stored["program"],
            "catalyst_ref" => stored["catalyst_ref"],
            "model" => stored["model"],
            "options_patch" => %{option => cast}
          })
        end

      send(self(), {:refresh, :agents})

      case result do
        {:ok, _written} ->
          {:noreply, socket}

        {:refused, sentence} ->
          {:noreply, put_flash(socket, :error, sentence)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
      end
    end)
  end

  # Sign in opens the member's editor and asks nothing: the page opens the
  # program's terminal where it was pressed, and asks when that ends. That
  # ask is this opening's.
  def handle_event("sign_in", %{"program" => program} = params, socket)
      when is_binary(program) and program != "" do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      send(self(), {:sign_in, program, params["panel"]})

      case params["member"] do
        member when is_binary(member) ->
          editor = %{to: nil, asked: [program]}
          {:noreply, update(socket, :editing, &Map.put(&1, member, editor))}

        _setup ->
          {:noreply, socket}
      end
    end)
  end

  @impl true
  def handle_async(:brain_options, {:ok, {tag, options}}, socket),
    do:
      CyfrWeb.ContextGuard.deliver(
        socket,
        tag,
        &{:noreply, &1 |> assign(:brain_options, options) |> drafted()}
      )

  def handle_async(:brain_options, {:exit, _reason}, socket), do: {:noreply, socket}

  # What the servers offer, as the latest ask read it, in the focus it
  # was asked in. An ask that crashed leaves what was shown until the next
  # write of the list asks again.
  def handle_async(:offerings, {:ok, {tag, offerings}}, socket),
    do:
      CyfrWeb.ContextGuard.deliver(
        socket,
        tag,
        &{:noreply, assign(&1, :offerings, offerings)}
      )

  def handle_async(:offerings, {:exit, _reason}, socket), do: {:noreply, socket}

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
    # instead of a fault's words; so does each crew member's the list
    # refused for holding a prompt, in place of its card.
    {listed, refused, unread} =
      case call_aqua(ctx, %{"action" => "list", "detail" => true, "include_disabled" => true}) do
        {:ok, %{guides: guides, refused: refused}} when is_list(guides) ->
          {Enum.filter(guides, &(&1.type in types)), refused, nil}

        {:error, {:conflict, sentence}} when is_binary(sentence) ->
          {[], [], sentence}

        _unread ->
          {[], [], "Aqua and its crew members cannot be read right now — try again."}
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
          "options" => g[:options] || %{},
          "tools" => g[:tools] || [],
          "disabled" => g.disabled == true,
          "member" => g[:member],
          "member_refusal" => g[:member_refusal],
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

    # Options read of a brain or model a member is no longer on are none
    # of the one it is on now.
    stood = Map.new(socket.assigns.agents, &{&1["name"], brain_of(&1)})
    moved = for a <- agents, stood[a["name"]] != brain_of(a), do: a["name"]

    socket
    |> update(:brain_options, &Map.drop(&1, moved))
    |> assign(:agents, agents)
    |> assign(:agents_unread, unread)
    |> assign(:soul, soul)
    |> assign(:crew, crew)
    |> assign(:refused, refused)
    |> assign(:model_status, status)
    |> load_brain_options(agents, status)
    |> ensure_tool_actions_loaded()
    |> assign(:browser, browser_status(ctx))
    |> assign(:servers, mcp_servers(ctx))
    |> ask_offerings()
  end

  # The athanor's MCP servers as their rows stand, asking none of them: a
  # program a person or a brain drives offers no tools. nil when the rows
  # cannot be read, which is not an athanor with none.
  defp mcp_servers(ctx) do
    case PrismWeb.Ops.call_tool(ctx, "mcp_servers/list", %{}) do
      {:ok, %{servers: servers}} ->
        for %{name: name, mark: mark} = server <- servers,
            mark != "driven",
            do: %{name: name, enabled: server.enabled == true}

      {:error, _unread} ->
        nil
    end
  end

  # What each MCP server that is on offers, asked after the render and
  # again after every write of the list; a later ask's answer replaces an
  # earlier one's, whichever ends first.
  defp ask_offerings(%{assigns: %{soul: %{"tools" => tools}}} = socket) do
    %{context: ctx, servers: servers} = socket.assigns
    asked = for %{name: name, enabled: true} <- servers || [], do: name
    tag = CyfrWeb.ContextGuard.capture(socket)
    start_async(socket, :offerings, fn -> {tag, Aqua.offerings(ctx, tools, asked)} end)
  end

  defp ask_offerings(socket), do: socket

  # The groups the block shows now: CYFR's own, then the servers'.
  defp shown_groups(assigns) do
    tools = (assigns.soul && assigns.soul["tools"]) || []

    Catalog.groups(assigns.tool_actions || [], assigns.servers, assigns.offerings, tools)
  end

  defp shown_group(socket, id) do
    {own, servers} = shown_groups(socket.assigns)
    Enum.find(own ++ servers, &(&1.id == id))
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
      soul_state: soul && state_of(status[soul["name"]]),
      soul_program: soul && program_of(soul),
      member: soul && soul["member"],
      members:
        for(
          m <- crew,
          not m["disabled"],
          do: %{
            name: m["name"],
            title: m["title"],
            agent: m,
            ready: ready?.(m["name"])
          }
        ),
      unconnected: for(m <- crew, not m["disabled"], not ready?.(m["name"]), do: m["name"]),
      listable:
        for(
          m <- crew,
          program = program_of(m),
          ready?.(m["name"]),
          uniq: true,
          do: program
        )
    }
  end

  defp brain_of(agent), do: Map.take(agent, ~w(program catalyst_ref model))

  defp state_of({state, _brain}), do: state
  defp state_of(nil), do: nil

  # Each ready catalyst brain's options whose editor is open, from its own
  # `describe` — a catalyst run each, so read off the page's process and
  # delivered for the focus they were read under — and, under `{:picked,
  # provider, model}`, those of the model picked on a key in the form that
  # makes a member. A program's are its own listing, which a press asked
  # for (`program_listings`). A brain that is not ready, or whose
  # `describe` or listing does not answer, offers none.
  defp load_brain_options(socket, agents, status) do
    soul_type = Compendium.agent_soul_type()
    refs = socket.assigns[:catalyst_refs] || %{}
    editing = socket.assigns.editing

    ready =
      Enum.filter(
        agents,
        &(&1["type"] != soul_type and is_nil(program_of(&1)) and
            Map.has_key?(editing, &1["name"]) and match?({:ready, _}, status[&1["name"]]))
      )

    picked =
      for {provider, model} <- List.wrap(picked(socket.assigns.draft)),
          ref = refs[provider],
          is_binary(ref),
          do: %{
            "name" => {:picked, provider, model},
            "catalyst_ref" => versionless(ref),
            "model" => model
          }

    case ready ++ picked do
      [] -> assign(socket, :brain_options, %{})
      described -> describe_brains(socket, described)
    end
  end

  # The key and the model picked on it in the form that makes a member,
  # nil while the form names a program, no key or no model.
  defp picked(%{"brain" => "catalyst:" <> provider, "model" => model})
       when is_binary(model) and model != "",
       do: {provider, model}

  defp picked(_draft), do: nil

  # The page's setup shows the same form: it is told what the form holds,
  # with the options and the access choices its harness or key and model
  # declare.
  defp drafted(socket) do
    send(self(), {:member_draft, draft_view(socket.assigns)})
    socket
  end

  @doc """
  What the form that makes a crew member shows before a press opens it:
  closed, no field filled and no option, since none is declared before a
  program or key is chosen.
  """
  @spec empty_draft() :: %{params: map(), options: [map()], open: boolean()}
  def empty_draft, do: %{params: %{}, options: [], open: false}

  # What the form holds, with the options a key declares for the model
  # picked on it (none while unread). A program's are its listing's, which
  # the form reads as it renders (`member_form/1`).
  defp draft_view(assigns) do
    options =
      case picked(assigns.draft) do
        {provider, model} -> assigns.brain_options[{:picked, provider, model}] || []
        nil -> []
      end

    %{params: assigns.draft, options: options, open: assigns.making}
  end

  defp describe_brains(socket, ready) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(socket)

    start_async(socket, :brain_options, fn ->
      {tag, Map.new(ready, &{&1["name"], offered_options(described(ctx, &1))})}
    end)
  end

  defp described(ctx, agent) do
    case Aqua.brain_options(ctx, agent) do
      {:ok, options} -> options
      {:error, _unread} -> :unlisted
    end
  end

  # A program's Effort is the chosen model's own, shown closed for a model
  # that takes none.
  defp effort_option(listing, model) do
    efforts =
      Enum.find_value(listing.models, [], fn listed ->
        if listed.id == model, do: listed.efforts
      end)

    [%{"name" => "effort", "kind" => "enum", "values" => efforts}]
  end

  defp program_options(listing, model),
    do: effort_option(listing, model) ++ access_option(listing.access)

  defp offered_options(:unlisted), do: []
  defp offered_options(options), do: options

  # A program's access as the option its member's file sets, its values
  # the ids of the choices its driver listed.
  defp access_option([]), do: []

  defp access_option(access),
    do: [%{"name" => "access", "kind" => "enum", "values" => Enum.map(access, & &1.id)}]

  # The program install a card offers, from the row of its name as its
  # status reads it: none of that name is offered to install, through the
  # Programs page's form for a program brain of that name
  # (`Opus.Programs.Definition.brains/0`). A row of that name that stands,
  # disabled, unfit or unread, is never offered an install: its status
  # says why.
  defp offers({:program_missing, _name}, %{"program" => program}) when is_binary(program) do
    query = %{"add" => program, "from" => "aqua"}
    [%{program: program, query: URI.encode_query(query)}]
  end

  defp offers(_status, _agent), do: []

  @doc """
  What is known now of each program in `programs`, the ones whose row
  stands (`Aqua.known_program/2`). Read as the page and the roster render,
  and kept by neither, so it outlives nothing.
  """
  @spec known(term(), [String.t()]) :: map()
  def known(ctx, programs),
    do: Map.new(programs, &{&1, Aqua.known_program(ctx, %{"program" => &1})})

  @doc """
  The programs of `programs` a member can be put on: each but those known
  signed out.
  """
  @spec runnable([String.t()], map()) :: [String.t()]
  def runnable(programs, known), do: Enum.reject(programs, &signed_out?(known, &1))

  @doc """
  Whether the program named `program` is known signed out
  (`Aqua.known_program/2`), the one thing that greys: never one nothing
  is known of, and never an error's reading.
  """
  @spec signed_out?(map(), String.t() | nil) :: boolean()
  def signed_out?(_known, nil), do: false
  def signed_out?(known, program), do: get_in(known, [program, :account]) == :signed_out

  # How a brain stands on its card: a program known signed out, whatever
  # else it waits on (Aqua's grant, say), since what is known is a
  # standing row's alone; a ready key or a program signed in, connected;
  # and a ready program nothing is known of, installed.
  defp standing(status, agent, known) do
    program = program_of(agent)
    ready? = match?({:ready, _name}, status)

    cond do
      signed_out?(known, program) -> :signed_out
      not ready? -> nil
      is_nil(program) -> :connected
      get_in(known, [program, :account]) == :signed_in -> :connected
      true -> :installed
    end
  end

  # The list a program gave when a press asked it, or nil.
  defp listed(listings, program) do
    case listings[program] do
      {:ok, listing} -> listing
      _unlisted -> nil
    end
  end

  # A closed card's values, each as the file holds it, a model and an
  # access by the name last known for it.
  defp stored(agent, known) do
    {harness, title} = harness(agent)
    listing = get_in(known, [program_of(agent), :listing]) || %{models: [], access: []}

    model =
      cond do
        agent["model"] -> named_choice(listing.models, agent["model"])
        program_of(agent) -> "The program's default"
        true -> "none chosen yet"
      end

    options =
      for {option, value} <- Enum.sort(agent["options"] || %{}) do
        {option, if(option == "access", do: named_choice(listing.access, value), else: value)}
      end

    runs_on = [{"Program or key", title || "none chosen yet"}]
    if harness, do: runs_on ++ [{"Model", model} | options], else: runs_on
  end

  defp named_choice(choices, id),
    do: Enum.find_value(choices, id, fn choice -> if choice.id == id, do: choice.name end)

  # Whether the card says its program's state in the sentence a turn on it
  # is refused with: a row that stands but cannot run, on every card, and
  # a program not installed on Aqua's alone, the member's own card offering
  # its install instead.
  defp program_said?({state, _}, _soul?) when state in [:program_disabled, :program_unfit],
    do: true

  defp program_said?({:program_missing, _}, soul?), do: soul?
  defp program_said?(_status, _soul?), do: false

  # Whose brain a card's states are: Aqua's are the member's it runs on.
  defp brain_title(%{"member" => member}, crew, true) when is_binary(member),
    do: Enum.find_value(crew, member, &(&1["name"] == member && &1["title"]))

  defp brain_title(agent, _crew, _soul?), do: agent["title"] || agent["name"]

  # A brain that is a program runs on that program's own sign-in, bound to
  # the one row named as its program, so its card offers no key to change
  # to.
  defp signs_in?(%{"program" => program}) when is_binary(program), do: true
  defp signs_in?(_agent), do: false

  # An editor's opening asks for its program's list, while the row
  # stands, and reads a key's options afresh: what an earlier opening read
  # authorizes nothing in this one.
  defp open_editor(socket, name) do
    %{agents: agents, model_status: status} = socket.assigns
    program = program_of(member(socket, name))
    asked = if program && match?({:ready, _}, status[name]), do: [program], else: []

    socket =
      socket
      |> update(:editing, &Map.put(&1, name, %{to: nil, asked: asked}))
      |> update(:brain_options, &Map.delete(&1, name))

    if asked != [], do: send(self(), {:ask_programs, asked})
    if program, do: socket, else: load_brain_options(socket, agents, status)
  end

  # A program chosen in an editor is asked for its list.
  defp ask_chosen("program:" <> program), do: send(self(), {:ask_programs, [program]})
  defp ask_chosen(_key_or_none), do: :ok

  # A program's draft keeps the options its newly chosen model lists.
  defp kept_options(%{"brain" => "program:" <> program} = draft, listings) do
    case listed(listings, program) do
      nil ->
        draft

      listing ->
        declared = program_options(listing, draft["model"])
        options = Map.reject(draft["options"] || %{}, &match?({_option, ""}, &1))
        gone = Map.keys(dropped_options(options, declared))
        Map.put(draft, "options", Map.drop(options, gone))
    end
  end

  defp kept_options(draft, _listings), do: draft

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

  # The option as it is declared for `stored`, the member as the write
  # found it: a program's by the list this opening asked for that program,
  # for the stored model, its access among them; a key's by the `describe`
  # read for the brain and model the member still holds. `:unlisted` while
  # neither stands.
  defp declared_option(socket, name, stored, option) do
    declared =
      case program_of(stored) do
        nil ->
          if brain_of(stored) == brain_of(member(socket, name)),
            do: Map.get(socket.assigns.brain_options, name, []),
            else: :unlisted

        program ->
          case opening_list(
                 socket.assigns.editing[name],
                 socket.assigns.program_listings,
                 program
               ) do
            nil -> :unlisted
            listing -> program_options(listing, stored["model"])
          end
      end

    if declared == :unlisted, do: :unlisted, else: Enum.find(declared, &(&1["name"] == option))
  end

  # The list this opening of an editor asked for and got: never an earlier
  # opening's, a pending ask's or a failed one's.
  defp opening_list(%{asked: asked}, listings, program) do
    if program in asked, do: listed(listings, program)
  end

  defp opening_list(_closed, _listings, _program), do: nil

  # An empty value takes the option off; any other is cast to its kind.
  defp cast_option(:unlisted, _value), do: {:refused, @unlisted}
  defp cast_option(nil, _value), do: {:refused, "That model does not take that option"}
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
    if value in values, do: {:ok, value}, else: {:refused, "Pick one of the values listed"}
  end

  defp cast_option(%{"kind" => "string"}, value), do: {:ok, value}
  defp cast_option(_declared, _value), do: {:refused, "That value does not fit the option"}

  # Whether `options` are ones `declared` offers, checked as a turn checks
  # the options a member sets.
  defp offered(options, declared) do
    case Prima.Model.check_chat_request(%{"options" => options}, declared) do
      :ok -> :ok
      {:error, {:invalid, _member}} -> :not_offered
    end
  end

  # Of `options`, those a brain and model the member moves to do not
  # list, each held to what they declare as Make holds a new member's (an
  # effort another model offered, an access its old program listed), as a
  # patch that takes each off and leaves every other option as it is.
  defp dropped_options(options, declared) do
    for {option, value} <- options,
        offered(%{option => value}, declared) != :ok,
        into: %{},
        do: {option, nil}
  end

  # A pick's one write, decided on the member as it is stored when the
  # pick lands (`stored_member/2`): its new brain and model beside each
  # option that model declares, at the value held or none, and every other
  # option it does not declare taken off, so what was checked together is
  # written together. A read that fails writes nothing, and so does a
  # declaration that did not come while the member holds an option it
  # would decide.
  defp patched(options, :unlisted) when map_size(options) > 0, do: :unlisted
  defp patched(_none, :unlisted), do: {:ok, %{}}

  defp patched(options, declared) do
    held = Map.new(declared, fn %{"name" => option} -> {option, options[option]} end)
    {:ok, Map.merge(held, dropped_options(options, declared))}
  end

  defp member(socket, name),
    do: Enum.find(socket.assigns.agents, %{"name" => name}, &(&1["name"] == name))

  # The member as it is stored now, in the roster's projection.
  defp stored_member(ctx, name) do
    with {:ok, %{} = file} <- call_aqua(ctx, %{"action" => "get", "name" => name}) do
      {:ok,
       %{
         "program" => file[:program],
         "catalyst_ref" => file[:catalyst_ref],
         "model" => file[:model],
         "options" => file[:options] || %{}
       }}
    end
  end

  defp set_model(socket, name, harness, model) do
    ctx = socket.assigns.context

    result =
      with {:ok, stored} <- stored_member(ctx, name),
           {:ok, named} <- target(socket, stored, harness),
           {:ok, declared} <- editable(socket, name, harness, named, model),
           {:ok, patch} <- patched(stored["options"], declared) do
        call_aqua(
          ctx,
          Map.merge(named, %{
            "action" => "update",
            "name" => name,
            "model" => model,
            "options_patch" => patch
          })
        )
      end

    send(self(), {:refresh, :agents})

    case result do
      {:ok, _written} ->
        update(socket, :editing, fn editing ->
          case editing[name] do
            nil -> editing
            editor -> Map.put(editing, name, %{editor | to: nil})
          end
        end)

      :error ->
        send(self(), {:refresh, :setup})
        put_flash(socket, :error, @not_connected)

      :unlisted ->
        put_flash(socket, :error, @unlisted)

      :not_offered ->
        put_flash(socket, :error, @not_offered)

      # A discarded refusal made the select box appear to work — the
      # refresh then quietly snapped it back.
      {:error, reason} ->
        put_flash(socket, :error, "Model update failed: #{error_message(reason)}")
    end
  end

  # The brain an edit leaves the member on: the one it is stored on as it
  # is, any other only while that one is connected here (`named/2`).
  defp target(socket, stored, harness) do
    if harness == harness_of(stored),
      do: as_named(harness, socket.assigns[:catalyst_refs] || %{}),
      else: named(harness, socket)
  end

  # What an edit may write for `model` on that brain: a program's, by the
  # list this opening asked for, its own default taking no effort; a
  # key's, by a model its provider listed and that model's `describe`.
  defp editable(socket, name, "program:" <> program, _named, model) do
    opening_list(socket.assigns.editing[name], socket.assigns.program_listings, program)
    |> listed_options(model)
  end

  defp editable(socket, _name, "catalyst:" <> provider, named, model) do
    if model in List.wrap(socket.assigns.models_by_provider[provider]),
      do: {:ok, described(socket.assigns.context, Map.put(named, "model", model))},
      else: :not_offered
  end

  defp listed_options(nil, _model), do: :unlisted

  defp listed_options(listing, model) do
    if is_nil(model) or Enum.any?(listing.models, &(&1.id == model)),
      do: {:ok, program_options(listing, model)},
      else: :not_offered
  end

  # What Make may write: a listed model, and the options the form showed
  # for it.
  defp makeable(socket, "program:" <> program = brain, _named, model) do
    # The form's own ask, made as that program was chosen in it.
    listing =
      if socket.assigns.draft["brain"] == brain,
        do: listed(socket.assigns.program_listings, program)

    listed_options(listing, model)
  end

  defp makeable(socket, "catalyst:" <> provider, _named, model) do
    if model in List.wrap(socket.assigns.models_by_provider[provider]),
      do: {:ok, Map.get(socket.assigns.brain_options, {:picked, provider, model}, [])},
      else: :not_offered
  end

  # Make's one write, and what the form holds after it: nothing once the
  # member is made, and what was sent, less its options, when one of them
  # is not the brain's to offer, so the form shows the brain's own choices.
  defp make(socket, name, brain, model, params) do
    with {:ok, named} <- named(brain, socket),
         {:ok, declared} <- makeable(socket, brain, named, model),
         {:ok, options} <- chosen(params["options"], declared),
         :ok <- offered(options, declared),
         {:ok, _created} <-
           call_aqua(
             socket.assigns.context,
             # A create names the one brain it is made on; an update
             # clears the other.
             Map.merge(Map.reject(named, fn {_brain, value} -> is_nil(value) end), %{
               "action" => "create",
               "name" => name,
               "title" => name,
               "description" => String.trim(params["description"] || ""),
               "avoid" => String.trim(params["avoid"] || ""),
               "model" => model,
               "options" => options
             })
           ) do
      send(self(), {:refresh, :agents})
      send(self(), {:refresh, :setup})

      {:noreply, socket |> assign(:draft, %{}) |> drafted() |> put_flash(:info, "Made #{name}.")}
    else
      :error ->
        send(self(), {:refresh, :setup})
        {:noreply, put_flash(socket, :error, @not_connected)}

      :unlisted ->
        {:noreply, put_flash(socket, :error, @unlisted)}

      :not_offered ->
        draft =
          params
          |> Map.take(~w(name brain model description avoid))
          |> Map.put("options", %{})

        socket = assign(socket, :draft, draft)

        {:noreply,
         socket
         |> drafted()
         |> load_brain_options(socket.assigns.agents, socket.assigns.model_status)
         |> put_flash(:error, @not_offered)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Make failed: #{error_message(reason)}")}
    end
  end

  # The options a Make sent, each cast to the kind the brain declares for
  # it; one left empty is the brain's own default and is not written, and
  # one the brain does not declare, or whose value does not fit, is not
  # the brain's to offer.
  defp chosen(%{} = options, declared) do
    Enum.reduce_while(options, {:ok, %{}}, fn
      {_option, ""}, kept ->
        {:cont, kept}

      {option, value}, {:ok, kept} when is_binary(value) ->
        case cast_option(Enum.find(declared, &(&1["name"] == option)), value) do
          {:ok, cast} -> {:cont, {:ok, Map.put(kept, option, cast)}}
          {:refused, _sentence} -> {:halt, :not_offered}
        end

      _other, _kept ->
        {:halt, :not_offered}
    end)
  end

  defp chosen(_none, _declared), do: {:ok, %{}}

  # A connected program or key as a crew file names it, by the value the
  # forms name it with (`brains/4`). One not connected here is `:error`:
  # one the forms do not offer, or one that no longer reads ready where a
  # member on it would (`Aqua.model_status/2`), read now and not from what
  # the page holds.
  defp named(value, socket) do
    assigns = socket.assigns
    refs = assigns[:catalyst_refs] || %{}

    offered? =
      (assigns[:models_by_provider] || %{})
      |> brains(
        refs,
        runnable(assigns.standing, known(assigns.context, assigns.standing)),
        assigns[:providers]
      )
      |> Enum.any?(&(&1.value == value))

    with true <- offered?,
         {:ok, named} <- as_named(value, refs),
         %{^value => {:ready, _brain}} <-
           Aqua.model_status(assigns.context, [Map.put(named, "name", value)]) do
      {:ok, named}
    else
      _not_connected -> :error
    end
  end

  # A forms' value as a crew file names that brain, the other one cleared:
  # a program by its row's name, a key by its catalyst's reference
  # without a version.
  defp as_named("program:" <> name, _refs), do: {:ok, %{"program" => name, "catalyst_ref" => nil}}

  defp as_named("catalyst:" <> provider, refs) do
    case refs[provider] do
      ref when is_binary(ref) -> {:ok, %{"program" => nil, "catalyst_ref" => versionless(ref)}}
      _unread -> :error
    end
  end

  defp as_named(_neither, _refs), do: :error

  @doc """
  The programs and keys a crew member can be put on here: each program in
  `programs` (a row that stands and is not known signed out, whatever an
  ask answered), by its title, then each key the setup's read
  (`Aqua.providers/1`) says is ready and whose provider listed models, by
  its provider. The model catalogue is kept a while, so a key it still
  lists is no proof the key is connected. Each is `%{value, title, kind,
  models}`: the value the forms name it with, `:program` or `:key`, and a
  key's models as `{id, name}`, none for a program, whose list only a
  press asks for.
  """
  @spec brains(map(), map(), [String.t()], term()) :: [map()]
  def brains(models_by_provider, catalyst_refs, programs, providers) do
    ready =
      case providers do
        {:ok, read} -> for %{state: :ready, provider: provider} <- read, do: provider
        _unread -> []
      end

    runs =
      for name <- Enum.sort(programs),
          do: %{value: "program:" <> name, title: program_title(name), kind: :program, models: []}

    keys =
      for {provider, [_ | _] = models} <- Enum.sort(models_by_provider),
          is_binary(catalyst_refs[provider]),
          provider in ready,
          do: %{
            value: "catalyst:" <> provider,
            title: provider,
            kind: :key,
            models: Enum.map(models, &{&1, &1})
          }

    runs ++ keys
  end

  @doc "A program's title as a person reads it: a program brain's CYFR ships, else its row's name."
  @spec program_title(String.t()) :: String.t()
  def program_title(name) do
    case Opus.Programs.Definition.brain(name) do
      %{title: title} -> title
      nil -> name
    end
  end

  # The program or key a member's file names, by the value the forms name
  # it with and the name a person reads; nil for a member with neither.
  defp harness_of(agent), do: elem(harness(agent), 0)

  defp harness(agent) do
    case {program_of(agent), agent_provider_for_select(agent)} do
      {program, _provider} when is_binary(program) ->
        {"program:" <> program, program_title(program)}

      {nil, provider} when is_binary(provider) ->
        {"catalyst:" <> provider, provider}

      {nil, nil} ->
        {nil, nil}
    end
  end

  @doc """
  A crew member as Aqua's "Runs on" names it: its name, then the program
  or key and the model it would run Aqua on, the model by the name last
  known for it and its id while none is, and that it is signed out while
  that is known.
  """
  @spec runs_on_label(map(), map()) :: String.t()
  def runs_on_label(agent, known) do
    title = agent["title"] || agent["name"]

    case harness(agent) do
      {nil, nil} ->
        "#{title} — no program or key yet"

      {"catalyst:" <> _key, on} ->
        "#{title} — #{on}, #{agent["model"] || "no model chosen yet"}"

      {"program:" <> program, on} ->
        listing = get_in(known, [program, :listing]) || %{models: []}

        model =
          if agent["model"],
            do: named_choice(listing.models, agent["model"]),
            else: "its default model"

        out = if signed_out?(known, program), do: " (signed out)", else: ""
        "#{title} — #{on}, #{model}#{out}"
    end
  end

  # A catalyst's reference as a crew file names it: without its version.
  defp versionless(ref), do: Regex.replace(~r/:\d+\.\d+\.\d+$/, ref, "")

  # The program a member's brain is, by its row's name, or nil.
  defp program_of(%{"program" => program}) when is_binary(program) and program != "",
    do: program

  defp program_of(_agent), do: nil

  # The models a key's card offers: the ones its provider listed, and the
  # member's own when that list does not name it, as a program's.
  defp key_choices(listed, model) do
    listed = listed || []
    if is_binary(model) and model not in listed, do: listed ++ [model], else: listed
  end

  # The models a program brain's card offers: the ones its program listed
  # for this opening, and the member's own model when that list does not
  # name it (or has not come), by the name last known, so the choice shows
  # what the file holds.
  defp program_choices(listed, model, known) do
    listed = listed || []
    named = (known && known.listing) || %{models: []}

    if is_binary(model) and not Enum.any?(listed, &(&1.id == model)),
      do: listed ++ [%{id: model, name: named_choice(named.models, model)}],
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

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    # Read here, for a render the roster makes of its own too.
    known = known(assigns.context, assigns.standing)

    assigns =
      assigns
      |> assign(:known, known)
      |> assign(
        :brains,
        brains(
          assigns[:models_by_provider] || %{},
          assigns[:catalyst_refs] || %{},
          runnable(assigns.standing, known),
          assigns[:providers]
        )
      )

    ~H"""
    <div id="aqua-agents" phx-target={@myself} class="space-y-6">
      <.section_flash flash={@flash} target={@myself} />

      <%!-- Offered once the roster is read: the one form that makes a
            crew member, as the setup's step for the crew shows it. --%>
      <div :if={@loaded and is_nil(@agents_unread)} class="text-xs text-gray-300">
        <.member_form
          id="aqua-new-member"
          brains={@brains}
          listings={@program_listings}
          draft={draft_view(assigns)}
        />
        <p :if={@brains == []} data-test="new-member-waits" class="text-gray-400">
          Connect a program or a key in the setup above to make a crew member.
        </p>
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
        Aqua's own file is missing. It ships with the server — restore the shipped files below to bring it back.
      </div>

      <.agent_card
        :if={@soul}
        myself={@myself}
        agent={@soul}
        models_by_provider={@models_by_provider}
        tool_actions={@tool_actions || []}
        is_soul={true}
        model_status={Map.get(@model_status, @soul["name"])}
        installing={@installing}
        setting_up={@setting_up}
        set_up_refused={@set_up_refused}
        athanor={@athanor}
        offers={[]}
        signs_in?={signs_in?(@soul)}
        standing={standing(Map.get(@model_status, @soul["name"]), @soul, @known)}
        terminal={panel_terminal(@terminal, @soul["name"])}
        browser={@browser}
        groups={shown_groups(assigns)}
        servers_read={@servers != nil}
        context={@context}
        provenance={@provenance}
        crew={@crew}
        known={@known}
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
          offers={offers(Map.get(@model_status, member["name"]), member)}
          signs_in?={signs_in?(member)}
          standing={standing(Map.get(@model_status, member["name"]), member, @known)}
          editing={Map.has_key?(@editing, member["name"])}
          editor={@editing[member["name"]]}
          moving_to={get_in(@editing, [member["name"], :to])}
          terminal={panel_terminal(@terminal, member["name"])}
          listings={@program_listings}
          known={@known}
          brains={@brains}
        />
      </div>

      <div :if={@refused != []} class="space-y-3 border-l border-gray-800 pl-4 ml-2">
        <div
          :for={member <- @refused}
          id={"aqua-refused-#{member.name}"}
          data-test="crew-refused"
          class="rounded-lg border border-amber-900/60 bg-gray-900/60 p-4 text-xs text-amber-300"
        >
          {member.reason}
        </div>
      </div>

      <PrismWeb.TerminalComponent.frame
        :if={cardless?(@terminal, @soul, @crew)}
        terminal={@terminal}
      />

      <!-- Prompt editor modal — the soul's prompt -->
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

  @grant_states [:consent_absent, :consent_stale, :consent_damaged, :consent_unavailable]

  @doc """
  The sentence for a state of the crew's grant, Aqua's
  (`Aqua.Models.t:status/0`): never given or revoked, stale, damaged or
  unread; nil for any other state. The one wording of these states, on a
  card, in the setup's step for Aqua and in the daily thread. A damaged
  or unread brain's own grant reads the same, since neither is a key to
  connect.
  """
  @spec grant_sentence(atom()) :: String.t() | nil
  def grant_sentence(:consent_absent),
    do: "You have not granted yet what Aqua and its crew members may use."

  def grant_sentence(:consent_stale),
    do: "What Aqua and its crew members may use changed since you granted it."

  def grant_sentence(:consent_damaged),
    do:
      "A consent this model runs under is damaged and cannot be used — " <>
        "revoke the damaged profile and grant it again."

  def grant_sentence(:consent_unavailable),
    do: "A consent this model runs under cannot be read right now — try again."

  def grant_sentence(_state), do: nil

  @doc """
  The state of the crew's grant (`grant_sentence/1`) with what the page
  can do about it: a grant never given, or one that moved, opens Aqua's
  own confirmation (`open_consent`, handled by the Aqua page); damage or
  an outage offers nothing to press, since connecting cannot repair a
  grant that exists. Nothing for any other state.
  """
  attr :state, :atom, required: true

  def grant_line(%{state: state} = assigns) when state in @grant_states do
    ~H"""
    <span
      data-test="aqua-grant"
      data-state={@state}
      class={if @state == :consent_damaged, do: "text-red-300", else: "text-amber-300"}
    >
      {grant_sentence(@state)}
    </span>
    <button
      :if={@state in [:consent_absent, :consent_stale]}
      type="button"
      phx-click="open_consent"
      phx-value-ref={Prima.AgentRef.soul_ref()}
      class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] font-medium text-white"
    >
      {if @state == :consent_absent, do: "Grant", else: "Grant again"}
    </button>
    """
  end

  def grant_line(assigns), do: ~H""

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
  attr :standing, :atom, default: nil
  attr :editing, :boolean, default: false
  attr :moving_to, :string, default: nil
  attr :editor, :map, default: nil
  attr :terminal, :any, default: nil
  attr :browser, :map, default: nil
  attr :groups, :any, default: {[], []}
  attr :servers_read, :boolean, default: true
  attr :context, :any, default: nil
  attr :provenance, :map, default: %{}
  attr :crew, :list, default: []
  attr :known, :map, default: %{}
  attr :listings, :map, default: %{}
  attr :brains, :list, default: []

  defp agent_card(assigns) do
    {harness, harness_title} = harness(assigns.agent)
    shown = assigns.moving_to || harness

    assigns =
      assigns
      |> assign(:current_provider, agent_provider_for_select(assigns.agent))
      |> assign(:harness, harness)
      |> assign(:harness_title, harness_title)
      |> assign(:shown, shown)
      |> assign(chosen(shown))
      |> assign(:signed_out?, assigns.standing == :signed_out)
      |> assign(:tools, assigns.agent["tools"] || [])
      |> assign(:removal, removal(assigns.agent))
      |> assign(:disabled?, assigns.agent["disabled"] == true)
      |> assign(:program, program_of(assigns.agent))

    assigns = assign(assigns, offered_here(assigns))

    ~H"""
    <div
      id={"aqua-card-#{@agent["name"]}"}
      class={[
        "rounded-lg border border-gray-800 bg-gray-900/60 p-4 space-y-3",
        (@disabled? or @signed_out?) && "opacity-60"
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
              {if @is_soul, do: "Aqua", else: @agent["type"]}
            </span>
            <code class="text-[11px] text-gray-500 font-mono">{@agent["name"]}</code>
            <.provenance_chip state={@agent["provenance"]} />
            <span
              :if={@disabled?}
              class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-gray-800 text-gray-400"
              title="Out of the crew — Aqua does not see this member until it is enabled"
            >
              disabled
            </span>
          </div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            :if={@is_soul}
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
            {"description", "Good at", "What Aqua hands this member…"},
            {"avoid", "Avoid", "What Aqua should never hand it…"}
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

      <div :if={@offers != []} class="flex flex-wrap items-center gap-2 text-[11px]">
        <span class="text-amber-300">It runs on a program you have not installed:</span>
        <.link
          :for={offer <- @offers}
          navigate={PrismWeb.Focus.path(@athanor, "/programs?" <> offer.query)}
          class="text-blue-400 hover:underline"
          data-test="install-program"
        >
          install {offer.program}
        </.link>
      </div>
      <%!-- Greyed is a real sign-out alone, as its driver read it: Sign in
            opens the member's editor and the program's terminal here, and
            Change the editor, or on Aqua's card the choice of member. --%>
      <div :if={@signed_out?} class="flex flex-wrap items-center gap-2 text-[11px]">
        <span class="text-amber-300" data-test="program-signed-out">
          {brain_title(@agent, @crew, @is_soul)}'s program is signed out. Sign it in, or choose another.
        </span>
        <button
          type="button"
          phx-click="sign_in"
          phx-value-program={@program}
          phx-value-member={if @is_soul, do: @agent["member"], else: @agent["name"]}
          phx-value-panel={@agent["name"]}
          phx-target={@myself}
          disabled={@setting_up != nil}
          class="text-blue-400 hover:underline disabled:opacity-50"
          data-test="sign-in"
        >
          {if @setting_up == @program, do: "Opening its terminal…", else: "Sign in"}
        </button>
        <button
          :if={@is_soul}
          type="button"
          phx-click={JS.focus(to: "#aqua-card-#{@agent["name"]}-member select")}
          class="text-blue-400 hover:underline"
          data-test="change"
        >
          Change
        </button>
        <button
          :if={not @is_soul}
          type="button"
          phx-click="open_editor"
          phx-value-name={@agent["name"]}
          phx-target={@myself}
          class="text-blue-400 hover:underline"
          data-test="change"
        >
          Change
        </button>
        <span
          :if={Map.has_key?(@set_up_refused, @program)}
          class="text-red-400"
          data-test="set-up-refused"
        >
          {Map.fetch!(@set_up_refused, @program)}
        </span>
      </div>
      <PrismWeb.TerminalComponent.frame :if={@terminal} terminal={@terminal} />

      <%!-- Aqua runs on a crew member, whose brain, model and options
           it takes: the member's own card sets those. While the member
           does not stand, the sentence Aqua's turn is refused with says
           why. --%>
      <form
        :if={@is_soul}
        id={"aqua-card-#{@agent["name"]}-member"}
        phx-change="editor_set_member"
        phx-auto-recover="ignore"
        phx-target={@myself}
      >
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Runs on</p>
        <select
          name="member"
          aria-label="Runs on"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option value="" selected={is_nil(@agent["member"])}>No crew member</option>
          <option
            :for={member <- @crew}
            :if={not member["disabled"] or member["name"] == @agent["member"]}
            value={member["name"]}
            selected={member["name"] == @agent["member"]}
            disabled={signed_out?(@known, program_of(member))}
            class={signed_out?(@known, program_of(member)) && "text-gray-500"}
          >
            {runs_on_label(member, @known)}
          </option>
        </select>
        <p
          :if={@agent["member_refusal"]}
          data-test="aqua-runs-on-refused"
          class="mt-1 text-[11px] text-amber-300"
        >
          {@agent["member_refusal"]}
        </p>
      </form>

      <div :if={@model_status} class="flex flex-wrap items-center gap-2 text-[11px]">
        <span :if={@standing == :connected} class="text-emerald-400">
          Model connected
        </span>
        <span :if={@standing == :installed} class="text-gray-400">Installed</span>
        <%!-- The crew's grant, which a member holds none of its own of
             and which names no brain, is said on Aqua's card once, at
             the top of what Aqua may use. A member's brain's own grant
             damaged or unread is said here the same way. --%>
        <.grant_line :if={not @is_soul} state={elem(@model_status, 0)} />
        <span :if={match?({:needs_key, _}, @model_status)} class="text-amber-300">
          Not connected — the model has no key yet
        </span>
        <span :if={match?({:needs_grant, _}, @model_status)} class="text-amber-300">
          Not connected — it needs only your grant
        </span>
        <%!-- A key with no model chosen on it runs nothing: said as a job
             handed to the member is refused, on Aqua's card of the member
             it runs on. --%>
        <span
          :if={match?({:needs_model, _}, @model_status)}
          data-test="needs-model"
          class="text-amber-300"
        >
          {Prima.Refusal.message({:crew_unready, brain_title(@agent, @crew, @is_soul), :no_model})}
        </span>
        <span :if={match?({:missing, _}, @model_status)} class="text-amber-300">
          The model's catalyst is not installed here yet
        </span>
        <%!-- A program's state is said as a turn on it is refused
             (`Prima.Refusal`), naming whose brain it is: on Aqua's card the
             member it runs on. A row that stands but is no brain's is never
             one to install: its row opens on the Programs page. A missing
             program is installed from the member's own card, which offers
             it above; Aqua's card says why Aqua cannot run. --%>
        <span
          :if={program_said?(@model_status, @is_soul)}
          data-test="program-refused"
          class="text-amber-300"
        >
          {Prima.Refusal.message(
            {:crew_unready, brain_title(@agent, @crew, @is_soul), elem(@model_status, 0)}
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
              {status, _} when status in [:needs_key, :needs_grant],
              @model_status
            )
          }
          patch={PrismWeb.Focus.path(@athanor, "/aqua?setup=1")}
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

      <%!-- A closed card is what the file holds; Edit opens its editor. --%>
      <div :if={not @is_soul and not @editing} class="flex items-start justify-between gap-3">
        <dl
          id={"aqua-card-#{@agent["name"]}-runs"}
          class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 text-xs"
        >
          <%= for {label, value} <- stored(@agent, @known) do %>
            <dt class="text-[10px] uppercase tracking-wider text-gray-500">{label}</dt>
            <dd class="text-gray-200 break-words">{value}</dd>
          <% end %>
        </dl>
        <button
          id={"aqua-card-#{@agent["name"]}-edit"}
          type="button"
          phx-click="open_editor"
          phx-value-name={@agent["name"]}
          phx-target={@myself}
          class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
        >
          Edit
        </button>
      </div>

      <%!-- The editor. What a crew member runs on, among the programs and
            keys offered and the one its file names: another chosen is
            offered with that one's models, and the member moves once one
            of them is picked. --%>
      <form
        :if={@editing}
        id={"aqua-card-#{@agent["name"]}-harness"}
        phx-change="editor_set_harness"
        phx-auto-recover="ignore"
        phx-target={@myself}
      >
        <input type="hidden" name="name" value={@agent["name"]} />
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Program or key</p>
        <select
          name="harness"
          aria-label="Program or key"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option :if={is_nil(@shown)} value="" selected>Choose a program or key</option>
          <option
            :if={@harness && not Enum.any?(@brains, &(&1.value == @harness))}
            value={@harness}
            selected={@harness == @shown}
          >
            {@harness_title}
          </option>
          <.withdrawn :if={@moving_to && @chosen_program} brains={@brains} value={@moving_to} />
          <.brain_choices brains={@brains} chosen={@shown} />
        </select>
      </form>

      <.listing_line
        :if={@editing && @asked}
        program={@asked}
        listing={@asked_listing}
        member={@agent["name"]}
        myself={@myself}
      />

      <%!-- Each change writes the agent's model, so a reconnect replays no
            change: the choice the page held may be older than the model
            another session wrote meanwhile. --%>
      <%!-- A program brain's models are the ones its program listed when
            asked, and none other. While they did not come, the member's
            model stands alone. --%>
      <form
        :if={@editing && @chosen_program}
        id={"aqua-card-#{@agent["name"]}-model"}
        phx-change="editor_set_model"
        phx-auto-recover="ignore"
        phx-target={@myself}
      >
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="brain" value="program" />
        <input type="hidden" name="program" value={@chosen_program} />
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</p>
        <select
          name="value"
          aria-label="Model"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option :if={@moving_to} value="-" selected>Choose a model</option>
          <option value="" selected={is_nil(@moving_to) and is_nil(@agent["model"])}>
            The program's default
          </option>
          <option
            :for={m <- program_choices(@program_models, @chosen_model, @known[@chosen_program])}
            value={m.id}
            selected={@chosen_model == m.id}
          >
            {m.name}
          </option>
        </select>
      </form>

      <%!-- A key's models are the ones its provider listed, and the
            member's own when that list does not name it. --%>
      <form
        :if={@editing && @chosen_key}
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
          <option :if={is_nil(@chosen_model)} value="-" selected>Choose a model</option>
          <option
            :for={m <- key_choices(@models_by_provider[@chosen_key], @chosen_model)}
            value={Catalog.model_choice(@chosen_key, m)}
            selected={@chosen_model == m}
          >
            {m}
          </option>
        </select>
      </form>

      <div :if={@editing && @options_here != []} id={"aqua-card-#{@agent["name"]}-options"}>
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">
          Options
          <span class="normal-case text-gray-600">
            — what every request may set; empty keeps the default.
          </span>
        </p>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
          <form
            :for={option <- @options_here}
            id={"aqua-card-#{@agent["name"]}-option-#{option["name"]}"}
            phx-change="editor_set_option"
            phx-auto-recover="ignore"
            phx-target={@myself}
            class="flex items-center gap-2"
          >
            <input type="hidden" name="name" value={@agent["name"]} />
            <input type="hidden" name="option" value={option["name"]} />
            <label class="text-[11px] font-mono text-gray-400 w-32 shrink-0">{option["name"]}</label>
            <.option_input
              option={option}
              name="value"
              value={Map.get(@agent["options"] || %{}, option["name"])}
            />
          </form>
        </div>
      </div>

      <%!-- A program brain's access: its driver's choices, in its words. --%>
      <form
        :if={@editing && @access != []}
        id={"aqua-card-#{@agent["name"]}-access"}
        phx-change="editor_set_option"
        phx-auto-recover="ignore"
        phx-target={@myself}
      >
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="option" value="access" />
        <.access_select
          access={@access}
          value={Map.get(@agent["options"] || %{}, "access")}
          name="value"
          label={"Access for " <> (@agent["title"] || @agent["name"])}
        />
      </form>

      <button
        :if={@editing}
        id={"aqua-card-#{@agent["name"]}-done"}
        type="button"
        phx-click="close_editor"
        phx-value-name={@agent["name"]}
        phx-target={@myself}
        class="rounded px-2 py-1 text-[11px] text-gray-300 hover:bg-gray-800"
      >
        Done
      </button>

      <p :if={!@is_soul} class="text-[11px] text-gray-500">
        Offered Aqua's tools on every job.
      </p>

      <.may_use
        :if={@is_soul}
        myself={@myself}
        agent={@agent}
        groups={@groups}
        tools={@tools}
        browser={@browser}
        athanor={@athanor}
        grant={@model_status && elem(@model_status, 0)}
        context={@context}
        provenance={@provenance}
        servers_read={@servers_read}
      />
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :agent, :map, required: true
  attr :groups, :any, required: true
  attr :tools, :list, required: true
  attr :browser, :map, default: nil
  attr :athanor, :any, default: nil
  attr :grant, :atom, default: nil
  attr :context, :any, required: true
  attr :provenance, :map, default: %{}
  attr :servers_read, :boolean, default: true

  # What Aqua and every crew member may use: the grant any switch moves,
  # said once, then CYFR's own groups, then the MCP servers'.
  defp may_use(assigns) do
    {own, servers} = assigns.groups

    assigns =
      assign(assigns,
        own: own,
        servers: servers,
        unread?: not assigns.servers_read
      )

    ~H"""
    <section
      id="aqua-may-use"
      aria-labelledby="aqua-may-use-title"
      class="space-y-3 border-t border-gray-800 pt-3"
    >
      <div>
        <h4 id="aqua-may-use-title" class="text-sm font-medium text-gray-200">
          What Aqua may use
        </h4>
        <p class="mt-0.5 text-[11px] text-gray-500">
          Aqua and every crew member are offered what is on here, whichever brain runs them.
        </p>
      </div>

      <div :if={grant_state?(@grant)} class="flex flex-wrap items-center gap-2 text-[11px]">
        <.grant_line state={@grant} />
      </div>

      <div class="space-y-1.5">
        <h5 class="text-xs font-medium text-gray-300">Your MCP servers</h5>
        <p
          :if={@unread?}
          data-test="aqua-servers-unread"
          class="flex flex-wrap items-center gap-2 text-[11px] text-amber-300"
        >
          Your MCP servers cannot be read right now.
          <button
            type="button"
            phx-click="offerings_again"
            phx-target={@myself}
            class="rounded px-2 py-1 text-blue-400 hover:bg-gray-800 hover:text-blue-300"
          >
            Ask again
          </button>
        </p>
        <p
          :if={@servers == [] and not @unread?}
          data-test="aqua-no-servers"
          class="rounded border border-dashed border-gray-800 px-3 py-2 text-[11px] text-gray-500"
        >
          No MCP server here yet. One you add on
          <.link
            :if={@athanor}
            navigate={PrismWeb.Focus.path(@athanor, "/programs")}
            class="text-blue-400 hover:underline"
          >
            Programs
          </.link>
          shows here with its tools, resources and prompts, off until you switch them on.
        </p>
        <div :if={@servers != []} class="rounded border border-gray-800 divide-y divide-gray-800/60">
          <.group
            :for={group <- @servers}
            group={group}
            tools={@tools}
            target={@myself}
            agent={@agent["name"]}
            athanor={@athanor}
          />
        </div>
      </div>
      <div class="space-y-1.5">
        <h5 class="text-xs font-medium text-gray-300">CYFR's own</h5>
        <div class="rounded border border-gray-800 divide-y divide-gray-800/60">
          <%= for group <- @own do %>
            <%= cond do %>
              <% group.id == "scrolls" -> %>
                <.live_component
                  module={PrismWeb.AquaLive.ScrollsComponent}
                  id="aqua-scrolls-section"
                  context={@context}
                  provenance={@provenance}
                  group={group}
                  tools={@tools}
                  target={@myself}
                />
              <% group.id == "family-browser" and @browser != nil -> %>
                <.group
                  group={group}
                  tools={@tools}
                  target={@myself}
                  agent={@agent["name"]}
                  switch={%{on: @browser[:on] == true, event: "browser_set"}}
                >
                  <.browser_setting athanor={@athanor} browser={@browser} />
                </.group>
              <% true -> %>
                <.group group={group} tools={@tools} target={@myself} agent={@agent["name"]} />
            <% end %>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp grant_state?(state), do: state in @grant_states

  @doc """
  One group of what Aqua may use (`t:PrismWeb.AquaLive.Catalog.group/0`): a
  disclosure whose summary names the group and how much of it is on, the
  group's switch beside it, which adds or takes off its keys in one
  update (or, given `switch`, sends that switch's own event), and its
  entries, each with its own switch, its kind and why a turn would not
  hand it. A server's group says its state once: asked, silent with Ask
  again, turned off, or no longer here. The person's open or closed
  stays theirs across the page's updates.
  """
  attr :group, :map, required: true
  attr :tools, :list, required: true
  attr :target, :any, required: true
  attr :agent, :string, default: "aqua"
  attr :details_id, :string, default: nil
  attr :open, :boolean, default: false
  attr :switch, :map, default: nil
  attr :athanor, :any, default: nil
  slot :inner_block

  def group(assigns) do
    assigns =
      assigns
      |> assign(:on, switch_state(assigns.group, assigns.tools, assigns.switch))
      |> assign(:summary, summary_words(assigns.group, assigns.tools, assigns.switch))
      |> assign(:not_handed, Enum.count(assigns.group.entries, & &1.why))
      |> assign(:server, server_of(assigns.group))

    ~H"""
    <div
      id={"aqua-group-" <> @group.id}
      data-test="aqua-group"
      data-state={@group.state}
      class="relative"
    >
      <details
        id={@details_id || "aqua-group-#{@group.id}-entries"}
        open={@open}
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group/entries"
      >
        <summary class={[
          "flex min-h-11 cursor-pointer list-none items-center gap-2 py-2 pl-3 hover:bg-gray-800/40 [&::-webkit-details-marker]:hidden",
          if(@group.state == :silent, do: "pr-44", else: "pr-24")
        ]}>
          <span
            aria-hidden="true"
            class="text-gray-500 transition-transform group-open/entries:rotate-90"
          >
            ›
          </span>
          <span class="min-w-0 flex-1">
            <span class="text-xs font-medium text-gray-200">{@group.title}</span>
            <span class={[
              "ml-1 text-[11px] tabular-nums",
              if(@group.state in [:silent, :gone, :unread],
                do: "text-amber-300",
                else: "text-gray-500"
              )
            ]}>
              {@summary}
            </span>
            <span :if={@not_handed > 0} class="ml-1 text-[11px] text-amber-300 tabular-nums">
              {@not_handed} not handed
            </span>
          </span>
        </summary>
        <div class="space-y-1 pb-2">
          <p
            :if={state_words(@group)}
            data-test="aqua-group-state"
            class="px-3 text-[11px] text-gray-500"
          >
            {state_words(@group)}
            <.link
              :if={@group.state == :off and @athanor}
              navigate={PrismWeb.Focus.path(@athanor, "/programs")}
              class="text-blue-400 hover:underline"
            >
              Programs
            </.link>
          </p>
          {render_slot(@inner_block)}
          <ul :if={@group.entries != []} class="divide-y divide-gray-800/40">
            <li :for={entry <- @group.entries} data-key={entry.key} class="px-3">
              <label class={[
                "flex min-h-11 cursor-pointer gap-2 py-1.5 sm:min-h-0",
                if(entry.description || entry.why, do: "items-start", else: "items-center")
              ]}>
                <input
                  type="checkbox"
                  checked={entry.key in @tools}
                  phx-click="editor_toggle_capability"
                  phx-target={@target}
                  phx-value-name={@agent}
                  phx-value-key={entry.key}
                  class={[
                    "rounded bg-gray-900 border-gray-600",
                    (entry.description || entry.why) && "mt-0.5"
                  ]}
                />
                <span class="min-w-0 flex-1">
                  <span class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
                    <span
                      data-test="aqua-entry-name"
                      class={[
                        "text-[11px] text-gray-300 break-all",
                        entry.kind == :tool && "font-mono"
                      ]}
                    >
                      {entry.name}
                    </span>
                    <.kind_tag kind={entry.kind} />
                  </span>
                  <span
                    :if={entry.description}
                    class="block truncate text-[11px] text-gray-500"
                    title={entry.description}
                  >
                    {entry.description}
                  </span>
                  <span
                    :if={entry.why}
                    data-test="aqua-not-handed"
                    data-reason={entry.why}
                    class="block text-[11px] text-amber-300"
                  >
                    {Catalog.not_handed(entry.why, @server)}
                  </span>
                </span>
              </label>
            </li>
          </ul>
        </div>
      </details>
      <div class="absolute right-2 top-0 flex h-11 items-center gap-1">
        <button
          :if={@group.state == :silent}
          type="button"
          phx-click="offerings_again"
          phx-target={@target}
          class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
        >
          Ask again
        </button>
        <button
          id={"aqua-group-" <> @group.id <> "-switch"}
          type="button"
          role="switch"
          aria-checked={aria_checked(@on)}
          aria-label={@group.title <> ": all of it"}
          data-test={@switch && @switch.event == "browser_set" && "aqua-browser-switch"}
          disabled={is_nil(@switch) and (@group.keys == [] or @group.state == :asking)}
          phx-click={if @switch, do: @switch.event, else: "group_toggle"}
          phx-value-group={@group.id}
          phx-value-on={@switch && to_string(not @switch.on)}
          phx-target={@target}
          class={[
            "min-w-12 shrink-0 rounded px-3 py-1 text-xs font-medium disabled:cursor-not-allowed disabled:opacity-50",
            case @on do
              :on -> "bg-emerald-700 text-white hover:bg-emerald-600"
              :some -> "bg-emerald-900/60 text-emerald-100 hover:bg-emerald-800"
              :off -> "bg-gray-800 text-gray-300 hover:bg-gray-700"
            end
          ]}
        >
          {switch_words(@on)}
        </button>
      </div>
    </div>
    """
  end

  defp switch_state(_group, _tools, %{on: on}), do: if(on, do: :on, else: :off)
  defp switch_state(group, tools, nil), do: Catalog.switch(group.keys, tools)

  defp aria_checked(:on), do: "true"
  defp aria_checked(:off), do: "false"
  defp aria_checked(:some), do: "mixed"

  defp switch_words(:on), do: "On"
  defp switch_words(:off), do: "Off"
  defp switch_words(:some), do: "Some"

  defp server_of(%{id: "server-" <> name}), do: name
  defp server_of(_own), do: nil

  # How much of a group is on, or what it is when it switches no entries
  # of its own.
  defp summary_words(%{id: "search"}, _tools, _switch), do: "the provider's own web search"
  defp summary_words(_group, _tools, %{event: "browser_set"}), do: "Aqua's own Chrome"

  defp summary_words(%{state: state, entries: entries}, tools, _switch)
       when state in [:asking, :silent, :off, :gone, :unread] do
    on = Enum.count(entries, &(&1.key in tools))
    if on > 0, do: "#{server_state(state)} · #{on} on", else: server_state(state)
  end

  defp summary_words(%{entries: []}, _tools, _switch), do: nil

  defp summary_words(%{entries: entries}, tools, _switch),
    do: "#{Enum.count(entries, &(&1.key in tools))} of #{length(entries)} on"

  defp server_state(:asking), do: "asking what it offers…"
  defp server_state(:silent), do: "did not answer"
  defp server_state(:off), do: "turned off"
  defp server_state(:gone), do: "no longer here"
  defp server_state(:unread), do: "cannot be read now"

  # What a server's state means, inside its group; the state itself is
  # said on the group's summary.
  defp state_words(%{state: :silent}),
    do:
      "What it offers is not shown until it answers. What is on stays on until you switch it off."

  defp state_words(%{state: :off}),
    do: "It is not asked, and nothing of it is handed. Turn it on in"

  defp state_words(%{state: :gone, title: name}),
    do: "There is no MCP server named #{name} here now. Switch off what the list still names."

  defp state_words(%{id: "search"}),
    do:
      "Search that the model's provider runs itself, inside its own service, where the " <>
        "provider offers it."

  defp state_words(_group), do: nil

  attr :kind, :atom, required: true

  # An entry's kind, as a turn's policy reads it.
  defp kind_tag(%{kind: kind} = assigns) when kind in [:read, :write, :execute, :destructive] do
    ~H"""
    <span class={[
      "inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium",
      case @kind do
        :read -> "bg-emerald-900/60 text-emerald-200"
        :write -> "bg-slate-700/70 text-slate-200"
        :execute -> "bg-amber-900/60 text-amber-200"
        :destructive -> "bg-red-900/60 text-red-200"
      end
    ]}>
      {kind_label(@kind)}
    </span>
    """
  end

  defp kind_tag(assigns), do: ~H""

  defp kind_label(:read), do: "Read"
  defp kind_label(:write), do: "Write"
  defp kind_label(:execute), do: "Execute"
  defp kind_label(:destructive), do: "Destructive"

  # The terminal in the panel where its Sign in was pressed.
  defp panel_terminal(%{panel: panel} = terminal, panel), do: terminal
  defp panel_terminal(_terminal, _name), do: nil

  # A terminal whose card is gone (deleted, or refused) stands below the
  # crew: the page asks nothing while it runs, so the person must still
  # be able to end it.
  defp cardless?(%{panel: panel}, soul, crew) when is_binary(panel),
    do: not Enum.any?(List.wrap(soul) ++ crew, &(&1["name"] == panel))

  defp cardless?(_terminal, _soul, _crew), do: false

  # The program or key an editor shows: the one chosen in it to move the
  # member to, else the member's.
  defp chosen("program:" <> program), do: [chosen_program: program, chosen_key: nil]
  defp chosen("catalyst:" <> provider), do: [chosen_program: nil, chosen_key: provider]
  defp chosen(nil), do: [chosen_program: nil, chosen_key: nil]

  # What an editor offers for what it shows. While it shows another
  # program or key to move to, the member holds no model of it yet, so no
  # option is offered until one is picked.
  defp offered_here(assigns) do
    %{agent: agent, moving_to: moving_to, chosen_program: program, editor: editor} = assigns
    # Only what this opening asked: another's list offers nothing here.
    mine? = program != nil and editor != nil and program in editor.asked
    listing = if mine?, do: listed(assigns.listings, program)
    here? = is_nil(moving_to)
    ready? = match?({:ready, _}, assigns.model_status)

    options =
      cond do
        not here? -> []
        is_nil(program) -> assigns.brain_options
        listing -> effort_option(listing, agent["model"])
        true -> []
      end

    [
      chosen_model: if(here?, do: agent["model"]),
      # An installed program is the one an editor asks.
      asked: if(not here? or ready?, do: program),
      asked_listing: if(mine?, do: assigns.listings[program]),
      program_models: listing && listing.models,
      options_here: options,
      access: if(here? and listing, do: listing.access, else: [])
    ]
  end

  attr :program, :string, required: true
  attr :listing, :any, default: nil
  attr :member, :string, default: nil
  attr :myself, :any, default: "#aqua-agents"

  # Where an ask stands in an editor: being asked, or why no list came,
  # with Try again. A list that came says nothing.
  defp listing_line(%{listing: {:ok, _listed}} = assigns), do: ~H""

  defp listing_line(%{listing: :asking} = assigns) do
    ~H"""
    <p class="text-[11px] text-gray-400">Asking {program_title(@program)}…</p>
    """
  end

  defp listing_line(%{listing: :held} = assigns) do
    ~H"""
    <p data-test="listing-held" class="text-[11px] text-gray-400">
      It is asked for its list when the sign-in's terminal ends.
    </p>
    """
  end

  defp listing_line(assigns) do
    ~H"""
    <p class="flex flex-wrap items-center gap-2 text-[11px]">
      <span :if={match?({:error, _}, @listing)} data-test="listing-failed" class="text-amber-300">
        {elem(@listing, 1)}
      </span>
      <button
        type="button"
        phx-click="list_again"
        phx-value-program={@program}
        phx-value-member={@member}
        phx-target={@myself}
        data-test="list-again"
        class="text-blue-400 hover:underline"
      >
        Try again
      </button>
    </p>
    """
  end

  attr :athanor, :any, default: nil
  attr :browser, :map, required: true

  # What the person's browser setting, the Browser group's switch, means,
  # and adding Aqua's browser while it is not added.
  defp browser_setting(assigns) do
    ~H"""
    <div id="aqua-browser" data-test="aqua-browser" class="space-y-2 px-3">
      <p class="text-[11px] text-gray-400">
        Aqua has a Chrome of its own that is yours alone, with a window for each thread. While this is on, Aqua opens, reads and acts on sites in it without asking. Off, Aqua cannot use it and its windows close; your sign-ins in it stay.
      </p>
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
  attr :name, :string, required: true
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
      name={@name}
      aria-label={@option["name"]}
      disabled={@choices == []}
      class="flex-1 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-70"
    >
      <option value="" selected={is_nil(@value)}>default{default_label(@option)}</option>
      <option :for={choice <- @choices} value={choice} selected={to_string(@value) == choice}>
        {choice}
      </option>
      <option :if={@value not in [nil, ""] and to_string(@value) not in @choices} selected>
        {@value}
      </option>
    </select>
    """
  end

  defp option_input(assigns) do
    ~H"""
    <input
      type={if @option["kind"] == "integer", do: "number", else: "text"}
      name={@name}
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

  attr :brains, :list, required: true
  attr :value, :string, required: true

  # A program a select holds that is offered no more, found signed out
  # when it was asked: it stands alone, so the select names what was
  # chosen and no other.
  defp withdrawn(%{value: "program:" <> name} = assigns) do
    assigns =
      assigns
      |> assign(:title, program_title(name))
      |> assign(:withdrawn?, not Enum.any?(assigns.brains, &(&1.value == assigns.value)))

    ~H"""
    <option :if={@withdrawn?} value={@value} selected>{@title}</option>
    """
  end

  attr :brains, :list, required: true
  attr :chosen, :string, default: nil

  # The programs, then the connected keys, each group named.
  defp brain_choices(assigns) do
    ~H"""
    <%= for {kind, label} <- [program: "Programs", key: "Keys"],
            listed = Enum.filter(@brains, &(&1.kind == kind)),
            listed != [] do %>
      <optgroup label={label}>
        <option :for={brain <- listed} value={brain.value} selected={brain.value == @chosen}>
          {brain.title}
        </option>
      </optgroup>
    <% end %>
    """
  end

  @doc """
  The form that makes a crew member, the one way to make one, open once
  New crew member is pressed: the name the person gives it, the program
  or key it runs on (`brains/4`), a model that one lists, each option it
  declares for that model, a program's Access selection
  (`access_select/1`), and what it is good at and should avoid.
  `listings` is what each program asked answered, and `draft` what the
  form holds, as the roster keeps it (`empty_draft/0` before anything is
  entered). Its events are the roster's. Nothing is shown while no
  program or key can be chosen and none was.
  """
  attr :id, :string, required: true
  attr :brains, :list, required: true
  attr :listings, :map, required: true
  attr :draft, :map, required: true

  def member_form(%{brains: [], draft: %{open: false}} = assigns), do: ~H""

  def member_form(%{draft: %{open: false}} = assigns) do
    ~H"""
    <button
      id={@id <> "-open"}
      type="button"
      phx-click="new_member"
      phx-target="#aqua-agents"
      class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-0.5 text-[11px] font-medium text-white"
    >
      New crew member
    </button>
    """
  end

  def member_form(assigns) do
    params = assigns.draft.params
    brain = Enum.find(assigns.brains, &(&1.value == params["brain"]))

    program =
      case params["brain"] do
        "program:" <> name -> name
        _key_or_none -> nil
      end

    listing = program && listed(assigns.listings, program)

    models =
      cond do
        is_nil(brain) -> nil
        is_nil(program) -> brain.models
        listing -> Enum.map(listing.models, &{&1.id, &1.name})
        true -> nil
      end

    options =
      cond do
        is_nil(program) -> assigns.draft.options
        brain && listing -> effort_option(listing, params["model"])
        true -> []
      end

    assigns =
      assigns
      |> assign(:params, params)
      |> assign(:program, program)
      |> assign(:models, models)
      |> assign(:options, options)
      |> assign(:access, if(brain && listing, do: listing.access, else: []))
      |> assign(:chosen, params["options"] || %{})

    ~H"""
    <form
      id={@id}
      phx-change="draft_member"
      phx-submit="make_member"
      phx-auto-recover="ignore"
      phx-target="#aqua-agents"
      class="space-y-1"
    >
      <p class="font-medium text-gray-100">New crew member</p>
      <div class="flex flex-wrap items-center gap-2">
        <input
          type="text"
          name="name"
          value={@params["name"]}
          aria-label="Name"
          placeholder="Name, such as Opus"
          pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
          title="Letters, digits, - and _"
          required
          class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
        <select
          name="brain"
          aria-label="Program or key"
          class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option value="">Choose a program or key</option>
          <.withdrawn :if={@program} brains={@brains} value={@params["brain"]} />
          <.brain_choices brains={@brains} chosen={@params["brain"]} />
        </select>
        <.listing_line :if={@program} program={@program} listing={@listings[@program]} />
        <select
          :if={@models}
          name="model"
          aria-label="Model"
          class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option value="">Choose a model</option>
          <option :for={{id, name} <- @models} value={id} selected={id == @params["model"]}>
            {name}
          </option>
        </select>
        <label
          :for={option <- @options}
          class="flex items-center gap-2 text-[11px] text-gray-400"
        >
          <span class="text-[10px] uppercase tracking-wider text-gray-500">{option["name"]}</span>
          <.option_input
            option={option}
            name={"options[" <> option["name"] <> "]"}
            value={@chosen[option["name"]]}
          />
        </label>
        <.access_select
          :if={@access != []}
          access={@access}
          value={@chosen["access"]}
          name="options[access]"
          label="Access"
        />
        <input
          type="text"
          name="description"
          value={@params["description"]}
          aria-label="Good at"
          placeholder="Good at (optional)"
          class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
        <input
          type="text"
          name="avoid"
          value={@params["avoid"]}
          aria-label="Avoid"
          placeholder="Avoid (optional)"
          class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
        <button
          type="submit"
          class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-0.5 text-[11px] font-medium text-white"
        >
          Make crew member
        </button>
      </div>
    </form>
    """
  end

  @doc """
  A program brain's Access selection: the choices its driver listed
  (`Aqua.program_listing/2`), each in the driver's own words, the
  member's stored one chosen, else the first, the driver's own default.
  While the driver offers one choice the selection is closed and names
  it, and a hidden field carries it, so a form sends what it shows.
  """
  attr :access, :list, required: true
  attr :value, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, required: true

  def access_select(assigns) do
    assigns = assign(assigns, :closed?, match?([_one], assigns.access))

    ~H"""
    <label class="flex items-center gap-2 text-[11px] text-gray-400">
      <span class="text-[10px] uppercase tracking-wider text-gray-500">Access</span>
      <select
        name={@name}
        aria-label={@label}
        disabled={@closed?}
        data-test="access"
        class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none disabled:cursor-not-allowed disabled:opacity-70"
      >
        <option :for={choice <- @access} value={choice.id} selected={choice.id == @value}>
          {choice.name}
        </option>
      </select>
      <input :if={@closed?} type="hidden" name={@name} value={hd(@access).id} />
    </label>
    """
  end
end
