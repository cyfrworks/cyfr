defmodule PrismWeb.AgentOverlayLive do
  @moduledoc """
  AQUA agent overlay — Cmd+K invokable, context-aware sheet.

  A first-class LiveView (not a tincture iframe — see plan rationale) that
  lives in the layout's portal slot and is summoned via Cmd+K. The full
  AgentLive at `/agent` remains the rich chat surface; this overlay is the
  Phase 3 MVP: simple compose + streaming response, with the user's
  current page context (route + focused resource) attached to every turn.

  ## Sheet states

  - `closed` — overlay hidden
  - `peek` — composer visible only (~140px)
  - `half` — conversation + composer (~55vh)
  - `full` — near-fullscreen (~100vh - 2.5rem)

  Persisted to localStorage by the JS hook so the user's preference
  survives reloads.

  ## Active context

  Subscribes to `PrismWeb.ActiveContext.topic(session_id)` on mount and
  receives `{:active_context, ctx}` updates whenever the user navigates.
  The latest context is included in the formula input map under the
  `"active_context"` key so AQUA always knows where the user is.
  """

  use PrismWeb, :live_view

  require Logger

  @compile {:no_warn_undefined, [Opus, Opus.ExecutionEventBuffer]}

  @agent_ref "formula:local.aqua"

  @impl true
  def mount(_params, session, socket) do
    socket =
      case PrismWeb.AuthHelpers.authenticate_session(session["session_token"]) do
        {:ok, _user, ctx} ->
          if connected?(socket) do
            sid = PrismWeb.ActiveContext.session_id(session)

            if sid,
              do: Phoenix.PubSub.subscribe(Emissary.PubSub, PrismWeb.ActiveContext.topic(sid))
          end

          socket
          |> assign(:context, ctx)
          |> assign(:authenticated, true)

        _ ->
          assign(socket, :authenticated, false)
      end

    {:ok,
     socket
     |> assign(:sheet_state, "closed")
     |> assign(:active_context, nil)
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:running, false)
     |> assign(:streaming_text, "")
     |> assign(:current_execution_id, nil)
     |> assign(:orchestrator, nil)
     |> assign(:orchestrators_loaded, false), layout: false}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("set_state", %{"state" => state}, socket)
      when state in ~w(closed peek half full) do
    socket =
      if state != "closed" and not socket.assigns.orchestrators_loaded do
        load_orchestrator(socket)
      else
        socket
      end

    {:noreply, assign(socket, :sheet_state, state)}
  end

  def handle_event("toggle", _params, socket) do
    next =
      case socket.assigns.sheet_state do
        "closed" -> "half"
        _ -> "closed"
      end

    socket =
      if next != "closed" and not socket.assigns.orchestrators_loaded do
        load_orchestrator(socket)
      else
        socket
      end

    {:noreply, assign(socket, :sheet_state, next)}
  end

  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("submit", %{"message" => raw}, socket) do
    message = String.trim(raw)
    cond do
      not socket.assigns[:authenticated] ->
        {:noreply, socket}

      message == "" ->
        {:noreply, socket}

      socket.assigns.running ->
        {:noreply, socket}

      socket.assigns.orchestrator == nil ->
        {:noreply, put_flash(socket, :error, "No orchestrators configured.")}

      true ->
        invoke_agent(socket, message)
    end
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info({:active_context, ctx}, socket) do
    {:noreply, assign(socket, :active_context, ctx)}
  end

  def handle_info({:execution_event, %{type: "emit", data: data}}, socket) do
    chunk = data["text"] || data[:text] || ""
    {:noreply, assign(socket, :streaming_text, socket.assigns.streaming_text <> chunk)}
  end

  def handle_info({:execution_event, %{type: "complete"}}, socket) do
    final = String.trim(socket.assigns.streaming_text)

    messages =
      if final != "" do
        socket.assigns.messages ++
          [%{role: "assistant", content: final, timestamp: DateTime.utc_now()}]
      else
        socket.assigns.messages
      end

    if socket.assigns.current_execution_id do
      Opus.ExecutionEventBuffer.unsubscribe(
        socket.assigns.current_execution_id,
        socket.assigns.context
      )
    end

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:streaming_text, "")
     |> assign(:running, false)
     |> assign(:current_execution_id, nil)}
  end

  def handle_info({:execution_event, %{type: "error", data: data}}, socket) do
    err = data["message"] || data[:message] || inspect(data)

    messages =
      socket.assigns.messages ++
        [%{role: "error", content: err, timestamp: DateTime.utc_now()}]

    if socket.assigns.current_execution_id do
      Opus.ExecutionEventBuffer.unsubscribe(
        socket.assigns.current_execution_id,
        socket.assigns.context
      )
    end

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:streaming_text, "")
     |> assign(:running, false)
     |> assign(:current_execution_id, nil)}
  end

  def handle_info({:stream_started, exec_id}, socket) do
    if opus_available?() do
      Opus.ExecutionEventBuffer.subscribe(exec_id, socket.assigns.context)
    end

    {:noreply, assign(socket, :current_execution_id, exec_id)}
  end

  def handle_info({:stream_error, reason}, socket) do
    err = "Execution failed: #{inspect(reason)}"

    messages =
      socket.assigns.messages ++
        [%{role: "error", content: err, timestamp: DateTime.utc_now()}]

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:running, false)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[AgentOverlayLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Agent invocation
  # ============================================================================

  defp invoke_agent(socket, message) do
    ctx = socket.assigns.context
    orchestrator = socket.assigns.orchestrator
    orchestrator_name = orchestrator["name"]

    user_msg = %{
      role: "user",
      content: message,
      timestamp: DateTime.utc_now()
    }

    system_prompt = PrismWeb.AgentLive.build_system_prompt(ctx, orchestrator_name)

    resolved_catalyst =
      case Prism.AgentConfig.resolve_catalyst(ctx, orchestrator["catalyst_ref"]) do
        {:ok, ref} -> ref
        _ -> orchestrator["catalyst_ref"]
      end

    sub_agents =
      Prism.AgentConfig.sub_agent_definitions(
        ctx,
        orchestrator_name,
        resolved_catalyst,
        orchestrator["model"]
      )

    input =
      %{
        "task" => message,
        "system" => system_prompt,
        "sub_agents" => sub_agents,
        "catalyst_ref" => resolved_catalyst,
        "model" => orchestrator["model"]
      }
      |> maybe_put_active_context(socket.assigns.active_context)

    lv = self()

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      result =
        Emissary.MCP.ToolRegistry.call("execution", ctx, %{
          "action" => "run_stream",
          "reference" => @agent_ref,
          "input" => input
        })

      case result do
        {:ok, %{execution_id: eid}} -> send(lv, {:stream_started, eid})
        {:ok, %{"execution_id" => eid}} -> send(lv, {:stream_started, eid})
        {:error, reason} -> send(lv, {:stream_error, reason})
      end
    end)

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [user_msg])
     |> assign(:input, "")
     |> assign(:running, true)
     |> assign(:streaming_text, "")}
  end

  defp maybe_put_active_context(input, nil), do: input
  defp maybe_put_active_context(input, ctx), do: Map.put(input, "active_context", ctx)

  defp opus_available?, do: Code.ensure_loaded?(Opus.ExecutionEventBuffer)

  defp load_orchestrator(socket) do
    ctx = socket.assigns[:context]

    if ctx == nil do
      assign(socket, :orchestrators_loaded, true)
    else
      orchestrator =
        case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
               "action" => "list",
               "type" => "orchestrator"
             }) do
          {:ok, result} ->
            guides = result[:guides] || result["guides"] || []

            case guides do
              [%{} = first | _] ->
                name = first[:name] || first["name"]

                case Emissary.MCP.ToolRegistry.call("aqua", ctx, %{
                       "action" => "get",
                       "name" => name
                     }) do
                  {:ok, detail} ->
                    %{
                      "name" => name,
                      "title" => detail[:title] || detail["title"] || name,
                      "catalyst_ref" => detail[:catalyst_ref] || detail["catalyst_ref"],
                      "model" => detail[:model] || detail["model"]
                    }

                  _ ->
                    nil
                end

              _ ->
                nil
            end

          _ ->
            nil
        end

      socket
      |> assign(:orchestrator, orchestrator)
      |> assign(:orchestrators_loaded, true)
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="agent-overlay-root"
      phx-hook="AgentOverlay"
      data-state={@sheet_state}
    >
      <div
        :if={@sheet_state != "closed"}
        class="fixed inset-0 z-40 bg-black/40"
        phx-click="set_state"
        phx-value-state="closed"
      ></div>

      <section
        :if={@sheet_state != "closed"}
        class={[
          "fixed inset-x-0 bottom-0 z-40 flex flex-col",
          "border-t border-gray-700 bg-gray-900 shadow-2xl rounded-t-xl",
          "transition-all duration-200",
          sheet_class(@sheet_state)
        ]}
      >
        <header class="flex items-center justify-between border-b border-gray-800 px-4 py-2">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-gray-200">A.Q.U.A.</span>
            <span :if={@orchestrator} class="text-xs text-gray-500">
              {@orchestrator["title"] || @orchestrator["name"]}
            </span>
            <span :if={!@orchestrator && @orchestrators_loaded} class="text-xs text-amber-400">
              No orchestrator configured
            </span>
          </div>
          <div class="flex items-center gap-1">
            <.sheet_toggle current={@sheet_state} value="peek" label="Peek" />
            <.sheet_toggle current={@sheet_state} value="half" label="Half" />
            <.sheet_toggle current={@sheet_state} value="full" label="Full" />
            <button
              phx-click="set_state"
              phx-value-state="closed"
              class="ml-1 rounded p-1 text-gray-500 hover:bg-gray-800 hover:text-gray-300"
              title="Close (Esc)"
            >
              <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </header>

        <div :if={@sheet_state in ["half", "full"]} class="flex-1 overflow-y-auto px-4 py-3 space-y-3">
          <div :if={@messages == [] and @streaming_text == ""} class="flex items-center justify-center h-full text-sm text-gray-500">
            Ask anything — I know what page you're on.
          </div>

          <%= for msg <- @messages do %>
            <.message_bubble role={msg.role} content={msg.content} />
          <% end %>

          <.message_bubble :if={@streaming_text != ""} role="assistant" content={@streaming_text} />

          <div :if={@running and @streaming_text == ""} class="flex items-center gap-2 text-xs text-gray-500">
            <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-blue-400" />
            <span>Thinking…</span>
          </div>
        </div>

        <form
          phx-submit="submit"
          phx-change="update_input"
          class="border-t border-gray-800 p-3 flex gap-2"
        >
          <textarea
            name="message"
            rows="2"
            placeholder="Ask AQUA…"
            class="flex-1 resize-none rounded-md border border-gray-700 bg-gray-950 px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none"
            autofocus
            disabled={@running or !@orchestrator}
          >{@input}</textarea>
          <button
            type="submit"
            disabled={@running or !@orchestrator or @input == ""}
            class="self-end rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {if @running, do: "…", else: "Send"}
          </button>
        </form>

        <div :if={@active_context && @active_context.route} class="border-t border-gray-800 px-3 py-1.5 text-[11px] text-gray-500">
          Context: {@active_context.route}
          <span :if={focus_label(@active_context)}> — {focus_label(@active_context)}</span>
        </div>
      </section>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  defp message_bubble(assigns) do
    ~H"""
    <div class={[
      "flex",
      role_align(@role)
    ]}>
      <div class={[
        "max-w-[85%] rounded-lg px-3 py-2 text-sm whitespace-pre-wrap break-words",
        role_class(@role)
      ]}>
        {@content}
      </div>
    </div>
    """
  end

  attr :current, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp sheet_toggle(assigns) do
    ~H"""
    <button
      phx-click="set_state"
      phx-value-state={@value}
      class={[
        "rounded px-2 py-1 text-[11px] uppercase tracking-wider",
        if(@current == @value,
          do: "bg-blue-900/50 text-blue-300",
          else: "text-gray-500 hover:bg-gray-800 hover:text-gray-300"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp sheet_class("peek"), do: "h-[140px]"
  defp sheet_class("half"), do: "h-[55vh]"
  defp sheet_class("full"), do: "h-[calc(100vh-2.5rem)]"
  defp sheet_class(_), do: "h-0"

  defp role_align("user"), do: "justify-end"
  defp role_align(_), do: "justify-start"

  defp role_class("user"), do: "bg-indigo-600 text-white"
  defp role_class("error"), do: "bg-red-900/40 text-red-300 border border-red-800"
  defp role_class(_), do: "bg-gray-800 text-gray-200"

  defp focus_label(%{focused_resource: {kind, id}}) when is_atom(kind) and is_binary(id) do
    "#{kind}: #{short(id)}"
  end

  defp focus_label(_), do: nil

  defp short(s) when is_binary(s) and byte_size(s) > 20, do: String.slice(s, 0, 20) <> "…"
  defp short(s), do: s
end
