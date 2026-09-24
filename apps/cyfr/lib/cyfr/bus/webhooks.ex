# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Webhooks do
  @moduledoc """
  The athanor's webhook rows changed, on `Cyfr.Bus.webhooks/1`. Readers
  re-read them.
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
