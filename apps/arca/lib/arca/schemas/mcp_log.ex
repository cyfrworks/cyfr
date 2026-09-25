# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.McpLog do
  @moduledoc """
  One MCP request log row. The facade is `Arca.McpLog`.

  Stores the complete MCP request lifecycle including input/output payloads.

  ## Schema

  Every row is the projection of one admission decision
  (`Arca.DecisionLog`), written in the same transaction as the decision:
  its start when the call is decided, its completion when the admitted
  work ends.

  - `id` (PK) - This call: the decision's call id (`call_<uuid7>`).
  - `request_id` - The ingress request every call in one chain shares. Group by
    this to see a formula's whole run: the `execution.run` that started it and
    each tool it reached from inside the sandbox.
  - `user_id` - User who made the request
  - `timestamp` - When the request was received
  - `tool` - Tool name (e.g., "execution", "storage")
  - `action` - Action within tool (e.g., "run", "get")
  - `method` - MCP method (e.g., "tools/call")
  - `status` - pending/success/error
  - `duration_ms` - Request duration in milliseconds
  - `routed_to` - Service that handled the request
  - `error_code` - JSON-RPC error code if failed
  - `input` - JSON-encoded request input
  - `output` - JSON-encoded response output
  - `error` - Error message if failed
  - `refusal_class` - A refused call's class (`Prima.Refusal.classes/0`)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # The request-log status vocabulary, in one place like its sibling stores.
  @statuses ~w(pending success error)

  @doc "Every status a log row can carry."
  def statuses, do: @statuses

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "mcp_logs" do
    field :request_id, :string
    field :user_id, :string
    field :athanor_id, :string
    field :timestamp, :utc_datetime_usec
    field :tool, :string
    field :action, :string
    field :method, :string
    field :status, :string, default: "pending"
    field :duration_ms, :integer
    field :routed_to, :string
    field :error_code, :integer
    field :input, :string
    field :output, :string
    field :error, :string
    field :refusal_class, :string
  end

  @required_fields [:id, :user_id, :athanor_id, :timestamp, :status]
  @optional_fields [
    :request_id,
    :tool,
    :action,
    :method,
    :duration_ms,
    :routed_to,
    :error_code,
    :input,
    :output,
    :error,
    :refusal_class
  ]

  @doc """
  Creates a changeset for inserting a new MCP log entry.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end
end
