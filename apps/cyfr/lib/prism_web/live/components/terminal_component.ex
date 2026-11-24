# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TerminalComponent do
  @moduledoc """
  A program's terminal, CYFR's own frame around it: the chrome names the
  program and offers Close, keeping it running when no one watches, and,
  for a program installed from the Aqua page, the way back to Aqua; inside
  it the `Terminal` hook (`assets/js/terminal/frame.js`) draws what the
  program writes with the vendored xterm.js, the terminal type the program
  is told it runs on (`Prima.LocusBackends.terminal_type/0`). Nothing the program writes
  reaches the chrome, and the frame asks the person for no secret. What
  the frame sends the program is what the person
  types and the terminal's own answers to the program's standard queries,
  never text the program chose. When the program ends, the screen the
  page drew stays, read-only, beside the ending, until the person closes
  the frame.

  The frame holds no byte of the session: the page that shows it attaches
  to the session (`Opus.Programs.attach/2`) when the hook says it stands
  (`terminal_ready`), answers it what was printed before, and hands each
  later write to the hook as an event (`terminal_output`), so the page's
  assigns, and so its crash report or termination log, carry none. What
  the person types (`terminal_input`) is a parameter
  `Prima.Sanitizer.filter_parameters/0` names, so no event log shows it.

  ## The page that shows it

  This module alone drives the frame. A page that shows one mounts it
  (`on_mount PrismWeb.TerminalComponent`, behind the page's context
  guard), subscribes to its person's `Cyfr.Bus.programs/2` topic, shows a
  session with `show/2`, gives it up with `detach/1` and renders
  `frame/1` of its `@terminal`. The frame's events, the session's output
  and ending, and a Close's answer are handled here. The page keeps what
  is its own: what else follows an ending (`c:terminal_ended/2`) and
  where it goes when the person closes the frame
  (`c:terminal_dismissed/1`).
  """

  use Phoenix.Component

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, push_event: 3, put_flash: 3, put_private: 3]

  alias Phoenix.LiveView.Socket

  @doc """
  An ending was heard, of any of the person's sessions. `ended` is the
  shown terminal as it ended, once, at its first ending, and nil for any
  other.
  """
  @callback terminal_ended(Socket.t(), ended :: map() | nil) :: Socket.t()

  @doc "The person closed the frame of a program that ended: its screen goes."
  @callback terminal_dismissed(Socket.t()) :: Socket.t()

  # What the frame sends while the session it shows is being closed, which
  # answers nothing until its close has.
  @asked_of_session ~w(terminal_input terminal_written terminal_resize terminal_keep terminal_close)
  @endings [:exited, :restarted, :closed, :idle, :row_changed, :standing, :unanswered]

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:terminal, nil)
     |> put_private(:terminal_delivery, nil)
     |> attach_hook(__MODULE__, :handle_event, &on_event/3)
     |> attach_hook(__MODULE__, :handle_info, &on_info/2)}
  end

  @doc """
  Show a session's frame: `shown` names its `session`, the program's
  `name`, the `back` link and whatever else the page keeps beside them.
  The one shown before is detached, and this one is attached once its
  hook stands (`terminal_ready`). The one shown already, named alike, stays
  as it is; named for another place on the page it moves there, as a
  frame of its own whose hook attaches afresh, so no delivery the last
  one was handed holds the next back.
  """
  @spec show(Socket.t(), map()) :: Socket.t()
  def show(
        %{assigns: %{terminal: %{session: session} = terminal}} = socket,
        %{session: session} = shown
      ) do
    if Map.take(terminal, Map.keys(shown)) == shown do
      socket
    else
      if connected?(socket), do: Opus.Programs.detach(socket.assigns.context, session)
      terminal = %{Map.merge(terminal, shown) | attached: false, moved: terminal.moved + 1}
      socket |> put_private(:terminal_delivery, nil) |> assign(:terminal, terminal)
    end
  end

  def show(socket, shown) do
    state = %{kept: false, ended: nil, attached: false, closing: nil, moved: 0}

    socket
    |> detach()
    |> put_private(:terminal_delivery, nil)
    |> assign(:terminal, Map.merge(shown, state))
  end

  @doc "Show no frame: the page detaches, which ends nothing."
  @spec detach(Socket.t()) :: Socket.t()
  def detach(%{assigns: %{terminal: %{session: session}}} = socket) do
    if connected?(socket), do: Opus.Programs.detach(socket.assigns.context, session)
    assign(socket, :terminal, nil)
  end

  def detach(socket), do: socket

  # The frame's hook stands: the page attaches to the session, sets the
  # frame's size and answers what was printed before.
  defp on_event("terminal_ready", %{"session" => session} = params, socket) do
    with %{session: ^session, ended: nil} = terminal <- socket.assigns.terminal,
         {:ok, %{tail: %{bytes: tail}, kept: kept}} <-
           Opus.Programs.attach(socket.assigns.context, session) do
      _ = resize(socket, session, params)
      terminal = %{terminal | kept: kept, attached: true}
      {:halt, %{data: Base.encode64(tail)}, assign(socket, :terminal, terminal)}
    else
      {:error, reason} -> {:halt, %{}, ended(socket, session, reason)}
      _other -> {:halt, %{}, socket}
    end
  end

  # A session being closed answers nothing until its close has, so the
  # page asks it nothing meanwhile.
  defp on_event(
         event,
         %{"session" => session},
         %{assigns: %{terminal: %{session: session, closing: task}}} = socket
       )
       when is_reference(task) and event in @asked_of_session,
       do: {:halt, %{}, socket}

  # Each piece the hook sends is answered before it sends the next, so
  # what a person pastes waits in the browser, not here.
  defp on_event("terminal_input", %{"session" => session, "terminal_input" => data}, socket)
       when is_binary(data) do
    case Opus.Programs.input(socket.assigns.context, session, data) do
      :ok ->
        {:halt, %{}, socket}

      {:error, reason} when reason in [:unavailable, :too_large] ->
        {:halt, %{}, put_flash(socket, :error, "The program did not take that; type it again.")}

      {:error, reason} ->
        {:halt, %{}, ended(socket, session, reason)}
    end
  end

  # The browser drew the delivery it names: the page forwards only the
  # token of the delivery it pushed last, and the session hands more when
  # that is the one it waits on.
  defp on_event("terminal_written", %{"session" => session, "delivery" => delivery}, socket)
       when is_binary(delivery) do
    with %{session: ^session} <- socket.assigns.terminal,
         ^delivery <- socket.private.terminal_delivery,
         {:error, reason} <- Opus.Programs.taken(socket.assigns.context, session, delivery) do
      {:halt, ended(socket, session, reason)}
    else
      _taken_or_not_the_last -> {:halt, socket}
    end
  end

  defp on_event("terminal_resize", %{"session" => session} = params, socket) do
    _ = resize(socket, session, params)
    {:halt, socket}
  end

  defp on_event("terminal_keep", %{"session" => session} = params, socket) do
    kept = params["kept"] == "true"

    case Opus.Programs.keep(socket.assigns.context, session, kept) do
      :ok -> {:halt, kept(socket, session, kept)}
      {:error, reason} -> {:halt, ended(socket, session, reason)}
    end
  end

  defp on_event("terminal_dismiss", _params, socket),
    do: {:halt, socket.view.terminal_dismissed(socket)}

  defp on_event("terminal_close", %{"session" => session}, socket) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)
    page = self()

    {:ok, task} =
      Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
        result = PrismWeb.Ops.run_to_end(fn -> Opus.Programs.close(ctx, session) end)
        send(page, {:terminal_closed, tag, session, result})
      end)

    {:halt, closing(socket, session, task)}
  end

  defp on_event(_event, _params, socket), do: {:cont, socket}

  # What the shown session's program wrote goes straight to the frame's
  # hook, and is kept nowhere here: the next output, or the tail that
  # replaces what the frame shows when more came than it was kept.
  defp on_info({Opus.Programs, session, {kind, delivery, %{bytes: bytes}}}, socket)
       when kind in [:bytes, :tail] do
    case socket.assigns.terminal do
      %{session: ^session} ->
        event = if kind == :tail, do: "terminal_tail", else: "terminal_output"
        data = %{session: session, delivery: delivery, data: Base.encode64(bytes)}
        # Kept out of the assigns, so a delivery renders nothing.
        {:halt, socket |> put_private(:terminal_delivery, delivery) |> push_event(event, data)}

      _other ->
        {:halt, socket}
    end
  end

  defp on_info({Opus.Programs, session, {:ended, reason}}, socket),
    do: {:halt, ended(socket, session, reason)}

  # The person's running sessions moved, here or on another surface; the
  # one shown ended, though its end never reached this page (it died).
  defp on_info(%Cyfr.Bus.Program{kind: :ended, session: session, reason: reason}, socket),
    do: {:halt, ended(socket, session, reason)}

  defp on_info({:terminal_closed, _tag, _session, _result} = answer, socket),
    do: {:halt, elem(handle_info(answer, socket), 1)}

  # A Close's task lost before it answered gives the terminal back. The
  # session says its ending itself, if it reached one.
  defp on_info(
         {:DOWN, task, :process, _pid, _reason},
         %{assigns: %{terminal: %{closing: task} = terminal}} = socket
       ) do
    socket = assign(socket, :terminal, %{terminal | closing: nil})

    if terminal.ended,
      do: {:halt, socket},
      else:
        {:halt, put_flash(socket, :error, "Failed: #{PrismWeb.Ops.error_message(:unavailable)}")}
  end

  defp on_info(_message, socket), do: {:cont, socket}

  @doc false
  # A Close's answer, taken only under the focus it was asked under.
  def handle_info({:terminal_closed, tag, session, result}, socket),
    do: CyfrWeb.ContextGuard.deliver(socket, tag, &{:noreply, closed(&1, session, result)})

  defp resize(socket, session, %{"rows" => rows, "cols" => cols})
       when is_integer(rows) and is_integer(cols),
       do: Opus.Programs.resize(socket.assigns.context, session, rows, cols)

  defp resize(_socket, _session, _params), do: {:error, :invalid_size}

  # What a Close answered, once it did.
  defp closed(socket, session, {:ok, _closed_or_gone}),
    do: socket |> answered(session) |> ended(session, :closed)

  defp closed(socket, session, {:error, :unanswered}),
    do: socket |> answered(session) |> ended(session, :unanswered)

  defp closed(socket, session, {:error, reason}) do
    socket
    |> answered(session)
    |> put_flash(:error, "Failed: #{PrismWeb.Ops.error_message(reason)}")
  end

  # The shown session's Close is out while its task is watched.
  defp closing(%{assigns: %{terminal: %{session: session} = terminal}} = socket, session, task),
    do: assign(socket, :terminal, %{terminal | closing: Process.monitor(task)})

  defp closing(socket, _session, _task), do: socket

  defp answered(
         %{assigns: %{terminal: %{session: session, closing: task} = terminal}} = socket,
         session
       )
       when is_reference(task) do
    Process.demonitor(task, [:flush])
    assign(socket, :terminal, %{terminal | closing: nil})
  end

  defp answered(socket, _session), do: socket

  # The shown session ended: its screen stays as it was, read-only, with
  # the ending said beside it, until the person closes the frame. The
  # first ending is the one said; a later answer for the gone session
  # (an acknowledgement the browser sent after) changes nothing.
  defp ended(
         %{assigns: %{terminal: %{session: session, ended: nil} = terminal}} = socket,
         session,
         reason
       ) do
    if connected?(socket), do: Opus.Programs.detach(socket.assigns.context, session)
    terminal = %{terminal | ended: if(reason in @endings, do: reason, else: :not_found)}

    socket =
      socket
      |> assign(:terminal, terminal)
      |> push_event("terminal_ended", %{session: session})

    socket.view.terminal_ended(socket, terminal)
  end

  defp ended(socket, _session, _reason), do: socket.view.terminal_ended(socket, nil)

  defp kept(%{assigns: %{terminal: %{session: session} = terminal}} = socket, session, kept),
    do: assign(socket, :terminal, %{terminal | kept: kept})

  defp kept(socket, _session, _kept), do: socket

  @doc "What the frame says when its session ended for `reason`."
  @spec ended_text(term()) :: String.t()
  def ended_text(:exited), do: "The program ended."

  def ended_text(:restarted),
    do:
      "The program stopped because CYFR restarted the part that runs programs. " <>
        "Open it again to go on."
  def ended_text(:closed), do: "The program was closed."
  def ended_text(:idle), do: "The program ended after a day with no one watching it."

  def ended_text(:row_changed),
    do: "The program ended: its definition was changed or it was removed."

  def ended_text(:standing), do: "The program ended: you no longer have access to this athanor."
  def ended_text(:unanswered), do: "The close was not confirmed yet; CYFR ends the program."
  def ended_text(:not_found), do: "This program is not running any more."

  attr :terminal, :map,
    required: true,
    doc: "%{session, name, kept, ended, attached, closing, back}, as `show/2` left it"

  @doc "The frame of the terminal `terminal` names."
  def frame(assigns) do
    ~H"""
    <div
      id={frame_id(@terminal)}
      class="rounded-lg border border-gray-700 bg-gray-950"
      data-test="terminal"
    >
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-gray-800 px-4 py-2">
        <span class="text-sm text-gray-300" data-test="terminal-name">
          <span class="font-mono text-blue-400">{@terminal.name}</span>
          — a terminal CYFR runs in the program's own folder
        </span>
        <div class="flex items-center gap-3">
          <.link
            :if={@terminal.back}
            navigate={@terminal.back}
            class="text-xs text-blue-400 hover:underline"
            data-test="back-to-aqua"
          >
            Back to Aqua
          </.link>
          <label :if={!@terminal.ended} class="flex items-center gap-1 text-xs text-gray-400">
            <input
              type="checkbox"
              phx-click="terminal_keep"
              phx-value-session={@terminal.session}
              phx-value-kept={to_string(!@terminal.kept)}
              checked={@terminal.kept}
              data-test="terminal-keep"
            /> Keep running when no one watches
          </label>
          <button
            :if={!@terminal.ended}
            type="button"
            phx-click="terminal_close"
            phx-value-session={@terminal.session}
            class="rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800"
            data-test="terminal-close"
          >
            Close
          </button>
          <button
            :if={@terminal.ended}
            type="button"
            phx-click="terminal_dismiss"
            class="rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800"
            data-test="terminal-dismiss"
          >
            Close
          </button>
        </div>
      </div>
      <p :if={@terminal.ended} class="px-4 py-2 text-xs text-amber-400" data-test="terminal-ended">
        {ended_text(@terminal.ended)}
      </p>
      <%!-- A screen the page drew stays after its program ends, read-only,
           so what the program last printed can be read; a frame shown for
           a session already gone has nothing to show. --%>
      <div
        :if={!@terminal.ended or @terminal.attached}
        id={frame_id(@terminal) <> "-screen"}
        phx-hook="Terminal"
        phx-update="ignore"
        data-session={@terminal.session}
        class="h-96 px-2 py-2"
      >
        <div data-terminal-screen class="h-full w-full"></div>
      </div>
    </div>
    """
  end

  # A frame moved on its page is another element, so its hook stands again.
  defp frame_id(%{session: session, moved: 0}), do: "terminal-#{session}"
  defp frame_id(%{session: session, moved: moved}), do: "terminal-#{session}-#{moved}"
end
