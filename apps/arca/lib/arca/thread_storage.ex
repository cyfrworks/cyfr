# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadStorage do
  @moduledoc """
  Persistence for the athanor's threads and their messages — the
  durable record every member reads (`Aqua.Tape` writes it,
  `PrismWeb.ThreadPaneLive` shows it).

  A thread belongs to the athanor of the context that opened it, and so
  to its person, who reads it, sends the next message and decides a
  pending approval. Reads scope through
  `Arca.QueryHelpers.where_tenant/2` (a context without an athanor raises,
  fail closed) and every write stamps the context's athanor.

  Message rows are appended in `seq` order by `append/3`; the unique index
  on `(thread_id, seq)` is what makes two writers appending at once
  safe — the loser retries with the next number. Approval rows move through
  `resolve_approval/4`, a compare-and-set on `status`, so two members
  clicking the same card cannot both run it.

  ## The claim

  `active_turn_id` is which turn holds the thread, and it is the only
  evidence of that: a runner process on some member is a lookup, never
  ownership. `claim/4` takes it in one statement naming the turn and the
  consumed sequence the claimant read, `release/3` gives it up, and
  `take_claim!/3` is the takeover a recovery makes inside its own
  transaction — admitted only for a thread nobody holds or one whose
  holder is not a live peer (`claim_holder/2`). The claim has no lease of
  its own: it is alive while its holder's member is.
  """

  import Ecto.Query
  # Every function takes the `Prima.Actor` first and matches it in the
  # head; an actor whose athanor is nil OR the empty string is
  # `{:error, :no_athanor}` before any query, and `insert_message!/3`,
  # which runs inside a caller's transaction, raises instead. The thread
  # cap is asked through `Prima.Caps`, the port, rather than by naming the
  # tenancy domain above this layer.
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Repo
  alias Arca.Schemas.Athanor
  alias Arca.Schemas.Thread
  alias Arca.Schemas.Message

  # The two reserved row authors, spelled once in the schema.
  @agent_author Message.agent_author()
  @system_author Message.system_author()
  @room_kinds Thread.room_kinds()

  # The rows a person reads as posts: what a turn writes for itself
  # (`tool_call`, `tool_result`, `compaction`, `turn_aborted`) is none.
  @post_kinds ~w(text approval error system opening pointer report)

  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc """
  The kinds of a person's rooms, the threads a crew member's child thread
  works under and their list holds: daily and workspace threads
  (`Arca.Schemas.Thread.room_kinds/0`).
  """
  @spec room_kinds() :: [String.t()]
  def room_kinds, do: @room_kinds

  @doc """
  The athanor's threads, most recently active first. `opts`: `:limit`
  (200 by default) and `:kind` (one of `Arca.Schemas.Thread.kinds/0`, or a
  list of them; every kind when absent).
  """
  @spec list(Prima.Actor.t(), keyword()) :: [map()] | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{athanor_id: athanor_id} = actor, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.list", fn ->
      limit = Keyword.get(opts, :limit, 200)

      query =
        from(c in Thread,
          order_by: [desc: coalesce(c.last_message_at, c.inserted_at)],
          limit: ^limit
        )

      query =
        case Keyword.get(opts, :kind) do
          nil -> query
          kinds when is_list(kinds) -> from(c in query, where: c.kind in ^kinds)
          kind -> from(c in query, where: c.kind == ^kind)
        end

      query
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :no_athanor}

  @doc "One thread of the context's athanor."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.get", fn -> thread_row(actor, id) end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  # The row itself, for the writers here that act on it inside their own
  # rescue or transaction; `get/2` is its projection.
  # arca:db-raise-ok inside the caller's rescue.
  defp thread_row(actor, id) do
    from(c in Thread, where: c.id == ^id)
    |> QueryHelpers.where_tenant(actor)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      thread -> {:ok, thread}
    end
  end

  @doc """
  The daily thread of `day` in the context's athanor, made when there is
  none: one per date, titled with the date, attributed to the context's
  user. Nothing else about the day is stored; which date is today is the
  caller's (`Aqua.Day`).

  A thread is a row a client's send can mint, so a new day is counted
  against the operator's `max_threads_per_athanor` ceiling, asked through
  `Prima.Caps`. One locking transaction takes the athanor's row, looks for
  the day, counts and inserts, so two callers making the same day at once
  leave one row and both answer it; an athanor with no row of its own is
  held to one row per day by the unique index on `(athanor_id, day)`, and
  the caller that loses that race reads the winner's. A refusal is the
  port's answer unchanged: `{:limit_reached, :max_threads_per_athanor,
  cap}` at the ceiling, `{:cap_unverifiable, :max_threads_per_athanor}`
  when the cap or the count cannot be read.
  """
  @spec daily(Prima.Actor.t(), Date.t()) ::
          {:ok, map()}
          | {:error,
             :no_athanor
             | {:invalid, map()}
             | {:limit_reached, :max_threads_per_athanor, pos_integer()}
             | {:cap_unverifiable, :max_threads_per_athanor}
             | :database_error}
  def daily(%Prima.Actor{athanor_id: athanor_id} = actor, %Date{} = day)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.daily", fn ->
      case Repo.locking_transaction(fn -> day_or_new(actor, day) end) do
        {:error, %Ecto.Changeset{errors: errors}} = refused ->
          if unique_day?(errors), do: day_row(actor, day), else: refused

        answer ->
          answer
      end
    end)
    |> Arca.Data.project()
  end

  def daily(%Prima.Actor{}, _day), do: {:error, :no_athanor}

  @doc """
  The daily thread of `day` in the context's athanor, if one was made:
  a read, which makes nothing. `{:error, :not_found}` for a day with none.
  """
  @spec day(Prima.Actor.t(), Date.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def day(%Prima.Actor{athanor_id: athanor_id} = actor, %Date{} = day)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.day", fn -> day_row(actor, day) end)
    |> Arca.Data.project()
  end

  def day(%Prima.Actor{}, _day), do: {:error, :no_athanor}

  defp day_or_new(actor, day) do
    lock_athanor(actor)

    case day_row(actor, day) do
      {:ok, thread} ->
        thread

      {:error, :not_found} ->
        insert_thread(actor, %{kind: "daily", day: day, title: Date.to_iso8601(day)})
    end
  end

  # arca:db-raise-ok inside the caller's rescue or transaction.
  defp day_row(actor, day) do
    from(c in Thread, where: c.kind == "daily" and c.day == ^day)
    |> QueryHelpers.where_tenant(actor)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      thread -> {:ok, thread}
    end
  end

  # The `(athanor_id, day)` index, by the field each adapter reports it on.
  defp unique_day?(errors) do
    Enum.any?(errors, fn
      {field, {_msg, meta}} when field in [:athanor_id, :day] ->
        Keyword.get(meta, :constraint) == :unique

      _other ->
        false
    end)
  end

  @doc """
  The daily thread of the context's athanor nearest `day` on one side of
  it: the latest one before it (`:before`) or the earliest one after it
  (`:after`). `{:error, :not_found}` when there is none that way.
  """
  @spec adjacent_day(Prima.Actor.t(), Date.t(), :before | :after) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def adjacent_day(%Prima.Actor{athanor_id: athanor_id} = actor, %Date{} = day, side)
      when is_binary(athanor_id) and athanor_id != "" and side in [:before, :after] do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.adjacent_day", fn ->
      query =
        case side do
          :before ->
            from(c in Thread, where: c.kind == "daily" and c.day < ^day, order_by: [desc: c.day])

          :after ->
            from(c in Thread, where: c.kind == "daily" and c.day > ^day, order_by: [asc: c.day])
        end

      from(c in query, limit: 1)
      |> QueryHelpers.where_tenant(actor)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        thread -> {:ok, thread}
      end
    end)
    |> Arca.Data.project()
  end

  def adjacent_day(%Prima.Actor{}, _day, _side), do: {:error, :no_athanor}

  @doc """
  Move the thread's read mark to `seq`, forward only: one statement that
  lands only on a mark below it, so of two devices marking at once the
  further one stands, and a mark never moves back. A `seq` past the
  thread's last message marks that message. Answers the mark as it
  stands after the statement.
  """
  @spec mark_read(Prima.Actor.t(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :not_found | :database_error}
  def mark_read(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, seq)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_integer(seq) and seq >= 0 do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.mark_read", fn ->
      last =
        from(m in Message,
          where: m.thread_id == ^thread_id and m.athanor_id == ^athanor_id,
          select: coalesce(max(m.seq), 0)
        )
        |> Repo.one()

      mark = min(seq, last)

      {_count, _} =
        from(c in Thread, where: c.id == ^thread_id and c.read_seq < ^mark)
        |> QueryHelpers.where_tenant(actor)
        |> Repo.update_all(set: [read_seq: mark])

      with {:ok, thread} <- thread_row(actor, thread_id), do: {:ok, thread.read_seq}
    end)
  end

  def mark_read(%Prima.Actor{}, _thread_id, _seq), do: {:error, :no_athanor}

  @doc """
  How many posts of the thread the person has not seen: the messages past
  its read mark that the person did not send, a schedule's line among
  them, since it is written in the server's voice. A turn's own rows are
  no posts.
  """
  @spec unread(Prima.Actor.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def unread(%Prima.Actor{athanor_id: athanor_id} = actor, %{id: thread_id, read_seq: mark})
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_integer(mark) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.unread", fn ->
      count =
        from(m in Message,
          where: m.thread_id == ^thread_id and m.seq > ^mark and m.kind in ^@post_kinds,
          where: m.sent_by != "person" or m.author in ^[@agent_author, @system_author]
        )
        |> QueryHelpers.where_tenant(actor)
        |> Repo.aggregate(:count)

      {:ok, count}
    end)
  end

  def unread(%Prima.Actor{}, _thread), do: {:error, :no_athanor}

  @doc false
  # A thread inserted inside the caller's locking transaction, counted
  # against the athanor's ceiling under the athanor's row lock as
  # `daily/2` counts a day: a refusal rolls the caller back. An
  # in-transaction helper for Arca's own writers (`Arca.TurnStorage`'s
  # workspace opening), answering the schema row.
  @spec insert_thread!(Prima.Actor.t(), map()) :: Thread.t()
  # arca:db-raise-ok inside the caller's transaction
  def insert_thread!(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs),
      do: insert_thread(actor, attrs)

  def insert_thread!(%Prima.Actor{}, _attrs),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.insert_thread!/2")

  # In the caller's locking transaction, which has taken the athanor's row
  # before the count, so creates into one athanor count and insert one at
  # a time.
  defp insert_thread(actor, attrs) do
    lock_athanor(actor)

    with :ok <-
           Prima.Caps.check_counted(actor, :max_threads_per_athanor, fn ->
             {:ok, count(actor)}
           end),
         {:ok, thread} <-
           %Thread{}
           |> Thread.changeset(%{
             id: attrs[:id] || Prima.UUID7.generate_id("thread"),
             athanor_id: actor.athanor_id,
             kind: attrs.kind,
             parent_id: attrs[:parent_id],
             day: attrs[:day],
             opened_from: attrs[:opened_from],
             workspace_state: attrs[:workspace_state],
             agent: attrs[:agent],
             title: attrs.title,
             created_by: actor.user_id || @system_author
           })
           |> Repo.insert() do
      thread
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  # The athanor's row, held until the caller's transaction ends: what
  # every create of a thread, every write that takes more than one thread
  # row (`lock_threads!/2`) and the blob sweep take first, so they run one
  # at a time in an athanor. An in-transaction helper.
  @spec lock_athanor!(Prima.Actor.t()) :: String.t() | nil
  # arca:db-raise-ok inside the caller's transaction
  def lock_athanor!(%Prima.Actor{athanor_id: athanor_id} = actor)
      when is_binary(athanor_id) and athanor_id != "",
      do: lock_athanor(actor)

  def lock_athanor!(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.lock_athanor!/1")

  @doc false
  # The one order of the rows a write takes among turns, the athanor's row
  # and thread rows, which every write keeps:
  #
  #   * its turns first. A turn's writers take the turn before its thread;
  #     a write that takes more than one turn takes them through one
  #     function, by when each was accepted and then by id
  #     (`Arca.TurnStorage.hold_turns!/2`); a write that stops or removes
  #     turns (a deletion, retention) chooses them and holds them so
  #     before anything else, then asks again under its locks.
  #   * then the athanor's row: shared by the standing check
  #     (`Arca.ExecutionStanding.locked/2`), after the turn; taken for
  #     update, before any standing check of its own, by every create of a
  #     thread and by a write that takes more than one thread row, by a
  #     lock, an update, a delete or a row it adds that names one.
  #   * then the thread rows, those it holds together in id order, which
  #     this function takes after the athanor's row.
  #
  # A write that takes one thread row takes no second, and no athanor lock
  # for it. Nothing takes the athanor's row before a turn's, so no two
  # writes wait on each other across the three. Answers the rows of `ids`
  # that stand, held until the caller's transaction ends. An
  # in-transaction helper.
  @spec lock_threads!(Prima.Actor.t(), [String.t()]) :: [Thread.t()]
  # arca:db-raise-ok inside the caller's transaction
  def lock_threads!(%Prima.Actor{athanor_id: athanor_id} = actor, ids)
      when is_binary(athanor_id) and athanor_id != "" and is_list(ids) do
    lock_athanor(actor)

    from(c in Thread, where: c.id in ^ids, order_by: [asc: c.id])
    |> QueryHelpers.where_tenant(actor)
    |> QueryHelpers.for_update()
    |> Repo.all()
  end

  def lock_threads!(%Prima.Actor{}, _ids),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.lock_threads!/2")

  # `threads.athanor_id` names no foreign key, so a create in an athanor
  # with no row lands with nothing locked; only an athanor with a row has
  # one to hold.
  defp lock_athanor(%Prima.Actor{athanor_id: athanor_id}) do
    from(a in Athanor, where: a.id == ^athanor_id, select: a.id)
    |> QueryHelpers.for_update()
    |> Repo.one()
  end

  # How many threads the athanor holds, read under its row lock.
  defp count(%Prima.Actor{} = actor) do
    Repo.aggregate(from(c in Thread, where: c.athanor_id == ^actor.athanor_id), :count)
  end

  @doc """
  Update a thread's title, agent, turn cursor or last
  activity.
  """
  @spec update(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :database_error | {:invalid, map()}}
  def update(%Prima.Actor{athanor_id: athanor_id} = actor, id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.update", fn ->
      with {:ok, thread} <- thread_row(actor, id) do
        attrs =
          attrs
          |> Map.take([:title, :agent, :turn_seq, :last_message_at])

        thread |> Thread.changeset(attrs) |> Repo.update()
      end
    end)
    |> Arca.Data.project()
  end

  def update(%Prima.Actor{}, _id, _attrs), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Child threads
  # ---------------------------------------------------------------------------

  @doc """
  The child thread `member` works in under the room `room_id`: the one
  that stands (not archived), made when there is none, titled by the
  member and counted against the athanor's thread ceiling as a new day is
  (`daily/2`). One locking transaction takes the athanor's row before it
  looks, so two callers never make two. `{:error, :not_found}` when the
  room is not a thread of the athanor, `{:error, :not_a_room}` when it is
  itself a child thread: a room is a daily or a workspace thread of the
  same athanor (`Arca.Schemas.Thread.room_kinds/0`).
  """
  @spec crew_thread(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error,
             :no_athanor
             | :not_found
             | :not_a_room
             | {:limit_reached, :max_threads_per_athanor, pos_integer()}
             | {:cap_unverifiable, :max_threads_per_athanor}
             | :database_error}
  def crew_thread(%Prima.Actor{athanor_id: athanor_id} = actor, room_id, member)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(room_id) and
             is_binary(member) and member != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.crew_thread", fn ->
      Repo.locking_transaction(fn ->
        lock_athanor(actor)

        with {:ok, %Thread{kind: kind} = room} when kind in @room_kinds <-
               thread_row(actor, room_id),
             nil <- standing_child(actor, room.id, member) do
          insert_thread(actor, %{
            kind: "crew",
            parent_id: room.id,
            agent: member,
            title: member
          })
        else
          {:ok, %Thread{}} -> Repo.rollback(:not_a_room)
          %Thread{} = child -> child
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def crew_thread(%Prima.Actor{}, _room_id, _member), do: {:error, :no_athanor}

  defp standing_child(actor, room_id, member) do
    from(c in Thread,
      where: c.kind == "crew" and c.parent_id == ^room_id and c.agent == ^member,
      where: is_nil(c.archived_at),
      limit: 1
    )
    |> QueryHelpers.where_tenant(actor)
    |> Repo.one()
  end

  @doc "The child threads of the room `room_id`, archived ones included, oldest first."
  @spec children(Prima.Actor.t(), String.t()) :: [map()] | {:error, :no_athanor | :database_error}
  def children(%Prima.Actor{athanor_id: athanor_id} = actor, room_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(room_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.children", fn ->
      from(c in Thread,
        where: c.kind == "crew" and c.parent_id == ^room_id,
        order_by: [asc: c.inserted_at, asc: c.id]
      )
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
    end)
    |> Arca.Data.project()
  end

  def children(%Prima.Actor{}, _room_id), do: {:error, :no_athanor}

  @doc """
  Retire the child thread `id`: from now on it admits nothing, and the
  next request to its member opens a new one. Every open turn of it —
  accepted, running, paused or suspended — is cancelled in the same
  transaction that marks it, each with its reply recorded
  (`Arca.TurnStorage.cancel_open!/4`, under the root's grant `attrs`
  carry), so a crash after the commit leaves nothing to recover. Answers
  the thread and the cancelled turns with the steps their holders'
  runtime cancels; archiving one already archived answers it unchanged
  with none; a thread of the person's own is `{:error, :not_crew}`.
  """
  @spec archive(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{thread: map(), cancelled: [map()]}}
          | {:error, :no_athanor | :not_found | :not_crew | :database_error}
  def archive(actor, id, attrs \\ %{})

  def archive(%Prima.Actor{athanor_id: athanor_id} = actor, id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.archive", fn ->
      Repo.locking_transaction(fn ->
        case thread_row(actor, id) do
          # The turns first and the thread after them, the order a turn's
          # own writers take them in. A turn accepted after the scan is
          # refused its claim (`Arca.TurnStorage.start/3`).
          {:ok, %Thread{kind: "crew", archived_at: nil}} ->
            cancel = Map.put_new(attrs, :error, "the thread was archived")
            cancelled = Arca.TurnStorage.cancel_open!(actor, id, cancel, :reply)
            {:ok, thread} = thread_row(actor, id)

            archived =
              thread |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()

            %{thread: archived, cancelled: cancelled}

          {:ok, %Thread{kind: "crew"} = thread} ->
            %{thread: thread, cancelled: []}

          {:ok, %Thread{}} ->
            Repo.rollback(:not_crew)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def archive(%Prima.Actor{}, _id, _attrs), do: {:error, :no_athanor}

  @doc """
  Forget the brain session (`brain_session`) of every thread of the
  actor's athanor whose agent is one of `agents`, so each one's next
  request opens a new session, and raise its `brain_generation` in the
  same statement, so a turn begun before it keeps no session it answers
  with afterwards (`Arca.TurnStorage.record_response/4`). Answers how
  many threads it moved on.
  """
  @spec forget_sessions(Prima.Actor.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def forget_sessions(%Prima.Actor{athanor_id: athanor_id} = actor, agents)
      when is_binary(athanor_id) and athanor_id != "" and is_list(agents) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.forget_sessions", fn ->
      {count, _} =
        from(c in Thread, where: c.agent in ^agents)
        |> QueryHelpers.where_tenant(actor)
        |> Repo.update_all(set: [brain_session: nil], inc: [brain_generation: 1])

      {:ok, count}
    end)
  end

  def forget_sessions(%Prima.Actor{}, _agents), do: {:error, :no_athanor}

  @doc """
  The requests still waiting on a crew member's reply, oldest first: of
  the thread `opts[:thread_id]` names, else of the whole athanor.
  """
  @spec pending_requests(Prima.Actor.t(), keyword()) ::
          [map()] | {:error, :no_athanor | :database_error}
  def pending_requests(%Prima.Actor{athanor_id: athanor_id} = actor, opts \\ [])
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.pending_requests", fn ->
      query =
        from(m in Message,
          # A card's notice waits too, but answers a request and is none.
          where: not is_nil(m.addressee) and m.status == "pending" and m.kind == "text",
          where: is_nil(m.reply_to),
          order_by: [asc: m.inserted_at, asc: m.seq]
        )

      query =
        case Keyword.get(opts, :thread_id) do
          nil -> query
          thread_id -> from(m in query, where: m.thread_id == ^thread_id)
        end

      query
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
    end)
    |> Arca.Data.project()
  end

  # ---------------------------------------------------------------------------
  # The thread claim
  # ---------------------------------------------------------------------------

  @doc """
  Take the thread for `turn_id`, naming the consumed sequence the claimant
  read.

  One statement, and it has to be: the claim and the sequence check
  together are what stop two members from both believing they run the
  thread. It lands only on a thread nobody holds whose `turn_seq` still
  reads what the claimant read, so of two members planning from the same
  read exactly one write matches.

  A claim that wrote nothing is told which of the two conditions refused
  it, from a second read that decides nothing: `{:error, :stale}` when a
  peer accepted the next message first — re-read, because which turn is
  next may have changed — and `{:error, {:held_elsewhere, turn_id}}` when
  another turn holds it. A thread this turn already holds answers `{:ok, thread}`,
  so a claimant that lost track of its own claim may ask again.
  """
  @spec claim(Prima.Actor.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()}
          | {:error,
             :no_athanor
             | :not_found
             | :stale
             | {:held_elsewhere, String.t()}
             | :database_error}
  def claim(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, turn_id, turn_seq)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(turn_id) and is_integer(turn_seq) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.claim", fn ->
      claimed =
        from(c in Thread,
          where: c.id == ^thread_id and c.athanor_id == ^athanor_id,
          where: c.turn_seq == ^turn_seq and is_nil(c.active_turn_id)
        )
        |> Repo.update_all(set: [active_turn_id: turn_id])

      case claimed do
        {1, _} -> thread_row(actor, thread_id)
        {0, _} -> claim_refused(actor, thread_id, turn_id)
      end
    end)
    |> Arca.Data.project()
  end

  def claim(%Prima.Actor{}, _thread_id, _turn_id, _turn_seq), do: {:error, :no_athanor}

  # Why the one statement wrote nothing. A read, so it decides nothing and
  # cannot be raced into admitting anything.
  defp claim_refused(actor, thread_id, turn_id) do
    case thread_row(actor, thread_id) do
      {:ok, %Thread{active_turn_id: ^turn_id} = thread} ->
        {:ok, thread}

      {:ok, %Thread{active_turn_id: held}} when is_binary(held) ->
        {:error, {:held_elsewhere, held}}

      # Nobody holds it now, so the sequence is what refused the claim —
      # or a release landed between the statement and this read. Both say
      # the same thing to the claimant: read the thread again.
      {:ok, %Thread{}} ->
        {:error, :stale}

      other ->
        other
    end
  end

  @doc """
  Give the thread's claim up, if this turn still holds it: one statement,
  so a turn whose claim a successor already took releases nothing of its
  successor's.

  An approval pause keeps the claim — the turn is still this member's
  work, waiting on a person. Every terminal transition releases it.
  """
  @spec release(Prima.Actor.t(), String.t(), String.t()) ::
          :ok | {:error, :no_athanor | :not_held | :database_error}
  def release(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(turn_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.release", fn ->
      case release_all!(actor, thread_id, turn_id) do
        {1, _} -> :ok
        {0, _} -> {:error, :not_held}
      end
    end)
    |> Arca.Data.project()
  end

  def release(%Prima.Actor{}, _thread_id, _turn_id), do: {:error, :no_athanor}

  @doc """
  `release/3` for a caller that owns the transaction: the count is the
  caller's to read, and a release that matched nothing is not an error
  there — a terminal turn that never held the claim releases nothing.
  """
  @spec release_all!(Prima.Actor.t(), String.t(), String.t()) ::
          {non_neg_integer(), nil | [term()]}
  # arca:db-raise-ok inside the caller's transaction
  def release_all!(%Prima.Actor{athanor_id: athanor_id}, thread_id, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(turn_id) do
    from(c in Thread,
      where: c.id == ^thread_id and c.athanor_id == ^athanor_id,
      where: c.active_turn_id == ^turn_id
    )
    |> Repo.update_all(set: [active_turn_id: nil])
  end

  def release_all!(%Prima.Actor{}, _thread_id, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.release_all!/3")

  @doc """
  Take the claim for `turn_id` inside the caller's transaction — the one
  place a claim may be taken from a turn that already holds it, and so
  the one place a recovery is admitted.

  The row admits the take only when the thread is free, or held by a turn
  whose runner is not a LIVE PEER: a member reads no registry and infers
  nothing from "the holder is not on my node". The liveness test is a
  subquery of the same statement, so a peer that renews its cell slot
  between a caller's read and its write cannot lose its turn to that
  caller, and a caller that rolls back spends nothing.

  The turn being taken is not itself an exception. A member that finds
  the thread already naming the turn it wants still has to pass the
  liveness test, or a peer's running turn would be recoverable by the
  first member to name it. A member's own turns are its own — a
  `runner_id` equal to this boot is never a live peer — so a member picks
  up what it left behind without waiting for anything. Rolls the caller's
  transaction back with `:held_elsewhere` when a live peer holds the
  thread.
  """
  @spec take_claim!(Prima.Actor.t(), String.t(), String.t()) :: :ok
  # arca:db-raise-ok inside the caller's transaction
  def take_claim!(%Prima.Actor{athanor_id: athanor_id}, thread_id, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(turn_id) do
    taken =
      from(c in Thread,
        where: c.id == ^thread_id and c.athanor_id == ^athanor_id,
        where:
          is_nil(c.active_turn_id) or
            c.active_turn_id not in subquery(live_peer_turns(athanor_id))
      )
      |> Repo.update_all(set: [active_turn_id: turn_id])

    case taken do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:held_elsewhere)
    end
  end

  def take_claim!(%Prima.Actor{}, _thread_id, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.take_claim!/3")

  @doc """
  Which turn holds the thread, and whether a live peer is running it.

  The one question a member asks before it recovers anything: absence from
  a local registry is never evidence, and this read is the row's answer.
  `live_peer?` is true only for a holder whose `runner_id` is another
  member's boot with a cell slot that has not lapsed on database time.
  """
  @spec claim_holder(Prima.Actor.t(), String.t()) ::
          {:ok,
           %{
             turn_id: String.t() | nil,
             runner_id: String.t() | nil,
             live_peer?: boolean()
           }}
          | {:error, :no_athanor | :not_found | :database_error}
  def claim_holder(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.claim_holder", fn ->
      with {:ok, thread} <- thread_row(actor, thread_id) do
        {:ok, holder_of(athanor_id, thread)}
      end
    end)
    |> Arca.Data.project()
  end

  def claim_holder(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  defp holder_of(_athanor_id, %Thread{active_turn_id: nil}),
    do: %{turn_id: nil, runner_id: nil, live_peer?: false}

  defp holder_of(athanor_id, %Thread{active_turn_id: turn_id}) do
    runner_id =
      Repo.one(
        from(t in Arca.Schemas.Turn,
          where: t.athanor_id == ^athanor_id and t.id == ^turn_id,
          select: t.runner_id
        )
      )

    live? = Repo.exists?(from(t in live_peer_turns(athanor_id), where: t.id == ^turn_id))
    %{turn_id: turn_id, runner_id: runner_id, live_peer?: live?}
  end

  # The turns of this athanor a live PEER holds: a turn whose `runner_id`
  # is some other member's boot and whose member's slot in `cell_leases`
  # has not lapsed on the cell's clock (`Arca.ServerMetaStorage.now!/0`).
  #
  # The instant is read from the database and compared inside the
  # statement, so every member decides liveness against one clock. Reading
  # it a moment before the write can only make a lapsed peer look live,
  # which refuses a take; it can never make a live peer look lapsed.
  defp live_peer_turns(athanor_id) do
    me = Prima.Boot.id()

    live_owners =
      from(l in Arca.Schemas.CellLease,
        where: l.lease_until > ^Arca.ServerMetaStorage.now!(),
        select: l.owner
      )

    from(t in Arca.Schemas.Turn,
      where: t.athanor_id == ^athanor_id and t.runner_id != ^me,
      where: t.runner_id in subquery(live_owners),
      select: t.id
    )
  end

  @doc """
  Delete a thread and its messages, and with a room its crew members'
  child threads, read under the athanor's lock a child's creation takes
  (`crew_thread/3`), so a child made during the deletion is in it or made
  after it, when its room is gone. The children's open turns are
  cancelled in the same transaction, recording no reply since the room
  they would answer is going (`Arca.TurnStorage.cancel_open!/4`, under the
  root's grant `attrs` carry). While a child's turn waits on a card the
  deletion is refused `{:error, {:child_awaits_card, member}}`, so the
  person decides there first.

  What other threads kept of it goes in the same transaction: the
  pointers and reports that name it, on every daily thread, and in each
  thread a turn of which read it (a `thread` source on the turn,
  `Prima.Source.thread/1`) the compactions written since the first such
  turn was accepted and the brain's session, whose generation is raised;
  an open turn that read it is cancelled as a stop cancels it, its reply
  recorded, and answered with the others. The turns it stops or
  removes are chosen and held first, then the athanor's row and the
  thread's (`lock_threads!/2`), and the turns asked again under those
  locks: one that opened or read the thread in between sends the
  deletion round again, at most three times, and then it is
  `{:error, :thread_in_use}`. So a delivery from it
  (`Arca.TurnStorage.accept_message/3` for a row naming it) lands before
  the deletion and goes with it, or finds it gone.

  The attachment blobs (`blob_root/1` under the athanor's storage) go
  after the commit, never before the transaction that decides: a refused
  deletion keeps every byte, and a crash or a failed blob delete after the
  commit leaves blobs no row backs, which the retention sweep reclaims
  (`sweep_orphaned_blobs/1`). Answers the cancelled turns with the steps
  their holders' runtime cancels.
  """
  @spec delete(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{cancelled: [map()]}}
          | {:error,
             :no_athanor
             | :not_found
             | {:child_awaits_card, String.t()}
             | :thread_in_use
             | :database_error}
  def delete(actor, id, attrs \\ %{})

  def delete(%Prima.Actor{athanor_id: athanor_id} = actor, id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.delete", fn -> do_delete(actor, id, attrs) end)
    |> Arca.Data.project()
  end

  def delete(%Prima.Actor{}, _id, _attrs), do: {:error, :no_athanor}

  defp do_delete(actor, id, attrs, tries \\ 3) do
    with {:ok, thread} <- thread_row(actor, id) do
      chosen = stopped_turns(actor, thread)

      case Repo.locking_transaction(fn -> delete_rows(actor, id, attrs, chosen) end) do
        {:ok, %{ids: ids, cancelled: cancelled}} ->
          Enum.each(ids, &delete_blobs_after(actor, &1))
          {:ok, %{cancelled: cancelled}}

        {:error, :turns_moved} when tries > 1 ->
          do_delete(actor, id, attrs, tries - 1)

        {:error, :turns_moved} ->
          {:error, :thread_in_use}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The turns a deletion of `thread` stops or removes: every turn of the
  # thread and of its children, which go with them, and the open turns of
  # other threads that read one of them, which it stops.
  defp stopped_turns(%Prima.Actor{athanor_id: athanor_id} = actor, %Thread{} = thread) do
    ids = [thread.id | child_ids(actor, thread)]
    removed_turns(athanor_id, ids, readers(athanor_id, ids))
  end

  defp removed_turns(athanor_id, ids, readers) do
    own =
      from(t in Arca.Schemas.Turn,
        where: t.athanor_id == ^athanor_id and t.thread_id in ^ids,
        select: t.id
      )
      |> Repo.all()

    Enum.uniq(own ++ for({_thread_id, _since, open} <- readers, turn_id <- open, do: turn_id))
  end

  # The turns chosen before the locks still cover those under them; a turn
  # that opened or read the thread in between sends the deletion round
  # again, choosing it first.
  defp still_chosen!(open, chosen),
    do: if(open -- chosen == [], do: :ok, else: Repo.rollback(:turns_moved))

  # arca:unscoped-ok thread_row(actor, id) establishes the thread's
  # ownership, and every child id is read from it under the actor.
  defp delete_rows(%Prima.Actor{athanor_id: athanor_id} = actor, id, attrs, chosen) do
    _held = Arca.TurnStorage.hold_turns!(actor, chosen)

    with [thread] <- lock_threads!(actor, [id]),
         children = child_ids(actor, thread),
         ids = [thread.id | children],
         readers = readers(athanor_id, ids),
         :ok <- still_chosen!(removed_turns(athanor_id, ids, readers), chosen),
         [] <- Arca.TurnStorage.awaiting_card!(actor, children) do
      cancel = Map.put_new(attrs, :error, "the room was deleted")

      cancelled =
        Enum.flat_map(children, &Arca.TurnStorage.cancel_open!(actor, &1, cancel, :silent))

      stopped = forget!(actor, ids, readers, attrs)

      # Explicit message deletion also covers SQLite connections without
      # foreign_keys=ON.
      Repo.delete_all(from(m in Message, where: m.thread_id in ^ids))
      delete_thread_satellites(ids)

      {_, _} =
        from(c in Thread, where: c.id in ^ids)
        |> QueryHelpers.where_tenant(actor)
        |> Repo.delete_all()

      %{ids: ids, cancelled: cancelled ++ stopped}
    else
      # No such thread: the athanor's row and none of its threads held.
      [] -> Repo.rollback(:not_found)
      [member | _] -> Repo.rollback({:child_awaits_card, member})
    end
  end

  # What other threads kept of the threads `ids` a deletion removes,
  # undone in the deleting transaction: the pointers and reports that
  # name one, on every daily thread; and in every thread a turn of which
  # read one (a `thread` source on the turn, `Prima.Source.thread/1`),
  # the compactions written since its first such turn was accepted, which
  # may summarize what was read, and the brain's session, which may hold
  # it, its generation raised so no turn keeps the old one. A turn still
  # open there is cancelled as a stop cancels it, its reply recorded;
  # answers those, for the caller's runtime to stop after the commit.
  # `readers` (`readers/2`) is what the caller read under its locks, whose
  # open turns it already holds.
  # arca:db-raise-ok inside the caller's transaction
  # arca:unscoped-ok every statement names the actor's athanor.
  defp forget!(%Prima.Actor{athanor_id: athanor_id} = actor, ids, readers, attrs) do
    {_, _} =
      Repo.delete_all(
        from(m in Message, where: m.athanor_id == ^athanor_id and m.workspace_id in ^ids)
      )

    for {thread_id, since, _open} <- readers do
      Repo.delete_all(
        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.thread_id == ^thread_id,
          where: m.kind == "compaction" and m.inserted_at >= ^since
        )
      )

      from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^thread_id)
      |> Repo.update_all(set: [brain_session: nil], inc: [brain_generation: 1])
    end

    stop = Map.put(attrs, :error, "what this thread read was deleted")

    Enum.flat_map(readers, fn
      {_thread_id, _since, []} ->
        []

      {thread_id, _since, open} ->
        Arca.TurnStorage.cancel_open!(actor, thread_id, Map.put(stop, :only, open), :reply)
    end)
  end

  # Each thread outside `ids` with a turn whose sources name one of them:
  # when its first such turn was accepted, and those of them still open. A
  # source set is canonical JSON (`Prima.Source.encode/1`), so a thread
  # source reads as one exact object in the text.
  # arca:db-raise-ok inside the caller's transaction
  defp readers(_athanor_id, []), do: []

  defp readers(athanor_id, ids) do
    named =
      Enum.reduce(ids, dynamic(false), fn id, acc ->
        pattern = "%" <> like_escape(thread_source(id)) <> "%"
        dynamic([t], ^acc or fragment("? LIKE ? ESCAPE '!'", t.sources, ^pattern))
      end)

    from(t in Arca.Schemas.Turn,
      where: t.athanor_id == ^athanor_id and t.thread_id not in ^ids,
      where: ^named,
      select: {t.thread_id, t.id, t.accepted_at, t.status}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {thread_id, turns} ->
      since = turns |> Enum.map(&elem(&1, 2)) |> Enum.min(DateTime)
      open = for {_, id, _, status} <- turns, status in Prima.TurnState.open_statuses(), do: id
      {thread_id, since, open}
    end)
  end

  defp thread_source(id),
    do: id |> Prima.Source.thread() |> Prima.Source.to_json() |> Jason.encode!()

  defp like_escape(text), do: String.replace(text, ["!", "%", "_"], &("!" <> &1))

  defp child_ids(actor, %Thread{kind: kind, id: room_id}) when kind in @room_kinds do
    from(c in Thread, where: c.kind == "crew" and c.parent_id == ^room_id, select: c.id)
    |> QueryHelpers.where_tenant(actor)
    |> Repo.all()
  end

  defp child_ids(_actor, %Thread{}), do: []

  # What a failed delete leaves no row backs, and the retention sweep
  # reclaims it.
  defp delete_blobs_after(actor, thread_id) do
    case delete_blobs(actor, thread_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ThreadStorage] the blobs of deleted thread #{thread_id} wait for the sweep: " <>
            inspect(reason)
        )
    end
  end

  # What rides with a thread besides its messages: what its person
  # already answered about tool calls in it.
  # Agent-scope grants are untouched — they belong to the agent, not the
  # thread.
  #
  # arca:unscoped-ok scoped transitively — every id comes from a read the
  # caller already tenant-proved (do_delete's `get`, delete_before's
  # `where_athanor`), and each row names exactly one thread.
  defp delete_thread_satellites(ids) do
    Repo.delete_all(
      from(g in Arca.Schemas.ToolGrant,
        where: g.scope == ^Arca.Schemas.ToolGrant.thread_scope() and g.thread_id in ^ids
      )
    )

    :ok
  end

  @doc """
  Where a thread's attachment bytes live under the athanor's storage:
  `threads/<thread_id>/<message_id>/<filename>`.
  """
  @spec blob_root(String.t()) :: [String.t()]
  def blob_root(thread_id) when is_binary(thread_id),
    do: ["threads", thread_id]

  @doc """
  Reclaim thread blob directories no row backs — the retention
  sweep's leg. The directories are snapshotted FIRST, then the surviving
  rows are read and the orphans removed under the athanor's row lock:
  blobs are written under an existing thread row (`Aqua.Attachments`), or
  under a workspace thread's id inside the transaction that makes its
  row, which holds that lock from before its first byte to its commit
  (`Arca.TurnStorage.open_workspace/2`). So a snapshotted directory
  either has a row (kept) or is a genuine orphan — a concurrent create
  can never lose its bytes to this sweep.
  """
  @spec sweep_orphaned_blobs(Prima.Actor.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_orphaned_blobs(%Prima.Actor{athanor_id: athanor_id} = actor)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.sweep_orphaned_blobs", fn ->
      do_sweep_orphaned_blobs(actor)
    end)
    |> Arca.Data.project()
  end

  def sweep_orphaned_blobs(%Prima.Actor{}), do: {:error, :no_athanor}

  defp do_sweep_orphaned_blobs(actor) do
    with {:ok, entries} <- Arca.list_typed(actor, ["threads"]) do
      dirs = for {name, :dir} <- entries, do: name

      Repo.locking_transaction(fn ->
        lock_athanor(actor)

        alive =
          from(c in Thread, select: c.id)
          |> QueryHelpers.where_tenant(actor)
          |> Repo.all()
          |> MapSet.new()

        dirs
        |> Enum.reject(&MapSet.member?(alive, &1))
        |> Enum.reduce_while({:ok, 0}, fn id, {:ok, reclaimed} ->
          case Arca.delete_tree(actor, blob_root(id)) do
            :ok -> {:cont, {:ok, reclaimed + 1}}
            {:error, :not_found} -> {:cont, {:ok, reclaimed}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end)
      |> case do
        {:ok, answer} -> answer
        {:error, _} = refused -> refused
      end
    end
  end

  # Typed: `:not_found` counts as deleted (nothing stored).
  defp delete_blobs(actor, thread_id) do
    case Arca.delete_tree(actor, blob_root(thread_id)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:storage_delete_failed, reason}}
    end
  end

  @doc """
  The messages of a thread, oldest first. `after_seq:` / `upto_seq:`
  bound the window (exclusive / inclusive) — a turn's task is the human
  rows between the last turn's cursor and the message that started it.
  """
  @spec messages(Prima.Actor.t(), String.t(), keyword()) ::
          [map()] | {:error, :no_athanor | :database_error}
  def messages(actor, thread_id, opts \\ [])

  def messages(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.messages", fn ->
      query =
        from(m in Message, where: m.thread_id == ^thread_id, order_by: [asc: m.seq])

      query =
        case Keyword.get(opts, :after_seq) do
          nil -> query
          seq -> from(m in query, where: m.seq > ^seq)
        end

      query =
        case Keyword.get(opts, :upto_seq) do
          nil -> query
          seq -> from(m in query, where: m.seq <= ^seq)
        end

      # `:limit` bounds a read that would otherwise load every row of a
      # long-lived thread; unset loads all (turn assembly needs the
      # whole transcript).
      query =
        case Keyword.get(opts, :limit) do
          nil -> query
          limit -> from(m in query, limit: ^limit)
        end

      query
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
    end)
    |> Arca.Data.project()
  end

  def messages(%Prima.Actor{}, _thread_id, _opts), do: {:error, :no_athanor}

  @doc """
  The newest `n` messages of a thread, in ascending order.

  The console's transcript view: `messages/3`'s `:limit` takes the OLDEST
  rows (it bounds windowed turn assembly), which is the wrong end for a
  reader opening a long-lived thread.
  """
  @spec latest_messages(Prima.Actor.t(), String.t(), pos_integer()) ::
          [map()] | {:error, term()}
  def latest_messages(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, n)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and is_integer(n) and
             n > 0 do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.latest_messages", fn ->
      from(m in Message,
        where: m.thread_id == ^thread_id,
        order_by: [desc: m.seq],
        limit: ^n
      )
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
      |> Enum.reverse()
    end)
    |> Arca.Data.project()
  end

  def latest_messages(%Prima.Actor{}, _thread_id, _n), do: {:error, :no_athanor}

  @doc "One message of the context's athanor."
  @spec get_message(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get_message(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.get_message", fn -> message_row(actor, id) end)
    |> Arca.Data.project()
  end

  def get_message(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's rescue.
  defp message_row(actor, id) do
    from(m in Message, where: m.id == ^id)
    |> QueryHelpers.where_tenant(actor)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      msg -> {:ok, msg}
    end
  end

  @doc "The approval rows of a thread still waiting on a decision."
  @spec pending_approvals(Prima.Actor.t(), String.t()) ::
          [map()] | {:error, :no_athanor | :database_error}
  def pending_approvals(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.pending_approvals", fn ->
      from(m in Message,
        where:
          m.thread_id == ^thread_id and m.kind == "approval" and
            m.status == "pending",
        order_by: [asc: m.seq]
      )
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
    end)
    |> Arca.Data.project()
  end

  def pending_approvals(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  @doc """
  Append one message to a thread.

  `attrs`: `:author` and `:sent_by` (required), `:kind` (default
  `"text"`), `:content`, `:payload` (a map, stored as JSON), `:status`,
  `:execution_id`. The next
  `seq` is taken inside a transaction; a concurrent appender losing the race
  on the unique index retries.
  """
  @spec append(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :seq_conflict | {:invalid, map()}}
  def append(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    # Rescued like every other write here: the transaction is inside the
    # private helper, where `Arca.DbRescueCoverageTest` (which inspects
    # public heads for repo calls) could not see it — so an outage raised
    # `DBConnection.ConnectionError` into the runner and the LiveView
    # instead of the module's `{:error, :database_error}`.
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadStorage.append", fn ->
      with {:ok, thread} <- thread_row(actor, thread_id) do
        do_append(actor, thread, attrs, 3)
      end
    end)
    |> Arca.Data.project()
  end

  def append(%Prima.Actor{}, _thread_id, _attrs), do: {:error, :no_athanor}

  @doc false
  # Insert one message inside the caller's transaction, at the next `seq`,
  # raising on a store error so the caller's transaction rolls back. The
  # `(thread_id, seq)` race surfaces as `Ecto.InvalidChangesetError`
  # carrying a `:unique` constraint on `:thread_id`; a caller that owns the
  # transaction retries the whole transaction on it
  # (`Arca.TurnStorage.with_seq_retry/1`). Bumps `last_message_at` as
  # `append/3` does. An
  # in-transaction helper: it answers the schema row to Arca's own
  # transactions, never across the boundary.
  @spec insert_message!(Prima.Actor.t(), Thread.t(), map()) :: Message.t()
  # arca:db-raise-ok inside the caller's transaction
  def insert_message!(%Prima.Actor{athanor_id: athanor_id} = actor, %Thread{} = thread, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    now = DateTime.utc_now()

    seq =
      Repo.one(
        from(m in Message,
          where: m.thread_id == ^thread.id and m.athanor_id == ^actor.athanor_id,
          select: coalesce(max(m.seq), 0)
        )
      ) + 1

    msg = Repo.insert!(Message.changeset(%Message{}, row(actor, thread, attrs, seq, now)))

    thread
    |> Thread.changeset(%{last_message_at: now})
    |> Repo.update!()

    msg
  end

  def insert_message!(%Prima.Actor{}, _thread, _attrs),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.insert_message!/3")

  @doc """
  The message a sender accepted under `client_id` in any daily thread of
  the context's athanor, if any: where a retry that crossed midnight was
  first accepted (`Aqua.ScheduleTurns`). A client id names one message
  per thread, so two daily threads holding it is no answer either.
  """
  @spec daily_message(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def daily_message(%Prima.Actor{athanor_id: athanor_id} = actor, client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(client_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.daily_message", fn ->
      from(m in Message,
        join: c in Thread,
        on: c.id == m.thread_id and c.athanor_id == m.athanor_id,
        where: m.client_id == ^client_id and c.kind == "daily",
        limit: 2
      )
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
      |> case do
        [msg] -> {:ok, msg}
        _none_or_two -> {:error, :not_found}
      end
    end)
    |> Arca.Data.project()
  end

  def daily_message(%Prima.Actor{}, _client_id), do: {:error, :no_athanor}

  @doc "The message a sender accepted under `client_id` in this thread, if any."
  @spec get_by_client_id(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get_by_client_id(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, client_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(client_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.get_by_client_id", fn ->
      case Repo.one(
             from(m in Message,
               where: m.thread_id == ^thread_id and m.athanor_id == ^actor.athanor_id,
               where: m.client_id == ^client_id
             )
           ) do
        nil -> {:error, :not_found}
        msg -> {:ok, msg}
      end
    end)
    |> Arca.Data.project()
  end

  def get_by_client_id(%Prima.Actor{}, _thread_id, _client_id), do: {:error, :no_athanor}

  defp do_append(_ctx, _thread, _attrs, 0), do: {:error, :seq_conflict}

  defp do_append(actor, thread, attrs, retries) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        seq =
          Repo.one(
            from(m in Message,
              where: m.thread_id == ^thread.id and m.athanor_id == ^actor.athanor_id,
              select: coalesce(max(m.seq), 0)
            )
          ) + 1

        changeset = Message.changeset(%Message{}, row(actor, thread, attrs, seq, now))

        case Repo.insert(changeset) do
          {:ok, msg} ->
            thread
            |> Thread.changeset(%{last_message_at: now})
            |> Repo.update!()

            msg

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, msg} ->
        {:ok, msg}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # Only the (thread_id, seq) unique race retries — any other
        # changeset error on that field is a real refusal, not the race.
        case Keyword.get(errors, :thread_id) do
          {_msg, meta} when is_list(meta) ->
            if Keyword.get(meta, :constraint) == :unique,
              do: do_append(actor, thread, attrs, retries - 1),
              else: {:error, changeset}

          _other ->
            {:error, changeset}
        end
    end
  end

  # The columns of one message row. `sent_by` is required on every row
  # (`Arca.Schemas.Message`): a writer that names none is refused.
  defp row(actor, thread, attrs, seq, now) do
    %{
      id: attrs[:id] || Prima.UUID7.generate_id("msg"),
      thread_id: thread.id,
      athanor_id: actor.athanor_id,
      seq: seq,
      author: attrs[:author],
      sent_by: attrs[:sent_by],
      addressee: attrs[:addressee],
      reply_to: attrs[:reply_to],
      outcome: attrs[:outcome],
      kind: attrs[:kind] || "text",
      content: attrs[:content] || "",
      payload: encode_json(attrs[:payload]),
      status: attrs[:status],
      execution_id: attrs[:execution_id],
      turn_id: attrs[:turn_id],
      approval_id: attrs[:approval_id],
      client_id: attrs[:client_id],
      workspace_id: attrs[:workspace_id],
      inserted_at: now
    }
  end

  @doc "Replace a message's content/payload (the runner finalising a streamed turn)."
  @spec update_message(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :database_error | {:invalid, map()}}
  def update_message(%Prima.Actor{athanor_id: athanor_id} = actor, id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.update_message", fn ->
      with {:ok, msg} <- message_row(actor, id) do
        attrs =
          attrs
          |> Map.take([:content, :payload, :status, :execution_id])
          |> Map.update(:payload, nil, &encode_json/1)
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        msg |> Message.changeset(attrs) |> Repo.update()
      end
    end)
    |> Arca.Data.project()
  end

  def update_message(%Prima.Actor{}, _id, _attrs), do: {:error, :no_athanor}

  @doc """
  Move an approval row from one of `from` to `to` — compare-and-set on
  `status`, so a second decision on the same card sees
  `{:error, :already_resolved}` instead of running it twice. `attrs` may
  carry `:resolution` (a map, stored as JSON); `resolved_by` is the
  context's user and `resolved_at` is now unless the row is only being
  marked `"running"`.
  """
  @spec resolve_approval(
          Prima.Actor.t(),
          String.t(),
          [String.t()] | String.t(),
          String.t(),
          map()
        ) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :already_resolved | :database_error}
  def resolve_approval(actor, id, from, to, attrs \\ %{})

  def resolve_approval(%Prima.Actor{athanor_id: athanor_id} = actor, id, from, to, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and
             to in ~w(running approved declined error) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.resolve_approval", fn ->
      do_resolve_approval(actor, id, from, to, attrs)
    end)
    |> Arca.Data.project()
  end

  def resolve_approval(%Prima.Actor{}, _id, _from, _to, _attrs), do: {:error, :no_athanor}

  defp do_resolve_approval(actor, id, from, to, attrs) do
    from = List.wrap(from)
    now = DateTime.utc_now()

    updates =
      [status: to, resolved_by: actor.user_id || @system_author]
      |> Keyword.merge(if(to == "running", do: [], else: [resolved_at: now]))
      |> Keyword.merge(
        case attrs[:resolution] do
          nil -> []
          resolution -> [resolution: encode_json(resolution)]
        end
      )

    {count, _} =
      from(m in Message, where: m.id == ^id and m.kind == "approval" and m.status in ^from)
      |> QueryHelpers.where_tenant(actor)
      |> Repo.update_all(set: updates)

    case count do
      1 ->
        message_row(actor, id)

      0 ->
        case message_row(actor, id) do
          {:ok, _} -> {:error, :already_resolved}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc "A message's `payload` decoded (`%{}` when none)."
  @spec payload(map()) :: map()
  def payload(%{payload: nil}), do: %{}
  def payload(%{payload: json}), do: decode_map(json, "payload")

  @doc "A message's `resolution` decoded (`%{}` when none)."
  @spec resolution(map()) :: map()
  def resolution(%{resolution: nil}), do: %{}
  def resolution(%{resolution: json}), do: decode_map(json, "resolution")

  # ---------------------------------------------------------------------------
  # Restart recovery / retention
  # ---------------------------------------------------------------------------

  @doc """
  Delete the athanor's threads whose last activity is older than
  `cutoff` — messages and attachment blobs included, the blobs after the
  rows' transaction has committed — and with each what
  other threads kept of it, as a deletion forgets it: the pointers and
  reports that name it, and in the threads that read it their later
  compactions and the brain's session. A thread with an open turn, one an
  open turn has read, and a workspace thread still `open` or `needs_you`
  are never among them. The context is the athanor's (retention walks
  each with an internal context).
  """
  @spec delete_before(Prima.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def delete_before(%Prima.Actor{athanor_id: athanor_id} = actor, %DateTime{} = cutoff)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadStorage.delete_before", fn ->
      delete_before_rows(actor, cutoff)
    end)
    |> Arca.Data.project()
  end

  def delete_before(%Prima.Actor{}, _cutoff), do: {:error, :no_athanor}

  # Which threads go is decided in the transaction that deletes them, and
  # their bytes go only once it has committed. The candidates are read,
  # their rows taken in the one order of a write that takes more than one
  # (`lock_threads!/2`), and the window
  # asked again over the rows as they then stand: a thread that a post
  # landed in, that was opened again, or that a turn began in meanwhile
  # is left, and counted as kept. Every kind of thread retention removes
  # goes this one way. A blob delete that fails after the commit leaves
  # bytes no row backs, which the sweep reclaims
  # (`sweep_orphaned_blobs/1`), as a hand delete does.
  defp delete_before_rows(actor, cutoff) do
    case stale_ids(actor, cutoff) do
      [] ->
        {:ok, 0}

      candidates ->
        Repo.locking_transaction(fn ->
          # The turns of the threads it may remove, which go with them,
          # before the athanor's row and the threads (`lock_threads!/2`).
          held =
            Arca.TurnStorage.hold_turns!(
              actor,
              from(t in Arca.Schemas.Turn, where: t.thread_id in ^candidates)
            )

          _threads = lock_threads!(actor, candidates)
          stale = MapSet.new(stale_ids(actor, cutoff))
          deletable = Enum.filter(candidates, &MapSet.member?(stale, &1))

          # A turn a removed thread took after the turns were held keeps
          # the threads for the next cycle.
          if removed_turns(actor.athanor_id, deletable, []) -- held != [],
            do: Repo.rollback(:turns_moved)

          # No open turn had read these (`stale_ids/2`); one that read
          # them since keeps them for the next cycle. That is asked before
          # anything is forgotten, so retention stops no turn and takes no
          # turn's row after the athanor's.
          readers = readers(actor.athanor_id, deletable)

          if Enum.any?(readers, fn {_thread_id, _since, open} -> open != [] end),
            do: Repo.rollback(:read_by_an_open_turn)

          [] = forget!(actor, deletable, readers, %{})

          Repo.delete_all(from(m in Message, where: m.thread_id in ^deletable))
          delete_thread_satellites(deletable)

          {count, _} =
            from(c in Thread, where: c.id in ^deletable)
            |> QueryHelpers.where_tenant(actor)
            |> Repo.delete_all()

          {count, deletable}
        end)
        |> case do
          {:ok, {count, deleted}} ->
            Enum.each(deleted, &delete_blobs_after(actor, &1))
            {:ok, count}

          {:error, reason} when reason in [:read_by_an_open_turn, :turns_moved] ->
            {:ok, 0}
        end
    end
  end

  # The retention window both verbs speak, scoped the one way this module
  # scopes: the athanor's threads whose last activity is older than
  # `cutoff`, never one holding an open turn, one a workspace thread still
  # at work or waiting on its person, or one an open turn has read (its
  # `thread` sources, `Prima.Source.thread/1`), whose forgetting would
  # have to stop that turn.
  defp stale_ids(%Prima.Actor{athanor_id: athanor_id} = actor, cutoff) do
    open =
      from(t in Arca.Schemas.Turn,
        where: t.athanor_id == ^athanor_id and t.status in ^Prima.TurnState.open_statuses()
      )

    read =
      from(t in open, select: t.sources)
      |> Repo.all()
      |> Enum.flat_map(&(&1 |> Prima.Source.decode() |> Prima.Source.threads()))
      |> MapSet.new()

    from(c in Thread,
      where: c.id not in subquery(from(t in open, select: t.thread_id)),
      where: is_nil(c.workspace_state) or c.workspace_state not in ^["open", "needs_you"],
      where: coalesce(c.last_message_at, c.inserted_at) < ^cutoff,
      select: c.id
    )
    |> QueryHelpers.where_tenant(actor)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(read, &1))
  end

  @doc """
  How many threads `delete_before/2` would remove — the dry-run
  count, sharing its rule: a thread with a running turn is never
  touched.
  """
  @spec count_before(Prima.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def count_before(%Prima.Actor{athanor_id: athanor_id} = actor, %DateTime{} = cutoff)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadStorage.count_before", fn ->
      {:ok, length(stale_ids(actor, cutoff))}
    end)
    |> Arca.Data.project()
  end

  def count_before(%Prima.Actor{}, _cutoff), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_map(json, field) do
    case decode_stored(json, %{}, field) do
      %{} = map -> map
      _ -> %{}
    end
  end

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes.
  defp decode_stored(json, default, field) do
    case Prima.Json.decode_stored(json, default) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Arca.ThreadStorage] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end
end
