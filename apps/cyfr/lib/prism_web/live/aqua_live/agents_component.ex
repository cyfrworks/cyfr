# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.AgentsComponent do
  @moduledoc """
  The soul and the roles it clones into — each with a prompt, a model and a
  capability allowlist — and the form a new role starts from. Every write
  goes through the `aqua` tool, the gate a card in chat goes through; a
  write that changes a file's provenance asks the page to re-read it
  (`{:refresh, :agents}`), since the chips and the removal verbs come off
  that read.
  """

  use PrismWeb, :live_component

  import PrismWeb.AquaLive.Section

  alias Compendium.AquaAgent
  alias Compendium.AquaPath
  alias Phoenix.LiveView.JS
  alias PrismWeb.AquaLive.Catalog

  # `field` names exactly what the forms edit — never an arbitrary map key.
  # An unconstrained key could shadow the "action" verb (a later duplicate
  # key wins in a map literal) or write any field, the system prompt
  # included, from an event the templates never send.
  @editable_fields ~w(title description)

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded, false)
     |> assign(:agents, [])
     |> assign(:soul, nil)
     |> assign(:roles, [])
     |> assign(:default_start, nil)
     |> assign(:tool_actions, nil)
     |> assign(:model_status, %{})
     |> assign(:editor_editing_prompt, nil)
     |> assign(:editor_prompt_content, "")
     |> assign(:editor_prompt_digest, nil)}
  end

  @impl true
  def update(%{load: true} = assigns, socket) do
    {:ok, socket |> assign(Map.delete(assigns, :load)) |> load_agents() |> assign(:loaded, true)}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("dismiss_flash", _params, socket), do: {:noreply, clear_flash(socket)}

  # A new role gets its hands in the same flow: the policy it starts from
  # (a role in the roster, or none), and leave for the soul to clone into
  # it — the `<name>.*` glob on the soul's own allowlist. A role without
  # the glob can be mentioned but never cloned into, which is the one
  # thing a person creating one cannot see from the card.
  #
  # Before the roster is read there is no role to start from and no soul
  # to give leave: a submit that arrives first is refused, not half-done.
  def handle_event("editor_create_role", _params, %{assigns: %{loading: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Still loading — try again in a moment.")}
  end

  def handle_event("editor_create_role", %{"name" => name} = params, socket)
      when name != "" do
    ctx = socket.assigns.context
    # The role a new one starts from is read again NOW — its hands as
    # another member may have edited them since this page loaded — the
    # same rule every allowlist edit on this page follows.
    start = fresh_role(ctx, params["start_from"])
    policy = if start, do: start["tool_policy"], else: %{}

    case call_aqua(ctx, %{
           "action" => "create",
           "name" => name,
           "title" => name,
           "description" => "Clone into #{name} for…",
           "content" => "# #{name}\n\nYou are AQUA in the #{name} role.",
           "tool_policy" => policy
         }) do
      {:ok, result} ->
        hands = if start, do: "the #{start["title"]} role's hands", else: "no hands yet"

        socket =
          case result do
            %{"cloneable" => true} ->
              put_flash(
                socket,
                :info,
                "Created the role '#{name}' with #{hands} — the soul may now clone into it."
              )

            %{"note" => note} ->
              put_flash(socket, :error, "Created the role '#{name}' with #{hands}. #{note}")
          end

        send(self(), {:refresh, :agents})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_create_role", _params, socket), do: {:noreply, socket}

  def handle_event(
        "editor_update_field",
        %{"name" => name, "field" => field, "value" => value},
        socket
      )
      when field in @editable_fields do
    args = Map.merge(%{field => value}, %{"action" => "update", "name" => name})

    case call_aqua(socket.assigns.context, args) do
      {:ok, _} ->
        send(self(), {:refresh, :agents})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_update_field", _params, socket), do: {:noreply, socket}

  # The tool owns the disposition: a role this estate made is deleted, an
  # edited copy of a shipped one reverts to shipped. The card offers the
  # verb only where one of those applies (`card_actions/2`).
  def handle_event("editor_delete", %{"name" => name}, socket) do
    case call_aqua(socket.assigns.context, %{"action" => "delete", "name" => name}) do
      {:ok, %{"restored" => _}} ->
        send(self(), {:refresh, :agents})
        {:noreply, put_flash(socket, :info, "Reverted '#{name}' to what ships with the server.")}

      {:ok, _} ->
        send(self(), {:refresh, :agents})
        {:noreply, put_flash(socket, :info, "Deleted the role '#{name}'.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
    end
  end

  # Taking a role out of the closet — and putting it back — without
  # touching its file's content. This is how a shipped role is set aside,
  # since the estate does not own it and cannot delete it.
  def handle_event("editor_set_disabled", %{"name" => name, "disabled" => flag}, socket)
      when flag in ["true", "false"] do
    disabled? = flag == "true"

    case call_aqua(socket.assigns.context, %{
           "action" => "update",
           "name" => name,
           "disabled" => disabled?
         }) do
      {:ok, _} ->
        send(self(), {:refresh, :agents})
        verb = if disabled?, do: "Disabled", else: "Enabled"
        {:noreply, put_flash(socket, :info, "#{verb} the role '#{name}'.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
    end
  end

  # Add/remove a `tool.action` from an allowlist. On add, the default is
  # what the agent CAN hold: on the soul, "auto" for a read (they never
  # ask) and "ask" for everything else; on a role, "auto" — a cloned role's
  # answer is a tool result, never a turn, so it has no card to raise and
  # an "ask" on it is a hand it silently loses. A destructive or external
  # action is never added to a role at all: it always asks, and only the
  # soul can ask. The kind is DERIVED here from the action's own
  # annotation (`Aqua.Actions.kind_for/2`), never taken off the wire. A
  # key that resolves to no known action is refused.
  def handle_event("editor_toggle_capability", %{"name" => name, "key" => key}, socket) do
    soul? = soul_name?(socket, name)

    {:noreply,
     update_tool_policy(socket, name, fn policy ->
       cond do
         Map.has_key?(policy, key) ->
           {:ok, %{key => nil}}

         resolved_kind(key) == nil ->
           {:refused, "Unknown capability: #{key}"}

         not soul? and not auto_permitted?(key) ->
           {:refused,
            "#{key} always asks, and a role has no card to raise — the soul asks for it"}

         not soul? ->
           {:ok, %{key => "auto"}}

         resolved_kind(key) == :read ->
           {:ok, %{key => "auto"}}

         true ->
           {:ok, %{key => "ask"}}
       end
     end)}
  end

  # Toggle a write/execute capability between "ask" (request approval) and
  # "auto" (run without asking) — on the soul only: a role holds every
  # hand at "auto" (it has no card to raise), and a destructive or
  # external action is never "auto" anywhere. Both rules are enforced
  # here, on the derived kind, whatever the client sent; the `aqua` door
  # holds the same rule for every other writer.
  def handle_event(
        "editor_set_capability_mode",
        %{"name" => name, "key" => key, "mode" => mode},
        socket
      )
      when mode in ["ask", "auto"] do
    cond do
      mode == "auto" and not auto_permitted?(key) ->
        {:noreply, put_flash(socket, :error, "#{key} always asks — it cannot be set to auto")}

      mode == "ask" and not soul_name?(socket, name) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A role has no card to raise — #{key} runs in the role or not at all"
         )}

      true ->
        {:noreply, update_tool_policy(socket, name, fn _policy -> {:ok, %{key => mode}} end)}
    end
  end

  # Toggle the provider-native search grant. It is an ordinary policy key
  # that coexists with the rest of the allowlist; the formula appends the
  # native tool when the key is "auto".
  def handle_event("editor_toggle_native", %{"name" => name}, socket) do
    {:noreply, update_tool_policy(socket, name, &{:ok, toggle_key(&1, "native_search")})}
  end

  # Which roles the soul may clone into: one `<role>.*` glob each on the
  # soul's allowlist. Only a role the roster holds can be named — the glob
  # is a policy key, and a key for a role that does not exist is noise
  # the runtime would carry forever.
  def handle_event("editor_toggle_clone", %{"role" => role_name}, socket) do
    with %{"name" => soul_name} <- socket.assigns.soul,
         %{"name" => _} <- find_role(socket, role_name) do
      {:noreply,
       update_tool_policy(
         socket,
         soul_name,
         &{:ok, toggle_key(&1, AquaAgent.clone_glob(role_name))}
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Unknown role: #{role_name}")}
    end
  end

  def handle_event("editor_edit_prompt", %{"name" => name}, socket) do
    agent = find_agent(socket, name)
    content = if agent, do: agent["content"] || "", else: ""

    {:noreply,
     socket
     |> assign(:editor_editing_prompt, name)
     |> assign(:editor_prompt_content, content)
     |> assign(:editor_prompt_digest, agent && agent["content_digest"])}
  end

  def handle_event("editor_cancel_prompt", _params, socket) do
    {:noreply, assign(socket, :editor_editing_prompt, nil)}
  end

  def handle_event("editor_save_prompt", %{"content" => content}, socket) do
    name = socket.assigns.editor_editing_prompt

    # The digest names the version this editor opened: a save over a
    # prompt another member changed since is refused as a conflict, and
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
  end

  def handle_event("editor_set_model", %{"name" => name, "value" => value}, socket) do
    ctx = socket.assigns.context

    result =
      case Catalog.decode_model_choice(value) do
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
          # the only ones that exist.
          catalyst_ref =
            case socket.assigns[:catalyst_refs][provider] do
              nil -> nil
              ref -> Regex.replace(~r/:\d+\.\d+\.\d+$/, ref, "")
            end

          call_aqua(ctx, %{
            "action" => "update",
            "name" => name,
            "model" => model,
            "catalyst_ref" => catalyst_ref
          })

        :noop ->
          {:ok, :noop}
      end

    send(self(), {:refresh, :agents})

    case result do
      {:ok, _} ->
        {:noreply, socket}

      {:error, reason} ->
        # A discarded refusal made the select box appear to work — the
        # refresh then quietly snapped it back.
        {:noreply, put_flash(socket, :error, "Model update failed: #{error_message(reason)}")}
    end
  end

  # ============================================================================
  # The roster
  # ============================================================================

  defp load_agents(socket) do
    ctx = socket.assigns.context
    provenance = socket.assigns.provenance
    types = [AquaAgent.soul_type(), AquaAgent.role_type()]

    # One call: list with detail carries every field the cards show, and
    # the roles set aside — `list` leaves them out of the closet; a role
    # disabled from this page must stay on it to be put back.
    listed =
      case call_aqua(ctx, %{"action" => "list", "detail" => true, "include_disabled" => true}) do
        {:ok, %{"guides" => guides}} when is_list(guides) ->
          Enum.filter(guides, &(&1["type"] in types))

        _ ->
          []
      end

    agents =
      for g <- listed do
        %{
          "name" => g["name"],
          "title" => g["title"] || g["name"],
          "type" => g["type"],
          "description" => g["description"] || "",
          "model" => g["model"],
          "catalyst_ref" => g["catalyst_ref"],
          "tool_policy" => g["tool_policy"] || %{},
          "content" => g["content"] || "",
          "disabled" => g["disabled"] == true,
          "provenance" => Map.get(provenance, Enum.join(AquaPath.agent_file(g["name"]), "/"))
        }
      end

    soul_type = AquaAgent.soul_type()
    soul = Enum.find(agents, &(&1["type"] == soul_type))
    roles = agents |> Enum.reject(&(&1["type"] == soul_type)) |> Enum.sort_by(& &1["name"])

    socket
    |> assign(:agents, agents)
    |> assign(:soul, soul)
    |> assign(:roles, roles)
    |> assign(:default_start, default_start(roles))
    |> assign(:model_status, Aqua.AgentConfig.model_status(ctx, agents))
    |> ensure_tool_actions_loaded()
  end

  # Enumerate `(tool, [actions...])` from the live MCP registry — populated
  # once per page open, so the matrix UI can render real (tool, action)
  # pairs the user can toggle. native_search is included as a bare key
  # (no actions enum) since the formula treats it specially.
  defp ensure_tool_actions_loaded(socket) do
    if socket.assigns[:tool_actions] do
      socket
    else
      assign(socket, :tool_actions, Catalog.enumerate_tool_actions())
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # The patch that flips one "auto"-or-absent key: present, it is taken
  # off; absent, put on.
  defp toggle_key(policy, key) do
    if Map.has_key?(policy, key), do: %{key => nil}, else: %{key => "auto"}
  end

  # The action's kind, resolved from its own annotation — the server-owned
  # fact the ask/auto decisions above key on. nil for a key the catalog
  # has never heard of (fail closed).
  defp resolved_kind(key) when is_binary(key) do
    case String.split(key, ".", parts: 2) do
      [tool, action] -> Aqua.Actions.kind_for(tool, action)
      _ -> nil
    end
  end

  # "auto" (run with no card) is only for kinds a card can be skipped for —
  # the one rule `Aqua.Actions.auto_permitted?/2` holds for every door.
  defp auto_permitted?(key) do
    case String.split(key, ".", parts: 2) do
      [tool, action] -> Aqua.Actions.auto_permitted?(tool, action)
      _ -> false
    end
  end

  defp soul_name?(socket, name) do
    case socket.assigns.soul do
      %{"name" => soul_name} -> soul_name == name
      _ -> Compendium.AquaPath.soul?(name)
    end
  end

  # An allowlist edit is one key's. `change` reads the policy as it is
  # NOW — again, just before the write, never the copy this page loaded —
  # to decide the direction, and answers the one-key patch
  # (`%{key => "auto" | "ask" | nil}`) the `aqua` door applies under its
  # lock, so a toggle another member makes at the same moment on another
  # key is kept, not written over. Or `{:refused, sentence}` for the person.
  defp edit_tool_policy(ctx, name, change) do
    with {:ok, agent} <- call_aqua(ctx, %{"action" => "get", "name" => name}),
         {:ok, patch} <- change.(agent["tool_policy"] || %{}),
         {:ok, _} <-
           call_aqua(ctx, %{"action" => "update", "name" => name, "tool_policy_patch" => patch}) do
      :ok
    end
  end

  defp update_tool_policy(socket, name, change) do
    case edit_tool_policy(socket.assigns.context, name, change) do
      :ok ->
        send(self(), {:refresh, :agents})
        socket

      {:refused, message} ->
        put_flash(socket, :error, message)

      {:error, reason} ->
        put_flash(socket, :error, "Update failed: #{error_message(reason)}")
    end
  end

  defp find_agent(socket, name), do: Enum.find(socket.assigns.agents, &(&1["name"] == name))

  defp find_role(_socket, name) when not is_binary(name) or name == "", do: nil
  defp find_role(socket, name), do: Enum.find(socket.assigns.roles, &(&1["name"] == name))

  defp fresh_role(_ctx, name) when not is_binary(name) or name == "", do: nil

  defp fresh_role(ctx, name) do
    case call_aqua(ctx, %{"action" => "get", "name" => name}) do
      {:ok, %{"type" => type} = agent} -> if type == AquaAgent.role_type(), do: agent
      _ -> nil
    end
  end

  # Where a new role starts from: the role with the fewest hands that can
  # change anything — a read-only one when the roster has it — so a role
  # made in a hurry cannot do more than look until someone widens it.
  defp default_start(roles) do
    roles
    |> Enum.reject(& &1["disabled"])
    |> Enum.sort_by(fn role -> {acting_count(role["tool_policy"]), role["name"]} end)
    |> List.first()
    |> then(&(&1 && &1["name"]))
  end

  defp acting_count(policy) when is_map(policy),
    do: Enum.count(policy, fn {key, _} -> resolved_kind(key) != :read end)

  defp acting_count(_), do: 0

  # The allowlist is the athanor's, not the person's: in a group, a member
  # editing it is editing what AQUA may do for everyone in it.
  defp allowlist_owner(%{kind: "group", name: name}),
    do: "This allowlist is #{name}'s — it applies to every member."

  defp allowlist_owner(_athanor), do: ""

  defp agent_provider_for_select(agent) do
    detect_provider_from_ref(agent["catalyst_ref"])
  end

  defp detect_provider_from_ref(nil), do: nil
  defp detect_provider_from_ref(""), do: nil

  defp detect_provider_from_ref(ref) when is_binary(ref) do
    # The grammar's own parser. `~r/catalyst:[^.]+\\.([^:]+)/` reads up to the
    # FIRST dot, so a publisher with one in it — `stripe.com` — gave
    # "com.api" as the provider. `Sanctum.ComponentRef` exists because the
    # split is the last dot, not the first.
    case Sanctum.ComponentRef.parse(ref) do
      {:ok, %{type: "catalyst", name: name}} -> name
      _ -> nil
    end
  end

  # The one removal verb a card may offer, read from its provenance: the
  # estate's own role is deleted, an edited copy of a shipped one reverts,
  # an unedited shipped role and the soul offer nothing. A provenance the
  # page could not read offers nothing either.
  defp removal(agent) do
    cond do
      agent["type"] == AquaAgent.soul_type() -> nil
      agent["provenance"] == "user" -> {"Delete", "Delete the role '"}
      agent["provenance"] == "bundled_modified" -> {"Revert to shipped", "Revert the role '"}
      true -> nil
    end
  end

  # Count of capabilities that run without asking that *aren't* reads —
  # i.e. the write/execute actions the user has blanket-approved ("auto").
  defp count_auto(tool_policy, tool_actions) when is_map(tool_policy) do
    kinds = kind_index(tool_actions)

    Enum.count(tool_policy, fn {key, val} ->
      val == "auto" and Map.get(kinds, key) not in [nil, :read]
    end)
  end

  defp count_auto(_, _), do: 0

  defp count_in_list(tool_policy, rows) when is_map(tool_policy) do
    Enum.count(rows, fn {t, a} -> Map.has_key?(tool_policy, "#{t}.#{a}") end)
  end

  defp count_in_list(_, _), do: 0

  # `%{"tool.action" => kind}` lookup built from the enumerated tool catalog.
  defp kind_index(tool_actions) do
    for {tool, actions} <- tool_actions, {action, kind} <- actions, into: %{} do
      {"#{tool}.#{action}", kind}
    end
  end

  defp kind_hint(:read), do: "available, never asks"
  defp kind_hint(:write), do: "asks unless marked auto"
  defp kind_hint(:execute), do: "asks unless marked auto"
  defp kind_hint(:destructive), do: "always asks — can't be automated"
  defp kind_hint(_), do: ""

  # Kind sections in fixed display order, with their visual treatment (matches
  # the approval-card colour ramp: read = calm green, write = near-neutral
  # slate, execute = amber, destructive = red, external = amber + ring).
  # Tuple: {atom_kind, label, pill-classes, summary-strip-classes}.
  # A role is offered no destructive row: it always asks, and only the
  # soul can ask.
  defp kind_sections(soul?) do
    sections = [
      {:read, "Read", "bg-emerald-900/60 text-emerald-200", "bg-emerald-900/10"},
      {:write, "Write", "bg-slate-700/70 text-slate-200", "bg-slate-800/20"},
      {:execute, "Execute", "bg-amber-900/60 text-amber-200", "bg-amber-900/10"},
      {:destructive, "Destructive", "bg-red-900/60 text-red-200", "bg-red-900/10"}
    ]

    if soul?, do: sections, else: Enum.reject(sections, &(elem(&1, 0) == :destructive))
  end

  defp capabilities_hint(true),
    do:
      "reads run without asking; writes and executes ask unless you mark them \"auto\"; destructive always asks."

  defp capabilities_hint(false),
    do:
      "a role runs every hand it holds without a card — the soul asks before cloning when it must; destructive actions stay with the soul."

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

      <%!-- Offered once the roster is read: the roles to start from and
            the soul's leave are what the form is about. --%>
      <div class="flex justify-end">
        <form
          :if={@loaded}
          phx-submit="editor_create_role"
          phx-target={@myself}
          class="flex flex-col items-end gap-1"
        >
          <div class="flex items-center gap-2">
            <input
              type="text"
              name="name"
              placeholder="new-role"
              pattern="[a-z0-9_-]+"
              required
              class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-blue-500 w-44 font-mono"
            />
            <select
              name="start_from"
              title="Which role's hands the new one starts with"
              class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-300 focus:border-blue-500"
            >
              <option value="">start with no hands</option>
              <option
                :for={role <- @roles}
                value={role["name"]}
                selected={role["name"] == @default_start}
              >
                start from {role["title"]}
              </option>
            </select>
            <button
              type="submit"
              class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
            >
              + New role
            </button>
          </div>
          <p class="text-[10px] text-gray-600">
            The soul is given leave to clone into the new role in the same step.
          </p>
        </form>
      </div>

      <div
        :if={@loaded and @soul == nil}
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
        roles={@roles}
        model_status={Map.get(@model_status, @soul["catalyst_ref"])}
        athanor={@athanor}
      />

      <div :if={@roles != []} class="space-y-3 border-l border-gray-800 pl-4 ml-2">
        <.agent_card
          :for={role <- @roles}
          myself={@myself}
          agent={role}
          models_by_provider={@models_by_provider}
          tool_actions={@tool_actions || []}
          is_soul={false}
          athanor={@athanor}
        />
      </div>
      
    <!-- Prompt editor modal — shared by the soul and the roles -->
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
  attr :roles, :list, default: []
  attr :model_status, :any, default: nil
  attr :athanor, :any, default: nil

  defp agent_card(assigns) do
    assigns =
      assigns
      |> assign(:current_provider, agent_provider_for_select(assigns.agent))
      |> assign(:tool_policy, assigns.agent["tool_policy"] || %{})
      |> assign(:removal, removal(assigns.agent))
      |> assign(:disabled?, assigns.agent["disabled"] == true)

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
          <form phx-change="editor_update_field" phx-target={@myself} class="space-y-1">
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
              title="Out of the closet — the soul does not see this role until it is enabled"
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
            phx-click="editor_delete"
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            data-confirm={elem(@removal, 1) <> @agent["name"] <> "'?"}
            class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
          >
            {elem(@removal, 0)}
          </button>
        </div>
      </div>

      <form :if={!@is_soul} phx-change="editor_update_field" phx-target={@myself} class="space-y-1">
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="field" value="description" />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500">Description</label>
        <input
          type="text"
          name="value"
          value={@agent["description"]}
          phx-debounce="blur"
          placeholder="One line the soul reads when choosing this role…"
          class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
      </form>

      <div
        :if={@is_soul and @model_status}
        class="flex flex-wrap items-center gap-2 text-[11px]"
      >
        <span :if={match?({:ready, _}, @model_status)} class="text-emerald-400">
          Model connected
        </span>
        <span :if={match?({:needs_key, _}, @model_status)} class="text-amber-300">
          Not connected — the model has no key yet
        </span>
        <span :if={match?({:missing, _}, @model_status)} class="text-amber-300">
          The model's catalyst is not installed here yet
        </span>
        <button
          :if={match?({status, _} when status in [:ready, :needs_key], @model_status)}
          type="button"
          phx-click="open_consent"
          phx-value-ref={elem(@model_status, 1)}
          class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] font-medium text-white"
        >
          {if match?({:ready, _}, @model_status), do: "Change the key", else: "Connect a model"}
        </button>
      </div>

      <form phx-change="editor_set_model" phx-target={@myself}>
        <input type="hidden" name="name" value={@agent["name"]} />
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</p>
        <select
          name="value"
          aria-label="Model"
          class="w-full md:w-1/2 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 focus:border-blue-500 focus:outline-none"
        >
          <option value="" selected={is_nil(@agent["model"])}>
            Inherit from parent
          </option>
          <%= for {provider, models} <- @models_by_provider, models != [] do %>
            <optgroup label={provider}>
              <option
                :for={m <- models}
                value={"#{provider}::#{m}"}
                selected={@agent["model"] == m and @current_provider == provider}
              >
                {m}
              </option>
            </optgroup>
          <% end %>
        </select>
      </form>

      <%!-- Which roles the soul may clone into: one glob each on its allowlist. --%>
      <div :if={@is_soul} id="aqua-clone-strip">
        <p class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">
          Roles this soul can clone into
        </p>
        <p :if={@roles == []} class="text-[11px] text-gray-600">
          No roles yet — add one above.
        </p>
        <div :if={@roles != []} class="flex flex-wrap gap-x-4 gap-y-1">
          <label
            :for={role <- @roles}
            class="flex items-center gap-1.5 text-[11px] text-gray-400 cursor-pointer"
          >
            <input
              type="checkbox"
              checked={Map.has_key?(@tool_policy, AquaAgent.clone_glob(role["name"]))}
              phx-click="editor_toggle_clone"
              phx-target={@myself}
              phx-value-role={role["name"]}
              class="rounded bg-gray-900 border-gray-600"
            />
            {role["title"]}
            <code class="text-gray-600 font-mono">{role["name"]}</code>
          </label>
        </div>
      </div>

      <div>
        <div class="flex items-center justify-between mb-1">
          <p class="block text-[10px] uppercase tracking-wider text-gray-500">
            Capabilities
            <span class="normal-case text-gray-600">
              — {capabilities_hint(@is_soul)} {allowlist_owner(@athanor)}
            </span>
          </p>
          <% auto_count = count_auto(@tool_policy, @tool_actions) %>
          <span :if={auto_count > 0} class="text-[10px] text-gray-600">{auto_count} won't ask</span>
        </div>

        <div class="border border-gray-800 rounded divide-y divide-gray-800/60 max-h-[28rem] overflow-y-auto">
          <%= for {kind, kind_label, kind_chip, kind_strip} <- kind_sections(@is_soul) do %>
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
                    {count_in_list(@tool_policy, rows)}/{length(rows)}
                  </span>
                </summary>

                <%= for {tool, action} <- rows do %>
                  <% key = "#{tool}.#{action}" %>
                  <% val = @tool_policy[key] %>
                  <div class="px-3 py-1 flex items-center gap-2 bg-gray-950/40">
                    <label class="flex items-center gap-1.5 flex-1 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={val != nil}
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
                    <%= cond do %>
                      <% is_nil(val) -> %>
                        <span></span>
                      <% kind == :read -> %>
                        <span class="text-[10px] text-emerald-400/70">runs without asking</span>
                      <% kind == :destructive -> %>
                        <span class="text-[10px] text-gray-500">always asks</span>
                      <% not @is_soul -> %>
                        <span class="text-[10px] text-amber-300/70">runs in this role</span>
                      <% true -> %>
                        <.auto_ask_toggle
                          myself={@myself}
                          agent={@agent["name"]}
                          key={key}
                          value={val}
                        />
                    <% end %>
                  </div>
                <% end %>
              </details>
            <% end %>
          <% end %>
        </div>
        <label class="flex items-center gap-2 mt-2 text-[11px] text-gray-400 cursor-pointer">
          <input
            type="checkbox"
            checked={Map.has_key?(@tool_policy, "native_search")}
            phx-click="editor_toggle_native"
            phx-target={@myself}
            phx-value-name={@agent["name"]}
            class="rounded bg-gray-900 border-gray-600"
          /> Native search (model-side web grounding) — runs inside the provider without asking
        </label>
      </div>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :agent, :string, required: true
  attr :key, :string, required: true
  attr :value, :string, required: true

  # Two-state ask/auto toggle for a write- or execute-kind capability.
  defp auto_ask_toggle(assigns) do
    ~H"""
    <div class="flex items-center gap-0.5">
      <button
        :for={{label, mode} <- [{"ask", "ask"}, {"auto", "auto"}]}
        type="button"
        phx-click="editor_set_capability_mode"
        phx-target={@myself}
        phx-value-name={@agent}
        phx-value-key={@key}
        phx-value-mode={mode}
        class={[
          "px-1.5 py-0.5 text-[10px] rounded font-medium",
          if(@value == mode,
            do:
              if(mode == "auto", do: "bg-slate-600 text-white", else: "bg-amber-800 text-amber-100"),
            else: "bg-gray-900 text-gray-500 hover:bg-gray-800 hover:text-gray-300"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end
end
