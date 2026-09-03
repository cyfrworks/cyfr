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
      scope = Map.fetch!(attrs, :scope)

      row =
        attrs
        |> Map.put_new(:id, Cyfr.UUID7.generate_id("grant"))
        |> Map.put_new(:granted_at, DateTime.utc_now())

      :ok = delete_matching(row)

      # The constraint is still declared: `delete_matching/1` and the
      # insert are two statements, so a concurrent writer can land between
      # them. Declaring it turns that race into a typed refusal instead of
      # an `Ecto.ConstraintError` raised past the db-error rescue.
      %ToolGrant{}
      |> Ecto.Changeset.change(row)
      |> Ecto.Changeset.unique_constraint(conflict_columns(scope), name: conflict_index(scope))
      |> Arca.Repo.insert()
    end)
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
  @spec list_for_conversation(String.t(), String.t()) :: [ToolGrant.t()]
  def list_for_conversation(athanor_id, conversation_id)
      when is_binary(athanor_id) and is_binary(conversation_id) do
    # Deliberate default: a policy read that cannot reach the store answers
    # "no standing grants", so the agent ASKS. Failing open here would mean
    # an outage silently auto-approving.
    Arca.Repo.Errors.with_db_rescue("Arca.ToolGrantStorage.list_for_conversation", [], fn ->
      from(g in ToolGrant,
        where:
          g.athanor_id == ^athanor_id and
            (g.scope == "agent" or g.conversation_id == ^conversation_id),
        order_by: [asc: g.granted_at, asc: g.id]
      )
      |> Arca.Repo.all()
    end)
  end

  @doc """
  One agent's agent-scope decisions, read from the athanor that OWNS the
  agent.

  `athanor_id` here is the agent's owner — an agent-scope row is only ever
  written while owner == focus (`Aqua.ToolGrants.authorize_scope/3`), so
  the owner's estate is where those rows live. This is a deliberate
  cross-estate read: a turn running a borrowed agent in another estate
  reads the standing answers from the agent's home, which is what makes
  "always"/"never" follow the agent rather than evaporate at the border.
  Fails closed like `list_for_conversation/2` — no reachable store, no
  standing answers, the agent asks.
  """
  @spec list_agent_scope(String.t(), String.t()) :: [ToolGrant.t()]
  def list_agent_scope(athanor_id, agent_name)
      when is_binary(athanor_id) and is_binary(agent_name) do
    Arca.Repo.Errors.with_db_rescue("Arca.ToolGrantStorage.list_agent_scope", [], fn ->
      from(g in ToolGrant,
        where:
          g.athanor_id == ^athanor_id and g.scope == "agent" and
            g.agent_athanor_id == ^athanor_id and g.agent_name == ^agent_name,
        order_by: [asc: g.granted_at, asc: g.id]
      )
      |> Arca.Repo.all()
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp conflict_columns("conversation"),
    do: [:conversation_id, :agent_athanor_id, :agent_name, :tool, :action]

  defp conflict_columns("agent"), do: [:agent_athanor_id, :agent_name, :tool, :action]

  defp conflict_index("conversation"), do: :tool_grants_conversation_scope_index
  defp conflict_index("agent"), do: :tool_grants_agent_scope_index

  # The scope's own key, spelled as a query — WITH the tenant, so a delete
  # is bounded by the owning athanor exactly as the module claims every
  # write is. The unique keys alone happen to be globally identifying
  # today; the tenant predicate is what keeps that an implementation
  # detail rather than a load-bearing accident.
  defp delete_matching(%{scope: "agent"} = attrs) do
    from(g in ToolGrant,
      where:
        g.athanor_id == ^attrs.athanor_id and
          g.scope == "agent" and
          g.agent_athanor_id == ^attrs.agent_athanor_id and
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
          g.scope == "conversation" and
          g.conversation_id == ^attrs.conversation_id and
          g.agent_athanor_id == ^attrs.agent_athanor_id and
          g.agent_name == ^attrs.agent_name and
          g.tool == ^attrs.tool and g.action == ^attrs.action
    )
    |> Arca.Repo.delete_all()

    :ok
  end
end
