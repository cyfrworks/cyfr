# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Request do
  @moduledoc """
  One MCP request logged, on `Cyfr.Bus.requests/1`. The host's bridge
  builds it from the transport's request telemetry.
  """

  alias Cyfr.Bus.Payload

  @kinds [:logged]
  @fields [:request_id, :method, :tool, :action, :status, :duration_ms]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :logged

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          request_id: String.t() | nil,
          method: String.t() | nil,
          tool: String.t() | nil,
          action: String.t() | nil,
          status: atom() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
