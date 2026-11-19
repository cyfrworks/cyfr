# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ThreadList do
  @moduledoc """
  One person's list of threads as a canvas reads it, the `threads.changes`
  stream (`Aqua.Providers.Thread.streams/0`), and the writers'
  announcements of its person's own threads on their `Cyfr.Bus.threads/2`
  topic (`Cyfr.Bus.ThreadListed`).

  The list is the athanor's daily and workspace threads (`daily`,
  `workspace`; a crew member's child thread is the room's, never listed),
  each as `Cyfr.Providers.Threads` derives its item, an archived one
  among them, which a canvas shows behind its Archived filter, and the
  active shared threads the person sits in (`shared`, as
  `Sanctum.SharedThreads.listed/1` names them); a shared thread's
  `unread` counts the messages unread to the person.

  `changed/2` follows the writes that move a listed thread's row as the
  list shows it: its creation, a message accepted into it, a turn's end,
  its read mark moved (`mark_read/3`); an archive
  is announced by the bridge (`Cyfr.TelemetryBridge`), whoever made it.
  `removed/2` follows a committed delete. Both are
  `Cyfr.Providers.Threads`'. A shared thread's change is announced by the
  bridge, since a shared thread is no athanor's.
  """

  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadListed
  alias Cyfr.Providers.Threads, as: Listing
  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  @listed Listing.listed_kinds()

  @doc """
  The refresh of `threads.changes`: the caller's athanor's daily and
  workspace threads, the latest of those not archived and the latest of
  those archived, as many of each as `Arca.ThreadStorage.list/2` reads by
  default (so an older one is found by search, not here), and the active
  shared threads the caller sits in, the latest activity first, each as
  its live payload reads. The subject is the caller's own id, which the
  gate binds.
  """
  @spec listed(Context.t(), String.t()) :: {:ok, [ThreadListed.t()]} | {:error, term()}
  def listed(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    actor = Context.actor(ctx)

    with active when is_list(active) <- Threads.list(actor, kind: @listed, archived: false),
         archived when is_list(archived) <- Threads.list(actor, kind: @listed, archived: true),
         threads = active ++ archived,
         {:ok, person} <- Listing.person(actor),
         {:ok, shared} <- Sanctum.SharedThreads.listed(user_id),
         {:ok, items} <- items(actor, Users.public_name(person), threads) do
      items = items ++ Enum.map(shared, &ThreadListed.new(actor, :shared, &1))
      {:ok, Enum.sort_by(items, & &1.last_activity, {:desc, DateTime})}
    end
  end

  def listed(%Context{}, _subject), do: {:error, :no_athanor}

  @doc """
  Move the person's read mark of `thread_id` to `seq`, forward only
  (`Arca.ThreadStorage.mark_read/3`), and announce the thread as it reads
  now, its count among it, so every view of the person's list sees it.
  """
  @spec mark_read(Context.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def mark_read(%Context{} = ctx, thread_id, seq)
      when is_binary(thread_id) and is_integer(seq) and seq >= 0 do
    with {:ok, _mark} <- Threads.mark_read(Context.actor(ctx), thread_id, seq) do
      changed(ctx, thread_id)
    end
  end

  @doc "The listed thread `thread_id` as it reads now, announced to its person's list."
  @spec changed(Context.t() | Prima.Actor.t(), String.t()) :: :ok
  def changed(%Context{} = ctx, thread_id), do: changed(Context.actor(ctx), thread_id)
  def changed(%Prima.Actor{} = actor, thread_id), do: Listing.changed(actor, thread_id)

  @doc "The thread `thread_id`, which a committed delete removed, leaving its person's list."
  @spec removed(Context.t() | Prima.Actor.t(), String.t()) :: :ok
  def removed(%Context{} = ctx, thread_id), do: removed(Context.actor(ctx), thread_id)
  def removed(%Prima.Actor{} = actor, thread_id), do: Listing.removed(actor, thread_id)

  defp items(actor, name, threads) do
    Enum.reduce_while(threads, {:ok, []}, fn thread, {:ok, acc} ->
      case Listing.item(actor, name, thread) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = unread -> {:halt, unread}
      end
    end)
  end
end
