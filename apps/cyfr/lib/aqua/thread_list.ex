# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ThreadList do
  @moduledoc """
  One person's list of threads as a canvas reads it, the `threads.changes`
  stream (`Aqua.Providers.Thread.streams/0`), and the publisher of its
  person's own threads on their `Cyfr.Bus.threads/2` topic
  (`Cyfr.Bus.ThreadListed`).

  The list is the athanor's daily and workspace threads (`daily`,
  `workspace`; a crew member's child thread is the room's, never listed)
  and the active shared threads the person sits in (`shared`, as
  `Sanctum.SharedThreads.listed/1` names them). A thread of the athanor is
  its id, its title (a daily thread's is its date), its person by the name
  a reader outside CYFR may see (`Sanctum.Tenancy.Users.public_name/1`),
  its last activity, whether a card in it waits on its person
  (`Arca.ThreadStorage.pending_approvals/2`) and how many of its posts the
  person has not seen (`Arca.ThreadStorage.unread/2`, past its read mark);
  a shared thread's `unread` counts the messages unread to the person.
  Never a message, an id of a person or an address.

  `changed/2` follows the writes that move a listed thread's row as the
  list shows it: its creation, a message accepted into it, a turn's end, a
  card opened or decided, its read mark moved (`mark_read/3`). It reads
  the thread again rather than trusting the write's answer; a thread
  gone announces nothing, and a child thread announces its room, whose
  state what moved there may move (a workspace thread's, by its crew's
  work: `Arca.TurnStorage`'s "Workspace threads"). `removed/2` follows a
  committed delete. Both
  run under the thread's lock on this node, so once `removed` has left, a
  later `changed` reads the thread gone and says nothing. The person is
  the athanor's owner, whoever's context wrote. A shared thread's change is
  announced by the bridge (`Cyfr.TelemetryBridge`), since a shared thread
  is no athanor's.
  """

  require Logger

  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadListed
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  # The athanor's threads its person's list holds; a crew member's is its
  # room's.
  @listed Threads.room_kinds()

  @doc """
  The refresh of `threads.changes`: the caller's athanor's daily and
  workspace threads, as
  many as `Arca.ThreadStorage.list/2` reads by default, and the active
  shared threads the caller sits in, the latest activity first, each as
  its live payload reads. The subject is the caller's own id, which the
  gate binds.
  """
  @spec listed(Context.t(), String.t()) :: {:ok, [ThreadListed.t()]} | {:error, term()}
  def listed(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    actor = Context.actor(ctx)

    with threads when is_list(threads) <- Threads.list(actor, kind: @listed),
         {:ok, person} <- person(actor),
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

  def changed(%Prima.Actor{} = actor, thread_id) when is_binary(thread_id) do
    serialized(thread_id, fn ->
      with {:ok, %{kind: kind} = thread} when kind in @listed <- Threads.get(actor, thread_id),
           {:ok, person} <- person(actor),
           {:ok, item} <- item(actor, Users.public_name(person), thread) do
        broadcast(actor, person, item)
      else
        {:ok, %{kind: "crew", parent_id: room}} when is_binary(room) -> {:room, room}
        {:ok, _child} -> :ok
        {:error, reason} -> unannounced(thread_id, reason)
      end
    end)
    |> case do
      {:room, room} -> changed(actor, room)
      _announced -> :ok
    end
  end

  @doc "The thread `thread_id`, which a committed delete removed, leaving its person's list."
  @spec removed(Context.t() | Prima.Actor.t(), String.t()) :: :ok
  def removed(%Context{} = ctx, thread_id), do: removed(Context.actor(ctx), thread_id)

  def removed(%Prima.Actor{} = actor, thread_id) when is_binary(thread_id) do
    serialized(thread_id, fn ->
      case person(actor) do
        {:ok, person} ->
          broadcast(actor, person, ThreadListed.new(actor, :removed, id: thread_id))

        {:error, reason} ->
          unannounced(thread_id, reason)
      end
    end)
  end

  defp items(actor, name, threads) do
    Enum.reduce_while(threads, {:ok, []}, fn thread, {:ok, acc} ->
      case item(actor, name, thread) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = unread -> {:halt, unread}
      end
    end)
  end

  # A thread of the athanor as the list shows it: a pending card waits on
  # the athanor's person, who alone decides one.
  defp item(actor, name, thread) do
    with {:ok, unread} <- Threads.unread(actor, thread) do
      {:ok,
       ThreadListed.new(actor, String.to_existing_atom(thread.kind),
         id: thread.id,
         title: thread.title,
         people: [name],
         last_activity: thread.last_message_at || thread.inserted_at,
         waits_on_you: match?([_ | _], Threads.pending_approvals(actor, thread.id)),
         unread: unread
       )}
    end
  end

  # Whose list an athanor's thread is on: the athanor's person.
  defp person(%Prima.Actor{athanor_id: athanor_id}) do
    case Athanors.get(athanor_id) do
      {:ok, %{owner_user_id: owner}} when is_binary(owner) and owner != "" -> {:ok, owner}
      {:ok, _ownerless} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp broadcast(actor, person, payload) do
    case Cyfr.Bus.broadcast(actor, Cyfr.Bus.threads(actor, person), payload) do
      :ok -> :ok
      {:error, reason} -> unannounced(payload.id, reason)
    end
  end

  # A thread or an athanor gone has no list to tell; anything else is said.
  defp unannounced(_thread_id, :not_found), do: :ok

  defp unannounced(thread_id, reason) do
    Logger.warning("[Aqua.ThreadList] thread #{thread_id} not announced: #{inspect(reason)}")
  end

  defp serialized(thread_id, fun),
    do: :global.trans({{__MODULE__, thread_id}, self()}, fun, [node()])
end
