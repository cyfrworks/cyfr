# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AgentsLive do
  @moduledoc """
  The athanor's AQUA agents — orchestrators and their sub-agents, each with
  a prompt, a model and a capability allowlist. The definitions are the
  athanor's own (`Compendium.AquaTemplate` seeds them); every member edits
  the same ones, through the `aqua` tool.

  This is also where a person connects a model: the soul's catalyst
  needs an API key bound to it before AQUA can answer, and "Connect a
  model" opens the consent sheet for that catalyst — reachable in `lite`,
  so a box that never opens `dev` still gets its key in.
  """

  use PrismWeb, :live_view

  alias PrismWeb.AgentsLive.Catalog

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:active_nav, "agents")
      |> assign(:editor_agents, [])
      |> assign(:editor_editing_prompt, nil)
      |> assign(:editor_prompt_content, "")
      |> assign(:models_by_provider, %{})
      |> assign(:catalyst_refs, %{})
      |> assign(:models_loaded, false)
      |> assign(:tool_actions, nil)
      |> assign(:consent_sheet_ref, nil)
      |> assign(:model_status, %{})
      |> assign(:personal_source, nil)

    socket =
      if connected?(socket) and socket.assigns[:context],
        do: socket |> load_editor_agents() |> load_models(),
        else: socket

    {:ok, socket}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("editor_create_role", %{"name" => name} = params, socket)
      when name != "" do
    # A create targets the tree the form picked — yours or the estate's.
    # `owner_ctx/3` honors the stamp only against this page's own sources,
    # and a form without the picker (one tree) creates where you are. A
    # role is flat in the closet; the soul is never created here.
    ctx = owner_ctx(socket, name, params["owner"])

    case call_aqua(ctx, %{
           "action" => "create",
           "name" => name,
           "title" => name,
           "description" => "Clone into #{name} for…",
           "content" => "# #{name}\n\nYou are AQUA in the #{name} role."
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_create_role", _params, socket), do: {:noreply, socket}

  # `field` names exactly what the forms edit — never an arbitrary map key.
  # An unconstrained key could shadow the "action" verb (a later duplicate
  # key wins in a map literal) or write any guide field, the system prompt
  # included, from an event the templates never send.
  @editable_fields ~w(title description)

  def handle_event(
        "editor_update_field",
        %{"name" => name, "field" => field, "value" => value} = params,
        socket
      )
      when field in @editable_fields do
    ctx = owner_ctx(socket, name, params["owner"])
    args = Map.merge(%{field => value}, %{"action" => "update", "name" => name})

    case call_aqua(ctx, args) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_update_field", _params, socket), do: {:noreply, socket}

  def handle_event("editor_delete", %{"name" => name} = params, socket) do
    ctx = owner_ctx(socket, name, params["owner"])

    case call_aqua(ctx, %{
           "action" => "delete",
           "name" => name
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
    end
  end

  # Add/remove a `tool.action` from an agent's allowlist. On add, the default
  # value is "auto" for reads (they never ask) and "ask" for everything else —
  # with the kind DERIVED here from the action's own annotation
  # (`Aqua.Actions.kind_for/2`), never taken off the wire: a client-sent
  # kind could name any action "read" and write "auto" for it with no card
  # ever shown. A key that resolves to no known action is refused.
  def handle_event(
        "editor_toggle_capability",
        %{"name" => agent_name, "key" => key} = params,
        socket
      ) do
    owner = params["owner"]
    agent = find_agent(socket, agent_name, owner)
    current = (agent && agent["tool_policy"]) || %{}

    cond do
      Map.has_key?(current, key) ->
        {:noreply, update_agent_tool_policy(socket, agent_name, owner, Map.delete(current, key))}

      resolved_kind(key) == nil ->
        {:noreply, put_flash(socket, :error, "Unknown capability: #{key}")}

      true ->
        default = if resolved_kind(key) == :read, do: "auto", else: "ask"

        {:noreply,
         update_agent_tool_policy(socket, agent_name, owner, Map.put(current, key, default))}
    end
  end

  # Toggle a write/execute capability between "ask" (request approval) and
  # "auto" (run without asking). Destructive/external rows don't expose this
  # in the UI — and the rule is enforced here, on the derived kind: "auto"
  # for a destructive or external action is refused whatever the client sent.
  def handle_event(
        "editor_set_capability_mode",
        %{"name" => agent_name, "key" => key, "mode" => mode} = params,
        socket
      )
      when mode in ["ask", "auto"] do
    if mode == "auto" and not auto_permitted?(key) do
      {:noreply, put_flash(socket, :error, "#{key} always asks — it cannot be set to auto")}
    else
      owner = params["owner"]
      agent = find_agent(socket, agent_name, owner)
      current = (agent && agent["tool_policy"]) || %{}
      {:noreply, update_agent_tool_policy(socket, agent_name, owner, Map.put(current, key, mode))}
    end
  end

  # Toggle the provider-native search grant. It is an ordinary policy key
  # that coexists with the rest of the allowlist; the formula appends the
  # native tool when the key is "auto".
  def handle_event("editor_toggle_native", %{"name" => agent_name} = params, socket) do
    owner = params["owner"]
    agent = find_agent(socket, agent_name, owner)
    current = (agent && agent["tool_policy"]) || %{}

    new_policy =
      if Map.has_key?(current, "native_search"),
        do: Map.delete(current, "native_search"),
        else: Map.put(current, "native_search", "auto")

    {:noreply, update_agent_tool_policy(socket, agent_name, owner, new_policy)}
  end

  def handle_event("editor_edit_prompt", %{"name" => name} = params, socket) do
    owner = params["owner"]
    agent = find_agent(socket, name, owner)
    content = if agent, do: agent["content"] || "", else: ""

    {:noreply,
     socket
     # Name AND owner: the save must land in the tree the prompt was read
     # from, and two trees can hold the same name.
     |> assign(:editor_editing_prompt, %{"name" => name, "owner" => owner})
     |> assign(:editor_prompt_content, content)}
  end

  def handle_event("editor_cancel_prompt", _params, socket) do
    {:noreply, assign(socket, :editor_editing_prompt, nil)}
  end

  def handle_event("editor_save_prompt", %{"content" => content}, socket) do
    %{"name" => name, "owner" => owner} = socket.assigns.editor_editing_prompt
    ctx = owner_ctx(socket, name, owner)

    case call_aqua(ctx, %{
           "action" => "update",
           "name" => name,
           "content" => content
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, assign(socket, :editor_editing_prompt, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_set_model", %{"name" => agent_name, "value" => value} = params, socket) do
    ctx = owner_ctx(socket, agent_name, params["owner"])

    result =
      case Catalog.decode_model_choice(value) do
        {:inherit} ->
          call_aqua(ctx, %{
            "action" => "update",
            "name" => agent_name,
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
            "name" => agent_name,
            "model" => model,
            "catalyst_ref" => catalyst_ref
          })

        :noop ->
          {:ok, :noop}
      end

    send(self(), :editor_refresh)

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
  # PubSub fan-in
  # ============================================================================

  # The consent sheet for an orchestrator's catalyst: the model gets its key.
  def handle_event("open_consent", %{"ref" => ref}, socket) when is_binary(ref) and ref != "" do
    {:noreply, assign(socket, :consent_sheet_ref, ref)}
  end

  @impl true
  def handle_info({:consent_granted, _ref, _result}, socket) do
    {:noreply,
     socket
     |> assign(:consent_sheet_ref, nil)
     |> put_flash(:info, "Model connected.")
     |> load_editor_agents()
     |> load_models()}
  end

  def handle_info({:consent_sheet_closed, _ref}, socket) do
    {:noreply, assign(socket, :consent_sheet_ref, nil)}
  end

  def handle_info(:editor_refresh, socket) do
    {:noreply, load_editor_agents(socket)}
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

  # ============================================================================
  # Helpers
  # ============================================================================

  # The action's kind, resolved from its own annotation — the server-owned
  # fact the ask/auto decisions above key on. nil for a key the catalog
  # has never heard of (fail closed).
  defp resolved_kind(key) when is_binary(key) do
    case String.split(key, ".", parts: 2) do
      [tool, action] -> Aqua.Actions.kind_for(tool, action)
      _ -> nil
    end
  end

  # "auto" (run with no card) is only for kinds a card can be skipped for.
  # Destructive and external actions always ask; an unknown kind refuses.
  defp auto_permitted?(key), do: resolved_kind(key) in [:read, :write, :execute]

  defp update_agent_tool_policy(socket, agent_name, owner, new_policy) do
    case call_aqua(owner_ctx(socket, agent_name, owner), %{
           "action" => "update",
           "name" => agent_name,
           "tool_policy" => new_policy
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        socket

      {:error, reason} ->
        put_flash(socket, :error, "Update failed: #{error_message(reason)}")
    end
  end

  defp load_editor_agents(socket) do
    ctx = socket.assigns[:context]

    # One call: list with detail carries every field this editor shows.
    # The get-per-guide loop this replaces was an N+1 fired from eight
    # handlers — renaming a title cost 1+N tool calls.
    # Your closet and the estate's, each tagged with the tree it lives in.
    # The tag is what every write here reads back to reach the right tree:
    # editing your soul while focused on a group must not materialize
    # `aqua.md` into the group's overlay.
    agents =
      for owner <- agent_sources(ctx),
          g <- agents_of(ctx, owner),
          g["type"] in ["soul", "role"] do
        %{
          "name" => g["name"],
          "owner" => owner,
          "mine?" => owner != ctx.athanor_id,
          "title" => g["title"] || g["name"],
          "type" => g["type"],
          "description" => g["description"] || "",
          "model" => g["model"],
          "catalyst_ref" => g["catalyst_ref"],
          "tool_policy" => g["tool_policy"] || %{},
          "content" => g["content"] || ""
        }
      end

    socket
    |> assign(:editor_agents, agents)
    |> assign(:personal_source, ctx |> agent_sources() |> Enum.find(&(&1 != ctx.athanor_id)))
    |> assign(:model_status, Aqua.AgentConfig.model_status(ctx, agents))
    |> ensure_tool_actions_loaded()
  end

  # Enumerate `(tool, [actions...])` from the live MCP registry — populated
  # once per editor open, so the matrix UI can render real (tool, action)
  # pairs the user can toggle. native_search is included as a bare key
  # (no actions enum) since the formula treats it specially.
  defp ensure_tool_actions_loaded(socket) do
    if socket.assigns[:tool_actions] do
      socket
    else
      tool_actions = Catalog.enumerate_tool_actions()
      assign(socket, :tool_actions, tool_actions)
    end
  end

  # The allowlist is the athanor's, not the person's: in a group, a member
  # editing it is editing what the agent may do for everyone in it.
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

  defp load_models(socket) do
    case PrismWeb.ModelCatalog.load(socket.assigns.context) do
      :ok -> socket
      :unavailable -> assign(socket, :models_loaded, true)
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-sm font-medium text-gray-200">AQUA</h3>
          <p class="text-[11px] text-gray-500 mt-0.5">
            One assistant — the soul — and the roles it clones into: a stance and a set of hands for one kind of work.
          </p>
        </div>
        <form phx-submit="editor_create_role" class="flex items-center gap-2">
          <input
            type="text"
            name="name"
            placeholder="new-role"
            pattern="[a-z0-9_-]+"
            required
            class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-blue-500 w-44 font-mono"
          />
          <select
            :if={@personal_source}
            name="owner"
            title="Which closet the new role lives in — yours follows you into every estate"
            class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-300 focus:border-blue-500"
          >
            <option value={@context.athanor_id}>in this estate</option>
            <option value={@personal_source}>in your athanor</option>
          </select>
          <button
            type="submit"
            class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
          >
            + New role
          </button>
        </form>
      </div>

      <.live_loading
        :if={@editor_agents == [] and not @models_loaded}
        message="Loading AQUA…"
      />

      <div
        :if={@editor_agents == [] and @models_loaded}
        class="text-xs text-gray-500 py-8 text-center border border-dashed border-gray-800 rounded"
      >
        No assistant here. The soul ships with the server — reset the AQUA tree to restore it.
      </div>

      <.agent_card
        :for={soul <- Enum.filter(@editor_agents, &(&1["type"] == "soul"))}
        agent={soul}
        models_by_provider={@models_by_provider}
        tool_actions={@tool_actions || []}
        is_soul={true}
        model_status={Map.get(@model_status, soul["catalyst_ref"])}
        athanor={@athanor}
      />

      <div
        :if={Enum.any?(@editor_agents, &(&1["type"] == "role"))}
        class="space-y-3 border-l border-gray-800 pl-4 ml-2"
      >
        <.agent_card
          :for={role <- Enum.filter(@editor_agents, &(&1["type"] == "role"))}
          agent={role}
          models_by_provider={@models_by_provider}
          tool_actions={@tool_actions || []}
          is_soul={false}
          athanor={@athanor}
        />
      </div>
      
    <!-- Consent sheet: bind a vault entry to the soul's model -->
      <div :if={@consent_sheet_ref} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/60"></div>
        <div class="relative w-full max-w-lg max-h-[80vh] overflow-y-auto rounded-lg border border-gray-800 bg-gray-900 p-4 shadow-xl">
          <.live_component
            module={PrismWeb.ConsentSheetComponent}
            id={"consent-#{@consent_sheet_ref}"}
            ref={@consent_sheet_ref}
            context={@context}
            athanor_route={@athanor_route}
            athanor_name={@athanor && @athanor.name}
          />
        </div>
      </div>
      
    <!-- Prompt editor modal — shared by the soul and the roles -->
      <div
        :if={@editor_editing_prompt}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/70"
        phx-click="editor_cancel_prompt"
      >
        <div
          class="w-full max-w-2xl max-h-[80vh] flex flex-col rounded-lg bg-gray-900 border border-gray-800 shadow-2xl"
          phx-click-away="editor_cancel_prompt"
        >
          <div class="flex items-center justify-between border-b border-gray-800 px-4 py-3">
            <h3 class="text-sm font-medium text-gray-200">
              Edit prompt —
              <code class="font-mono text-blue-400">{@editor_editing_prompt["name"]}</code>
            </h3>
            <button
              type="button"
              phx-click="editor_cancel_prompt"
              class="text-gray-500 hover:text-gray-300"
              aria-label="Close"
            >
              ×
            </button>
          </div>
          <form phx-submit="editor_save_prompt" class="flex-1 flex flex-col p-4 gap-3">
            <textarea
              name="content"
              class="flex-1 rounded bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-gray-200 font-mono resize-none focus:border-blue-500 focus:outline-none"
              rows="20"
            >{@editor_prompt_content}</textarea>
            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                phx-click="editor_cancel_prompt"
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
        </div>
      </div>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :models_by_provider, :map, required: true
  attr :tool_actions, :list, required: true
  attr :is_soul, :boolean, default: false
  attr :model_status, :any, default: nil
  attr :athanor, :any, default: nil

  defp agent_card(assigns) do
    assigns =
      assigns
      |> assign(:current_provider, agent_provider_for_select(assigns.agent))
      |> assign(:tool_policy, assigns.agent["tool_policy"] || %{})

    ~H"""
    <div class="rounded-lg border border-gray-800 bg-gray-900/60 p-4 space-y-3">
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1 min-w-0">
          <form phx-change="editor_update_field" class="space-y-1">
            <input type="hidden" name="name" value={@agent["name"]} />
            <input type="hidden" name="owner" value={@agent["owner"]} />
            <input type="hidden" name="field" value="title" />
            <input
              type="text"
              name="value"
              value={@agent["title"]}
              phx-debounce="500"
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
              {if @is_soul, do: "soul", else: "role"}
            </span>
            <code class="text-[11px] text-gray-500 font-mono">{@agent["name"]}</code>
            <span
              :if={@agent["mine?"]}
              class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-emerald-900/40 text-emerald-300"
              title="Lives in your own athanor — edits here follow it, not this estate"
            >
              yours
            </span>
          </div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            type="button"
            phx-click="editor_edit_prompt"
            phx-value-name={@agent["name"]}
            phx-value-owner={@agent["owner"]}
            class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
          >
            Edit prompt
          </button>
          <button
            type="button"
            phx-click="editor_delete"
            phx-value-name={@agent["name"]}
            phx-value-owner={@agent["owner"]}
            data-confirm={"Delete agent '#{@agent["name"]}'?"}
            class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
          >
            Delete
          </button>
        </div>
      </div>

      <form :if={!@is_soul} phx-change="editor_update_field" class="space-y-1">
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="owner" value={@agent["owner"]} />
        <input type="hidden" name="field" value="description" />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500">Description</label>
        <input
          type="text"
          name="value"
          value={@agent["description"]}
          phx-debounce="500"
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

      <form phx-change="editor_set_model">
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="owner" value={@agent["owner"]} />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500 mb-1">Model</label>
        <select
          name="value"
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

      <div>
        <div class="flex items-center justify-between mb-1">
          <label class="block text-[10px] uppercase tracking-wider text-gray-500">
            Capabilities
            <span class="normal-case text-gray-600">
              — reads run without asking; everything else asks unless you mark it "auto". {allowlist_owner(
                @athanor
              )}
            </span>
          </label>
          <% auto_count = count_auto(@tool_policy, @tool_actions) %>
          <span :if={auto_count > 0} class="text-[10px] text-gray-600">{auto_count} won't ask</span>
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
                        phx-value-name={@agent["name"]}
                        phx-value-owner={@agent["owner"]}
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
                      <% true -> %>
                        <.auto_ask_toggle
                          agent={@agent["name"]}
                          owner={@agent["owner"]}
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
            phx-value-name={@agent["name"]}
            phx-value-owner={@agent["owner"]}
            class="rounded bg-gray-900 border-gray-600"
          /> Native search (model-side web grounding) — runs inside the provider without asking
        </label>
      </div>
    </div>
    """
  end

  attr :agent, :string, required: true
  attr :owner, :string, default: nil
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
        phx-value-name={@agent}
        phx-value-owner={@owner}
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

  # One owner for the aqua call and its key normalization.
  defp call_aqua(ctx, args), do: Aqua.AgentConfig.call_aqua(ctx, args)

  # Whose `aqua/` trees this page shows: the person's own, then the estate
  # in focus. One tree when they are the same.
  defp agent_sources(nil), do: []

  defp agent_sources(%Sanctum.Context{} = ctx) do
    [personal_athanor(ctx), ctx.athanor_id] |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp personal_athanor(%Sanctum.Context{user_id: user_id}) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{personal_athanor_id: id}} -> id
      _ -> nil
    end
  end

  defp personal_athanor(_), do: nil

  defp agents_of(ctx, owner) do
    with {:ok, read_ctx} <- Sanctum.Context.refocus(ctx, owner),
         {:ok, result} <- call_aqua(read_ctx, %{"action" => "list", "detail" => true}) do
      result["guides"] || []
    else
      _ -> []
    end
  end

  # The context a write to `name` must run under: the tree that agent lives
  # in. `owner` arrives stamped on the event by the card (or create form)
  # that named the agent — and is honored ONLY when it is one of this
  # page's own sources (your personal athanor, the estate in focus), so a
  # forged event cannot name an arbitrary athanor. Without a stamp, the
  # loaded roster answers, the focused estate's entry winning a name
  # collision; a name the page does not know falls back to focus.
  defp owner_ctx(socket, name, owner) do
    ctx = socket.assigns.context

    target =
      cond do
        is_binary(owner) and owner != "" and owner in agent_sources(ctx) ->
          owner

        match?(%{"owner" => o} when is_binary(o), find_agent(socket, name, nil)) ->
          find_agent(socket, name, nil)["owner"]

        true ->
          nil
      end

    with true <- is_binary(target),
         {:ok, refocused} <- Sanctum.Context.refocus(ctx, target) do
      refocused
    else
      _ -> ctx
    end
  end

  # One agent out of the loaded roster, by identity — name AND owner. With
  # no owner, the focused estate's entry wins a collision, mirroring what a
  # bare `@mention` means.
  defp find_agent(socket, name, owner) do
    agents = socket.assigns[:editor_agents] || []

    if is_binary(owner) and owner != "" do
      Enum.find(agents, &(&1["name"] == name and &1["owner"] == owner))
    else
      focus = socket.assigns.context && socket.assigns.context.athanor_id

      Enum.find(agents, &(&1["name"] == name and &1["owner"] == focus)) ||
        Enum.find(agents, &(&1["name"] == name))
    end
  end

  # Count of capabilities the agent runs without asking that *aren't* reads —
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
end
