# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.LiveSocket do
  @moduledoc """
  The console's LiveView socket, mounted at `/live`: `Phoenix.LiveView.Socket`
  with one refusal. Once this node drains (`drain/0`), every connect is
  refused, over the WebSocket or the long-poll transport, on a new
  connection or on one already open.

  A graceful stop marks the drain before the endpoint stops accepting
  (`Cyfr.Application.prep_stop/1`). Closing the listening port refuses a
  new connection, but the connections already open stay open through the
  drain, idle keep-alive ones included, and a tab whose WebSocket fails
  falls back to long polling over whichever it can reach. With every
  connect refused here too, a tab that rejoins reaches another member or
  the restarted server, never the node that is stopping.
  """

  use Phoenix.LiveView.Socket

  # Read on every connect, written once per stop: a persistent term costs
  # the read nothing, and the write happens when the node is going away.
  @draining {__MODULE__, :draining}

  # `Phoenix.Socket`'s connect callback, overriding the default the `use`
  # defines; LiveView's own connect runs after it on an `{:ok, socket}`.
  # Left without `@impl`: the `use` defines `id/1` without one, and a
  # module that marks one callback must mark them all.
  def connect(_params, socket, _connect_info) do
    if draining?(), do: :error, else: {:ok, socket}
  end

  @doc """
  Mark this node draining: from here on every connect is refused. Nothing
  clears the mark while the node stops; the application's start clears it
  (`undrain/0`), so a stop and a start in one VM do not leave `/live`
  refusing.
  """
  @spec drain() :: :ok
  def drain, do: :persistent_term.put(@draining, true)

  @doc "Clear the drain mark: `Cyfr.Application.start/2` calls it before the endpoint starts."
  @spec undrain() :: :ok
  def undrain do
    _existed = :persistent_term.erase(@draining)
    :ok
  end

  @doc "Whether this node is draining (`drain/0`), and so refuses every connect."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@draining, false)
end
