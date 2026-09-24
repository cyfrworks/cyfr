# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Components do
  @moduledoc """
  The athanor's component registry changed, on `Cyfr.Bus.components/1`:
  a version installed or removed after its registration committed, one
  pushed to a registry, or the registry otherwise changed. Readers re-read
  the registry on any kind.
  """

  alias Cyfr.Bus.Payload

  @kinds [:installed, :removed, :pushed, :changed]
  @fields [:name, :version, :publisher, :component_type]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :installed | :removed | :pushed | :changed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          name: String.t() | nil,
          version: String.t() | nil,
          publisher: String.t() | nil,
          component_type: String.t() | nil
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
