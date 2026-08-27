# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AgentsLive do
  @moduledoc """
  The athanor's AQUA agents — orchestrators and their sub-agents, each with
  a prompt, a model and a capability allowlist. The definitions are the
  athanor's own (`Compendium.AquaTemplate` seeds them); every member edits
  the same ones, through the `aqua` tool.

  This is also where a person connects a model: an orchestrator's catalyst
  needs an API key bound to it before AQUA can answer, and "Connect a
  model" opens the consent sheet for that catalyst — reachable in `lite`,
  so a box that never opens `dev` still gets its key in.
  """

  use PrismWeb, :live_view

  require Logger

  alias PrismWeb.AgentsLive.Catalog

  @list_models_ref "formula:local.list-models"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:active_nav, "agents")
      |> assign(:editor_agents, [])
      |> assign(:editor_editing_prompt, nil)
      |> assign(:editor_prompt_content, "")
      |> assign(:editor_creating_sub_for, nil)
      |> assign(:models_by_provider, %{})
      |> assign(:catalyst_refs, %{})
      |> assign(:models_loaded, false)
      |> assign(:tool_actions, nil)
      |> assign(:consent_sheet_ref, nil)
      |> assign(:model_status, %{})

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
  def handle_event("editor_create_orchestrator", %{"name" => name}, socket) when name != "" do
    ctx = socket.assigns.context

    case call_aqua(ctx, %{
           "action" => "create",
           "name" => name,
           "title" => name,
           "content" => "# #{name}\n\nYou are #{name}."
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_create_orchestrator", _params, socket), do: {:noreply, socket}

  def handle_event("editor_create_sub_agent", %{"parent" => parent, "name" => name}, socket)
      when name != "" do
    ctx = socket.assigns.context

    case call_aqua(ctx, %{
           "action" => "create",
           "parent" => parent,
           "name" => name,
           "title" => name,
           "description" => "Spawn a #{name} specialist.",
           "content" => "# #{name}\n\nYou are the #{name} agent."
         }) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, assign(socket, :editor_creating_sub_for, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_create_sub_agent", _params, socket), do: {:noreply, socket}

  def handle_event("editor_toggle_sub_form", %{"parent" => parent}, socket) do
    next = if socket.assigns.editor_creating_sub_for == parent, do: nil, else: parent
    {:noreply, assign(socket, :editor_creating_sub_for, next)}
  end

  def handle_event(
        "editor_update_field",
        %{"name" => name, "field" => field, "value" => value},
        socket
      ) do
    ctx = socket.assigns.context
    args = %{"action" => "update", "name" => name, field => value}

    case call_aqua(ctx, args) do
      {:ok, _} ->
        send(self(), :editor_refresh)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{error_message(reason)}")}
    end
  end

  def handle_event("editor_delete", %{"name" => name}, socket) do
    ctx = socket.assigns.context

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
  # value is "auto" for reads (they never ask) and "ask" for everything else.
  def handle_event(
        "editor_toggle_capability",
        %{"name" => agent_name, "key" => key} = params,
        socket
      ) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = (agent && agent["tool_policy"]) || %{}

    new_policy =
      if Map.has_key?(current, key) do
        Map.delete(current, key)
      else
        default = if params["kind"] == "read", do: "auto", else: "ask"
        Map.put(current, key, default)
      end

    {:noreply, update_agent_tool_policy(socket, agent_name, new_policy)}
  end

  # Toggle a write/execute capability between "ask" (request approval) and
  # "auto" (run without asking). Reads and destructive/external rows don't
  # expose this — but guard the value space anyway.
  def handle_event(
        "editor_set_capability_mode",
        %{"name" => agent_name, "key" => key, "mode" => mode},
        socket
      )
      when mode in ["ask", "auto"] do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = (agent && agent["tool_policy"]) || %{}
    {:noreply, update_agent_tool_policy(socket, agent_name, Map.put(current, key, mode))}
  end

  # Toggle the provider-native search grant. It is an ordinary policy key
  # that coexists with the rest of the allowlist; the formula appends the
  # native tool when the key is "auto".
  def handle_event("editor_toggle_native", %{"name" => agent_name}, socket) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == agent_name))
    current = (agent && agent["tool_policy"]) || %{}

    new_policy =
      if Map.has_key?(current, "native_search"),
        do: Map.delete(current, "native_search"),
        else: Map.put(current, "native_search", "auto")

    {:noreply, update_agent_tool_policy(socket, agent_name, new_policy)}
  end

  def handle_event("editor_edit_prompt", %{"name" => name}, socket) do
    agent = Enum.find(socket.assigns.editor_agents, &(&1["name"] == name))
    content = if agent, do: agent["content"] || "", else: ""

    {:noreply,
     socket
     |> assign(:editor_editing_prompt, name)
     |> assign(:editor_prompt_content, content)}
  end

  def handle_event("editor_cancel_prompt", _params, socket) do
    {:noreply, assign(socket, :editor_editing_prompt, nil)}
  end

  def handle_event("editor_save_prompt", %{"content" => content}, socket) do
    ctx = socket.assigns.context
    name = socket.assigns.editor_editing_prompt

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

  def handle_event("editor_set_model", %{"name" => agent_name, "value" => value}, socket) do
    ctx = socket.assigns.context

    case Catalog.decode_model_choice(value) do
      {:inherit} ->
        call_aqua(ctx, %{
          "action" => "update",
          "name" => agent_name,
          "model" => nil,
          "catalyst_ref" => nil
        })

      {:model, provider, model} ->
        catalyst_ref =
          case socket.assigns[:catalyst_refs][provider] do
            nil -> "catalyst:moonmoon69.#{provider}"
            ref -> Regex.replace(~r/:\d+\.\d+\.\d+$/, ref, "")
          end

        call_aqua(ctx, %{
          "action" => "update",
          "name" => agent_name,
          "model" => model,
          "catalyst_ref" => catalyst_ref
        })

      :noop ->
        :ok
    end

    send(self(), :editor_refresh)
    {:noreply, socket}
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
    raw = result[:result] || result["result"] || result

    decoded =
      cond do
        is_binary(raw) ->
          case Jason.decode(raw) do
            {:ok, m} -> m
            _ -> %{}
          end

        is_map(raw) ->
          raw

        true ->
          %{}
      end

    models_by_provider =
      (decoded["models"] || %{})
      |> Map.new(fn {provider, value} -> {provider, Catalog.normalize_provider_models(value)} end)

    {:noreply,
     socket
     |> assign(:models_by_provider, models_by_provider)
     |> assign(:catalyst_refs, decoded["refs"] || %{})
     |> assign(:models_loaded, true)}
  end

  def handle_info({:list_models_result, {:error, _reason}}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info({:task_timeout, :models}, socket) do
    {:noreply, assign(socket, :models_loaded, true)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[AgentsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp update_agent_tool_policy(socket, agent_name, new_policy) do
    case call_aqua(socket.assigns.context, %{
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

    agents =
      case ctx && call_aqua(ctx, %{"action" => "list"}) do
        {:ok, result} ->
          guides = result["guides"] || []

          Enum.flat_map(guides, fn g ->
            name = g["name"]
            type = g["type"]

            if type in ["orchestrator", "sub-agent"] do
              case call_aqua(ctx, %{
                     "action" => "get",
                     "name" => name
                   }) do
                {:ok, detail} ->
                  [
                    %{
                      "name" => name,
                      "title" => detail["title"] || name,
                      "type" => type,
                      "parent" => detail["parent"],
                      "description" => detail["description"] || "",
                      "model" => detail["model"],
                      "catalyst_ref" => detail["catalyst_ref"],
                      "tool_policy" => detail["tool_policy"] || %{},
                      "content" => detail["content"] || ""
                    }
                  ]

                _ ->
                  []
              end
            else
              []
            end
          end)

        _ ->
          []
      end

    socket
    |> assign(:editor_agents, agents)
    |> assign(:model_status, Prism.AgentConfig.model_status(ctx, agents))
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
    # ref shape: "catalyst:moonmoon69.claude" or with version suffix
    case Regex.run(~r/catalyst:[^.]+\.([^:]+)/, ref) do
      [_, provider] -> provider
      _ -> nil
    end
  end

  defp load_models(socket) do
    if Cyfr.Execution.available?() do
      lv = self()
      ctx = socket.assigns.context

      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        result =
          Emissary.MCP.ToolRegistry.call_external("execution", ctx, %{
            "action" => "run",
            "reference" => @list_models_ref,
            "input" => %{}
          })

        send(lv, {:list_models_result, result})
      end)

      # Guard rail — if list-models hangs the picker still settles on the
      # agent's stored model instead of staying empty.
      Process.send_after(lv, {:task_timeout, :models}, 60_000)
      socket
    else
      assign(socket, :models_loaded, true)
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
          <h3 class="text-sm font-medium text-gray-200">Agents</h3>
          <p class="text-[11px] text-gray-500 mt-0.5">
            Orchestrators are top-level guides. Sub-agents inherit context from their parent and are spawned on demand.
          </p>
        </div>
        <form phx-submit="editor_create_orchestrator" class="flex items-center gap-2">
          <input
            type="text"
            name="name"
            placeholder="new-orchestrator"
            pattern="[a-z0-9_-]+"
            required
            class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-blue-500 w-44 font-mono"
          />
          <button
            type="submit"
            class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
          >
            + New orchestrator
          </button>
        </form>
      </div>

      <.live_loading
        :if={@editor_agents == [] and not @models_loaded}
        message="Loading agents…"
      />

      <div
        :if={@editor_agents == [] and @models_loaded}
        class="text-xs text-gray-500 py-8 text-center border border-dashed border-gray-800 rounded"
      >
        No agents configured. Create your first orchestrator above.
      </div>

      <%= for orch <- Enum.filter(@editor_agents, &(&1["type"] == "orchestrator")) do %>
        <% sub_agents = Enum.filter(@editor_agents, &(&1["parent"] == orch["name"])) %>
        <.agent_card
          agent={orch}
          models_by_provider={@models_by_provider}
          tool_actions={@tool_actions || []}
          is_orchestrator={true}
          model_status={Map.get(@model_status, orch["catalyst_ref"])}
          athanor={@athanor}
        />
        <div :if={sub_agents != []} class="ml-6 space-y-3 border-l border-gray-800 pl-4">
          <.agent_card
            :for={sub <- sub_agents}
            agent={sub}
            models_by_provider={@models_by_provider}
            tool_actions={@tool_actions || []}
            is_orchestrator={false}
            athanor={@athanor}
          />
        </div>

        <div class="ml-6 pl-4">
          <button
            :if={@editor_creating_sub_for != orch["name"]}
            type="button"
            phx-click="editor_toggle_sub_form"
            phx-value-parent={orch["name"]}
            class="text-[11px] text-blue-400 hover:text-blue-300"
          >
            + Add sub-agent
          </button>
          <form
            :if={@editor_creating_sub_for == orch["name"]}
            phx-submit="editor_create_sub_agent"
            class="flex items-center gap-2"
          >
            <input type="hidden" name="parent" value={orch["name"]} />
            <input
              type="text"
              name="name"
              placeholder="sub-agent-name"
              pattern="[a-z0-9_-]+"
              required
              autofocus
              class="rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 font-mono w-48"
            />
            <button
              type="submit"
              class="rounded bg-blue-600 hover:bg-blue-500 px-2 py-1 text-[11px] text-white"
            >
              Create
            </button>
            <button
              type="button"
              phx-click="editor_toggle_sub_form"
              phx-value-parent={orch["name"]}
              class="text-[11px] text-gray-500 hover:text-gray-300"
            >
              Cancel
            </button>
          </form>
        </div>
      <% end %>
      
    <!-- Consent sheet: bind a Connection to an orchestrator's model -->
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
      
    <!-- Prompt editor modal — shared by orchestrators and sub-agents -->
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
              Edit prompt — <code class="font-mono text-blue-400">{@editor_editing_prompt}</code>
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
  attr :is_orchestrator, :boolean, default: false
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
              if(@is_orchestrator,
                do: "bg-purple-900/40 text-purple-300",
                else: "bg-blue-900/40 text-blue-300"
              )
            ]}>
              {if @is_orchestrator, do: "orchestrator", else: "sub-agent"}
            </span>
            <code class="text-[11px] text-gray-500 font-mono">{@agent["name"]}</code>
            <code :if={@agent["parent"]} class="text-[11px] text-gray-600 font-mono">
              ↳ parent: {@agent["parent"]}
            </code>
          </div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            type="button"
            phx-click="editor_edit_prompt"
            phx-value-name={@agent["name"]}
            class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
          >
            Edit prompt
          </button>
          <button
            type="button"
            phx-click="editor_delete"
            phx-value-name={@agent["name"]}
            data-confirm={"Delete agent '#{@agent["name"]}'?"}
            class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
          >
            Delete
          </button>
        </div>
      </div>

      <form :if={!@is_orchestrator} phx-change="editor_update_field" class="space-y-1">
        <input type="hidden" name="name" value={@agent["name"]} />
        <input type="hidden" name="field" value="description" />
        <label class="block text-[10px] uppercase tracking-wider text-gray-500">Description</label>
        <input
          type="text"
          name="value"
          value={@agent["description"]}
          phx-debounce="500"
          placeholder="One-line description shown to the orchestrator…"
          class="w-full rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
        />
      </form>

      <div
        :if={@is_orchestrator and @model_status}
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
                        phx-value-key={key}
                        phx-value-kind={Atom.to_string(kind)}
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
                        <.auto_ask_toggle agent={@agent["name"]} key={key} value={val} />
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
            class="rounded bg-gray-900 border-gray-600"
          /> Native search (model-side web grounding) — runs inside the provider without asking
        </label>
      </div>
    </div>
    """
  end

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

  # Every aqua-tool call goes through here so guide maps arrive with ONE key
  # spelling (see Prism.AgentConfig.stringify_deep/1) — in-process results
  # are atom-keyed, wire round-trips string-keyed, and consumers must not
  # carry `m[:k] || m["k"]` pairs.
  defp call_aqua(ctx, args) do
    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, args) do
      {:ok, result} -> {:ok, Prism.AgentConfig.stringify_deep(result)}
      other -> other
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
