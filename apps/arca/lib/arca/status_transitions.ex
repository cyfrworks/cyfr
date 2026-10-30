# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StatusTransitions do
  @moduledoc """
  Which statuses a row may move to by a status write, and from which,
  one table per domain: the stored credentials' (`:credentials`), which
  `Arca.VaultStorage.set_status/3` and `Arca.InstanceEntries.set_status/3`
  hold their conditional writes to, the profiles' (`:profiles`), which
  `Arca.ProfileStorage.transition/4` holds its write to, and the shares'
  (`:shares`), which `Arca.Shares` holds its revocations to. The domains
  share the words `active` and `revoked` and nothing else: each table
  answers only for its own rows.

  A credential is `revoked` from `active`, `needs_reauth` or `revoked`,
  and `needs_reauth` or `active` from `active` or `needs_reauth`. Nothing
  leaves `revoked` or `tombstoned` by a status write, so a delete or a
  revoke is never undone by a later mark; a tombstone is each store's own
  verb.

  A profile is `revoked` from any status, and blocked at `needs_consent`
  from `active` or `needs_consent`. It is `active` again only from
  `needs_consent`, by the revision that re-consents it. Nothing leaves
  `revoked`: a revoked profile keeps its history and a new one takes its
  identity. A profile already `needs_consent` or `revoked` may be written
  so again, so a retry finishes what an earlier attempt left; an `active`
  one may not, since `active` comes only by re-consent.

  A share is `revoked` from `active` or `revoked`, and nothing moves one
  to `active`: a share is born active and never made so again, so a
  revoked entry is shared again by a new share.

  A declared restore (`Arca.SecurityTransitions.restore/1`) moves each
  domain's `active` rows once, by the move `restored/1` names and the
  table admits: a credential to `needs_reauth`, until it is rotated at its
  destination, a profile to `needs_consent`, until it is re-consented,
  and a share to `revoked`, until its owner shares the entry again. A row
  in any other status keeps it.
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

  @shares %{
    "revoked" => ~w(active revoked)
  }

  @restored %{
    credentials: {"active", "needs_reauth"},
    profiles: {"active", "needs_consent"},
    shares: {"active", "revoked"}
  }

  @statuses %{
    credentials: ~w(active needs_reauth revoked tombstoned),
    profiles: ~w(active needs_consent revoked),
    shares: ~w(active revoked)
  }

  @typedoc "Whose rows a table answers for."
  @type domain :: :credentials | :profiles | :shares

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
  def from(:shares, status), do: Map.fetch(@shares, status)

  @doc """
  The status a profile is blocked at when what its head binds ends: a
  share revoked, or the entry a share names revoked or deleted. Only a
  revision that re-consents it moves it back.
  """
  @spec blocked_profile_status() :: String.t()
  def blocked_profile_status, do: "needs_consent"

  @doc """
  The move a declared restore makes on `domain`'s rows, `{from, to}`: the
  one status it moves and the status it writes, a move the domain's table
  admits.
  """
  @spec restored(domain()) :: {String.t(), String.t()}
  def restored(domain) do
    {from, to} = restored = Map.fetch!(@restored, domain)
    {:ok, admitted} = from(domain, to)
    true = from in admitted
    restored
  end
end
