# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StatusTransitions do
  @moduledoc """
  Which statuses a row may move to by a status write, and from which,
  one table per domain: the stored credentials' (`:credentials`), which
  `Arca.VaultStorage.set_status/3` and `Arca.InstanceEntries.set_status/3`
  hold their conditional writes to, and the profiles' (`:profiles`), which
  `Arca.ProfileStorage.transition/4` holds its write to. The domains share
  the word `active` and nothing else: each table answers only for its own
  rows.

  A credential is `revoked` from `active`, `needs_reauth` or `revoked`,
  and `needs_reauth` or `active` from `active` or `needs_reauth`. Nothing
  leaves `revoked` or `tombstoned` by a status write, so a delete or a
  revoke is never undone by a later mark; a tombstone is each store's own
  verb.

  A profile is `revoked` from any status, and blocked at `needs_consent`
  from `active` or `needs_consent`. It is `active` again only from
  `needs_consent`, by the revision that re-consents it. Nothing leaves
  `revoked`: a revoked profile keeps its history and a new one takes its
  identity. Writing the status a row already holds is admitted wherever
  the table lists it, so a retry finishes what an earlier attempt left.
  """

  @credentials %{
    "revoked" => ~w(active needs_reauth revoked),
    "needs_reauth" => ~w(active needs_reauth),
    "active" => ~w(active needs_reauth)
  }

  @profiles %{
    "revoked" => ~w(active needs_consent revoked),
    "needs_consent" => ~w(active needs_consent),
    "active" => ~w(needs_consent)
  }

  @statuses %{
    credentials: ~w(active needs_reauth revoked tombstoned),
    profiles: ~w(active needs_consent revoked)
  }

  @typedoc "Whose rows a table answers for."
  @type domain :: :credentials | :profiles

  @doc "Every status a row of `domain` can hold."
  @spec statuses(domain()) :: [String.t()]
  def statuses(domain), do: Map.fetch!(@statuses, domain)

  @doc """
  The statuses a row of `domain` may hold for a status write to move it
  to `status`; `:error` for a status no write moves to.
  """
  @spec from(domain(), term()) :: {:ok, [String.t()]} | :error
  def from(:credentials, status), do: Map.fetch(@credentials, status)
  def from(:profiles, status), do: Map.fetch(@profiles, status)
end
