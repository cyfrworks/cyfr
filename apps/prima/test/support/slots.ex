# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.Slots do
  @moduledoc """
  A shared `Prima.Slots` server put back where a test starts: the suite's
  scripted runs are admitted and their runners killed for real, so a key
  can carry unreaped-kill notes from an earlier test. Notes otherwise
  decay only after the server's `unreaped_ttl_ms`.
  """

  @doc "Drop `key`'s unreaped-kill notes from the running server `server`."
  @spec clear_unreaped(GenServer.server(), term()) :: :ok
  def clear_unreaped(server, key) do
    :sys.replace_state(server, fn state ->
      %{state | unreaped: Map.delete(state.unreaped, key)}
    end)

    :ok
  end
end
