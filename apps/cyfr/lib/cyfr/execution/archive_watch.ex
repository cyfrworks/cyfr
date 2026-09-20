# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.ArchiveWatch do
  @moduledoc """
  Stops an archived athanor's running work.

  Archiving is the identity domain's act: it flips the status, revokes the
  athanor's standing credentials and drops every member's cached caller
  before it returns, because those are authorization properties. What is
  still *running* is this domain's, and the identity domain has no
  business naming it — so the archive announces
  (`Cyfr.Bus.athanor_archived_global/0`) and this watch reacts.

  Best effort, as the in-line cancel it replaces was: the status gates
  already refuse new work, so a run this fails to reach ends on its own
  lease. What it must not do is take the archive down with it, which is
  why it runs in its own process rather than on the archiving caller's.

  Started when `config :cyfr, :execution_archive_watch_enabled` is true
  (the default). Queries from a permanent process poison the test sandbox
  — the lent connection outlives its owning test — the same reason the
  stale-execution sweeper is gated; test config turns it off and the
  reaction is exercised directly.
  """

  use GenServer

  require Logger

  # The same bound the in-line cancel carried: an athanor with more
  # running executions than this has a bigger problem than the archive.
  @cancel_limit 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:cyfr, :execution_archive_watch_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.athanor_archived_global())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:athanor_archived_global, athanor_id}, state)
      when is_binary(athanor_id) and athanor_id != "" do
    cancel_running(athanor_id)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp cancel_running(athanor_id) do
    if Cyfr.Execution.available?() do
      ctx = Sanctum.internal_context(athanor_id: athanor_id, scope: :athanor)

      case Cyfr.Execution.list(ctx, status: :running, limit: @cancel_limit) do
        {:ok, running} ->
          Enum.each(running, fn %{id: id} -> Cyfr.Execution.cancel(ctx, id) end)

        {:error, reason} ->
          Logger.warning(
            "[Cyfr.Execution.ArchiveWatch] #{athanor_id}: running executions not listed " <>
              "(#{inspect(reason)}); they end on their own lease"
          )
      end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Cyfr.Execution.ArchiveWatch] cancel on archive failed (#{Exception.message(e)})"
      )

      :ok
  catch
    # A store that answers by exiting — an ownership refusal under the
    # suite's sandbox is one — must not take the watch down with it: the
    # status gates already refuse new work and the runs end on their own
    # lease.
    kind, reason ->
      Logger.warning(
        "[Cyfr.Execution.ArchiveWatch] cancel on archive #{kind}: #{inspect(reason)}"
      )

      :ok
  end
end
