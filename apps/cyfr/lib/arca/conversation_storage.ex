# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConversationStorage do
  @moduledoc """
  Persistence for the athanor's conversations and their messages — the
  durable record every member reads (`Prism.ConversationRunner` writes it,
  `PrismWeb.ConversationLive` shows it).

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

  alias Arca.QueryHelpers
  alias Arca.Repo
  alias Arca.Schemas.Conversation
  alias Arca.Schemas.Message
  alias Sanctum.Context

  @default_title "New conversation"
  @title_max 80

  # ---------------------------------------------------------------------------
  # Conversations
  # ---------------------------------------------------------------------------

  @doc "The athanor's conversations, most recently active first."
  @spec list(Context.t(), keyword()) :: [Conversation.t()]
  def list(%Context{} = ctx, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(c in Conversation,
      order_by: [desc: coalesce(c.last_message_at, c.inserted_at)],
      limit: ^limit
    )
    |> QueryHelpers.where_tenant(ctx)
    |> Repo.all()
  end

  @doc "One conversation of the context's athanor."
  @spec get(Context.t(), String.t()) :: {:ok, Conversation.t()} | {:error, :not_found}
  def get(%Context{} = ctx, id) when is_binary(id) do
    from(c in Conversation, where: c.id == ^id)
    |> QueryHelpers.where_tenant(ctx)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      conv -> {:ok, conv}
    end
  end

  @doc "Open a new conversation in the context's athanor, attributed to its user."
  @spec create(Context.t(), map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create(%Context{} = ctx, attrs \\ %{}) do
    Context.require_tenant!(ctx)

    %Conversation{}
    |> Conversation.changeset(%{
      id: attrs[:id] || Emissary.UUID7.generate_id("conv"),
      athanor_id: ctx.athanor_id,
      title: attrs[:title] || @default_title,
      created_by: ctx.user_id || "system"
    })
    |> Repo.insert()
  end

  @doc "Update a conversation's title, history or running execution."
  @spec update(Context.t(), String.t(), map()) ::
          {:ok, Conversation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(%Context{} = ctx, id, attrs) when is_binary(id) and is_map(attrs) do
    with {:ok, conv} <- get(ctx, id) do
      attrs =
        attrs
        |> Map.take([:title, :history, :execution_id, :last_message_at])
        |> encode_history()

      conv |> Conversation.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Delete a conversation and its messages."
  @spec delete(Context.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(%Context{} = ctx, id) when is_binary(id) do
    with {:ok, conv} <- get(ctx, id) do
      # Messages cascade through the FK; delete them explicitly as well so
      # SQLite files opened without foreign_keys=ON cannot leave orphans.
      Repo.transaction(fn ->
        Repo.delete_all(from(m in Message, where: m.conversation_id == ^conv.id))
        Repo.delete!(conv)
      end)

      :ok
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

  @doc "Every message of a conversation, oldest first."
  @spec messages(Context.t(), String.t()) :: [Message.t()]
  def messages(%Context{} = ctx, conversation_id) when is_binary(conversation_id) do
    from(m in Message, where: m.conversation_id == ^conversation_id, order_by: [asc: m.seq])
    |> QueryHelpers.where_tenant(ctx)
    |> Repo.all()
  end

  @doc "One message of the context's athanor."
  @spec get_message(Context.t(), String.t()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message(%Context{} = ctx, id) when is_binary(id) do
    from(m in Message, where: m.id == ^id)
    |> QueryHelpers.where_tenant(ctx)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      msg -> {:ok, msg}
    end
  end

  @doc "The approval rows of a conversation still waiting on a decision."
  @spec pending_approvals(Context.t(), String.t()) :: [Message.t()]
  def pending_approvals(%Context{} = ctx, conversation_id) when is_binary(conversation_id) do
    from(m in Message,
      where:
        m.conversation_id == ^conversation_id and m.kind == "approval" and
          m.status == "pending",
      order_by: [asc: m.seq]
    )
    |> QueryHelpers.where_tenant(ctx)
    |> Repo.all()
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
          {:ok, Message.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def append(%Context{} = ctx, conversation_id, attrs) when is_map(attrs) do
    with {:ok, conv} <- get(ctx, conversation_id) do
      do_append(ctx, conv, attrs, 3)
    end
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
            id: attrs[:id] || Emissary.UUID7.generate_id("msg"),
            conversation_id: conv.id,
            athanor_id: ctx.athanor_id,
            seq: seq,
            author: attrs[:author],
            kind: attrs[:kind] || "text",
            content: attrs[:content] || "",
            payload: encode_json(attrs[:payload]),
            status: attrs[:status],
            execution_id: attrs[:execution_id],
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
        if Keyword.has_key?(errors, :conversation_id),
          do: do_append(ctx, conv, attrs, retries - 1),
          else: {:error, changeset}
    end
  end

  # A conversation is named by its first user text; later renames are the
  # user's own (`update/3`).
  defp title_after(%Conversation{title: @default_title}, %Message{
         kind: "text",
         author: author,
         content: content
       })
       when author not in ["aqua", "system"] and is_binary(content) do
    case content |> String.trim() |> String.split("\n", parts: 2) |> List.first() do
      "" -> @default_title
      nil -> @default_title
      line -> String.slice(line, 0, @title_max)
    end
  end

  defp title_after(%Conversation{title: title}, _msg), do: title

  @doc "Replace a message's content/payload (the runner finalising a streamed turn)."
  @spec update_message(Context.t(), String.t(), map()) ::
          {:ok, Message.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_message(%Context{} = ctx, id, attrs) when is_binary(id) and is_map(attrs) do
    with {:ok, msg} <- get_message(ctx, id) do
      attrs =
        attrs
        |> Map.take([:content, :payload, :status, :execution_id])
        |> Map.update(:payload, nil, &encode_json/1)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      msg |> Message.changeset(attrs) |> Repo.update()
    end
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
          {:ok, Message.t()} | {:error, :not_found | :already_resolved}
  def resolve_approval(%Context{} = ctx, id, from, to, attrs \\ %{})
      when is_binary(id) and to in ~w(running approved declined error) do
    Context.require_tenant!(ctx)
    from = List.wrap(from)
    now = DateTime.utc_now()

    updates =
      [status: to, resolved_by: ctx.user_id || "system"]
      |> Keyword.merge(if(to == "running", do: [], else: [resolved_at: now]))
      |> Keyword.merge(
        case attrs[:resolution] do
          nil -> []
          resolution -> [resolution: encode_json(resolution)]
        end
      )

    {count, _} =
      from(m in Message,
        where:
          m.id == ^id and m.athanor_id == ^ctx.athanor_id and m.kind == "approval" and
            m.status in ^from
      )
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
    Repo.all(from(c in Conversation, where: not is_nil(c.execution_id)))
  end

  @doc "The distinct athanor ids that have conversations (retention walks them)."
  @spec distinct_athanors() :: [String.t()]
  def distinct_athanors do
    Repo.all(from(c in Conversation, select: c.athanor_id, distinct: true))
  end

  @doc """
  Delete an athanor's conversations whose last activity is older than
  `cutoff`, messages included. Requires `:athanor_id`.
  """
  @spec delete_before(DateTime.t(), keyword()) :: {non_neg_integer(), nil}
  def delete_before(%DateTime{} = cutoff, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    stale =
      from(c in Conversation,
        where:
          c.athanor_id == ^athanor_id and is_nil(c.execution_id) and
            coalesce(c.last_message_at, c.inserted_at) < ^cutoff,
        select: c.id
      )

    ids = Repo.all(stale)

    if ids == [] do
      {0, nil}
    else
      Repo.delete_all(from(m in Message, where: m.conversation_id in ^ids))
      Repo.delete_all(from(c in Conversation, where: c.id in ^ids))
    end
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
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end
end
