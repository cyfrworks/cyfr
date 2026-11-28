# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadStorage do
  @moduledoc """
  Persistence for the athanor's threads and their messages — the
  durable record every member reads (`Aqua.Tape` writes it,
  `PrismWeb.ThreadPaneLive` shows it).

  A thread belongs to the athanor of the context that opened it, and so
  to its person, who reads it and sends the next message. Reads scope
  through `Arca.QueryHelpers.where_tenant/2` (a context without an
  athanor raises, fail closed) and every write stamps the context's
  athanor.

  Message rows are appended in `seq` order by `append/3`; the unique index
  on `(thread_id, seq)` is what makes two writers appending at once
  safe — the loser retries with the next number.

  ## The claim

  `active_turn_id` is which turn holds the thread, and it is the only
  evidence of that: a runner process on some member is a lookup, never
  ownership. `claim/4` takes it in one statement naming the turn and the
  consumed sequence the claimant read, `release/3` gives it up, and
  `take_claim!/3` is the takeover a recovery makes inside its own
  transaction — admitted only for a thread nobody holds or one whose
  holder is not a live peer (`claim_holder/2`). The claim has no lease of
  its own: it is alive while its holder's member is.

  ## Archive

  A daily or a workspace thread is archived by its person (`archive/2`)
  or by the athanor's setting after days with no activity
  (`archive_idle/2`, the retention kind `archive_days`), never while work
  remains in it or in a crew thread under it. It is an ordinary thread
  behind the list's Archived filter: it stays readable and searchable,
  admits everything but the server's nudge and reminder (`Aqua.Nudge`),
  and keeps its files and notes. New work there takes
  it out again (`unarchive!/2`). A crew member's thread is never
  archived: it is retired (`retire/3`), which stops its work. No thread
  is deleted by age; a deletion is the person's (`delete/3`).

  ## Read threads

  A turn, an execution and a guest object record the ids of the threads
  whose posts they came to hold, as the JSON text of the sorted list
  (`threads_text/1`, read back by `threads_of/1`), so that a deletion
  finds every turn that read a thread by the exact JSON string of its id
  in that text (`delete/3`).
  """

  import Ecto.Query
  # Every function takes the `Prima.Actor` first and matches it in the
  # head; an actor whose athanor is nil OR the empty string is
  # `{:error, :no_athanor}` before any query, and `insert_message!/3`,
  # which runs inside a caller's transaction, raises instead.
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Repo
  alias Arca.Schemas.Athanor
  alias Arca.Schemas.Thread
  alias Arca.Schemas.Message

  @typedoc """
  A brain session a clearing or a deletion owed its removal
  (`Prima.OutboxRecord.brain_forget/1`): its thread, and the session
  generation it was held under.
  """
  @type forgotten :: %{thread_id: String.t(), generation: non_neg_integer()}

  # The two reserved row authors, spelled once in the schema.
  @agent_author Message.agent_author()
  @system_author Message.system_author()
  @room_kinds Thread.room_kinds()

  # The rows a person reads as posts: what a turn writes for itself
  # (`tool_call`, `tool_result`, `compaction`, `turn_aborted`, `page_call`,
  # `page_result`) is none.
  @post_kinds ~w(text error system opening pointer report)

  # The most posts one search answers, and how many rows it reads at a
  # time while it looks for them.
  @search_max 20
  @search_batch 200

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
  Whether a daily or a workspace thread, as `get/2` or `list/2` answers
  it, is archived (`Arca.Schemas.Thread.archived?/1`); a crew thread never
  is.
  """
  @spec archived?(map()) :: boolean()
  defdelegate archived?(thread), to: Thread

  @doc """
  Whether `row` is one a person reads as a post: what a turn writes for
  itself is drawn as its steps, never as a post (`messages/3`'s `posts:`).
  """
  @spec post?(map()) :: boolean()
  def post?(%{kind: kind}), do: kind in @post_kinds

  @doc "The kinds of the rows a person reads as posts (`post?/1`)."
  @spec post_kinds() :: [String.t()]
  def post_kinds, do: @post_kinds

  @doc """
  The athanor's threads, most recently active first. `opts`: `:limit`
  (200 by default), `:kind` (one of `Arca.Schemas.Thread.kinds/0`, or a
  list of them; every kind when absent), `:archived` (`true` for the
  archived ones alone, `false` for the others; both when absent) and
  `:title`, text a thread's title holds: a plain substring match made by
  the store's own query, with its order and limit, over every thread of
  the athanor, ASCII letters folded to lower case on both sides and every
  other character matched as itself, so both adapters answer the same
  threads and no character of the text is a pattern (a daily thread's
  title is its date). `nil` matches every title.
  """
  @spec list(Prima.Actor.t(), keyword()) :: [map()] | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{athanor_id: athanor_id} = actor, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.list", fn ->
      limit = Keyword.get(opts, :limit, 200)

      query =
        case Keyword.get(opts, :kind) do
          nil -> Thread
          kinds when is_list(kinds) -> from(c in Thread, where: c.kind in ^kinds)
          kind -> from(c in Thread, where: c.kind == ^kind)
        end

      query =
        case Keyword.get(opts, :archived) do
          nil -> query
          true -> from(c in query, where: not is_nil(c.archived_at))
          false -> from(c in query, where: is_nil(c.archived_at))
        end

      query =
        case Keyword.get(opts, :title) do
          nil -> query
          title when is_binary(title) -> from(c in query, where: ^titled(title))
        end

      from(c in query,
        order_by: [desc: coalesce(c.last_message_at, c.inserted_at)],
        limit: ^limit
      )
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, _opts), do: {:error, :no_athanor}

  # A title holding `text`, matched by the store: ASCII letters folded to
  # lower case on both sides, by SQLite's `lower/1`, which folds ASCII
  # alone, and by PostgreSQL's under the "C" collation, which does the
  # same, and `%`, `_` and `\\` escaped so no character is a pattern.
  defp titled(text) do
    pattern =
      text
      |> String.downcase(:ascii)
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    title_like("%" <> pattern <> "%")
  end

  if Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3) ==
       Ecto.Adapters.Postgres do
    defp title_like(pattern),
      do: dynamic([c], fragment(~s|lower(? COLLATE "C") LIKE ? ESCAPE '\\'|, c.title, ^pattern))
  else
    defp title_like(pattern),
      do: dynamic([c], fragment("lower(?) LIKE ? ESCAPE '\\'", c.title, ^pattern))
  end

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

  One locking transaction takes the athanor's row, looks for the day and
  inserts it, so two callers making the same day at once leave one row
  and both answer it; an athanor with no row of its own is held to one
  row per day by the unique index on `(athanor_id, day)`, and the caller
  that loses that race reads the winner's.
  """
  @spec daily(Prima.Actor.t(), Date.t()) ::
          {:ok, map()}
          | {:error, :no_athanor | {:invalid, map()} | :database_error}
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
  # A thread inserted inside the caller's locking transaction, under the
  # athanor's row lock as `daily/2` inserts a day: an invalid row rolls
  # the caller back. An in-transaction helper for Arca's own writers
  # (`Arca.TurnStorage`'s workspace opening), answering the schema row.
  @spec insert_thread!(Prima.Actor.t(), map()) :: Thread.t()
  # arca:db-raise-ok inside the caller's transaction
  def insert_thread!(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs),
      do: insert_thread(actor, attrs)

  def insert_thread!(%Prima.Actor{}, _attrs),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.insert_thread!/2")

  # In the caller's locking transaction, under the athanor's row that
  # every create of a thread takes: creates into one athanor insert one
  # at a time, a day is looked for and made under it (`daily/2`), and the
  # blob sweep, which takes it too, never runs between a new thread's
  # first byte and its row (`sweep_orphaned_blobs/1`).
  defp insert_thread(actor, attrs) do
    lock_athanor(actor)

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
    |> Repo.insert()
    |> Repo.committed()
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
  #     turns (a deletion) chooses them and holds them so
  #     before anything else, then asks again under its locks.
  #   * then the athanor's row: shared by the standing check
  #     (`Arca.ExecutionStanding.locked/2`), after the turn; taken for
  #     update, before any standing check of its own, by every create of a
  #     thread and by a write that takes more than one thread row, by a
  #     lock, an update, a delete or a row it adds that names one.
  #   * then the thread rows, those it holds together in id order, which
  #     this function takes after the athanor's row.
  #
  # A write that takes one thread row takes no second, and no athanor
  # lock for it. Nothing takes the athanor's row before a turn's, so no
  # two writes wait on each other across the three. Answers the rows of
  # `ids` that stand, held until the caller's transaction ends. An
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
  that stands (not retired), made when there is none, titled by the
  member. One locking transaction takes the athanor's row before it
  looks, as a new day's does (`daily/2`), so two callers never make two.
  `{:error, :not_found}` when the room is not a thread of the athanor,
  `{:error, :not_a_room}` when it is itself a child thread: a room is a
  daily or a workspace thread of the same athanor
  (`Arca.Schemas.Thread.room_kinds/0`).
  """
  @spec crew_thread(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error,
             :no_athanor
             | :not_found
             | :not_a_room
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
      where: is_nil(c.retired_at),
      limit: 1
    )
    |> QueryHelpers.where_tenant(actor)
    |> Repo.one()
  end

  @doc "The child threads of the room `room_id`, retired ones included, oldest first."
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
  runtime cancels; retiring one already retired answers it unchanged
  with none; a thread of the person's own is `{:error, :not_crew}` (it is
  archived, `archive/2`); one a deletion removed while the retirement
  waited on its turns is `{:error, :not_found}`, with nothing written.
  """
  @spec retire(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{thread: map(), cancelled: [map()]}}
          | {:error, :no_athanor | :not_found | :not_crew | :database_error}
  def retire(actor, id, attrs \\ %{})

  def retire(%Prima.Actor{athanor_id: athanor_id} = actor, id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.retire", fn ->
      Repo.locking_transaction(fn ->
        case thread_row(actor, id) do
          # The turns first and the thread after them, the order a turn's
          # own writers take them in. A turn accepted after the scan is
          # refused its claim (`Arca.TurnStorage.start/3`).
          {:ok, %Thread{kind: "crew", retired_at: nil}} ->
            cancel = Map.put_new(attrs, :error, "the thread was retired")
            cancelled = Arca.TurnStorage.cancel_open!(actor, id, cancel, :reply)

            # Read again under the thread's own lock: a deletion that went
            # while the retirement waited on the thread's turns leaves
            # nothing to retire, which is a refusal with nothing written.
            case held_row(actor, id) do
              %Thread{} = thread ->
                retired =
                  thread
                  |> Ecto.Changeset.change(retired_at: DateTime.utc_now())
                  |> Repo.update!()

                %{thread: retired, cancelled: cancelled}

              nil ->
                Repo.rollback(:not_found)
            end

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

  def retire(%Prima.Actor{}, _id, _attrs), do: {:error, :no_athanor}

  # The thread's row, held until the caller's transaction ends, or nil
  # when it is gone.
  # arca:db-raise-ok inside the caller's transaction
  defp held_row(actor, id) do
    from(c in Thread, where: c.id == ^id)
    |> QueryHelpers.where_tenant(actor)
    |> QueryHelpers.for_update()
    |> Repo.one()
  end

  @doc """
  Forget the brain session (`brain_session`) of every thread of the
  actor's athanor that a reset or a retirement of the kept home of the
  program row `row_id` reaches, so each one's next request opens a new
  session, and raise its `brain_generation` in the same statement, so a
  turn begun before it keeps no session it answers with afterwards: a
  program's batch that would keep one is refused
  (`Arca.TurnStorage.commit_events/3`). The threads are
  those the row's identity is stored on: a session stored with the row
  (`brain_progress`'s `row`), and an open turn pinned to the row
  (`turns.program`), whose first start may not have committed a session
  yet. A program brain's configured name is never read: a row
  deleted no longer answers it, and a replacement of the same name, whose
  threads store its own id, is never reached. Each thread, and the open
  turns pinned to the row, are read again under the threads' locks, so a
  thread whose session moved to another row, or whose pinned turn ended,
  meanwhile is left as it is. A session a program's transcript may back
  is owed its removal first, in the same transaction
  (`Prima.OutboxRecord.brain_forget/1`). Answers those sessions, for the
  caller to close their holders after the commit.
  """
  @spec forget_sessions(Prima.Actor.t(), String.t()) ::
          {:ok, [forgotten()]} | {:error, :no_athanor | :database_error}
  def forget_sessions(%Prima.Actor{athanor_id: athanor_id} = actor, row_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(row_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.forget_sessions", fn ->
      Repo.locking_transaction(fn ->
        candidates = Enum.uniq(stored_with(actor, row_id) ++ pinned_to(actor, row_id))

        locked = lock_threads!(actor, candidates)
        # Read again under the locks: a pinned turn that ended while this
        # waited for them, its thread's session kept on another row since,
        # is no longer the row's.
        pinned = pinned_to(actor, row_id)

        threads =
          for %Thread{} = thread <- locked,
              thread.id in pinned or stored_row(thread) == row_id,
              do: thread

        forgotten = owe_forgets!(actor, threads)
        ids = Enum.map(threads, & &1.id)

        {_count, _} =
          from(c in Thread, where: c.id in ^ids)
          |> QueryHelpers.where_tenant(actor)
          |> Repo.update_all(set: [brain_session: nil], inc: [brain_generation: 1])

        forgotten
      end)
    end)
  end

  def forget_sessions(%Prima.Actor{}, _row_id), do: {:error, :no_athanor}

  # The threads a program row's identity is stored on: a session kept with
  # the row (`stored_row/1`), and an open turn pinned to it.
  # arca:db-raise-ok inside the caller's transaction
  defp stored_with(actor, row_id) do
    from(c in Thread, where: not is_nil(c.brain_progress))
    |> QueryHelpers.where_tenant(actor)
    |> Repo.all()
    |> Enum.filter(&(stored_row(&1) == row_id))
    |> Enum.map(& &1.id)
  end

  # arca:db-raise-ok inside the caller's transaction
  # arca:unscoped-ok the statement names the athanor.
  defp pinned_to(%Prima.Actor{athanor_id: athanor_id}, row_id) do
    open = Prima.TurnState.open_statuses()

    from(t in Arca.Schemas.Turn,
      where: t.athanor_id == ^athanor_id and t.program == ^row_id and t.status in ^open,
      select: t.thread_id
    )
    |> Repo.all()
    |> Enum.uniq()
  end

  # The program row a thread's brain session is stored with, as
  # `session_rows/2` reads it, or nil.
  defp stored_row(%Thread{brain_progress: progress}) when is_binary(progress) do
    case Jason.decode!(progress) do
      %{"row" => row_id} when is_binary(row_id) and row_id != "" -> row_id
      _none -> nil
    end
  end

  defp stored_row(%Thread{}), do: nil

  @doc """
  The requests still waiting on a crew member's reply, oldest first: of
  the thread `opts[:thread_id]` names, else of the whole athanor; with
  `opts[:unstarted]`, only those no turn of the member has opened for
  yet, whose delivery is still to come.
  """
  @spec pending_requests(Prima.Actor.t(), keyword()) ::
          [map()] | {:error, :no_athanor | :database_error}
  def pending_requests(%Prima.Actor{athanor_id: athanor_id} = actor, opts \\ [])
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.pending_requests", fn ->
      query =
        from(m in Message,
          # A reply answers a request and is none.
          where: not is_nil(m.addressee) and m.status == "pending" and m.kind == "text",
          where: is_nil(m.reply_to),
          order_by: [asc: m.inserted_at, asc: m.seq]
        )

      query =
        case Keyword.get(opts, :thread_id) do
          nil -> query
          thread_id -> from(m in query, where: m.thread_id == ^thread_id)
        end

      query =
        if Keyword.get(opts, :unstarted, false) do
          started =
            from(t in Arca.Schemas.Turn,
              where: t.athanor_id == ^athanor_id and not is_nil(t.request_id),
              select: t.request_id
            )

          from(m in query, where: m.id not in subquery(started))
        else
          query
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

  A pause keeps the claim — the turn is still this member's work,
  waiting on a person. Every terminal transition releases it.
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
  after it, when its room is gone. Its open turns and the children's
  are cancelled in the same transaction (`Arca.TurnStorage.cancel_open!/4`,
  under the root's grant `attrs` carry): one asked from a thread that
  survives the delete answers its asker, and one whose asker goes with it,
  or that has none, stays silent. They are answered for the caller's
  runtime to stop.

  What other threads kept of it goes in the same transaction: the
  pointers and reports that name it, on every daily thread, and in each
  thread a turn of which read it (its id among the turn's read threads)
  the compactions written since the first such turn was accepted and the
  brain's session, whose generation is raised;
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
  their holders' runtime cancels, and the brain sessions it cleared or
  deleted that a program's transcript may back, each owed its removal
  first in the same transaction (`Prima.OutboxRecord.brain_forget/1`), for the caller to
  close their holders after the commit.
  """
  @spec delete(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{cancelled: [map()], forgotten: [forgotten()]}}
          | {:error,
             :no_athanor
             | :not_found
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
        {:ok, %{ids: ids, cancelled: cancelled, forgotten: forgotten}} ->
          Enum.each(ids, &delete_blobs_after(actor, &1))
          {:ok, %{cancelled: cancelled, forgotten: forgotten}}

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
         :ok <- still_chosen!(removed_turns(athanor_id, ids, readers), chosen) do
      # Before anything clears or deletes them: the sessions of the
      # threads that go and of those that read one, read from the rows
      # that hold them.
      forgotten = owe_forgets_of!(actor, ids ++ Enum.map(readers, &elem(&1, 0)))

      gone = if thread.kind == "crew", do: "the thread was deleted", else: "the room was deleted"
      cancel = Map.put_new(attrs, :error, gone)

      # A turn asked from a thread that survives the delete answers it;
      # one whose asker goes with it answers nobody.
      cancelled =
        Enum.flat_map(
          ids,
          &Arca.TurnStorage.cancel_open!(actor, &1, cancel, {:silent_to, ids})
        )

      stopped = forget!(actor, ids, readers, attrs)

      # Explicit message deletion also covers SQLite connections without
      # foreign_keys=ON.
      Repo.delete_all(from(m in Message, where: m.thread_id in ^ids))

      {_, _} =
        from(c in Thread, where: c.id in ^ids)
        |> QueryHelpers.where_tenant(actor)
        |> Repo.delete_all()

      %{ids: ids, cancelled: cancelled ++ stopped, forgotten: forgotten}
    else
      # No such thread: the athanor's row and none of its threads held.
      [] -> Repo.rollback(:not_found)
    end
  end

  # What other threads kept of the threads `ids` a deletion removes,
  # undone in the deleting transaction: the pointers and reports that
  # name one, on every daily thread; and in every thread a turn of which
  # read one (its id among the turn's read threads), the compactions
  # written since its first such turn was accepted, which
  # may summarize what was read, and the brain's session, which may hold
  # it, its generation raised so no turn keeps the old one; and there the
  # results of the reads that carried one's posts (`blank_reads!/3`). A
  # turn still open there is cancelled as a stop cancels it, its reply
  # recorded; answers those, for the caller's runtime to stop after the
  # commit. `readers` (`readers/2`) is what the caller read under its
  # locks, whose open turns it already holds.
  # arca:db-raise-ok inside the caller's transaction
  # arca:unscoped-ok every statement names the actor's athanor.
  defp forget!(%Prima.Actor{athanor_id: athanor_id} = actor, ids, readers, attrs) do
    {_, _} =
      Repo.delete_all(
        from(m in Message, where: m.athanor_id == ^athanor_id and m.workspace_id in ^ids)
      )

    blank_reads!(athanor_id, ids, Enum.map(readers, &elem(&1, 0)))

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

    # The person's deletion stops what read it, as their stop would.
    stop = Map.merge(attrs, %{error: "what this thread read was deleted", ended_by: :person})

    Enum.flat_map(readers, fn
      {_thread_id, _since, []} ->
        []

      {thread_id, _since, open} ->
        Arca.TurnStorage.cancel_open!(actor, thread_id, Map.put(stop, :only, open), :reply)
    end)
  end

  @doc false
  # Put, in the caller's transaction and before the statement that clears
  # or deletes them, a `brain_forget` record
  # (`Prima.OutboxRecord.brain_forget/1`) for each of `threads`' brain
  # sessions a program's transcript backs, so the record commits with its
  # clearing or not at all. `threads` are rows the caller holds
  # (`lock_threads!/2`, or a turn's own thread), so a session a batch
  # keeps meanwhile (`Arca.TurnStorage.commit_events/3`) is either read
  # here or kept under a generation the caller then raises past. A session
  # backs a transcript in the folder of the row it is stored with
  # (`session_rows/1`); a session with no stored row owes nothing. Answers
  # the sessions recorded. An in-transaction helper.
  @spec owe_forgets!(Prima.Actor.t(), [Thread.t()]) :: [forgotten()]
  def owe_forgets!(_actor, []), do: []

  # arca:db-raise-ok inside the caller's transaction
  def owe_forgets!(%Prima.Actor{athanor_id: athanor_id} = actor, threads)
      when is_binary(athanor_id) and athanor_id != "" and is_list(threads) do
    held =
      for %Thread{athanor_id: ^athanor_id, brain_session: session} = thread <- threads,
          is_binary(session) and session != "",
          do: thread

    rows = session_rows(actor, held)

    for %Thread{id: thread_id} = thread <- held, row_id <- List.wrap(rows[thread_id]) do
      record =
        Prima.OutboxRecord.brain_forget(%{
          athanor_id: athanor_id,
          thread_id: thread_id,
          row_id: row_id,
          session: thread.brain_session,
          generation: thread.brain_generation
        })

      # A thread owes one removal per generation, and each clearing
      # raises it: a record already there is this very one.
      _put_or_there = Arca.Outbox.put!(actor, record)
      %{thread_id: thread_id, generation: thread.brain_generation}
    end
  end

  def owe_forgets!(%Prima.Actor{}, _threads),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.owe_forgets!/2")

  # arca:db-raise-ok inside the caller's transaction
  defp owe_forgets_of!(actor, ids), do: owe_forgets!(actor, lock_threads!(actor, Enum.uniq(ids)))

  # The program row each thread's brain session is stored with: the
  # `row` of its `brain_progress`, written in the one write that keeps a
  # session a `started` names (`Arca.TurnStorage.commit_events/3`) and
  # left by everything else, so a forget still reads it until the next
  # `started`. It is the session's folder, which neither the row its
  # driver runs on now (`driver`, which a new driver's hello moves) nor a
  # later turn's start names. Its `epoch` is not the record's: a folder is
  # its row's whatever the row's epoch, and a removal holds the row's
  # owner at the epoch the row has then. A stored row that is gone or
  # keeps no folder is left out: its home's
  # retirement removes the session's transcript with it.
  defp session_rows(_actor, []), do: %{}

  # arca:db-raise-ok inside the caller's transaction
  # arca:unscoped-ok the statement names the athanor.
  defp session_rows(%Prima.Actor{athanor_id: athanor_id}, threads) do
    stored =
      for %Thread{id: id, brain_progress: progress} <- threads,
          is_binary(progress),
          %{"row" => row_id} when is_binary(row_id) and row_id != "" <- [Jason.decode!(progress)],
          into: %{},
          do: {id, row_id}

    row_ids = stored |> Map.values() |> Enum.uniq()

    kept =
      from(r in Arca.Schemas.McpServer,
        where: r.athanor_id == ^athanor_id and r.id in ^row_ids,
        where: r.transport == "program" and r.mark == "driven" and r.home == "kept",
        select: r.id
      )
      |> Repo.all()
      |> MapSet.new()

    Map.filter(stored, fn {_thread_id, row_id} -> MapSet.member?(kept, row_id) end)
  end

  @doc """
  The sentence a read's result holds once the thread it read is deleted
  (`delete/3`): what the model reads in its place.
  """
  @spec forgotten_read() :: String.t()
  def forgotten_read,
    do: "What this read answered came from a thread that has since been deleted."

  @doc """
  The stored text of a list of read threads: the JSON list of the ids,
  sorted and without duplicates, `"[]"` for none.
  """
  @spec threads_text([String.t()]) :: String.t()
  def threads_text(ids) when is_list(ids),
    do: ids |> Enum.uniq() |> Enum.sort() |> Jason.encode!()

  @doc """
  The thread ids a stored read-threads text holds, sorted and without
  duplicates: a JSON list's non-empty strings; nil, or text that is not
  a JSON list, holds none.
  """
  @spec threads_of(String.t() | nil) :: [String.t()]
  def threads_of(nil), do: []

  def threads_of(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, ids} when is_list(ids) ->
        ids |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq() |> Enum.sort()

      _unreadable ->
        []
    end
  end

  # The answers that carried posts of the threads `ids`, in the threads
  # `reader_ids`: a step's result row whose payload records, among the
  # threads its answer carried, one of them, as the step's close recorded
  # them from what the read joined (`Arca.TurnStorage.close_step/4`),
  # never from the answer's text, which a binding may have cut. Its text
  # becomes `forgotten_read/0`, whole, whatever else it carried; the row
  # stays, so the call it answers still has its result.
  # arca:db-raise-ok inside the caller's transaction
  defp blank_reads!(_athanor_id, _ids, []), do: :ok

  defp blank_reads!(athanor_id, ids, reader_ids) do
    forgotten = MapSet.new(ids)

    carried =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id in ^reader_ids,
        where: m.kind in ["tool_result", "page_result"] and like(m.payload, ^"%\"threads\"%"),
        select: {m.id, m.payload}
      )
      |> Repo.all()
      |> Enum.filter(fn {_id, payload} ->
        case decode_map(payload, "payload")["threads"] do
          threads when is_list(threads) -> Enum.any?(threads, &MapSet.member?(forgotten, &1))
          _none -> false
        end
      end)
      |> Enum.map(&elem(&1, 0))

    {_, _} =
      from(m in Message, where: m.athanor_id == ^athanor_id and m.id in ^carried)
      |> Repo.update_all(set: [content: forgotten_read()])

    :ok
  end

  # Each thread outside `ids` with a turn whose read threads name one of
  # them: when its first such turn was accepted, and those of them still
  # open. The read threads are the JSON text `threads_text/1` writes, so
  # an id reads as its exact JSON string in it.
  # arca:db-raise-ok inside the caller's transaction
  defp readers(athanor_id, [_ | _] = ids) do
    named =
      Enum.reduce(ids, dynamic(false), fn id, acc ->
        pattern = "%" <> like_escape(Jason.encode!(id)) <> "%"
        dynamic([t], ^acc or fragment("? LIKE ? ESCAPE '!'", t.read_threads, ^pattern))
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
  `posts: true` keeps only the rows a person reads as posts, leaving out
  what a turn writes for itself; `status:` only the rows of that status.
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

      query =
        if Keyword.get(opts, :posts, false),
          do: from(m in query, where: m.kind in ^@post_kinds),
          else: query

      query =
        case Keyword.get(opts, :status) do
          nil -> query
          status -> from(m in query, where: m.status == ^status)
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
  The posts of the athanor's daily and workspace threads whose text holds
  `needle`, newest first: a plain substring match of the text folded to
  lower case by `String.downcase/1`, made here over the rows read a page
  at a time, so both adapters answer the same posts in the same order
  and no character of `needle` is a pattern. A crew member's thread is
  never searched. `opts`: `:limit` (#{@search_max}, the most), `:before`
  (the `next` a previous answer gave: posts older than that one).

  Answers `%{posts: [%{message: row, thread: %{id, kind, day, title}}],
  next: id | nil, scanned: rows read}`; `next` is the last post's id
  when the answer is full, and a page after it may be empty. A `before`
  that names no post of the athanor is `{:error, :not_found}`.
  """
  @spec search(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, %{posts: [map()], next: String.t() | nil, scanned: non_neg_integer()}}
          | {:error, :no_athanor | :not_found | :database_error}
  def search(actor, needle, opts \\ [])

  def search(%Prima.Actor{athanor_id: athanor_id} = actor, needle, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(needle) and needle != "" do
    limit = opts |> Keyword.get(:limit, @search_max) |> min(@search_max) |> max(1)

    Arca.Repo.Errors.with_db_rescue("ThreadStorage.search", fn ->
      with {:ok, cursor} <- search_cursor(actor, Keyword.get(opts, :before)) do
        {posts, scanned} = search_pages(actor, String.downcase(needle), cursor, limit, [], 0)
        next = if length(posts) == limit, do: List.last(posts).message.id

        {:ok, %{posts: posts, next: next, scanned: scanned}}
      end
    end)
    |> Arca.Data.project()
  end

  def search(%Prima.Actor{}, _needle, _opts), do: {:error, :no_athanor}

  defp search_cursor(_actor, nil), do: {:ok, nil}

  defp search_cursor(actor, id) when is_binary(id) do
    case message_row(actor, id) do
      {:ok, %Message{inserted_at: at, id: id}} -> {:ok, {at, id}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp search_cursor(_actor, _other), do: {:error, :not_found}

  # One page of the athanor's posts older than `cursor`, newest first,
  # until the answer is full or the rows run out. Ordered by when each
  # was written and then by id, compared by its bytes on both adapters
  # (`Arca.QueryHelpers.by_bytes/1`), as the cursor's comparison is.
  # arca:db-raise-ok inside the caller's rescue.
  defp search_pages(_actor, _needle, _cursor, limit, found, scanned)
       when length(found) >= limit,
       do: {Enum.take(found, limit), scanned}

  defp search_pages(
         %Prima.Actor{athanor_id: athanor_id} = actor,
         needle,
         cursor,
         limit,
         found,
         scanned
       ) do
    query =
      from(m in Message,
        join: c in Thread,
        on: c.id == m.thread_id and c.athanor_id == m.athanor_id,
        where: m.athanor_id == ^athanor_id and c.kind in ^@room_kinds,
        where: m.kind in ^@post_kinds,
        order_by: ^[desc: dynamic([m], m.inserted_at), desc: QueryHelpers.by_bytes(:id)],
        limit: ^@search_batch,
        select: {m, %{id: c.id, kind: c.kind, day: c.day, title: c.title}}
      )

    query =
      case cursor do
        nil ->
          query

        {at, id} ->
          before = QueryHelpers.bytes_before(:id, id)
          older = dynamic([m], m.inserted_at < ^at or (m.inserted_at == ^at and ^before))
          from(query, where: ^older)
      end

    rows = query |> QueryHelpers.where_tenant(actor) |> Repo.all()

    hits =
      for {message, thread} <- rows,
          String.contains?(String.downcase(message.content || ""), needle),
          do: %{message: message, thread: thread}

    found = found ++ hits
    scanned = scanned + length(rows)

    case List.last(rows) do
      {%Message{inserted_at: at, id: id}, _thread} when length(rows) == @search_batch ->
        search_pages(actor, needle, {at, id}, limit, found, scanned)

      _last_page ->
        {Enum.take(found, limit), scanned}
    end
  end

  @doc """
  The newest `n` messages of a thread, in ascending order. `opts`:
  `:kinds`, a list of kinds: the newest `n` rows of those kinds, whatever
  rows of other kinds stand between them.

  The console's transcript view: `messages/3`'s `:limit` takes the OLDEST
  rows (it bounds windowed turn assembly), which is the wrong end for a
  reader opening a long-lived thread.
  """
  @spec latest_messages(Prima.Actor.t(), String.t(), pos_integer(), keyword()) ::
          [map()] | {:error, term()}
  def latest_messages(actor, thread_id, n, opts \\ [])

  def latest_messages(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, n, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and is_integer(n) and
             n > 0 and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.latest_messages", fn ->
      query =
        from(m in Message,
          where: m.thread_id == ^thread_id,
          order_by: [desc: m.seq],
          limit: ^n
        )

      query =
        case Keyword.get(opts, :kinds) do
          nil -> query
          kinds when is_list(kinds) -> from(m in query, where: m.kind in ^kinds)
        end

      query
      |> QueryHelpers.where_tenant(actor)
      |> Repo.all()
      |> Enum.reverse()
    end)
    |> Arca.Data.project()
  end

  def latest_messages(%Prima.Actor{}, _thread_id, _n, _opts), do: {:error, :no_athanor}

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

  @doc "A message's `payload` decoded (`%{}` when none)."
  @spec payload(map()) :: map()
  def payload(%{payload: nil}), do: %{}
  def payload(%{payload: json}), do: decode_map(json, "payload")

  # ---------------------------------------------------------------------------
  # Archive
  # ---------------------------------------------------------------------------

  @doc """
  Archive the daily or workspace thread `id`, the person's own act: the
  person's list shows it behind its Archived filter from now on, and
  nothing else about it changes: no turn is cancelled, nothing is
  refused, its posts stay searchable and its files and notes stay. It is
  refused `{:error, :working}` while work remains in it or in a crew
  thread under it (`Arca.TurnStorage.work_remains?/2`), whatever it
  reads, or while a workspace thread reads working (`workspace_state`
  `open`). Decided under the thread's row lock, which every write that
  starts new work there or in a crew thread under it holds as well,
  archived or not, from its clear to its commit (`unarchive!/2`): the
  archive waits for work under way and then finds it, or the work's
  clear waits for the archive and undoes it. One
  already archived answers as it stands. A crew member's thread is
  `{:error, :not_a_room}`: it is retired (`retire/3`). `:archived` is
  announced after the commit (`[:cyfr, :arca, :thread, :archived]`).
  """
  @spec archive(Prima.Actor.t(), String.t()) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :not_a_room | :working | :database_error}
  def archive(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.archive", fn ->
      Repo.locking_transaction(fn ->
        case held_row(actor, id) do
          nil ->
            Repo.rollback(:not_found)

          %Thread{kind: "crew"} ->
            Repo.rollback(:not_a_room)

          %Thread{archived_at: %DateTime{}} = thread ->
            {thread, false}

          %Thread{} = thread ->
            if at_work?(actor, thread), do: Repo.rollback(:working)
            {%{thread | archived_at: archived!(actor, [thread.id])}, true}
        end
      end)
    end)
    |> case do
      {:ok, {thread, moved}} ->
        if moved, do: announce_archived(actor, [thread.id])
        {:ok, thread}

      other ->
        other
    end
    |> Arca.Data.project()
  end

  def archive(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Archive the athanor's daily and workspace threads with no activity since
  `cutoff` (the retention kind `archive_days`, `Arca.Retention.Threads`):
  the newest last activity of the thread and of the crew threads under it,
  each its `last_message_at` or else its creation, before `cutoff`, and
  no work remaining (`archive/2`'s rule). The candidates are read, their
  rows taken in the one order of a write that takes more than one
  (`lock_threads!/2`, the athanor's row first, which a crew thread's new
  work takes too), and the rule asked again over the rows as they then
  stand: one that new work reached meanwhile is left for the next cycle.
  Answers how many it archived, each announced after the commit as
  `archive/2` announces one.
  """
  @spec archive_idle(Prima.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def archive_idle(%Prima.Actor{athanor_id: athanor_id} = actor, %DateTime{} = cutoff)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.archive_idle", fn ->
      case idle_ids(actor, cutoff) do
        [] ->
          {:ok, []}

        candidates ->
          Repo.locking_transaction(fn ->
            _threads = lock_threads!(actor, candidates)
            idle = MapSet.new(idle_ids(actor, cutoff))
            ids = Enum.filter(candidates, &MapSet.member?(idle, &1))
            _at = archived!(actor, ids)
            ids
          end)
      end
    end)
    |> case do
      {:ok, ids} ->
        announce_archived(actor, ids)
        {:ok, length(ids)}

      {:error, _} = refused ->
        refused
    end
  end

  def archive_idle(%Prima.Actor{}, _cutoff), do: {:error, :no_athanor}

  @doc """
  How many threads `archive_idle/2` would archive now: the dry run's
  count, by the same rule.
  """
  @spec count_idle(Prima.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def count_idle(%Prima.Actor{athanor_id: athanor_id} = actor, %DateTime{} = cutoff)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.count_idle", fn ->
      {:ok, length(idle_ids(actor, cutoff))}
    end)
  end

  def count_idle(%Prima.Actor{}, _cutoff), do: {:error, :no_athanor}

  @doc false
  # New work in the daily or workspace thread `room_id` takes it out of
  # the archive: one statement that takes the thread's row whether or not
  # it is archived and clears the mark, never a field of a changeset
  # built from a row read earlier. The row, held until the work commits,
  # is what an archive waits on (`archive/2` and `archive_idle/2` take it
  # too): an archive that comes second finds the work, and one that came
  # first is undone, this statement reading on PostgreSQL the row the
  # archive left once its lock is free; SQLite runs one write at a time.
  # Its callers are the writes that start or join ordinary work there or
  # in a crew thread under it (`Arca.TurnStorage`'s "The archive"), each
  # in its own transaction, in the one order `lock_threads!/2` states. An
  # in-transaction helper.
  @spec unarchive!(Prima.Actor.t(), String.t()) :: :ok
  # arca:db-raise-ok inside the caller's transaction
  def unarchive!(%Prima.Actor{athanor_id: athanor_id} = actor, room_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(room_id) do
    {_count, _} =
      from(c in Thread, where: c.id == ^room_id)
      |> QueryHelpers.where_tenant(actor)
      |> Repo.update_all(set: [archived_at: nil])

    :ok
  end

  def unarchive!(%Prima.Actor{}, _room_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.unarchive!/2")

  # The threads `ids` archived now, in the caller's transaction, which
  # holds their rows. Answers when.
  # arca:db-raise-ok inside the caller's transaction
  defp archived!(actor, ids) do
    now = DateTime.utc_now()

    {_count, _} =
      from(c in Thread, where: c.id in ^ids and is_nil(c.archived_at))
      |> QueryHelpers.where_tenant(actor)
      |> Repo.update_all(set: [archived_at: now])

    now
  end

  # Whether a daily or a workspace thread may not be archived now: work
  # remains in it or in a crew thread under it, or a workspace thread
  # reads working.
  # arca:db-raise-ok inside the caller's transaction
  defp at_work?(actor, %Thread{} = thread),
    do: thread.workspace_state == "open" or Arca.TurnStorage.work_remains?(actor, thread)

  # The daily and workspace threads `archive_idle/2` archives: none
  # archived, the newest activity of each and of its crew threads before
  # `cutoff`, and no work remaining.
  # arca:db-raise-ok inside the caller's rescue or transaction.
  defp idle_ids(actor, cutoff) do
    crew_since =
      from(k in Thread,
        where: k.kind == "crew" and k.athanor_id == parent_as(:room).athanor_id,
        where: k.parent_id == parent_as(:room).id,
        where: coalesce(k.last_message_at, k.inserted_at) >= ^cutoff,
        select: 1
      )

    from(c in Thread,
      as: :room,
      where: c.kind in ^@room_kinds and is_nil(c.archived_at),
      where: coalesce(c.last_message_at, c.inserted_at) < ^cutoff,
      where: not exists(subquery(crew_since)),
      order_by: [asc: c.id]
    )
    |> QueryHelpers.where_tenant(actor)
    |> Repo.all()
    |> Enum.reject(&at_work?(actor, &1))
    |> Enum.map(& &1.id)
  end

  # Each archived thread, told after its commit: the person's list moves
  # it behind its filter, and a browser holding its window closes it
  # (`Cyfr.TelemetryBridge`).
  defp announce_archived(%Prima.Actor{athanor_id: athanor_id}, ids) do
    for id <- ids,
        do:
          :telemetry.execute([:cyfr, :arca, :thread, :archived], %{count: 1}, %{
            athanor_id: athanor_id,
            thread_id: id
          })

    :ok
  end

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
