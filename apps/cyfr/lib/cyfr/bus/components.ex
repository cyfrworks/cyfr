# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Components do
  @moduledoc """
  The athanor's component registry changed, on `Cyfr.Bus.components/1`:
  a version installed or removed after its registration committed, one
  pushed to a registry, or the registry otherwise changed. The console's
  readers re-read the registry on any kind. `installed`, `removed` and
  `pushed` name the version (`ref`, `type`, `name`, `version`); `icon`,
  `update_available` and `grant_current` are what the listing reads for
  a version, carried only where a reader of the listing built the
  payload (`components.changes`' refresh), and nil on the bridge's live
  events. `changed` names no version and asks a reader to read again.
  """

  alias Cyfr.Bus.Payload

  @kinds [:installed, :removed, :pushed, :changed]
  @fields [:ref, :type, :name, :icon, :version, :update_available, :grant_current]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :installed | :removed | :pushed | :changed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          ref: String.t() | nil,
          type: String.t() | nil,
          name: String.t() | nil,
          icon: String.t() | nil,
          version: String.t() | nil,
          update_available: boolean() | nil,
          grant_current: boolean() | nil
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
