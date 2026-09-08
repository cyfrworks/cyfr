# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ToolGrantStorage do
  @moduledoc """
  Persistence mechanics for tool grants. The scope rules and the
  composition with declared policy live in `Aqua.ToolGrants`, which is the
  only caller. Every read and write is keyed by the owning athanor.
  """

  import Ecto.Query

  alias Arca.Schemas.ToolGrant

  @doc """
  Record a decision, replacing whatever the same key already said.

  Upsert rather than insert: a person flipping "always" to "never" is
  answering the same question again, not stacking a contradiction. The
  conflict target is the scope's own partial index — an agent-scope row
  carries no conversation, and a nullable column in a composite unique
  index constrains nothing.
  """
  @spec put(map()) :: {:ok, ToolGrant.t()} | {:error, term()}
  # arca:unscoped-ok the athanor arrives in attrs and its absence fails loudly below.
  def put(attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.ToolGrantStorage.put", fn ->
      _ = Map.fetch!(attrs, :athanor_id)

      row =
        attrs
        |> Map.put_new(:id, Cyfr.UUID7.generate_id("grant"))
        |> Map.put_new(:granted_at, DateTime.utc_now())

      # One transaction: the delete and the insert are two statements, and
      # a failed insert must not leave the key with no row at all — the
      # decision that stood before has to stand until the new one is
      # written. A concurrent writer landing between the two is a typed
      # refusal through the constraint below, never a raise.
      Arca.Repo.transaction(fn ->
        :ok = delete_matching(row)

        case Arca.Repo.insert(changeset(row)) do
          {:ok, stored} -> stored
          {:error, changeset} -> Arca.Repo.rollback(changeset)
        end
      end)
    end)
  end

  @doc false
  # The scope's partial unique index, declared under BOTH names an adapter
  # can report it by. Postgres reports the name the migration gave it —
  # short on purpose, because the default for the conversation-scope key
  # runs past the 63-byte identifier limit and would come back truncated.
  # SQLite cannot name a violated index at all and reports the columns,
  # from which `ecto_sqlite3` derives Ecto's default index name. One
  # declaration would match one adapter and raise on the other.
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(row) when is_map(row) do
    scope = Map.fetch!(row, :scope)
    columns = conflict_columns(scope)

    row
    |> ToolGrant.changeset()
    |> Ecto.Changeset.unique_constraint(columns, name: conflict_index(scope))
    |> Ecto.Changeset.unique_constraint(columns, name: column_index_name(columns))
  end

  @doc "Drop one decision, by its identifying key. Idempotent."
  @spec delete(map()) :: :ok | {:error, term()}
  # The athanor arrives in attrs; its absence fails loudly here, and
  # `delete_matching/1` keys every query on it.
  def delete(attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.ToolGrantStorage.delete", fn ->
      _ = Map.fetch!(attrs, :athanor_id)
      delete_matching(attrs)
    end)
  end

  @doc """
  Every grant that could bear on one conversation: this thread's
  conversation-scope rows and the agent-scope rows for the agents in play.

  Read whole and filtered in memory — a conversation has a handful of
  grants, and one indexed read beats a query per agent per turn.
  """
  @spec list_for_conversation(String.t(), String.t()) ::
          {:ok, [ToolGrant.t()]} | {:error, term()}
  def list_for_conversation(athanor_id, conversation_id)
      when is_binary(athanor_id) and is_binary(conversation_id) do
    # A read that cannot reach the store is an ERROR, never an empty list:
    # "no standing answers" would drop every deny and leave an authored
    # `auto` automatic, so an outage would widen what runs with no card.
    # The caller refuses the turn instead.
    Arca.Repo.Errors.with_db_rescue("Arca.ToolGrantStorage.list_for_conversation", fn ->
      {:ok,
       from(g in ToolGrant,
         where:
           g.athanor_id == ^athanor_id and
             (g.scope == ^ToolGrant.agent_scope() or g.conversation_id == ^conversation_id),
         order_by: [asc: g.granted_at, asc: g.id]
       )
       |> Arca.Repo.all()}
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp conflict_columns("conversation"), do: [:conversation_id, :agent_name, :tool, :action]
  defp conflict_columns("agent"), do: [:athanor_id, :agent_name, :tool, :action]

  defp conflict_index("conversation"), do: :tool_grants_conversation_scope_index
  defp conflict_index("agent"), do: :tool_grants_agent_scope_index

  # Ecto's default index name for these columns — what SQLite's adapter
  # reports a violation under whatever the index was actually called.
  defp column_index_name(columns), do: :"tool_grants_#{Enum.join(columns, "_")}_index"

  # The scope's own key, spelled as a query — WITH the tenant, so a delete
  # is bounded by the owning athanor exactly as the module claims every
  # write is; the conversation key happens to be globally identifying, and
  # the tenant predicate keeps that an implementation detail.
  defp delete_matching(%{scope: "agent"} = attrs) do
    from(g in ToolGrant,
      where:
        g.athanor_id == ^attrs.athanor_id and
          g.scope == ^ToolGrant.agent_scope() and
          g.agent_name == ^attrs.agent_name and
          g.tool == ^attrs.tool and g.action == ^attrs.action
    )
    |> Arca.Repo.delete_all()

    :ok
  end

  defp delete_matching(%{scope: "conversation"} = attrs) do
    from(g in ToolGrant,
      where:
        g.athanor_id == ^attrs.athanor_id and
          g.scope == ^ToolGrant.conversation_scope() and
          g.conversation_id == ^attrs.conversation_id and
          g.agent_name == ^attrs.agent_name and
          g.tool == ^attrs.tool and g.action == ^attrs.action
    )
    |> Arca.Repo.delete_all()

    :ok
  end
end
