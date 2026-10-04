# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.InstanceEntryChanged do
  @moduledoc """
  An instance entry changed, on the global
  `Cyfr.Bus.instance_entries/0`: the platform administrator's cards and
  every person's vault page read what they show again. The kind is the
  durable change `Sanctum.InstanceEntries` announced; `entry_id` names
  the entry and nothing else travels: no name, provider, destination,
  audience, component, digest or value. A page reads the entry again
  through the operations, under its own context, and learns only what
  that context may.
  """

  alias Cyfr.Bus.Payload

  @kinds [:created, :rotated, :rebound, :audience, :policy, :caps, :revoked, :deleted]

  @enforce_keys [:kind, :entry_id]
  defstruct [:kind, :entry_id]

  @type kind ::
          :created | :rotated | :rebound | :audience | :policy | :caps | :revoked | :deleted

  @type t :: %__MODULE__{kind: kind(), entry_id: String.t()}

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The change `kind` of the entry `entry_id`. A kind outside `kinds/0`, or
  an entry id that is not a non-empty string, raises.
  """
  @spec new(kind(), String.t()) :: t()
  def new(kind, entry_id) when is_binary(entry_id) and entry_id != "",
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, kind, @kinds), entry_id: entry_id}

  def new(_kind, entry_id) do
    raise ArgumentError,
          "an instance entry change names its entry, got #{Prima.LoggerContext.shape(entry_id)}"
  end
end
