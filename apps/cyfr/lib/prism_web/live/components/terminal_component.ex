# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TerminalComponent do
  @moduledoc """
  A program's terminal, CYFR's own frame around it: the chrome names the
  program and offers Close, keeping it running when no one watches, and,
  for a terminal opened from Aqua's card, the way back to Aqua; inside
  it the `Terminal` hook (`assets/js/terminal/frame.js`) draws what the
  program writes with the vendored xterm.js. Nothing the program writes
  reaches the chrome, and the frame asks for nothing but what the person
  types to the program.

  The frame holds no byte of the session: the page that shows it
  (`PrismWeb.ProgramsLive`) attaches to the session
  (`Opus.Programs.attach/2`) when the hook says it stands
  (`terminal_ready`), answers it what was printed before, and hands each
  later write to the hook as an event (`terminal_output`), so the page's
  assigns, and so its crash report or termination log, carry none. What
  the person types (`terminal_input`) is a parameter
  `Prima.Sanitizer.filter_parameters/0` names, so no event log shows it.
  """

  use Phoenix.Component

  @doc "What the frame says when its session ended for `reason`."
  @spec ended_text(term()) :: String.t()
  def ended_text(:exited), do: "The program ended."
  def ended_text(:closed), do: "The program was closed."
  def ended_text(:idle), do: "The program ended after a day with no one watching it."

  def ended_text(:row_changed),
    do: "The program ended: its definition was changed or it was removed."

  def ended_text(:standing), do: "The program ended: you no longer have access to this athanor."
  def ended_text(:unanswered), do: "The close was not confirmed yet; CYFR ends the program."
  def ended_text(:not_found), do: "This program is not running any more."

  attr :terminal, :map, required: true, doc: "%{session, name, kept, ended, attached, back}"

  @doc "The frame of the terminal `terminal` names."
  def frame(assigns) do
    ~H"""
    <div
      id={"terminal-#{@terminal.session}"}
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
        id={"terminal-#{@terminal.session}-screen"}
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
end
