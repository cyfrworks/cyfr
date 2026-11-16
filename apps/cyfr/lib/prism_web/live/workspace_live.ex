# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WorkspaceLive do
  @moduledoc """
  One of the person's workspace threads, at `/a/<athanor>/workspace/<id>`:
  a page of the `:athanor` session drawn full over the desktop
  (`overlay: :full`, `PrismWeb.Layouts`), so the desktop's frames keep
  running under it, and the shelf, Aqua's panel (`PrismWeb.AquaPanelLive`,
  which opens the daily thread over it) and the system layer stand above
  it. It opens from the thread's pointer or a report on the daily thread,
  and from the panel's list, and its close goes back to the desktop.

  On the desk the conversation stands at the side and the thread's steps
  and what it made stand in the middle; in the hand the conversation is
  the screen and the steps and results are a second tab. The conversation
  is the thread pane (`PrismWeb.ThreadPaneLive`) on this thread, so words
  typed there go to this thread's own soul, and a crew member's thread
  under it opens in that pane, which leads back. The steps are
  `Aqua.steps/3`'s, worded by Aqua (`Aqua.Steps`), read again as the
  thread's events arrive; the results are the posts of Aqua's that hold a
  picture, a file or a link, which the pane reads and tells this page
  (`{:results, …}`, `{:result, …}`), drawn as the pane draws a post. The
  thread's title and state are `Aqua.workspace/2`'s, worded by
  `PrismWeb.DisplayHelpers.work_state/1`, read again when the person's
  list announces the thread (`Cyfr.Bus.ThreadListed`) and when a card
  opens or is decided in the athanor (`Cyfr.Bus.Notify`), since a card in
  a crew member's thread under it moves it too.

  Every read is the person's own: the page's context is focused on the
  athanor in its address, which only its person may focus
  (`PrismWeb.Focus`), and the thread is read under it, so a thread of
  another athanor, a thread of another kind, an id of none or a thread
  deleted while it is open reads as not here, with nothing of it shown
  and no composer. A grant the pane's turn needs is asked in this
  page's system layer (`PrismWeb.SystemLayer`), under its context.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias Cyfr.Bus.{ThreadEvent, ThreadListed}
  alias PrismWeb.{SystemLayer, ThreadPaneLive}

  # The thread's events after which its steps are read again.
  @step_events [
    :message,
    :tool_activity,
    :turn_started,
    :turn_paused,
    :turn_finished,
    :approval_resolved
  ]

  @tabs ~w(conversation work)

  @doc "The address of workspace thread `id` in the athanor `route` names."
  @spec address(String.t() | nil, String.t()) :: String.t()
  def address(route, id) when is_binary(id),
    do: PrismWeb.Focus.path(route, "/workspace/" <> URI.encode(id, &URI.char_unreserved?/1))

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    ctx = socket.assigns.context

    socket =
      socket
      |> assign(:page_title, "Workspace thread")
      |> assign(:overlay, :full)
      |> assign(:tab, "conversation")
      |> assign(:steps, [])
      |> assign(:results, [])
      |> assign(:pane, nil)

    case Aqua.workspace(ctx, id) do
      {:ok, work} ->
        if connected?(socket), do: follow(ctx, id)

        {:ok,
         socket
         |> assign(:work, work)
         |> assign(:page_title, work.title)
         |> read_steps()}

      {:error, _none} ->
        {:ok, assign(socket, :work, :none)}
    end
  end

  # The thread's own events, the person's list of threads and the
  # athanor's notifications.
  defp follow(ctx, id) do
    actor = Sanctum.Context.actor(ctx)
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, id))
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.threads(actor, ctx.user_id))
    Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
  end

  # The steps as they stand; a read that fails keeps what was shown.
  defp read_steps(%{assigns: %{work: %{id: id}}} = socket) do
    case Aqua.steps(socket.assigns.context, id) do
      {:ok, steps} -> assign(socket, :steps, steps)
      {:error, _unread} -> socket
    end
  end

  defp read_steps(socket), do: socket

  # The thread as it is now; one that cannot be found is gone, and the
  # page says so, with nothing of it left.
  defp read_work(%{assigns: %{work: %{id: id}}} = socket) do
    case Aqua.workspace(socket.assigns.context, id) do
      {:ok, work} -> socket |> assign(:work, work) |> assign(:page_title, work.title)
      {:error, :not_found} -> gone(socket)
      {:error, _unread} -> socket
    end
  end

  defp read_work(socket), do: socket

  defp gone(socket) do
    socket
    |> assign(:work, :none)
    |> assign(:page_title, "Workspace thread")
    |> assign(:steps, [])
    |> assign(:results, [])
    |> assign(:pane, nil)
  end

  # ============================================================================
  # Events
  # ============================================================================

  # In the hand: the conversation, or the steps and results.
  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("tab", _params, socket), do: {:noreply, socket}

  # ============================================================================
  # The thread, the person's list and what the pane tells this page
  # ============================================================================

  @impl true
  def handle_info(
        %ThreadEvent{thread_id: id, kind: kind},
        %{assigns: %{work: %{id: id}}} = socket
      )
      when kind in @step_events,
      do: {:noreply, read_steps(socket)}

  def handle_info(%ThreadEvent{}, socket), do: {:noreply, socket}

  def handle_info(
        %ThreadListed{kind: :workspace, id: id},
        %{assigns: %{work: %{id: id}}} = socket
      ),
      do: {:noreply, read_work(socket)}

  def handle_info(%ThreadListed{kind: :removed, id: id}, %{assigns: %{work: %{id: id}}} = socket),
    do: {:noreply, gone(socket)}

  def handle_info(%ThreadListed{}, socket), do: {:noreply, socket}

  def handle_info(%Cyfr.Bus.Notify{kind: kind}, socket)
      when kind in [:approval_pending, :approval_resolved],
      do: {:noreply, read_work(socket)}

  def handle_info(%Cyfr.Bus.Notify{}, socket), do: {:noreply, socket}

  def handle_info({:pane, _pane, {:ready, pid, _thread_id}}, socket) when is_pid(pid),
    do: {:noreply, assign(socket, :pane, pid)}

  # What the thread made, as the pane read it: the newest first.
  def handle_info(
        {:pane, _pane, {:results, id, results}},
        %{assigns: %{work: %{id: id}}} = socket
      ),
      do: {:noreply, assign(socket, :results, Enum.sort_by(results, & &1.seq, :desc))}

  def handle_info({:pane, _pane, {:result, id, result}}, %{assigns: %{work: %{id: id}}} = socket) do
    results = [result | Enum.reject(socket.assigns.results, &(&1.id == result.id))]
    {:noreply, assign(socket, :results, Enum.sort_by(results, & &1.seq, :desc))}
  end

  # The pane asked for a thread: this one, or a crew member's thread under
  # it, which the pane shows and leads back from; another workspace thread
  # is its own layer.
  def handle_info({:pane, _pane, {:open_thread, id}}, %{assigns: %{work: %{id: id}}} = socket),
    do: {:noreply, switch_pane(socket, id)}

  def handle_info({:pane, _pane, {:open_thread, id}}, %{assigns: %{work: %{}}} = socket)
      when is_binary(id) do
    case Aqua.workspace(socket.assigns.context, id) do
      {:ok, _another} ->
        {:noreply, push_navigate(socket, to: address(socket.assigns.athanor_route, id))}

      {:error, _not_a_workspace} ->
        {:noreply, switch_pane(socket, id)}
    end
  end

  # A grant the pane's turn needs: asked in this page's layer, under this
  # page's context; the outcome goes back to the pane.
  def handle_info({:pane, _pane, {:grant, pid, prompt}}, socket) when is_pid(pid),
    do: {:noreply, SystemLayer.relay(socket, pid, prompt)}

  def handle_info({:pane, _pane, _message}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # The pane is turned to a thread by message once it has reported in; the
  # pane reads the thread under its own context, so an id of another
  # athanor's shows nothing.
  defp switch_pane(%{assigns: %{pane: pid}} = socket, id) when is_pid(pid) do
    send(pid, {:switch_thread, id})
    socket
  end

  defp switch_pane(socket, _id), do: socket

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(%{work: :none} = assigns) do
    ~H"""
    <div id="workspace" class="flex h-full min-h-0 flex-col">
      <.close_row athanor_route={@athanor_route} />
      <div
        id="workspace-missing"
        class="flex flex-1 flex-col items-center justify-center gap-2 p-4 text-sm text-gray-400"
      >
        <p>This workspace thread is not here.</p>
        <.link
          navigate={PrismWeb.DesktopLive.path(@athanor_route)}
          class="text-blue-400 hover:underline"
        >
          Back to the desktop
        </.link>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="workspace" class="flex h-full min-h-0 flex-col" data-state={@work.state}>
      <.close_row athanor_route={@athanor_route}>
        <h1 id="workspace-title" class="min-w-0 truncate text-sm font-semibold text-gray-100">
          {@work.title}
        </h1>
        <span
          id="workspace-state"
          data-state={@work.state}
          class={[
            "shrink-0 text-xs",
            if(@work.waits_on_you, do: "text-amber-300", else: "text-gray-400")
          ]}
        >
          {work_state(@work.state)}
        </span>
      </.close_row>

      <%!-- In the hand, the conversation and the steps and results are two
            tabs; on the desk both stand, and the tabs are not drawn. --%>
      <div
        id="workspace-tabs"
        role="tablist"
        aria-label="This workspace thread"
        class="flex shrink-0 border-b border-gray-800/60 md:hidden"
      >
        <button
          :for={{tab, words} <- [{"conversation", "Conversation"}, {"work", "Steps and results"}]}
          id={"workspace-tab-" <> tab}
          type="button"
          role="tab"
          aria-selected={to_string(@tab == tab)}
          aria-controls={"workspace-" <> tab}
          phx-click="tab"
          phx-value-tab={tab}
          class={[
            "min-h-10 flex-1 border-b-2 px-3 text-sm",
            if(@tab == tab,
              do: "border-blue-400 text-gray-100",
              else: "border-transparent text-gray-400 hover:text-gray-200"
            )
          ]}
        >
          {words}
        </button>
      </div>

      <div class="flex min-h-0 flex-1">
        <section
          id="workspace-work"
          aria-label="Steps and results"
          class={[
            "min-h-0 min-w-0 flex-1 space-y-6 overflow-y-auto p-4 lg:p-6",
            @tab != "work" && "max-md:hidden"
          ]}
        >
          <div>
            <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500">Steps</h2>
            <p :if={@steps == []} id="workspace-no-steps" class="text-sm text-gray-500">
              Nothing done yet.
            </p>
            <ol :if={@steps != []} id="workspace-steps" class="space-y-1">
              <li
                :for={step <- @steps}
                id={"workspace-step-" <> step.id}
                data-status={step.status}
                class="flex min-h-6 items-center gap-2 text-sm"
              >
                <span
                  class={["h-2 w-2 shrink-0 rounded-full", step_dot(step.status)]}
                  aria-hidden="true"
                ></span>
                <span class="min-w-0 flex-1 truncate text-gray-200">{step.sentence}</span>
                <span :if={words = step_words(step.status)} class="shrink-0 text-xs text-gray-400">
                  {words}
                </span>
                <span class="shrink-0 text-xs text-gray-500">{format_time(step.at, :time)}</span>
              </li>
            </ol>
          </div>

          <div>
            <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500">
              Results
            </h2>
            <p :if={@results == []} id="workspace-no-results" class="text-sm text-gray-500">
              Nothing made yet.
            </p>
            <div :if={@results != []} id="workspace-results" class="space-y-3">
              <ThreadPaneLive.message_bubble
                :for={result <- @results}
                id={"workspace-result-" <> result.id}
                role="assistant"
                content={result.content}
                author="Aqua"
                attachments={result.attachments}
                attachment_href={&ThreadPaneLive.attachment_path(@athanor_route, result.id, &1)}
                links={result.links}
              />
            </div>
          </div>
        </section>

        <%!-- The conversation, at the side on the desk: the thread pane on
              this thread, whose sends go to its own soul. --%>
        <aside
          id="workspace-conversation"
          aria-label="Conversation"
          class={[
            "flex min-h-0 min-w-0 flex-col max-md:flex-1 md:w-[26rem] md:shrink-0 md:border-l md:border-gray-800/60",
            @tab != "conversation" && "max-md:hidden"
          ]}
        >
          {live_render(@socket, ThreadPaneLive,
            id: "workspace-pane",
            container: {:div, class: "flex min-h-0 flex-1 flex-col"},
            session: %{
              "athanor_id" => @context.athanor_id,
              "thread_id" => @work.id,
              "ui_mode" => @ui_mode
            }
          )}
        </aside>
      </div>

      <.live_component
        module={SystemLayer}
        id={SystemLayer.layer_id()}
        context={@context}
        athanor_route={@athanor_route}
      />
    </div>
    """
  end

  attr :athanor_route, :any, required: true
  slot :inner_block

  # The layer's own row: the thread's name and state, and the close that
  # returns to the desktop.
  defp close_row(assigns) do
    ~H"""
    <div class="flex h-10 shrink-0 items-center gap-2 border-b border-gray-800/60 pl-4 pr-2">
      {render_slot(@inner_block)}
      <span class="flex-1"></span>
      <.link
        id="workspace-close"
        navigate={PrismWeb.DesktopLive.path(@athanor_route)}
        class="rounded-md px-2 py-0.5 text-sm text-gray-400 hover:bg-gray-800 hover:text-gray-200"
        aria-label="Back to the desktop"
        title="Back to the desktop"
      >
        ×
      </.link>
    </div>
    """
  end

  # A step's state as a person reads it beside its sentence; a step done
  # says nothing more.
  defp step_words(:running), do: "Running"
  defp step_words(:waiting), do: "Waits for you"
  defp step_words(:failed), do: "Failed"
  defp step_words(:refused), do: "Refused"
  defp step_words(:skipped), do: "Skipped"
  defp step_words(_done), do: nil

  defp step_dot(:running), do: "bg-green-400 animate-pulse"
  defp step_dot(:waiting), do: "bg-amber-400"
  defp step_dot(:done), do: "bg-green-400"
  defp step_dot(:failed), do: "bg-red-400"
  defp step_dot(_other), do: "bg-gray-500"
end
