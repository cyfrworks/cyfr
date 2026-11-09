# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ThreadList do
  @moduledoc """
  One person's list of threads as a canvas reads it, the `threads.changes`
  stream (`Aqua.Providers.Thread.streams/0`), and the publisher of its
  person's own threads on their `Cyfr.Bus.threads/2` topic
  (`Cyfr.Bus.ThreadListed`).

  The list is the athanor's own threads (`own`; a crew member's child
  thread is the room's, never listed) and the active shared threads the
  person sits in (`shared`, as `Sanctum.SharedThreads.listed/1` names
  them). An own thread is its id, its title, its person by the name a
  reader outside CYFR may see (`Sanctum.Tenancy.Users.public_name/1`), its
  last activity and whether a card in it waits on its person
  (`Arca.ThreadStorage.pending_approvals/2`). Never a message, an id of a
  person or an address.

  `changed/2` follows the writes that move an own thread's row as the list
  shows it: its creation, a message accepted into it (the first titles
  it), a turn's end, a card opened or decided. It reads the thread again
  rather than trusting the write's answer, and a thread gone or a child
  thread announces nothing. `removed/2` follows a committed delete. Both
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

  @doc """
  The refresh of `threads.changes`: the caller's athanor's own threads, as
  many as `Arca.ThreadStorage.list/2` reads by default, and the active
  shared threads the caller sits in, the latest activity first, each as
  its live payload reads. The subject is the caller's own id, which the
  gate binds.
  """
  @spec listed(Context.t(), String.t()) :: {:ok, [ThreadListed.t()]} | {:error, term()}
  def listed(%Context{athanor_id: athanor_id, user_id: user_id} = ctx, _subject)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    actor = Context.actor(ctx)

    with own when is_list(own) <- Threads.list(actor, kind: "own"),
         {:ok, person} <- person(actor),
         {:ok, shared} <- Sanctum.SharedThreads.listed(user_id) do
      name = Users.public_name(person)

      items =
        Enum.map(own, &own(actor, name, &1)) ++
          Enum.map(shared, &ThreadListed.new(actor, :shared, &1))

      {:ok, Enum.sort_by(items, & &1.last_activity, {:desc, DateTime})}
    end
  end

  def listed(%Context{}, _subject), do: {:error, :no_athanor}

  @doc "The own thread `thread_id` as it reads now, announced to its person's list."
  @spec changed(Context.t() | Prima.Actor.t(), String.t()) :: :ok
  def changed(%Context{} = ctx, thread_id), do: changed(Context.actor(ctx), thread_id)

  def changed(%Prima.Actor{} = actor, thread_id) when is_binary(thread_id) do
    serialized(thread_id, fn ->
      with {:ok, %{kind: "own"} = thread} <- Threads.get(actor, thread_id),
           {:ok, person} <- person(actor) do
        broadcast(actor, person, own(actor, Users.public_name(person), thread))
      else
        {:ok, _child} -> :ok
        {:error, reason} -> unannounced(thread_id, reason)
      end
    end)
  end

  @doc "The own thread `thread_id`, which a committed delete removed, leaving its person's list."
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

  # An own thread as the list shows it: a pending card waits on the
  # athanor's person, who alone decides one.
  defp own(actor, name, thread) do
    ThreadListed.new(actor, :own,
      id: thread.id,
      title: thread.title,
      people: [name],
      last_activity: thread.last_message_at || thread.inserted_at,
      waits_on_you: match?([_ | _], Threads.pending_approvals(actor, thread.id))
    )
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
