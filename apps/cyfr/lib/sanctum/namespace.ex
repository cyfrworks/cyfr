# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Namespace do
  @moduledoc """
  A person's cyfr.run namespace, as this server knows it.

  cyfr.run is the authority for *what* the slug is — it is claimed once,
  bound to the IdP identity there, and the same on every server. The
  `users` row is the authority for *whether this server knows it*: the
  slug is recorded on `users.namespace` the moment a probe or a claim
  yields it (`Sanctum.SignIn.record_namespace/2`) and read from there
  ever after. The registry push tokens in `Compendium.Registry.CredentialStore`
  are what a push needs, not who a person is — losing them costs a
  re-probe, never the identity.

  This module is the one-line lookup callers use to materialize
  `ctx.namespace` from `ctx.user_id`: `EmissaryWeb.Plugs.Authenticate`,
  `PrismWeb.AuthHelpers`, `Sanctum.Session.row_to_context/2`, the auth
  providers, API-key and webhook attribution.
  """

  require Logger
  require Arca.Repo.Errors

  alias Sanctum.Tenancy.Users

  # Read on every request that carries a session or a bearer credential;
  # the users row changes only through `Users.set_namespace/2` (which
  # invalidates below), so a short TTL keeps the read off the hot path.
  # Only positive results cache: an unclaimed person stays on the live path
  # so a fresh claim is visible immediately. (The test config sets the TTL
  # to 0: a sandbox rollback is a write no invalidation sees.)
  @cache_ttl_ms 60_000

  # A read that raises is a transient failure, never "unclaimed". Only
  # genuinely transient classes belong here: ArgumentError is deliberately
  # absent — it is the repo's programmer-error signal (an athanor-less
  # context at a storage backstop, a malformed call), and catching it as
  # retryable would hide bugs as 503s.
  @transient [DBConnection.OwnershipError] ++ Arca.Repo.Errors.db_errors()

  @doc """
  Resolve a person's namespace slug.

  Returns the slug when this server has recorded one for the person AND
  it still satisfies the canonical rule
  (`Sanctum.ComponentRef.valid_personal_slug?/1`). Otherwise `nil`. Safe to
  call with `nil` / non-binary user_id (returns `nil`).

  Defense-in-depth: the rule is re-checked even though cyfr.run enforced it
  at claim time — a corrupted row must not inject `..`, slashes, or other
  path-unsafe characters into `ctx.namespace`.

  A read failure is reported as `nil` — the caller's invariant is
  "namespace populated when known, nil when not"; `lookup_status/1` is
  the form that tells a failure from an unclaimed person.
  """
  @spec lookup(String.t() | nil) :: String.t() | nil
  def lookup(user_id) do
    case lookup_status(user_id) do
      {:ok, slug} -> slug
      _ -> nil
    end
  end

  @doc """
  Drop the cached slug for `user_id` — called when the users row's
  namespace is written, so a claim is visible on the next request, not
  after the TTL.
  """
  @spec invalidate(String.t() | term()) :: :ok
  def invalidate(user_id) when is_binary(user_id) do
    Arca.Cache.invalidate({:namespace_slug, user_id})
    :ok
  end

  def invalidate(_), do: :ok

  @typedoc "Distinguishes a transient store failure from an unclaimed namespace."
  @type status :: {:ok, String.t()} | :not_claimed | {:error, term()}

  @doc """
  Like `lookup/1` but distinguishes a **transient store error**
  (`{:error, reason}` — retryable; the caller should surface a 503 rather
  than wedge the person at namespace claiming) from a genuinely
  **unclaimed** namespace (`:not_claimed`).
  """
  @spec lookup_status(String.t() | nil) :: status()
  def lookup_status(user_id) when is_binary(user_id) and user_id != "" do
    key = {:namespace_slug, user_id}
    ttl = Application.get_env(:cyfr, :namespace_cache_ttl_ms, @cache_ttl_ms)

    case Arca.Cache.get(key) do
      {:ok, slug} ->
        {:ok, slug}

      :miss ->
        case Users.get(user_id) do
          {:ok, %{namespace: slug}} when is_binary(slug) ->
            if Sanctum.ComponentRef.valid_personal_slug?(slug) do
              if ttl > 0, do: Arca.Cache.put(key, slug, ttl)
              {:ok, slug}
            else
              Logger.warning(
                "[Sanctum.Namespace] users.namespace for user_id=#{inspect(user_id)} " <>
                  "is not a valid personal slug — treating as unclaimed"
              )

              :not_claimed
            end

          {:ok, _} ->
            :not_claimed

          {:error, :not_found} ->
            :not_claimed

          {:error, reason} ->
            Logger.warning(
              "[Sanctum.Namespace] transient namespace lookup failure for " <>
                "user_id=#{inspect(user_id)}: #{inspect(reason)} — treating as retryable"
            )

            {:error, reason}
        end
    end
  rescue
    e in @transient ->
      Logger.warning(
        "[Sanctum.Namespace] transient namespace lookup failure for " <>
          "user_id=#{inspect(user_id)}: #{Exception.message(e)} — treating as retryable"
      )

      {:error, e}
  end

  def lookup_status(_), do: :not_claimed
end
