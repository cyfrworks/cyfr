# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SignInTerminalComponent do
  @moduledoc """
  A program's sign-in, in a bounded terminal frame: the row's login command
  runs on a pseudo-terminal in a login entry's kept home, and its lines and
  the person's input go both ways.

  On its first update it asks `mcp_servers.sign_in` for the row and the
  entry, which opens the session and starts a relay bound to the person's
  session, and attaches the page's process to it
  (`Opus.Programs.sign_in_attach/3`), telling the page
  `{PrismWeb.SignInTerminalComponent, :started, id, token}` so it closes
  this session before it opens a terminal for another target: each
  terminal holds one session, under an id of its own. The page forwards each relay message,
  `{Opus.Programs, token, {:lines, lines}}` or `{:ended, reason}`, here as
  the `relay` assign. The frame keeps the last #{500} lines, each with its
  terminal control sequences removed; a line the person types goes to the
  program with `Opus.Programs.sign_in_send/3`. Close ends the session
  (`Opus.Programs.sign_in_close/2`) and tells the page
  `{PrismWeb.SignInTerminalComponent, :closed}`. CYFR stores nothing of
  what passes: the program keeps its own sign-in in its home. What the
  person types is sent and never kept here; its field, `sign_in_line`, is
  one `Prima.Sanitizer.filter_parameters/0` names, so no event log shows it.
  The lines the frame shows are held in a `Lines` struct that inspects as
  their count alone, and rendered as one expression rather than a
  comprehension (whose per-line variables LiveView keeps), so the page's
  state in a crash report or LiveView's termination log carries none of
  their text.
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
     |> assign(:reason, nil)
     |> assign(:sent, 0)}
  end

  @impl true
  def update(%{relay: {token, event}}, %{assigns: %{token: token}} = socket),
    do: {:ok, relay(socket, event)}

  def update(%{relay: _other}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:relay, :flash, :myself]))

    if socket.assigns.token do
      {:ok, socket}
    else
      {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, start(&1)})
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("send", %{"sign_in_line" => line}, %{assigns: %{state: :running}} = socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case Opus.Programs.sign_in_send(socket.assigns.context, socket.assigns.token, line) do
        :ok -> {:noreply, update(socket, :sent, &(&1 + 1))}
        {:error, reason} -> {:noreply, ended(socket, reason)}
      end
    end)
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("close", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      if socket.assigns.token,
        do: Opus.Programs.sign_in_close(socket.assigns.context, socket.assigns.token)

      send(self(), {__MODULE__, :closed})
      {:noreply, socket}
    end)
  end

  defp start(socket) do
    args = %{"name" => socket.assigns.row, "entry" => socket.assigns.entry}

    with {:ok, result} <- call_tool(socket.assigns.context, "mcp_servers/sign_in", args),
         token when is_binary(token) <- result[:session] || result["session"],
         :ok <- Opus.Programs.sign_in_attach(socket.assigns.context, token, self()) do
      send(self(), {__MODULE__, :started, socket.assigns.id, token})
      socket |> assign(:token, token) |> assign(:state, :running)
    else
      {:error, reason} -> ended(socket, reason)
      _ -> ended(socket, "the sign-in did not start")
    end
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
        <.button variant="ghost" phx-click="close" phx-target={@myself}>Close</.button>
      </div>
      <pre
        id={"#{@id}-lines"}
        phx-hook="ScrollBottom"
        class="max-h-96 min-h-32 overflow-y-auto whitespace-pre-wrap break-all px-4 py-3 font-mono text-xs text-gray-200"
        data-test="terminal-lines"
      >{Lines.text(@lines)}</pre>
      <p :if={@state == :starting} class="px-4 pb-2 text-xs text-gray-500">Starting…</p>
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
        <.button type="submit" variant="ghost">Send</.button>
      </form>
    </div>
    """
  end
end
