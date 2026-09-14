# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ToolGrant do
  @moduledoc """
  A standing decision a person made about one `tool.action` for one agent
  of the estate the row belongs to.

  Distinct from the agent's markdown `tool_policy`, which is **authored**
  policy — what the agent's author says it may do. A grant is what a human
  answered when asked, and the two are composed at use time by
  `Aqua.ToolGrants.effective/2`.

  `scope` says how far the answer reaches: `"thread"` — this thread
  only, surviving a runner restart — or `"agent"` — every thread
  this agent runs in, in this estate. An agent belongs to the estate whose
  `aqua/` tree holds it, so the row's `athanor_id` is the agent's estate
  as well as the tenancy that reclaims the row.

  `effect` is `"allow"` or `"deny"`; deny is where the decline verb
  ("never ask me this again") lives, and it beats an authored `"auto"`.
  The vocabulary is spelled here, once, and validated at the write.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @scopes ~w(thread agent)
  @effects ~w(allow deny)

  schema "tool_grants" do
    field :athanor_id, :string
    field :scope, :string
    field :effect, :string
    field :thread_id, :string
    field :agent_name, :string
    field :tool, :string
    field :action, :string
    field :granted_by, :string
    field :granted_at, :utc_datetime_usec
  end

  @doc "The scopes a grant may carry."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "The effects a grant may carry."
  @spec effects() :: [String.t()]
  def effects, do: @effects

  @doc "The scope of an answer for one thread."
  @spec thread_scope() :: String.t()
  def thread_scope, do: "thread"

  @doc "The scope of an answer for the agent wherever it runs in its estate."
  @spec agent_scope() :: String.t()
  def agent_scope, do: "agent"

  @doc """
  The row a write is held to: every key present, the scope and effect in
  the vocabulary, and a thread named exactly when the scope is a
  thread's. The partial unique indexes are declared by the storage
  module, which knows the names each adapter reports them by.
  """
  @spec changeset(t() | map(), map()) :: Ecto.Changeset.t()
  def changeset(grant \\ %__MODULE__{}, attrs) do
    grant
    |> cast(attrs, [
      :id,
      :athanor_id,
      :scope,
      :effect,
      :thread_id,
      :agent_name,
      :tool,
      :action,
      :granted_by,
      :granted_at
    ])
    |> validate_required([
      :id,
      :athanor_id,
      :scope,
      :effect,
      :agent_name,
      :tool,
      :action,
      :granted_at
    ])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:effect, @effects)
    |> validate_thread()
  end

  defp validate_thread(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :thread_id)} do
      {"thread", nil} ->
        add_error(changeset, :thread_id, "names no thread")

      {"agent", id} when is_binary(id) ->
        add_error(changeset, :thread_id, "an agent-scope answer names no thread")

      _ ->
        changeset
    end
  end
end
