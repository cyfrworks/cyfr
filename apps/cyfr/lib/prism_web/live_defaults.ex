# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveDefaults do
  @moduledoc """
  The last `handle_event/3` clause every console LiveView gets.

  A LiveView's event names are client-supplied: anything the browser sends
  over the channel is dispatched by name, and an unmatched name is a
  `FunctionClauseError` that kills the LiveView process. The client
  reconnects and remounts, so nothing is permanently broken — but whatever
  the person had on screen and unsent is gone, and a client that sends one
  such event in a loop makes an error report per remount.

  Twenty-three LiveViews had no such clause. This is the same clause
  written once, appended after each module's own by `@before_compile` so it
  never shadows a real handler.

  `:warning` rather than `:debug` on purpose: a `phx-click` whose name no
  longer matches its handler is a real bug, and it should not go quiet
  because this clause caught it.
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile PrismWeb.LiveDefaults
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @impl true
      def handle_event(event, _params, socket) do
        require Logger
        # The event name is client-supplied and reaches a structured log, so
        # it is bounded — the same move `Emissary.MCP.Router` makes for an
        # unvalidated `method`. Unbounded, one loop inflates log lines at
        # will, and this clause is attached to every LiveView.
        Logger.warning(
          "#{inspect(__MODULE__)}: unhandled event " <>
            inspect(String.slice(to_string(event), 0, 200))
        )

        {:noreply, socket}
      end
    end
  end
end
