# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadStorage do
  @moduledoc """
  Persistence for the athanor's threads and their messages — the
  durable record every member reads (`Aqua.Tape` writes it,
  `PrismWeb.ThreadPaneLive` shows it).

  A thread belongs to the athanor of the context that opened it;
  members are interchangeable, so any member of that athanor may read it,
  send the next message or decide a pending approval. Reads scope through
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
  alias Arca.Schemas.Thread
  alias Arca.Schemas.Message

  # The two reserved row authors, spelled once in the schema.
  @agent_author Message.agent_author()
  @system_author Message.system_author()

  @default_title "New thread"
  @title_max 80

  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc "The athanor's threads, most recently active first."
  @spec list(Prima.Actor.t(), keyword()) :: [map()] | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{athanor_id: athanor_id} = actor, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.list", fn ->
      limit = Keyword.get(opts, :limit, 200)

      from(c in Thread,
        order_by: [desc: coalesce(c.last_message_at, c.inserted_at)],
        limit: ^limit
      )
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
  Open a new thread in the context's athanor, attributed to its user.

  The creator starts out following it — a thread unfollowed by its own
  author would be born invisible — and everyone else follows it
  themselves. There is deliberately no subscriber list to pass: a client
  must not follow other members.
  """
  @spec create(Prima.Actor.t(), map()) ::
          {:ok, map()} | {:error, :no_athanor | {:invalid, map()} | :database_error}
  def create(actor, attrs \\ %{})

  def create(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.create", fn ->
      # A thread is a row any member's client can mint from the wire, so
      # the estate's count is held to the operator's cap like its DMs are.
      with :ok <-
             Prima.Caps.check_counted(actor, :max_threads_per_athanor, fn ->
               {:ok, count(actor)}
             end),
           {:ok, thread} <-
             %Thread{}
             |> Thread.changeset(%{
               id: attrs[:id] || Prima.UUID7.generate_id("thread"),
               athanor_id: actor.athanor_id,
               title: attrs[:title] || @default_title,
               created_by: actor.user_id || @system_author
             })
             |> Repo.insert() do
        subscribe_creator(actor, thread)
        {:ok, thread}
      end
    end)
    |> Arca.Data.project()
  end

  def create(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  # How many threads the estate holds — read inside `create/2`'s rescue.
  defp count(%Prima.Actor{} = actor) do
    Repo.aggregate(from(c in Thread, where: c.athanor_id == ^actor.athanor_id), :count)
  end

  # Best effort: a thread that exists but is in nobody's sidebar is a
  # recoverable annoyance (follow it), where failing the create over it
  # would lose the thread itself.
  defp subscribe_creator(%Prima.Actor{user_id: creator} = actor, thread) when is_binary(creator) do
    Arca.ThreadSubscriptionStorage.follow(actor, thread.id, creator)
  end

  defp subscribe_creator(_ctx, _thread), do: :ok

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
  next may have changed — and `{:error, {:busy, turn_id}}` when another
  turn holds it. A thread this turn already holds answers `{:ok, thread}`,
  so a claimant that lost track of its own claim may ask again.
  """
  @spec claim(Prima.Actor.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :stale | {:busy, String.t()} | :database_error}
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
        {:error, {:busy, held}}

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
  work, waiting on a person. `turn.suspend` and every terminal transition
  release it.
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
  transaction back with `:busy` when a live peer holds the thread.
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
      {0, _} -> Repo.rollback(:busy)
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
  Delete a thread, its messages and its attachment blobs
  (`blob_root/1` under the athanor's storage). Bytes go FIRST: a failed
  blob delete keeps the rows and answers
  `{:error, {:storage_delete_failed, reason}}`, so the DB can never claim
  a deletion the tree didn't make — the next attempt (or the orphan
  sweep) retries.
  """
  @spec delete(Prima.Actor.t(), String.t()) ::
          :ok | {:error, :no_athanor | :not_found | {:storage_delete_failed, term()}}
  def delete(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.delete", fn -> do_delete(actor, id) end)
    |> Arca.Data.project()
  end

  def delete(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  defp do_delete(actor, id) do
    with {:ok, thread} <- thread_row(actor, id),
         :ok <- delete_blobs(actor, thread.id) do
      # arca:unscoped-ok thread_row(actor, id) above establishes thread ownership.
      # Delete its messages, follows, and grants. Explicit message deletion
      # also covers SQLite connections without foreign_keys=ON.
      Repo.transaction(fn ->
        Repo.delete_all(from(m in Message, where: m.thread_id == ^thread.id))
        delete_thread_satellites([thread.id])
        Repo.delete!(thread)
      end)

      :ok
    end
  end

  # What rides with a thread besides its messages: who followed it,
  # and what its members already answered about tool calls in it.
  # Agent-scope grants are untouched — they belong to the agent, not the
  # thread.
  #
  # arca:unscoped-ok scoped transitively — every id comes from a read the
  # caller already tenant-proved (do_delete's `get`, delete_before's
  # `where_athanor`), and each row names exactly one thread.
  defp delete_thread_satellites(ids) do
    Repo.delete_all(from(s in Arca.Schemas.ThreadSubscription, where: s.thread_id in ^ids))

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
  rows: blobs are only ever written under an existing thread row
  (`Aqua.Attachments`), so a snapshotted directory either has a row
  (kept) or is a genuine orphan — a concurrent create can never lose its
  bytes to this sweep.
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
    end
  end

  # Bytes-first, typed: `:not_found` counts as deleted (nothing stored).
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

  `attrs`: `:author` (required), `:kind` (default `"text"`), `:content`,
  `:payload` (a map, stored as JSON), `:status`, `:execution_id`. The next
  `seq` is taken inside a transaction; a concurrent appender losing the race
  on the unique index retries. The first user text message titles a
  thread that still carries the default title.
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
  # (`Arca.TurnStorage.with_seq_retry/1`). Titles the thread from its first
  # user text and bumps `last_message_at` as `append/3` does. An
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

    msg =
      Repo.insert!(
        Message.changeset(%Message{}, %{
          id: attrs[:id] || Prima.UUID7.generate_id("msg"),
          thread_id: thread.id,
          athanor_id: actor.athanor_id,
          seq: seq,
          author: attrs[:author],
          kind: attrs[:kind] || "text",
          content: attrs[:content] || "",
          payload: encode_json(attrs[:payload]),
          status: attrs[:status],
          execution_id: attrs[:execution_id],
          turn_id: attrs[:turn_id],
          approval_id: attrs[:approval_id],
          client_id: attrs[:client_id],
          inserted_at: now
        })
      )

    thread
    |> Thread.changeset(%{last_message_at: now, title: title_after(thread, msg)})
    |> Repo.update!()

    msg
  end

  def insert_message!(%Prima.Actor{}, _thread, _attrs),
    do: Arca.QueryHelpers.no_athanor!("Arca.ThreadStorage.insert_message!/3")

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
              where: m.thread_id == ^thread.id,
              select: coalesce(max(m.seq), 0)
            )
          ) + 1

        changeset =
          Message.changeset(%Message{}, %{
            id: attrs[:id] || Prima.UUID7.generate_id("msg"),
            thread_id: thread.id,
            athanor_id: actor.athanor_id,
            seq: seq,
            author: attrs[:author],
            kind: attrs[:kind] || "text",
            content: attrs[:content] || "",
            payload: encode_json(attrs[:payload]),
            status: attrs[:status],
            execution_id: attrs[:execution_id],
            turn_id: attrs[:turn_id],
            approval_id: attrs[:approval_id],
            client_id: attrs[:client_id],
            inserted_at: now
          })

        case Repo.insert(changeset) do
          {:ok, msg} ->
            thread
            |> Thread.changeset(%{
              last_message_at: now,
              title: title_after(thread, msg)
            })
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

  # A thread is named by its first user text; later renames are the
  # user's own (`update/3`).
  defp title_after(%Thread{title: @default_title}, %Message{
         kind: "text",
         author: author,
         content: content
       })
       when author not in [@agent_author, @system_author] and is_binary(content) do
    # The row keeps the text as typed; the title drops a leading `@aqua`.
    first_line = content |> String.trim() |> String.split("\n", parts: 2) |> List.first()

    case first_line && Regex.replace(~r/^@\S+\s*/, first_line, "") do
      "" -> @default_title
      nil -> @default_title
      line -> String.slice(line, 0, @title_max)
    end
  end

  defp title_after(%Thread{title: title}, _msg), do: title

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
  @spec resolve_approval(Prima.Actor.t(), String.t(), [String.t()] | String.t(), String.t(), map()) ::
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
  `cutoff` — messages and attachment blobs included. The context is the
  athanor's (retention walks each with an internal context).
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

  defp delete_before_rows(actor, cutoff) do
    ids = Repo.all(from(c in stale_before(actor, cutoff), select: c.id))

    # Bytes before rows, per thread: an id whose blob delete fails
    # keeps its rows and retries next cycle — never an orphaned tree the
    # DB has already forgotten.
    deletable =
      Enum.filter(ids, fn id ->
        case delete_blobs(actor, id) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("[ThreadStorage] keeping #{id} this cycle: #{inspect(reason)}")

            false
        end
      end)

    if deletable == [] do
      {:ok, 0}
    else
      # One transaction, like `do_delete/2`: a crash between the two
      # deletes otherwise left an empty thread row behind. The
      # satellites (follows, thread-scope grants) sweep with the
      # rows, same as a hand delete.
      {:ok, count} =
        Repo.transaction(fn ->
          Repo.delete_all(from(m in Message, where: m.thread_id in ^deletable))
          delete_thread_satellites(deletable)

          {count, _} =
            from(c in Thread, where: c.id in ^deletable)
            |> QueryHelpers.where_tenant(actor)
            |> Repo.delete_all()

          count
        end)

      {:ok, count}
    end
  end

  # The retention window both verbs speak, scoped the one way this module
  # scopes: the athanor's threads whose last activity is older than
  # `cutoff`, a thread holding an open turn never among them.
  defp stale_before(%Prima.Actor{athanor_id: athanor_id} = actor, cutoff) do
    open =
      from(t in Arca.Schemas.Turn,
        where: t.athanor_id == ^athanor_id and t.status in ^Arca.TurnStorage.open_statuses(),
        select: t.thread_id
      )

    from(c in Thread,
      where: c.id not in subquery(open) and coalesce(c.last_message_at, c.inserted_at) < ^cutoff
    )
    |> QueryHelpers.where_tenant(actor)
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
      {:ok, Repo.aggregate(stale_before(actor, cutoff), :count)}
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
  defp decode_stored(nil, default, _field), do: default
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Prima.Json.decode(json) do
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
