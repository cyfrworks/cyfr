# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.McpServers do
  @moduledoc """
  The athanor's external MCP servers changed, on `Cyfr.Bus.mcp_servers/1`:
  a row written, or a live server's tool list moved. Readers re-read
  them; an MCP listener tells its client `tools/list_changed`.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed]
  @fields []

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :changed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind()
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Cyfr.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Cyfr.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
