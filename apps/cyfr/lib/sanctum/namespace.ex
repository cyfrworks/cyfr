# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Namespace do
  @moduledoc """
  Single seam for retrieving a user's personal namespace slug from cyfr.run.

  cyfr.run is the namespace authority — slugs are minted by
  `Compendium.Registry.Client.claim_personal_namespace/4` and persisted
  locally via `Compendium.Registry.CredentialStore`. This module is the
  one-line lookup callers use to materialize `ctx.namespace` from the
  persistent identity (`ctx.user_id`).

  Used by:
  - `EmissaryWeb.Plugs.MCPSession.maybe_resolve_membership/1`
  - `PrismWeb.AuthHelpers.maybe_resolve_membership/1`
  - `Sanctum.Session.row_to_context/1` (via session-resolution wrapper)
  - the configured auth provider's `authenticate/1` (after `resolve_membership/1`)
  - `Context.for_scheduled/2` (auto-resolve for real user_ids; sentinel
    `"_system"` for `"system"` / `"cron:*"`)

  A "personal" slug is bare (no dot); publisher slugs contain a dot.
  CredentialStore returns entries personal-first, so the first bare-slug
  hit wins.
  """

  alias Compendium.Registry.CredentialStore

  # Same shape as cyfr.run's server-side regex (see `Sanctum.Context.suggest_slug/1`).
  # Defense-in-depth: we re-validate even though cyfr.run already enforced it
  # at claim time — a corrupted CredentialStore row shouldn't be able to inject
  # `..`, slashes, or other path-unsafe characters into `ctx.namespace`.
  @slug_regex ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  @doc """
  Resolve a user's personal namespace slug.

  Returns the slug string when the user has claimed one on cyfr.run AND
  the stored slug still matches the canonical regex
  `^[a-z0-9]+(-[a-z0-9]+)*$`. Otherwise returns `nil`. Safe to call with
  `nil` / non-binary user_id (returns `nil`).

  Network/DB errors are caught and reported as `nil` — the caller's
  invariant is "namespace populated when known, nil when not", and a
  CredentialStore failure shouldn't crash an unrelated request.
  """
  @spec lookup(String.t() | nil) :: String.t() | nil
  def lookup(user_id) do
    case lookup_status(user_id) do
      {:ok, slug} -> slug
      _ -> nil
    end
  end

  @typedoc "Distinguishes a transient store failure from an unclaimed namespace."
  @type status :: {:ok, String.t()} | :not_claimed | {:error, term()}

  @doc """
  Like `lookup/1` but distinguishes a **transient store error**
  (`{:error, reason}` — retryable; the caller should surface a 503 rather
  than wedge the user at namespace claiming) from a genuinely **unclaimed**
  namespace (`:not_claimed`). A blanket `rescue _ -> nil` previously
  conflated the two, silently downgrading a valid user on a transient error.
  """
  @spec lookup_status(String.t() | nil) :: status()
  def lookup_status(user_id) when is_binary(user_id) and user_id != "" do
    registry = Compendium.Registry.canonical_host()

    slug =
      user_id
      |> CredentialStore.list_for_user(registry)
      |> Enum.find_value(fn cred ->
        s = cred[:namespace] || cred["namespace"]
        if is_binary(s) and Regex.match?(@slug_regex, s), do: s
      end)

    if is_binary(slug), do: {:ok, slug}, else: :not_claimed
  rescue
    e in [
      RuntimeError,
      ArgumentError,
      MatchError,
      Ecto.QueryError,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError
    ] ->
      require Logger

      Logger.warning(
        "[Sanctum.Namespace] transient namespace lookup failure for " <>
          "user_id=#{inspect(user_id)}: #{Exception.message(e)} — treating as retryable"
      )

      {:error, e}
  end

  def lookup_status(_), do: :not_claimed
end
