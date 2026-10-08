# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StatusTransitions do
  @moduledoc """
  Which statuses a stored credential may move to by a status write, and
  from which: the one table `Arca.VaultStorage.set_status/3` and
  `Arca.InstanceEntries.set_status/3` hold their conditional writes to.

  `revoked` is reached from `active`, `needs_reauth` or `revoked`;
  `needs_reauth` and `active` from `active` or `needs_reauth`. Nothing
  leaves `revoked` or `tombstoned` by a status write, so a delete or a
  revoke is never undone by a later mark; a tombstone is each store's own
  verb.
  """

  @from %{
    "revoked" => ~w(active needs_reauth revoked),
    "needs_reauth" => ~w(active needs_reauth),
    "active" => ~w(active needs_reauth)
  }

  @doc "The statuses a row may hold for a status write to move it to `status`."
  @spec from(term()) :: {:ok, [String.t()]} | :error
  def from(status), do: Map.fetch(@from, status)
end
