# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.VaultEntry do
  @moduledoc """
  A vault entry as a committed write left it, on the athanor's
  `Cyfr.Bus.vault_entries/1`, for the stream a canvas reads
  (`vault.changes`): `changed` with its `name`, its `type` (the entry's
  credential kind) and its `status` (`fine` or `needs_reauthorisation`),
  or `removed` with its `name` once a delete, a revoke or a rename takes
  that name away. Never a value, a field name, a destination or a last
  use. `Cyfr.Bus.VaultEntryChanged` is the console's verb-by-verb signal
  of the same writes.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed, :removed]
  @fields [:name, :type, :status]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :changed | :removed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          name: String.t() | nil,
          type: String.t() | nil,
          status: String.t() | nil
        }

  @doc "The closed union of what this payload says happened: the entry stands as it reads, or its name is gone."
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
