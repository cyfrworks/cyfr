# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.VaultEntryChanged do
  @moduledoc """
  A vault entry changed, on the athanor's `Cyfr.Bus.vault_changed/1` and
  on the server-wide `Cyfr.Bus.vault_changed_global/0`. The kind is the
  verb. `name` names the entry for every verb, since a deleted row can no
  longer be read for it, and `old_name` the name a rename vacated, which
  is what a live server's header template still spells. No material
  travels.
  """

  alias Cyfr.Bus.Payload

  @kinds [:create, :rename, :rotate, :rebind, :revoke, :delete]
  @fields [:entry_id, :name, :old_name]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :create | :rename | :rotate | :rebind | :revoke | :delete

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          entry_id: String.t() | nil,
          name: String.t() | nil,
          old_name: String.t() | nil
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
