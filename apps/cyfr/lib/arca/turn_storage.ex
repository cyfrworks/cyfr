# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorage do
  @moduledoc """
  The `turns` rows: accepted work in a conversation and how it ended.

  Keyed by the execution running the turn once accepted, which is what
  every runner path holds when the turn ends. A write that fails is
  reported, never raised: the turn's bookkeeping must not take the turn
  down with it.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Turn
  alias Sanctum.Context

  @statuses ["accepted", "completed", "failed", "cancelled"]

  @doc """
  Record a turn the runner accepted, for the execution now running it. The
  conversation must be the athanor's own — refused here by name, and held
  by the table's composite key besides.
  """
  @spec accept(Context.t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def accept(%Context{} = ctx, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accept", fn ->
      now = DateTime.utc_now()
      athanor_id = Context.athanor!(ctx)
      conversation_id = Map.fetch!(attrs, :conversation_id)

      conversation =
        Arca.Repo.get_by(Arca.Schemas.Conversation, id: conversation_id, athanor_id: athanor_id)

      if is_nil(conversation), do: throw(:conversation_not_found)

      %Turn{}
      |> Ecto.Changeset.change(%{
        id: Cyfr.UUID7.generate_id("trn"),
        athanor_id: athanor_id,
        conversation_id: conversation_id,
        execution_id: Map.get(attrs, :execution_id),
        orchestrator: Map.get(attrs, :orchestrator),
        requested_by: Map.get(attrs, :requested_by),
        status: "accepted",
        accepted_at: now
      })
      |> Arca.Repo.insert()
    end)
  catch
    :conversation_not_found -> {:error, :conversation_not_found}
  end

  @doc """
  Close the accepted turn `execution_id` runs as `status` — completed,
  failed or cancelled — with the error, if any. A turn already closed, or
  one this athanor never accepted, is left as it is.
  """
  @spec close(Context.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def close(%Context{} = ctx, execution_id, status, error \\ nil)
      when is_binary(execution_id) and status in @statuses do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.close", fn ->
      athanor_id = Context.athanor!(ctx)

      {count, _} =
        Arca.Repo.update_all(
          from(t in Turn,
            where:
              t.athanor_id == ^athanor_id and t.execution_id == ^execution_id and
                t.status == "accepted"
          ),
          set: [status: status, error: error, ended_at: DateTime.utc_now()]
        )

      {:ok, count}
    end)
  end

  @doc "The turns of a conversation, newest first."
  @spec list(Context.t(), String.t(), keyword()) :: {:ok, [Turn.t()]} | {:error, term()}
  def list(%Context{} = ctx, conversation_id, opts \\ []) when is_binary(conversation_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.list", fn ->
      athanor_id = Context.athanor!(ctx)
      limit = opts |> Keyword.get(:limit, 50) |> min(500) |> max(1)

      {:ok,
       Arca.Repo.all(
         from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.conversation_id == ^conversation_id,
           order_by: [desc: t.accepted_at],
           limit: ^limit
         )
       )}
    end)
  end
end
