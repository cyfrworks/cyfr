# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ThreadList do
  @moduledoc """
  One person's list of threads: as a view reads it (`threads/2`, Aqua's
  panel and the command palette), as a canvas reads it, the
  `threads.changes` stream (`Aqua.Providers.Thread.streams/0`), and the
  writers' announcements of its person's own threads on their
  `Cyfr.Bus.threads/2` topic (`Cyfr.Bus.ThreadListed`).

  The list is one query, which the view's list and the stream's refresh
  both read: the athanor's daily and workspace threads (`daily`,
  `workspace`; a crew member's child thread is the room's, never listed),
  each as `Cyfr.Providers.Threads` derives its item, an archived one
  among them, which a canvas shows behind its Archived filter, and the
  active shared threads the person sits in (`shared`, as
  `Sanctum.SharedThreads.listed/1` names them); a shared thread's
  `unread` counts the messages unread to the person. A title asked for
  is matched as `thread.search` folds text (`Arca.ThreadStorage.list/2`'s
  `:title`), over every thread of the athanor before the list's window,
  and a shared thread's title the same way.

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

  @typedoc """
  A thread as a view lists it: its kind, its title (a daily thread's is
  its date), a workspace thread's `state` (nil for the others), its last
  activity, whether it waits on the person, how many of its posts they
  have not seen and whether it is archived.
  """
  @type entry :: %{
          id: String.t(),
          kind: :daily | :workspace | :shared,
          title: String.t() | nil,
          state: String.t() | nil,
          last_activity: DateTime.t(),
          waits_on_you: boolean(),
          unread: non_neg_integer(),
          archived: boolean()
        }

  @doc """
  The caller's list of threads as a view reads it, the latest activity
  first. `title:` is text a thread's title holds, folded as
  `thread.search` folds it and matched over every thread of theirs, the
  oldest included; nil lists the windows the refresh reads.
  """
  @spec threads(Context.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def threads(%Context{} = ctx, opts) when is_list(opts) do
    with {:ok, listed} <- read(ctx, Keyword.get(opts, :title)) do
      {:ok, Enum.map(listed, &entry/1)}
    end
  end

  @doc """
  The refresh of `threads.changes`: the caller's athanor's daily and
  workspace threads, the latest of those not archived and the latest of
  those archived, as many of each as `Arca.ThreadStorage.list/2` reads by
  default (so an older one is found by its title, not here), and the
  active shared threads the caller sits in, the latest activity first,
  each as its live payload reads. The subject is the caller's own id,
  which the gate binds.
  """
  @spec listed(Context.t(), String.t()) :: {:ok, [ThreadListed.t()]} | {:error, term()}
  def listed(%Context{} = ctx, _subject) do
    with {:ok, listed} <- read(ctx, nil) do
      {:ok, Enum.map(listed, fn {item, _state} -> item end)}
    end
  end

  # The one query: each thread as its live payload reads, with a
  # workspace thread's state beside it.
  defp read(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, title)
       when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    actor = Context.actor(ctx)
    opts = [kind: @listed, title: title]

    with active when is_list(active) <- Threads.list(actor, [archived: false] ++ opts),
         archived when is_list(archived) <- Threads.list(actor, [archived: true] ++ opts),
         threads = active ++ archived,
         {:ok, person} <- Listing.person(actor),
         {:ok, shared} <- Sanctum.SharedThreads.listed(user_id),
         {:ok, items} <- items(actor, Users.public_name(person), threads) do
      shared =
        for listing <- shared,
            titled?(listing.title, title),
            do: {ThreadListed.new(actor, :shared, listing), nil}

      {:ok, Enum.sort_by(items ++ shared, &elem(&1, 0).last_activity, {:desc, DateTime})}
    end
  end

  defp read(%Context{}, _title), do: {:error, :no_athanor}

  # A shared thread's title, folded as a search folds text; a pair has
  # none, and matches only when no title is asked for.
  defp titled?(_title, nil), do: true
  defp titled?(nil, _asked), do: false

  defp titled?(title, asked),
    do: String.contains?(String.downcase(title), String.downcase(asked))

  defp entry({%ThreadListed{} = item, state}) do
    %{
      id: item.id,
      kind: item.kind,
      title: item.title,
      state: state,
      last_activity: item.last_activity,
      waits_on_you: item.waits_on_you,
      unread: item.unread,
      archived: item.archived == true
    }
  end

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
        {:ok, item} -> {:cont, {:ok, [{item, state(thread)} | acc]}}
        {:error, _} = unread -> {:halt, unread}
      end
    end)
  end

  defp state(%{kind: "workspace", workspace_state: state}), do: state
  defp state(_thread), do: nil
end
