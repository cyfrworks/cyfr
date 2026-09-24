# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Execution do
  @moduledoc """
  One execution record: the complete lifecycle of a run, including its
  input and output payloads, WASI traces and host policy snapshot. Owned
  by the athanor. The facade is `Arca.Execution`.

  - `id` - Execution ID (exec_<uuid7>)
  - `request_id` - MCP request ID (req_<uuid7>) for cross-entity correlation
  - `reference` - JSON-encoded component reference
  - `input_hash` - SHA256 hash of input JSON (for deduplication)
  - `user_id` - User who initiated the execution
  - `component_type` - catalyst, reagent, or formula
  - `component_digest` - SHA256 digest of the WASM component
  - `started_at` - When execution started
  - `completed_at` - When execution finished (nil if running)
  - `duration_ms` - Execution duration in milliseconds
  - `status` - running, completed, failed, or cancelled
  - `error_message` - Error message if failed
  - `input` - JSON-encoded execution input
  - `output` - JSON-encoded execution output
  - `host_policy` - JSON-encoded host policy snapshot
  """

  use Ecto.Schema
  import Ecto.Changeset

  # The execution lifecycle vocabulary, in one place like its sibling
  # stores. A row starts "running" and ends in exactly one of the
  # terminal three.
  @statuses ~w(running paused completed failed cancelled)
  # What a row is: a component run, a host loop's logical turn root, or an
  # outbound tool call.
  @kinds ~w(component turn tool_call)
  @terminal_statuses ~w(completed failed cancelled)

  @type t :: %__MODULE__{}

  @doc "Every status an execution row can carry."
  def statuses, do: @statuses

  @doc "The statuses a finished execution can carry."
  def terminal_statuses, do: @terminal_statuses

  @doc "Every kind an execution row can carry."
  def kinds, do: @kinds

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "executions" do
    field :reference, :string
    field :input_hash, :string
    field :user_id, :string
    field :athanor_id, :string
    field :request_id, :string
    field :component_type, :string
    field :component_digest, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :status, :string, default: "running"
    field :error_message, :string
    field :input, :string
    field :output, :string
    field :host_policy, :string
    field :parent_execution_id, :string
    # The key the parent's runner minted for this child (`Prima.HostAPI`
    # `t:child_key/0`): unique under the parent, so a retried admission is
    # answered with this row (`child_by_key/3`). Nil for a root.
    field :child_key, :string
    field :root_execution_id, :string
    field :resolver_digest, :string
    field :activation_digest, :string
    field :activation_graph, :string
    # Which consent this execution rooted under: stamped by every root —
    # `run_root/5` and a `run_root_edge/5` tincture ingress alike — and nil
    # for a child row, which walks its parent's authority rather than
    # rooting one. The row is the SSOT: a caller that needs the turn's
    # authority again — an approval, an audit — reads it here instead of
    # re-deriving a selection that may since have become ambiguous.
    field :profile_id, :string
    # What the row is: a `component` run, the logical `turn` root a host
    # loop holds without a guest, or an outbound `tool_call`. A turn root's
    # `component_type` is `agent`.
    field :kind, :string, default: "component"
    # The turn or schedule this execution belongs to.
    field :turn_id, :string
    field :schedule_id, :string
    # The attempt that owns the row (`Arca.ExecutionAttempts`): every
    # attempt-scoped write names it, and a successor moves it in the same
    # transaction that retires the predecessor.
    field :current_attempt, :string
    # The durable event counter: `Arca.ExecutionEvents` allocates a seq by
    # incrementing it inside the writer's transaction.
    field :event_seq, :integer, default: 0
  end

  # Every column a start writes — the write path's half of the row shape,
  # exposed so the engine's record layer can pin its attrs against it.
  @start_fields [
    :id,
    :reference,
    :input_hash,
    :user_id,
    :athanor_id,
    :request_id,
    :component_type,
    :component_digest,
    :started_at,
    :status,
    :input,
    :host_policy,
    :parent_execution_id,
    :child_key,
    :root_execution_id,
    :resolver_digest,
    :activation_digest,
    :activation_graph,
    :profile_id,
    :kind,
    :turn_id,
    :schedule_id,
    :current_attempt,
    :event_seq
  ]

  @doc "The columns `start_changeset/1` casts, for the write path to pin against."
  def start_fields, do: @start_fields

  @doc """
  Creates a changeset for inserting a new execution record when starting.
  """
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @start_fields)
    |> validate_required([
      :id,
      :reference,
      :user_id,
      :athanor_id,
      :started_at,
      :status,
      :component_type
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_component_type()
    |> validate_child_key()
  end

  # A child key is the wire's shape and belongs to a child: a root carries
  # none. The unique index decides the race between two admissions of one
  # key; `Arca.Execution` names its loss.
  defp validate_child_key(changeset) do
    case get_field(changeset, :child_key) do
      nil ->
        changeset

      key ->
        changeset
        |> validate_change(:child_key, fn :child_key, _key ->
          if Prima.HostAPI.valid_child_key?(key), do: [], else: [child_key: "is malformed"]
        end)
        |> validate_required([:parent_execution_id])
        |> unique_constraint(:child_key,
          name: :executions_athanor_id_parent_execution_id_child_key_index
        )
    end
  end

  # Which component types exist is product vocabulary — sourced from the
  # canonical list rather than re-declared in the persistence layer.
  # Tinctures never execute server-side, hence executable_types. A turn
  # root is an `agent` (a consent source, never a component) and an
  # outbound tool call a `tool_server`; both are row-level types.
  defp validate_component_type(changeset) do
    case get_field(changeset, :kind) do
      "turn" -> validate_inclusion(changeset, :component_type, ["agent"])
      "tool_call" -> validate_inclusion(changeset, :component_type, ["tool_server"])
      _ -> validate_inclusion(changeset, :component_type, Prima.ComponentRef.executable_types())
    end
  end

  @doc """
  Creates a changeset for completing an execution.
  """
  def complete_changeset(execution, attrs) do
    execution
    |> cast(attrs, [:completed_at, :duration_ms, :status, :error_message, :output])
    |> validate_required([:completed_at, :duration_ms, :status])
    |> validate_inclusion(:status, @terminal_statuses)
  end
end
