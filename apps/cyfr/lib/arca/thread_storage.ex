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
  """

  import Ecto.Query
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Repo
  alias Arca.Schemas.Thread
  alias Arca.Schemas.Message
  alias Sanctum.Context

  # The two reserved row authors, spelled once in the schema.
  @agent_author Message.agent_author()
  @system_author Message.system_author()

  @default_title "New thread"
  @title_max 80

  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc "The athanor's threads, most recently active first."
  @spec list(Context.t(), keyword()) :: [Thread.t()] | {:error, :database_error}
  def list(%Context{} = ctx, opts \\ []) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.list", fn ->
      limit = Keyword.get(opts, :limit, 200)

      from(c in Thread,
        order_by: [desc: coalesce(c.last_message_at, c.inserted_at)],
        limit: ^limit
      )
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.all()
    end)
  end

  @doc "One thread of the context's athanor."
  @spec get(Context.t(), String.t()) ::
          {:ok, Thread.t()} | {:error, :not_found | :database_error}
  def get(%Context{} = ctx, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.get", fn ->
      from(c in Thread, where: c.id == ^id)
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        thread -> {:ok, thread}
      end
    end)
  end

  @doc """
  Open a new thread in the context's athanor, attributed to its user.

  The creator starts out following it — a thread unfollowed by its own
  author would be born invisible — and everyone else follows it
  themselves. There is deliberately no subscriber list to pass: a client
  must not follow other members.
  """
  @spec create(Context.t(), map()) ::
          {:ok, Thread.t()} | {:error, Ecto.Changeset.t() | :database_error}
  def create(%Context{} = ctx, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.create", fn ->
      Context.require_tenant!(ctx)

      # A thread is a row any member's client can mint from the wire, so
      # the estate's count is held to the operator's cap like its DMs are.
      with :ok <-
             Sanctum.Tenancy.Caps.check_counted(:max_threads_per_athanor, fn ->
               {:ok, count(ctx)}
             end),
           {:ok, thread} <-
             %Thread{}
             |> Thread.changeset(%{
               id: attrs[:id] || Cyfr.UUID7.generate_id("thread"),
               athanor_id: ctx.athanor_id,
               title: attrs[:title] || @default_title,
               created_by: ctx.user_id || @system_author
             })
             |> Repo.insert() do
        subscribe_creator(ctx, thread)
        {:ok, thread}
      end
    end)
  end

  # How many threads the estate holds — read inside `create/2`'s rescue.
  defp count(%Context{} = ctx) do
    Repo.aggregate(from(c in Thread, where: c.athanor_id == ^ctx.athanor_id), :count)
  end

  # Best effort: a thread that exists but is in nobody's sidebar is a
  # recoverable annoyance (follow it), where failing the create over it
  # would lose the thread itself.
  defp subscribe_creator(%Context{user_id: creator} = ctx, thread) when is_binary(creator) do
    Arca.ThreadSubscriptionStorage.follow(ctx, thread.id, creator)
  end

  defp subscribe_creator(_ctx, _thread), do: :ok

  @doc """
  Update a thread's title, orchestrator, turn cursor or last
  activity.
  """
  @spec update(Context.t(), String.t(), map()) ::
          {:ok, Thread.t()} | {:error, :not_found | :database_error | Ecto.Changeset.t()}
  def update(%Context{} = ctx, id, attrs) when is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.update", fn ->
      with {:ok, thread} <- get(ctx, id) do
        attrs =
          attrs
          |> Map.take([:title, :orchestrator, :turn_seq, :last_message_at])

        thread |> Thread.changeset(attrs) |> Repo.update()
      end
    end)
  end

  @doc """
  Delete a thread, its messages and its attachment blobs
  (`blob_root/1` under the athanor's storage). Bytes go FIRST: a failed
  blob delete keeps the rows and answers
  `{:error, {:storage_delete_failed, reason}}`, so the DB can never claim
  a deletion the tree didn't make — the next attempt (or the orphan
  sweep) retries.
  """
  @spec delete(Context.t(), String.t()) ::
          :ok | {:error, :not_found | {:storage_delete_failed, term()}}
  def delete(%Context{} = ctx, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.delete", fn -> do_delete(ctx, id) end)
  end

  defp do_delete(ctx, id) do
    with {:ok, thread} <- get(ctx, id),
         :ok <- delete_blobs(ctx, thread.id) do
      # arca:unscoped-ok get(ctx, id) above establishes thread ownership.
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
  @spec sweep_orphaned_blobs(Context.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_orphaned_blobs(%Context{} = ctx) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.sweep_orphaned_blobs", fn ->
      do_sweep_orphaned_blobs(ctx)
    end)
  end

  defp do_sweep_orphaned_blobs(ctx) do
    with {:ok, entries} <- Arca.list_typed(ctx, ["threads"]) do
      dirs = for {name, :dir} <- entries, do: name

      alive =
        from(c in Thread, select: c.id)
        |> QueryHelpers.where_tenant(ctx)
        |> Repo.all()
        |> MapSet.new()

      dirs
      |> Enum.reject(&MapSet.member?(alive, &1))
      |> Enum.reduce_while({:ok, 0}, fn id, {:ok, reclaimed} ->
        case Arca.delete_tree(ctx, blob_root(id)) do
          :ok -> {:cont, {:ok, reclaimed + 1}}
          {:error, :not_found} -> {:cont, {:ok, reclaimed}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Bytes-first, typed: `:not_found` counts as deleted (nothing stored).
  defp delete_blobs(ctx, thread_id) do
    case Arca.delete_tree(ctx, blob_root(thread_id)) do
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
  @spec messages(Context.t(), String.t(), keyword()) ::
          [Message.t()] | {:error, :database_error}
  def messages(%Context{} = ctx, thread_id, opts \\ []) when is_binary(thread_id) do
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
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.all()
    end)
  end

  @doc """
  The newest `n` messages of a thread, in ascending order.

  The console's transcript view: `messages/3`'s `:limit` takes the OLDEST
  rows (it bounds windowed turn assembly), which is the wrong end for a
  reader opening a long-lived thread.
  """
  @spec latest_messages(Context.t(), String.t(), pos_integer()) ::
          [Message.t()] | {:error, term()}
  def latest_messages(%Context{} = ctx, thread_id, n)
      when is_binary(thread_id) and is_integer(n) and n > 0 do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.latest_messages", fn ->
      from(m in Message,
        where: m.thread_id == ^thread_id,
        order_by: [desc: m.seq],
        limit: ^n
      )
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.all()
      |> Enum.reverse()
    end)
  end

  @doc "One message of the context's athanor."
  @spec get_message(Context.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :not_found | :database_error}
  def get_message(%Context{} = ctx, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.get_message", fn ->
      from(m in Message, where: m.id == ^id)
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        msg -> {:ok, msg}
      end
    end)
  end

  @doc "The approval rows of a thread still waiting on a decision."
  @spec pending_approvals(Context.t(), String.t()) ::
          [Message.t()] | {:error, :database_error}
  def pending_approvals(%Context{} = ctx, thread_id) when is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.pending_approvals", fn ->
      from(m in Message,
        where:
          m.thread_id == ^thread_id and m.kind == "approval" and
            m.status == "pending",
        order_by: [asc: m.seq]
      )
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.all()
    end)
  end

  @doc """
  Append one message to a thread.

  `attrs`: `:author` (required), `:kind` (default `"text"`), `:content`,
  `:payload` (a map, stored as JSON), `:status`, `:execution_id`. The next
  `seq` is taken inside a transaction; a concurrent appender losing the race
  on the unique index retries. The first user text message titles a
  thread that still carries the default title.
  """
  @spec append(Context.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, :not_found | :seq_conflict | Ecto.Changeset.t()}
  def append(%Context{} = ctx, thread_id, attrs) when is_map(attrs) do
    # Rescued like every other write here: the transaction is inside the
    # private helper, where `Arca.DbRescueCoverageTest` (which inspects
    # public heads for repo calls) could not see it — so an outage raised
    # `DBConnection.ConnectionError` into the runner and the LiveView
    # instead of the module's `{:error, :database_error}`.
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadStorage.append", fn ->
      with {:ok, thread} <- get(ctx, thread_id) do
        do_append(ctx, thread, attrs, 3)
      end
    end)
  end

  @doc """
  Insert one message inside the caller's transaction, at the next `seq`,
  raising on a store error so the caller's transaction rolls back. The
  `(thread_id, seq)` race surfaces as `Ecto.InvalidChangesetError`
  carrying a `:unique` constraint on `:thread_id`; a caller that
  owns the transaction retries the whole transaction on it
  (`Arca.TurnStorage.with_seq_retry/1`). Titles the thread from its
  first user text and bumps `last_message_at` as `append/3` does.
  """
  @spec insert_message!(Context.t(), Thread.t(), map()) :: Message.t()
  # arca:db-raise-ok inside the caller's transaction
  def insert_message!(%Context{} = ctx, %Thread{} = thread, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    seq =
      Repo.one(
        from(m in Message,
          where: m.thread_id == ^thread.id and m.athanor_id == ^ctx.athanor_id,
          select: coalesce(max(m.seq), 0)
        )
      ) + 1

    msg =
      Repo.insert!(
        Message.changeset(%Message{}, %{
          id: attrs[:id] || Cyfr.UUID7.generate_id("msg"),
          thread_id: thread.id,
          athanor_id: ctx.athanor_id,
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

  @doc "The message a sender accepted under `client_id` in this thread, if any."
  @spec get_by_client_id(Context.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :not_found | :database_error}
  def get_by_client_id(%Context{} = ctx, thread_id, client_id)
      when is_binary(thread_id) and is_binary(client_id) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.get_by_client_id", fn ->
      case Repo.one(
             from(m in Message,
               where: m.thread_id == ^thread_id and m.athanor_id == ^ctx.athanor_id,
               where: m.client_id == ^client_id
             )
           ) do
        nil -> {:error, :not_found}
        msg -> {:ok, msg}
      end
    end)
  end

  defp do_append(_ctx, _thread, _attrs, 0), do: {:error, :seq_conflict}

  defp do_append(ctx, thread, attrs, retries) do
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
            id: attrs[:id] || Cyfr.UUID7.generate_id("msg"),
            thread_id: thread.id,
            athanor_id: ctx.athanor_id,
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
              do: do_append(ctx, thread, attrs, retries - 1),
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
  @spec update_message(Context.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, :not_found | :database_error | Ecto.Changeset.t()}
  def update_message(%Context{} = ctx, id, attrs) when is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.update_message", fn ->
      with {:ok, msg} <- get_message(ctx, id) do
        attrs =
          attrs
          |> Map.take([:content, :payload, :status, :execution_id])
          |> Map.update(:payload, nil, &encode_json/1)
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        msg |> Message.changeset(attrs) |> Repo.update()
      end
    end)
  end

  @doc """
  Move an approval row from one of `from` to `to` — compare-and-set on
  `status`, so a second decision on the same card sees
  `{:error, :already_resolved}` instead of running it twice. `attrs` may
  carry `:resolution` (a map, stored as JSON); `resolved_by` is the
  context's user and `resolved_at` is now unless the row is only being
  marked `"running"`.
  """
  @spec resolve_approval(Context.t(), String.t(), [String.t()] | String.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, :not_found | :already_resolved | :database_error}
  def resolve_approval(%Context{} = ctx, id, from, to, attrs \\ %{})
      when is_binary(id) and to in ~w(running approved declined error) do
    Arca.Repo.Errors.with_db_rescue("ThreadStorage.resolve_approval", fn ->
      do_resolve_approval(ctx, id, from, to, attrs)
    end)
  end

  defp do_resolve_approval(ctx, id, from, to, attrs) do
    Context.require_tenant!(ctx)
    from = List.wrap(from)
    now = DateTime.utc_now()

    updates =
      [status: to, resolved_by: ctx.user_id || @system_author]
      |> Keyword.merge(if(to == "running", do: [], else: [resolved_at: now]))
      |> Keyword.merge(
        case attrs[:resolution] do
          nil -> []
          resolution -> [resolution: encode_json(resolution)]
        end
      )

    {count, _} =
      from(m in Message, where: m.id == ^id and m.kind == "approval" and m.status in ^from)
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.update_all(set: updates)

    case count do
      1 ->
        get_message(ctx, id)

      0 ->
        case get_message(ctx, id) do
          {:ok, _} -> {:error, :already_resolved}
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  @doc "A message's `payload` decoded (`%{}` when none)."
  @spec payload(Message.t()) :: map()
  def payload(%Message{payload: nil}), do: %{}
  def payload(%Message{payload: json}), do: decode_map(json)

  @doc "A message's `resolution` decoded (`%{}` when none)."
  @spec resolution(Message.t()) :: map()
  def resolution(%Message{resolution: nil}), do: %{}
  def resolution(%Message{resolution: json}), do: decode_map(json)

  # ---------------------------------------------------------------------------
  # Restart recovery / retention
  # ---------------------------------------------------------------------------

  @doc """
  Delete the athanor's threads whose last activity is older than
  `cutoff` — messages and attachment blobs included. The context is the
  athanor's (retention walks each with an internal context).
  """
  @spec delete_before(Context.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_before(%Context{} = ctx, %DateTime{} = cutoff) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadStorage.delete_before", fn ->
      delete_before_rows(ctx, cutoff)
    end)
  end

  defp delete_before_rows(ctx, cutoff) do
    ids = Repo.all(from(c in stale_before(ctx, cutoff), select: c.id))

    # Bytes before rows, per thread: an id whose blob delete fails
    # keeps its rows and retries next cycle — never an orphaned tree the
    # DB has already forgotten.
    deletable =
      Enum.filter(ids, fn id ->
        case delete_blobs(ctx, id) do
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
            |> QueryHelpers.where_tenant(ctx)
            |> Repo.delete_all()

          count
        end)

      {:ok, count}
    end
  end

  # The retention window both verbs speak, scoped the one way this module
  # scopes: the athanor's threads whose last activity is older than
  # `cutoff`, a thread holding an open turn never among them.
  defp stale_before(ctx, cutoff) do
    athanor_id = Context.athanor!(ctx)

    open =
      from(t in Arca.Schemas.Turn,
        where: t.athanor_id == ^athanor_id and t.status in ^Arca.TurnStorage.open_statuses(),
        select: t.thread_id
      )

    from(c in Thread,
      where: c.id not in subquery(open) and coalesce(c.last_message_at, c.inserted_at) < ^cutoff
    )
    |> QueryHelpers.where_tenant(ctx)
  end

  @doc """
  How many threads `delete_before/2` would remove — the dry-run
  count, sharing its rule: a thread with a running turn is never
  touched.
  """
  @spec count_before(Context.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_before(%Context{} = ctx, %DateTime{} = cutoff) do
    Arca.Repo.Errors.with_db_rescue("Arca.ThreadStorage.count_before", fn ->
      {:ok, Repo.aggregate(stale_before(ctx, cutoff), :count)}
    end)
  end

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_map(json) do
    case Cyfr.Json.decode_or(json, %{}, "Arca.ThreadStorage.decode_map") do
      %{} = map -> map
      _ -> %{}
    end
  end
end
