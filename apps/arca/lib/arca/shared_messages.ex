# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedMessages do
  @moduledoc """
  The messages of a shared thread (`Arca.Schemas.SharedMessage`): what
  its people say, in `seq` order, dense from 1. Each carries its author,
  its text and a payload map, stored as JSON: the attachments' refs and
  the provenance of a line said aloud. Who may post and read is
  `Sanctum.SharedThreads`'.

  ## The first argument

  Every function matches `scope: :platform` and refuses any other actor
  with `{:error, :cross_tenant}`: a shared thread is no athanor's.

  ## Appending

  `append/3` runs under this member's slot (`Arca.Repo.owned/2`;
  `:not_owner` once another member holds it) and takes the next `seq`
  after the thread's last. The baseline's unique `(thread_id, seq)` index
  lets one of two appenders that read the same last `seq` write the next:
  the loser's insert writes nothing, and it reads the last `seq` again and
  takes the one after. The thread's `last_message_at` is then set only
  while it is active, under its row lock, so a message never lands in a
  thread an archive committed first.

  A row crosses as a plain map (`Arca.Data`), its payload decoded. A
  refusal is `:not_found`, `:archived`, `{:invalid, %{field => [message]}}`,
  `:cross_tenant`, `:not_owner` or `:database_error`.
  """

  import Ecto.Query

  alias Arca.Schemas.{SharedMessage, SharedThread}

  @typedoc "A message, as a plain map with its payload decoded."
  @type row :: map()

  @max_page 500

  @doc "The ceiling on one page of messages, which is also its default."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  @doc """
  Append a message to the thread: `attrs` names its `:author`, a person,
  and optionally its `:content` (default `""`) and `:payload`, a map.
  """
  @spec append(Prima.Actor.t(), String.t(), map()) ::
          {:ok, row()}
          | {:error, :not_found | :archived | {:invalid, map()}}
          | {:error, :cross_tenant | :not_owner | :database_error}
  # arca:unscoped-ok a shared thread is no athanor's; its messages are written by its id.
  def append(%Prima.Actor{scope: :platform}, thread_id, attrs)
      when is_binary(thread_id) and is_map(attrs) do
    with {:ok, fields} <- fields(attrs) do
      Arca.Repo.owned("Arca.SharedMessages.append", fn ->
        case Arca.Repo.get(SharedThread, thread_id) do
          nil -> {:error, :not_found}
          %SharedThread{status: "archived"} -> {:error, :archived}
          %SharedThread{} -> write(thread_id, fields, Arca.ServerMetaStorage.now!())
        end
      end)
      |> decoded()
    end
  end

  def append(%Prima.Actor{}, _thread_id, _attrs), do: {:error, :cross_tenant}

  # arca:unscoped-ok a shared thread is no athanor's; its message is written by its id.
  defp write(thread_id, fields, now) do
    id = Prima.UUID7.generate_id("shm")
    last = from(m in SharedMessage, where: m.thread_id == ^thread_id, select: max(m.seq))
    row = Map.merge(fields, %{id: id, thread_id: thread_id, inserted_at: now})

    case Arca.Repo.insert_all(SharedMessage, [Map.put(row, :seq, (Arca.Repo.one(last) || 0) + 1)],
           on_conflict: :nothing,
           conflict_target: [:thread_id, :seq]
         ) do
      {1, _} -> touch(thread_id, id, now)
      {0, _} -> write(thread_id, fields, now)
    end
  end

  # arca:unscoped-ok a shared thread is no athanor's; it is touched by its id.
  defp touch(thread_id, id, now) do
    case Arca.Repo.update_all(
           from(t in SharedThread, where: t.id == ^thread_id and t.status == "active"),
           set: [last_message_at: now]
         ) do
      {1, _} -> {:ok, Arca.Repo.get!(SharedMessage, id)}
      {0, _} -> {:error, :archived}
    end
  end

  @doc """
  The thread's messages, oldest first: those after `after_seq:` (default
  0), at most `limit:` of them (default and ceiling `max_page/0`).
  """
  @spec list(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  def list(actor, thread_id, opts \\ [])

  # arca:unscoped-ok a shared thread is no athanor's; its messages are read by its id.
  def list(%Prima.Actor{scope: :platform}, thread_id, opts)
      when is_binary(thread_id) and is_list(opts) do
    opts = Keyword.validate!(opts, after_seq: 0, limit: @max_page)
    after_seq = Keyword.fetch!(opts, :after_seq)
    limit = opts |> Keyword.fetch!(:limit) |> min(@max_page)

    Arca.Repo.Errors.with_db_rescue("Arca.SharedMessages.list", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in SharedMessage,
           where: m.thread_id == ^thread_id and m.seq > ^after_seq,
           order_by: [asc: m.seq],
           limit: ^limit
         )
       )}
    end)
    |> decoded()
  end

  def list(%Prima.Actor{}, _thread_id, _opts), do: {:error, :cross_tenant}

  defp fields(attrs) do
    author = attrs[:author]
    content = Map.get(attrs, :content, "")
    payload = attrs[:payload]

    encoded =
      case payload do
        nil -> {:ok, nil}
        %{} -> Jason.encode(payload)
        _other -> :error
      end

    errors =
      [
        {:author, Prima.PersonId.person?(author)},
        {:content, is_binary(content)},
        {:payload, match?({:ok, _}, encoded)}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required or malformed"]} end)

    if errors == %{} do
      {:ok, json} = encoded
      {:ok, %{author: author, content: content, payload: json}}
    else
      {:error, {:invalid, errors}}
    end
  end

  defp decoded({:ok, rows}) when is_list(rows), do: {:ok, Enum.map(rows, &decode/1)}
  defp decoded({:ok, %{} = row}), do: {:ok, decode(row)}
  defp decoded(error), do: error

  defp decode(%SharedMessage{} = row), do: row |> Arca.Data.project() |> decode()

  defp decode(%{payload: json} = row) do
    case Prima.Json.decode_stored(json, %{}) do
      {:ok, %{} = payload} -> %{row | payload: payload}
      _not_a_map -> %{row | payload: %{}}
    end
  end
end
