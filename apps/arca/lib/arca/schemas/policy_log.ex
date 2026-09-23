# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.PolicyLog do
  @moduledoc """
  One policy consultation log row. The facade is `Arca.PolicyLog`.

  Stores complete policy consultation records including policy snapshots
  and decision reasons.

  ## Schema

  - `id` (PK) - Auto-generated ID
  - `request_id` - MCP request ID for correlation
  - `execution_id` - Execution ID if triggered by an execution
  - `user_id` - User whose policy was consulted
  - `timestamp` - When the consultation occurred
  - `event_type` - policy_consultation/denied/violation
  - `component_ref` - Component being evaluated
  - `component_type` - catalyst/reagent/formula
  - `decision` - allowed/denied/default
  - `host_policy_snapshot` - JSON-encoded policy snapshot
  - `decision_reason` - Reason for the policy decision
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "policy_logs" do
    field :request_id, :string
    field :execution_id, :string
    field :user_id, :string
    field :athanor_id, :string
    field :timestamp, :utc_datetime_usec
    field :event_type, :string
    field :component_ref, :string
    field :component_type, :string
    field :decision, :string
    field :host_policy_snapshot, :string
    field :decision_reason, :string
    field :consent_id, :string
    field :activation_digest, :string
    field :dep_ref, :string
    field :need, :string
    field :cursor_state, :string
    field :chain, :string
    field :value_source, :string
  end

  @required_fields [:id, :user_id, :athanor_id, :timestamp, :event_type]
  @optional_fields [
    :request_id,
    :execution_id,
    :component_ref,
    :component_type,
    :decision,
    :host_policy_snapshot,
    :decision_reason,
    :consent_id,
    :activation_digest,
    :dep_ref,
    :need,
    :cursor_state,
    :chain,
    :value_source
  ]

  @doc """
  Creates a changeset for inserting a new policy log entry.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
