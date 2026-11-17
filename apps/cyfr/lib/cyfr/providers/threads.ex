# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.Threads do
  @moduledoc """
  A thread of the athanor as one person's list of threads shows it, and
  its announcement on that person's `Cyfr.Bus.threads/2` topic
  (`Cyfr.Bus.ThreadListed`), derived here once for the stream's refresh
  and its writers' announcements (`Aqua.ThreadList`) and for the bridge's
  announcement of an archive (`Cyfr.TelemetryBridge`), which a write
  beneath the host makes and names no person.

  An item is the thread's id, its title (a daily thread's is its date),
  its person by the name a reader outside CYFR may see
  (`Sanctum.Tenancy.Users.public_name/1`), its last activity, whether a
  card in it waits on its person (`Arca.ThreadStorage.pending_approvals/2`),
  how many of its posts the person has not seen
  (`Arca.ThreadStorage.unread/2`, past its read mark) and whether it is
  archived (`Arca.ThreadStorage.archived?/1`). Never a message, an id of
  a person or an address.

  `changed/2` reads the thread again rather than trusting the write's
  answer; a thread gone announces nothing, and a crew member's thread
  announces its room, whose state what moved there may move. `removed/2`
  follows a committed delete. Both run under the thread's lock on this
  node, so once `removed` has left, a later `changed` reads the thread
  gone and says nothing. The person is the athanor's owner, whoever's
  context wrote.
  """

  require Logger

  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadListed
  alias Sanctum.Tenancy.{Athanors, Users}

  # The athanor's threads its person's list holds; a crew member's is its
  # room's.
  @listed Threads.room_kinds()

  @doc "The kinds of thread the list holds: daily and workspace threads."
  @spec listed_kinds() :: [String.t()]
  def listed_kinds, do: @listed

  @doc "The listed thread `thread_id` as it reads now, announced to its person's list."
  @spec changed(Prima.Actor.t(), String.t()) :: :ok
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
  @spec removed(Prima.Actor.t(), String.t()) :: :ok
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

  @doc """
  A thread of the athanor as the list shows it, under its person's
  public `name`: a pending card waits on the athanor's person, who alone
  decides one.
  """
  @spec item(Prima.Actor.t(), String.t() | nil, map()) ::
          {:ok, ThreadListed.t()} | {:error, term()}
  def item(actor, name, thread) do
    with {:ok, unread} <- Threads.unread(actor, thread) do
      {:ok,
       ThreadListed.new(actor, String.to_existing_atom(thread.kind),
         id: thread.id,
         title: thread.title,
         people: [name],
         last_activity: thread.last_message_at || thread.inserted_at,
         waits_on_you: match?([_ | _], Threads.pending_approvals(actor, thread.id)),
         unread: unread,
         archived: Threads.archived?(thread)
       )}
    end
  end

  @doc "Whose list an athanor's thread is on: the athanor's person."
  @spec person(Prima.Actor.t()) :: {:ok, String.t()} | {:error, term()}
  def person(%Prima.Actor{athanor_id: athanor_id}) do
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
    Logger.warning(
      "[Cyfr.Providers.Threads] thread #{thread_id} not announced: #{inspect(reason)}"
    )
  end

  defp serialized(thread_id, fun),
    do: :global.trans({{__MODULE__, thread_id}, self()}, fun, [node()])
end
