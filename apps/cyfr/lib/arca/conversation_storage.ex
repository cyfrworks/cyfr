# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConversationStorage do
  @moduledoc """
  Persistence for the athanor's conversations and their messages — the
  durable record every member reads (`Aqua.ConversationRunner` writes it,
  `PrismWeb.ConversationPaneLive` shows it).

  A conversation belongs to the athanor of the context that opened it;
  members are interchangeable, so any member of that athanor may read it,
  send the next message or decide a pending approval. Reads scope through
  `Arca.QueryHelpers.where_tenant/2` (a context without an athanor raises,
  fail closed) and every write stamps the context's athanor.

  Message rows are appended in `seq` order by `append/3`; the unique index
  on `(conversation_id, seq)` is what makes two writers appending at once
  safe — the loser retries with the next number. Approval rows move through
  `resolve_approval/4`, a compare-and-set on `status`, so two members
  clicking the same card cannot both run it.
  """

  import Ecto.Query
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Repo
  alias Arca.Schemas.Conversation
  alias Arca.Schemas.Message
  alias Sanctum.Context

  # The two reserved row authors, spelled once in the schema.
  @agent_author Message.agent_author()
  @system_author Message.system_author()

  @default_title "New conversation"
  @title_max 80

  # ---------------------------------------------------------------------------
  # Conversations
  # ---------------------------------------------------------------------------

  @doc "The athanor's conversations, most recently active first."
  @spec list(Context.t(), keyword()) :: [Conversation.t()] | {:error, :database_error}
  def list(%Context{} = ctx, opts \\ []) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.list", fn ->
      limit = Keyword.get(opts, :limit, 200)

      from(c in Conversation,
        order_by: [desc: coalesce(c.last_message_at, c.inserted_at)],
        limit: ^limit
      )
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.all()
    end)
  end

  @doc "One conversation of the context's athanor."
  @spec get(Context.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :not_found | :database_error}
  def get(%Context{} = ctx, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.get", fn ->
      from(c in Conversation, where: c.id == ^id)
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        conv -> {:ok, conv}
      end
    end)
  end

  @doc """
  Open a new conversation in the context's athanor, attributed to its user.

  The creator starts out following it — a thread unfollowed by its own
  author would be born invisible — and everyone else follows it
  themselves. There is deliberately no subscriber list to pass: a client
  must not follow other members.
  """
  @spec create(Context.t(), map()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t() | :database_error}
  def create(%Context{} = ctx, attrs \\ %{}) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.create", fn ->
      Context.require_tenant!(ctx)

      # A thread is a row any member's client can mint from the wire, so
      # the estate's count is held to the operator's cap like its DMs are.
      with :ok <-
             Sanctum.Tenancy.Caps.check_counted(:max_conversations_per_athanor, fn ->
               {:ok, count(ctx)}
             end),
           {:ok, conv} <-
             %Conversation{}
             |> Conversation.changeset(%{
               id: attrs[:id] || Cyfr.UUID7.generate_id("conv"),
               athanor_id: ctx.athanor_id,
               title: attrs[:title] || @default_title,
               created_by: ctx.user_id || @system_author
             })
             |> Repo.insert() do
        subscribe_creator(ctx, conv)
        {:ok, conv}
      end
    end)
  end

  # How many threads the estate holds — read inside `create/2`'s rescue.
  defp count(%Context{} = ctx) do
    Repo.aggregate(from(c in Conversation, where: c.athanor_id == ^ctx.athanor_id), :count)
  end

  # Best effort: a topic that exists but is in nobody's sidebar is a
  # recoverable annoyance (follow it), where failing the create over it
  # would lose the thread itself.
  defp subscribe_creator(%Context{user_id: creator} = ctx, conv) when is_binary(creator) do
    Arca.TopicSubscriptionStorage.follow(ctx, conv.id, creator)
  end

  defp subscribe_creator(_ctx, _conv), do: :ok

  @doc """
  Update a conversation's title, history, running execution, orchestrator
  or turn cursor.
  """
  @spec update(Context.t(), String.t(), map()) ::
          {:ok, Conversation.t()} | {:error, :not_found | :database_error | Ecto.Changeset.t()}
  def update(%Context{} = ctx, id, attrs) when is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.update", fn ->
      with {:ok, conv} <- get(ctx, id) do
        attrs =
          attrs
          |> Map.take([
            :title,
            :history,
            :execution_id,
            :orchestrator,
            :turn_seq,
            :last_message_at
          ])
          |> encode_history()

        conv |> Conversation.changeset(attrs) |> Repo.update()
      end
    end)
  end

  @doc """
  Delete a conversation, its messages and its attachment blobs
  (`blob_root/1` under the athanor's storage). Bytes go FIRST: a failed
  blob delete keeps the rows and answers
  `{:error, {:storage_delete_failed, reason}}`, so the DB can never claim
  a deletion the tree didn't make — the next attempt (or the orphan
  sweep) retries.
  """
  @spec delete(Context.t(), String.t()) ::
          :ok | {:error, :not_found | {:storage_delete_failed, term()}}
  def delete(%Context{} = ctx, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.delete", fn -> do_delete(ctx, id) end)
  end

  defp do_delete(ctx, id) do
    with {:ok, conv} <- get(ctx, id),
         :ok <- delete_blobs(ctx, conv.id) do
      # arca:unscoped-ok get(ctx, id) above establishes conversation ownership.
      # Delete its messages, follows, and grants. Explicit message deletion
      # also covers SQLite connections without foreign_keys=ON.
      Repo.transaction(fn ->
        Repo.delete_all(from(m in Message, where: m.conversation_id == ^conv.id))
        delete_conversation_satellites([conv.id])
        Repo.delete!(conv)
      end)

      :ok
    end
  end

  # What rides with a conversation besides its messages: who followed it,
  # and what its members already answered about tool calls in it.
  # Agent-scope grants are untouched — they belong to the agent, not the
  # thread.
  #
  # arca:unscoped-ok scoped transitively — every id comes from a read the
  # caller already tenant-proved (do_delete's `get`, delete_before's
  # `where_athanor`), and each row names exactly one conversation.
  defp delete_conversation_satellites(ids) do
    Repo.delete_all(from(s in Arca.Schemas.TopicSubscription, where: s.conversation_id in ^ids))

    Repo.delete_all(
      from(g in Arca.Schemas.ToolGrant,
        where:
          g.scope == ^Arca.Schemas.ToolGrant.conversation_scope() and g.conversation_id in ^ids
      )
    )

    :ok
  end

  @doc """
  Where a conversation's attachment bytes live under the athanor's storage:
  `conversations/<conversation_id>/<message_id>/<filename>`.
  """
  @spec blob_root(String.t()) :: [String.t()]
  def blob_root(conversation_id) when is_binary(conversation_id),
    do: ["conversations", conversation_id]

  @doc """
  Reclaim conversation blob directories no row backs — the retention
  sweep's leg. The directories are snapshotted FIRST, then the surviving
  rows: blobs are only ever written under an existing conversation row
  (`Aqua.Attachments`), so a snapshotted directory either has a row
  (kept) or is a genuine orphan — a concurrent create can never lose its
  bytes to this sweep.
  """
  @spec sweep_orphaned_blobs(Context.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_orphaned_blobs(%Context{} = ctx) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.sweep_orphaned_blobs", fn ->
      do_sweep_orphaned_blobs(ctx)
    end)
  end

  defp do_sweep_orphaned_blobs(ctx) do
    with {:ok, entries} <- Arca.list_typed(ctx, ["conversations"]) do
      dirs = for {name, :dir} <- entries, do: name

      alive =
        from(c in Conversation, select: c.id)
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
  defp delete_blobs(ctx, conversation_id) do
    case Arca.delete_tree(ctx, blob_root(conversation_id)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:storage_delete_failed, reason}}
    end
  end

  @doc "The provider-shape history stored on a conversation, decoded (`[]` when none)."
  @spec history(Conversation.t()) :: [map()]
  def history(%Conversation{history: nil}), do: []

  def history(%Conversation{history: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  @doc """
  The messages of a conversation, oldest first. `after_seq:` / `upto_seq:`
  bound the window (exclusive / inclusive) — a turn's task is the human
  rows between the last turn's cursor and the message that started it.
  """
  @spec messages(Context.t(), String.t(), keyword()) ::
          [Message.t()] | {:error, :database_error}
  def messages(%Context{} = ctx, conversation_id, opts \\ []) when is_binary(conversation_id) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.messages", fn ->
      query =
        from(m in Message, where: m.conversation_id == ^conversation_id, order_by: [asc: m.seq])

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
      # long-lived conversation; unset loads all (turn assembly needs the
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
  The newest `n` messages of a conversation, in ascending order.

  The console's transcript view: `messages/3`'s `:limit` takes the OLDEST
  rows (it bounds windowed turn assembly), which is the wrong end for a
  reader opening a long-lived conversation.
  """
  @spec latest_messages(Context.t(), String.t(), pos_integer()) ::
          [Message.t()] | {:error, term()}
  def latest_messages(%Context{} = ctx, conversation_id, n)
      when is_binary(conversation_id) and is_integer(n) and n > 0 do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.latest_messages", fn ->
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
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
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.get_message", fn ->
      from(m in Message, where: m.id == ^id)
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        msg -> {:ok, msg}
      end
    end)
  end

  @doc "The approval rows of a conversation still waiting on a decision."
  @spec pending_approvals(Context.t(), String.t()) ::
          [Message.t()] | {:error, :database_error}
  def pending_approvals(%Context{} = ctx, conversation_id) when is_binary(conversation_id) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.pending_approvals", fn ->
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and m.kind == "approval" and
            m.status == "pending",
        order_by: [asc: m.seq]
      )
      |> QueryHelpers.where_tenant(ctx)
      |> Repo.all()
    end)
  end

  @doc """
  Append one message to a conversation.

  `attrs`: `:author` (required), `:kind` (default `"text"`), `:content`,
  `:payload` (a map, stored as JSON), `:status`, `:execution_id`. The next
  `seq` is taken inside a transaction; a concurrent appender losing the race
  on the unique index retries. The first user text message titles a
  conversation that still carries the default title.
  """
  @spec append(Context.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, :not_found | :seq_conflict | Ecto.Changeset.t()}
  def append(%Context{} = ctx, conversation_id, attrs) when is_map(attrs) do
    # Rescued like every other write here: the transaction is inside the
    # private helper, where `Arca.DbRescueCoverageTest` (which inspects
    # public heads for repo calls) could not see it — so an outage raised
    # `DBConnection.ConnectionError` into the runner and the LiveView
    # instead of the module's `{:error, :database_error}`.
    Arca.Repo.Errors.with_db_rescue("Arca.ConversationStorage.append", fn ->
      with {:ok, conv} <- get(ctx, conversation_id) do
        do_append(ctx, conv, attrs, 3)
      end
    end)
  end

  @doc """
  Insert one message inside the caller's transaction, at the next `seq`,
  raising on a store error so the caller's transaction rolls back. The
  `(conversation_id, seq)` race surfaces as `Ecto.InvalidChangesetError`
  carrying a `:unique` constraint on `:conversation_id`; a caller that
  owns the transaction retries the whole transaction on it
  (`Arca.TurnStorage.with_seq_retry/1`). Titles the conversation from its
  first user text and bumps `last_message_at` as `append/3` does.
  """
  @spec insert_message!(Context.t(), Conversation.t(), map()) :: Message.t()
  # arca:db-raise-ok inside the caller's transaction
  def insert_message!(%Context{} = ctx, %Conversation{} = conv, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    seq =
      Repo.one(
        from(m in Message,
          where: m.conversation_id == ^conv.id and m.athanor_id == ^ctx.athanor_id,
          select: coalesce(max(m.seq), 0)
        )
      ) + 1

    msg =
      Repo.insert!(
        Message.changeset(%Message{}, %{
          id: attrs[:id] || Cyfr.UUID7.generate_id("msg"),
          conversation_id: conv.id,
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

    conv
    |> Conversation.changeset(%{last_message_at: now, title: title_after(conv, msg)})
    |> Repo.update!()

    msg
  end

  @doc "The message a sender accepted under `client_id` in this conversation, if any."
  @spec get_by_client_id(Context.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :not_found | :database_error}
  def get_by_client_id(%Context{} = ctx, conversation_id, client_id)
      when is_binary(conversation_id) and is_binary(client_id) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.get_by_client_id", fn ->
      case Repo.one(
             from(m in Message,
               where: m.conversation_id == ^conversation_id and m.athanor_id == ^ctx.athanor_id,
               where: m.client_id == ^client_id
             )
           ) do
        nil -> {:error, :not_found}
        msg -> {:ok, msg}
      end
    end)
  end

  defp do_append(_ctx, _conv, _attrs, 0), do: {:error, :seq_conflict}

  defp do_append(ctx, conv, attrs, retries) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        seq =
          Repo.one(
            from(m in Message,
              where: m.conversation_id == ^conv.id,
              select: coalesce(max(m.seq), 0)
            )
          ) + 1

        changeset =
          Message.changeset(%Message{}, %{
            id: attrs[:id] || Cyfr.UUID7.generate_id("msg"),
            conversation_id: conv.id,
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
            conv
            |> Conversation.changeset(%{
              last_message_at: now,
              title: title_after(conv, msg)
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
        # Only the (conversation_id, seq) unique race retries — any other
        # changeset error on that field is a real refusal, not the race.
        case Keyword.get(errors, :conversation_id) do
          {_msg, meta} when is_list(meta) ->
            if Keyword.get(meta, :constraint) == :unique,
              do: do_append(ctx, conv, attrs, retries - 1),
              else: {:error, changeset}

          _other ->
            {:error, changeset}
        end
    end
  end

  # A conversation is named by its first user text; later renames are the
  # user's own (`update/3`).
  defp title_after(%Conversation{title: @default_title}, %Message{
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

  defp title_after(%Conversation{title: title}, _msg), do: title

  @doc "Replace a message's content/payload (the runner finalising a streamed turn)."
  @spec update_message(Context.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, :not_found | :database_error | Ecto.Changeset.t()}
  def update_message(%Context{} = ctx, id, attrs) when is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.update_message", fn ->
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
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.resolve_approval", fn ->
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
  Conversations that were mid-turn when the server last stopped: rows with an
  `execution_id`. Unscoped by design — the runner supervisor walks every
  athanor at boot and reconciles each inside its own context.
  """
  @spec with_running_turn() :: [Conversation.t()]
  def with_running_turn do
    # Fail-open default: boot recovery over an unreadable store recovers nothing now; the next boot retries.
    Arca.Repo.Errors.with_db_rescue("ConversationStorage.with_running_turn", [], fn ->
      # arca:unscoped-ok boot recovery walks every athanor's mid-turn rows;
      # each conversation is then reconciled inside its own athanor's context.
      Repo.all(from(c in Conversation, where: not is_nil(c.execution_id)))
    end)
  end

  @doc """
  Delete the athanor's conversations whose last activity is older than
  `cutoff` — messages and attachment blobs included. The context is the
  athanor's (retention walks each with an internal context).
  """
  @spec delete_before(Context.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_before(%Context{} = ctx, %DateTime{} = cutoff) do
    Arca.Repo.Errors.with_db_rescue("Arca.ConversationStorage.delete_before", fn ->
      delete_before_rows(ctx, cutoff)
    end)
  end

  defp delete_before_rows(ctx, cutoff) do
    ids = Repo.all(from(c in stale_before(ctx, cutoff), select: c.id))

    # Bytes before rows, per conversation: an id whose blob delete fails
    # keeps its rows and retries next cycle — never an orphaned tree the
    # DB has already forgotten.
    deletable =
      Enum.filter(ids, fn id ->
        case delete_blobs(ctx, id) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("[ConversationStorage] keeping #{id} this cycle: #{inspect(reason)}")

            false
        end
      end)

    if deletable == [] do
      {:ok, 0}
    else
      # One transaction, like `do_delete/2`: a crash between the two
      # deletes otherwise left an empty conversation row behind. The
      # satellites (follows, conversation-scope grants) sweep with the
      # rows, same as a hand delete.
      {:ok, count} =
        Repo.transaction(fn ->
          Repo.delete_all(from(m in Message, where: m.conversation_id in ^deletable))
          delete_conversation_satellites(deletable)

          {count, _} =
            from(c in Conversation, where: c.id in ^deletable)
            |> QueryHelpers.where_tenant(ctx)
            |> Repo.delete_all()

          count
        end)

      {:ok, count}
    end
  end

  # The retention window both verbs speak, scoped the one way this module
  # scopes: the athanor's conversations whose last activity is older than
  # `cutoff`, a conversation with a running turn never among them.
  defp stale_before(ctx, cutoff) do
    from(c in Conversation,
      where: is_nil(c.execution_id) and coalesce(c.last_message_at, c.inserted_at) < ^cutoff
    )
    |> QueryHelpers.where_tenant(ctx)
  end

  @doc """
  How many conversations `delete_before/2` would remove — the dry-run
  count, sharing its rule: a conversation with a running turn is never
  touched.
  """
  @spec count_before(Context.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_before(%Context{} = ctx, %DateTime{} = cutoff) do
    Arca.Repo.Errors.with_db_rescue("Arca.ConversationStorage.count_before", fn ->
      {:ok, Repo.aggregate(stale_before(ctx, cutoff), :count)}
    end)
  end

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  defp encode_history(%{history: history} = attrs) when is_list(history),
    do: %{attrs | history: Jason.encode!(history)}

  defp encode_history(attrs), do: attrs

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value
  defp encode_json(value), do: Jason.encode!(value)

  defp decode_map(json) do
    case Cyfr.Json.decode_or(json, %{}, "Arca.ConversationStorage.decode_map") do
      %{} = map -> map
      _ -> %{}
    end
  end
end
