# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SignInTerminalComponent do
  @moduledoc """
  A program's sign-in, in a bounded terminal frame: the row's login command
  runs on a pseudo-terminal in a login entry's kept home, and its lines and
  the person's input go both ways.

  On its first update it closes the session of the terminal it replaces
  (`predecessor`, a token, when there is one) and then asks
  `mcp_servers.sign_in` for the row and the entry, which opens the session
  and starts a relay bound to the person's session; its answer attaches
  the page's process to it (`Opus.Programs.sign_in_attach/3`) and tells the
  page `{PrismWeb.SignInTerminalComponent, :started, id, token}` (token nil
  when it did not start), so the page hands that session to the terminal
  for another target as its predecessor: each terminal holds one session,
  under an id of its own. The close comes before the open, in one call,
  because the backends service keys a session by its caller, program and
  home: the same entry opened again resumes the session a later close
  would end. The page forwards each relay message,
  `{Opus.Programs, token, {:lines, lines}}` or `{:ended, reason}`, here as
  the `relay` assign. The frame keeps the last #{500} lines, each with its
  terminal control sequences removed; a line the person types goes to the
  program with `Opus.Programs.sign_in_send/3`. Close ends the session
  (`Opus.Programs.sign_in_close/2`) and tells the page
  `{PrismWeb.SignInTerminalComponent, :closed, id}`. CYFR stores nothing of
  what passes: the program keeps its own sign-in in its home. What the
  person types is sent and never kept here; its field, `sign_in_line`, is
  one `Prima.Sanitizer.filter_parameters/0` names, so no event log shows it.
  The lines the frame shows are held in a `Lines` struct that inspects as
  their count alone, and rendered as one expression rather than a
  comprehension (whose per-line variables LiveView keeps), so the page's
  state in a crash report or LiveView's termination log carries none of
  their text.

  The start, each line sent and the close call off the page's process
  (`ask/3`): a start waits on the backends service for minutes and a line
  or a close up to 35 s, and the browser gives up on an event it waits on
  for 30 seconds. The relay is no task's: it runs under its own
  supervisor and is attached here only once its start is answered, so a
  page gone before that leaves it to end unattended. The frame says
  Starting…, Sending… or Closing… until the answer comes, and takes no
  second line or close meanwhile.
  """

  defmodule Lines do
    @moduledoc """
    A sign-in terminal's lines, the text a program wrote on its terminal,
    which may be a credential: inspected as how many there are, never
    what they say, so a crash report that prints the page's assigns
    prints none of them.
    """

    defstruct lines: []

    @type t :: %__MODULE__{lines: [String.t()]}

    @doc """
    The lines as the frame's one text, each ended by a newline. The frame
    renders this one expression, never a comprehension over the lines,
    whose per-line variables LiveView keeps for change tracking and a
    crash report would print.
    """
    @spec text(t()) :: String.t()
    def text(%__MODULE__{lines: lines}), do: Enum.map_join(lines, &(&1 <> "\n"))

    defimpl Inspect, for: PrismWeb.SignInTerminalComponent.Lines do
      use Boundary, classify_to: PrismWeb

      def inspect(%{lines: lines}, _opts),
        do: "#PrismWeb.SignInTerminalComponent.Lines<#{length(lines)} lines>"
    end
  end

  use PrismWeb, :live_component

  @max_lines 500

  # CSI and OSC sequences, character-set designations, keypad and cursor
  # save modes, and carriage returns: what a terminal draws with and a
  # frame of text does not.
  @control ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[()][0-9A-Za-z]|\e[=>78]|\r/

  @doc "What the frame says when a sign-in ends for `reason`."
  @spec ended_text(term()) :: String.t()
  def ended_text(reason), do: sentence(reason)

  @doc "A line of a terminal as text: its control sequences removed."
  @spec text(String.t()) :: String.t()
  def text(line) when is_binary(line), do: String.replace(line, @control, "")

  @doc "The most lines the frame keeps."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:token, nil)
     |> assign(:lines, %Lines{})
     |> assign(:state, :starting)
     |> assign(:asked, false)
     |> assign(:predecessor, nil)
     |> assign(:sending, false)
     |> assign(:closing, false)
     |> assign(:reason, nil)
     |> assign(:sent, 0)}
  end

  @impl true
  def update(%{relay: {token, event}}, %{assigns: %{token: token}} = socket),
    do: {:ok, relay(socket, event)}

  def update(%{relay: _other}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:relay, :flash, :myself]))

    if socket.assigns.asked do
      {:ok, socket}
    else
      {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, start(&1)})
      {:ok, socket}
    end
  end

  @impl true
  def handle_event(
        "send",
        %{"sign_in_line" => line},
        %{assigns: %{state: :running, sending: false}} = socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      token = socket.assigns.token

      {:noreply,
       socket
       |> assign(:sending, true)
       |> ask(:send, &Opus.Programs.sign_in_send(&1, token, line))}
    end)
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  # Closed while its start is in flight, the terminal says it is closing,
  # and closes the session the start opened as soon as the start answers,
  # before anything else (`told/1`).
  def handle_event("close", _params, %{assigns: %{state: :starting}} = socket),
    do: {:noreply, assign(socket, :closing, true)}

  def handle_event("close", _params, %{assigns: %{closing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("close", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case socket.assigns.token do
        nil ->
          send(self(), {__MODULE__, :closed, socket.assigns.id})
          {:noreply, socket}

        token ->
          {:noreply,
           socket
           |> assign(:closing, true)
           |> ask(:close, &Opus.Programs.sign_in_close(&1, token))}
      end
    end)
  end

  # A start's answer the guard refuses leaves the terminal ended, its
  # sentence shown by the page; the session it opened is attached to
  # nothing, and its relay ends it within 30 s.
  @impl true
  def handle_async(:start, {:ok, {tag, result}}, socket) do
    {:noreply, socket} =
      CyfrWeb.ContextGuard.deliver(
        ended(socket, :unavailable),
        tag,
        &{:noreply, started(&1, result)}
      )

    {:noreply, told(socket)}
  end

  def handle_async(:send, {:ok, {tag, result}}, socket),
    do:
      CyfrWeb.ContextGuard.deliver(
        assign(socket, :sending, false),
        tag,
        &{:noreply, sent(&1, result)}
      )

  def handle_async(:close, {:ok, {tag, _result}}, socket),
    do: CyfrWeb.ContextGuard.deliver(assign(socket, :closing, false), tag, &closed/1)

  # Only the node's shutdown stops a call (`run_to_end/1`).
  def handle_async(_name, {:exit, _reason}, socket), do: {:noreply, socket}

  # The start, off the update that first renders the terminal: the
  # predecessor's session closed, then this one opened, in that order in
  # one call; the answer attaches this page's process to it. The close
  # waits for the predecessor's relay to finish what it is doing, up to
  # 35 s, and the open follows whatever the close answered.
  defp start(socket) do
    args = %{"name" => socket.assigns.row, "entry" => socket.assigns.entry}
    predecessor = socket.assigns.predecessor

    socket
    |> assign(:asked, true)
    |> ask(:start, fn ctx ->
      if predecessor, do: Opus.Programs.sign_in_close(ctx, predecessor)
      call_tool(ctx, "mcp_servers/sign_in", args)
    end)
  end

  # A call of this terminal's, off the page's process and run to its end;
  # its answer, `name`, comes back to `handle_async/3` held to the
  # person's standing.
  defp ask(socket, name, fun) do
    ctx = socket.assigns.context
    tag = CyfrWeb.ContextGuard.capture(ctx)

    start_async(socket, name, fn -> {tag, run_to_end(fn -> fun.(ctx) end)} end,
      supervisor: Prism.TaskSupervisor
    )
  end

  # Asked to close while it started: the session the start opened, if it
  # opened one, is closed before anything else, never attached.
  defp started(%{assigns: %{closing: true}} = socket, result) do
    socket = assign(socket, :state, :starting)

    case session_of(result) do
      token when is_binary(token) ->
        socket |> assign(:token, token) |> ask(:close, &Opus.Programs.sign_in_close(&1, token))

      nil ->
        socket
    end
  end

  defp started(socket, result), do: attached(socket, result)

  # The page told how the start ended (the session it opened, or nil), so
  # it hands that session to the next terminal to close first; and a
  # terminal asked to close that holds no session closes now.
  defp told(socket) do
    %{id: id, token: token, closing: closing} = socket.assigns
    send(self(), {__MODULE__, :started, id, token})
    if closing and is_nil(token), do: send(self(), {__MODULE__, :closed, id})
    socket
  end

  defp session_of({:ok, result}) do
    case result[:session] || result["session"] do
      token when is_binary(token) -> token
      _none -> nil
    end
  end

  defp session_of(_refused), do: nil

  defp attached(socket, {:ok, _} = result) do
    with token when is_binary(token) <- session_of(result),
         :ok <- Opus.Programs.sign_in_attach(socket.assigns.context, token, self()) do
      socket |> assign(:token, token) |> assign(:state, :running)
    else
      {:error, reason} -> ended(socket, reason)
      _ -> ended(socket, "the sign-in did not start")
    end
  end

  defp attached(socket, {:error, reason}), do: ended(socket, reason)

  # A line's answer can come after the relay said how the sign-in ended,
  # whose words it never replaces.
  defp sent(%{assigns: %{state: :ended}} = socket, _result), do: socket
  defp sent(socket, :ok), do: update(socket, :sent, &(&1 + 1))
  defp sent(socket, {:error, reason}), do: ended(socket, reason)

  defp closed(socket) do
    send(self(), {__MODULE__, :closed, socket.assigns.id})
    {:noreply, socket}
  end

  defp relay(socket, {:lines, lines}) when is_list(lines) do
    kept = (socket.assigns.lines.lines ++ Enum.map(lines, &text/1)) |> Enum.take(-@max_lines)
    assign(socket, :lines, %Lines{lines: kept})
  end

  defp relay(socket, {:ended, reason}), do: ended(socket, reason)
  defp relay(socket, _event), do: socket

  defp ended(socket, reason),
    do: socket |> assign(:state, :ended) |> assign(:reason, sentence(reason))

  # What the relay's end says: signed in, or the end it names.
  defp sentence(:signed_in), do: "Signed in."
  defp sentence({:exited, nil}), do: "The sign-in command ended."
  defp sentence({:exited, code}), do: "The sign-in command exited with status #{code}."

  defp sentence({:not_signed_in, why}),
    do: "The command ended, but the login entry is not signed in: #{reason_text(why)}"

  defp sentence(:closed), do: "The sign-in was closed."
  defp sentence(:unattended), do: "The sign-in ended: nothing was attached to it."
  defp sentence(:stand_down), do: "The sign-in ended: another server took the program over."
  defp sentence(:owner_moved), do: "The sign-in ended: the program's definition changed."
  defp sentence(:lost), do: "The sign-in ended: the backends service was lost."
  defp sentence(:not_yours), do: "This sign-in belongs to another session."
  defp sentence(text) when is_binary(text), do: text
  defp sentence(reason), do: "The sign-in ended: #{error_message(reason)}"

  defp reason_text(text) when is_binary(text), do: text
  defp reason_text(reason), do: error_message(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-gray-700 bg-gray-950" data-test="sign-in-terminal">
      <div class="flex items-center justify-between border-b border-gray-800 px-4 py-2">
        <span class="text-sm text-gray-300">
          Sign in <span class="font-mono text-blue-400">{@row}</span>
        </span>
        <.button
          variant="ghost"
          phx-click="close"
          phx-target={@myself}
          disabled={@closing}
        >
          {if @closing, do: "Closing…", else: "Close"}
        </.button>
      </div>
      <pre
        id={"#{@id}-lines"}
        phx-hook="ScrollBottom"
        class="max-h-96 min-h-32 overflow-y-auto whitespace-pre-wrap break-all px-4 py-3 font-mono text-xs text-gray-200"
        data-test="terminal-lines"
      >{Lines.text(@lines)}</pre>
      <p :if={@state == :starting and not @closing} class="px-4 pb-2 text-xs text-gray-500">
        Starting…
      </p>
      <p :if={@state == :ended} class="px-4 pb-2 text-xs text-amber-400" data-test="terminal-ended">
        {@reason}
      </p>
      <form
        :if={@state == :running}
        phx-submit="send"
        phx-target={@myself}
        class="flex gap-2 border-t border-gray-800 px-4 py-2"
        id={"#{@id}-input"}
        data-test="terminal-input"
      >
        <.input
          id={"#{@id}-line-#{@sent}"}
          name="sign_in_line"
          value=""
          placeholder="type an answer and press Enter"
          class="font-mono"
        />
        <.button type="submit" variant="ghost" disabled={@sending}>
          {if @sending, do: "Sending…", else: "Send"}
        </.button>
      </form>
    </div>
    """
  end
end
