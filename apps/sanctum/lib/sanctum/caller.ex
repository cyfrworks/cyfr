# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Caller do
  @moduledoc """
  One verb that establishes who is calling and where they work.

  A credential names a caller; what a surface needs is the finished
  Context — the principal named, its standing checked, the tenant gate
  passed, optionally focused on an athanor. This is the only builder of
  an authenticated Context: every surface hands its credential here and
  gets a Context or a named refusal its adapter maps to a halt, a
  redirect, or a status code.

  Credentials, and the standing each is held to:

    * `{:session, token}` — a person's session (the bare token is the
      same credential). Memberships resolve the athanor, the users row
      supplies the namespace, and a person the door no longer admits is
      `{:denied, ctx}`.
    * `{:api_key, raw}` — an athanor's key (`client_ip:` for its
      allowlist). The athanor is the key row's, never the creator's
      current membership; the key stands while the athanor is open and
      its creator is not denied.
    * `{:tincture_token, token}` — the short-lived `?_t=` token one
      tincture is opened with (`tincture: {publisher, name}` names the
      one the request is for; `{nil, nil}` on a route that names none).
      Held to the standing of what minted it: a person's, or a key's.
    * `{:webhook, webhook}` — a verified webhook row (`request_id:`).
      Stands while its athanor is open and its creator is not denied.

  Refusals:

    * `:unauthenticated` — no token, or not a session this server issued.
    * `:invalid_credential` / `:expired_credential` — a key or token that
      is not one of this server's, or one past its life.
    * `:revoked` / `:ip_not_allowed` — a key the store or its allowlist
      refuses.
    * `{:denied, ctx}` — a session whose person the door no longer
      admits. The context rides along for surfaces that forward it to the
      anonymous surface rather than halting.
    * `:not_standing` — a token or webhook whose principal no longer
      stands where it was minted.
    * `:wrong_tincture` — a tincture token presented to another tincture.
    * `:no_athanor` — authenticated, but no athanor resolved.
    * `:not_member` / `:archived` / `:not_found` — the requested focus
      refused.
    * `:unavailable` — a transient store failure. Retryable: it must
      never read as "signed out" or bounce a person into a claim they
      already made.
  """

  alias Sanctum.Context
  alias Sanctum.Session

  require Logger

  @type refusal ::
          :unauthenticated
          | :invalid_credential
          | :expired_credential
          | :revoked
          | :ip_not_allowed
          | {:denied, Context.t()}
          | :not_standing
          | :wrong_tincture
          | :no_athanor
          | :not_member
          | :archived
          | :not_found
          | :unavailable

  @type credential ::
          {:session, String.t() | nil}
          | {:api_key, String.t()}
          | {:tincture_token, String.t()}
          | {:webhook, Arca.Schemas.Webhook.t()}

  @doc """
  Establish the caller behind a session token.

  Options:

    * `:surface` — forwarded to `Session.load/2` (default `:console`).
    * `:focus` — an athanor id or row to focus the established context on
      (`Context.focus/2`); how a nested view follows the page's focus.
    * `:refresh` — slide the session's expiry when due (default `true`).
    * `:task_supervisor` — where the fire-and-forget refresh runs; no
      supervisor, no refresh. Callers pass their own so the write never
      blocks the hot path and test sandboxes see a known process.
  """
  @spec establish(credential() | String.t() | nil, keyword()) ::
          {:ok, Context.t()} | {:error, refusal()}
  def establish(credential, opts \\ [])

  # A bare token is a session token: what the browser cookie and the CLI carry.
  def establish(token, opts) when is_binary(token) or is_nil(token),
    do: establish({:session, token}, opts)

  def establish({:session, token}, _opts) when token in [nil, ""], do: {:error, :unauthenticated}

  def establish({:session, token}, opts) when is_binary(token) do
    ttl = Application.get_env(:sanctum, :establish_cache_ms, 2_000)

    if ttl > 0 do
      # A cold page load establishes the same caller several times inside
      # a second (the plug, the dead render, the connected mount, the
      # nested topbar). The short memo collapses those to one pipeline
      # run. Only successes are cached, and every session mutation
      # (`Session.destroy/1`, `destroy_by_hash/1`, `use_athanor/2`,
      # `revoke_all_for_user/1`) calls `invalidate_hash/1`, so a revoked
      # or repointed session misses on its very next establish — the TTL
      # only bounds reads that race the mutation itself.
      key = memo_key(token, opts)

      case Arca.Cache.get(key) do
        {:ok, %Context{} = ctx} ->
          {:ok, ctx}

        :miss ->
          result = do_establish(token, opts)

          with {:ok, ctx} <- result, do: Arca.Cache.put(key, ctx, ttl)
          result
      end
    else
      do_establish(token, opts)
    end
  end

  def establish({:api_key, raw}, opts) when is_binary(raw) do
    case Sanctum.ApiKey.validate(raw, client_ip: Keyword.get(opts, :client_ip)) do
      {:ok, metadata} ->
        ctx = Sanctum.ApiKey.context_from_metadata(metadata)
        with :ok <- tenant_ok(ctx), do: {:ok, ctx}

      {:error, reason} ->
        {:error, api_key_refusal(reason)}
    end
  end

  def establish({:tincture_token, token}, opts) when is_binary(token) do
    with {:ok, payload} <- Sanctum.TinctureAuth.verify_access_token(token),
         :ok <- names_tincture(payload, Keyword.get(opts, :tincture)) do
      Context.build(
        user_id: payload.u,
        namespace: payload.n,
        athanor_id: payload.a,
        permissions: [:execute],
        scope: :athanor,
        auth_method: :tincture,
        authenticated: true
      )
      |> standing(payload.a, Map.get(payload, :m, :person))
    end
  end

  def establish({:webhook, %Arca.Schemas.Webhook{} = webhook}, opts) do
    # The stored row must not remain a standing execution channel once its
    # athanor is archived or its creator denied here.
    if Sanctum.Tenancy.channel_active?(webhook.athanor_id, webhook.created_by) do
      # namespace is identity-only (not path-bearing): the creator's, for
      # attribution; nil if the webhook is orphaned.
      namespace =
        case webhook.created_by do
          user_id when is_binary(user_id) and user_id != "" -> Sanctum.Namespace.lookup(user_id)
          _ -> nil
        end

      ctx =
        Context.build(
          user_id: "webhook:#{webhook.slug}",
          namespace: namespace,
          permissions: [:execute],
          athanor_id: webhook.athanor_id,
          auth_method: :webhook,
          # A webhook is not anonymous: the hook is operator-created and
          # consented (profile_id is required at create), so its bound
          # executions may read their vault material.
          authenticated: true,
          anonymous: false,
          request_id: Keyword.get(opts, :request_id)
        )

      with :ok <- tenant_ok(ctx), do: {:ok, ctx}
    else
      {:error, :not_standing}
    end
  end

  # The key store's answers, in this module's vocabulary. A malformed key
  # and an unknown one read alike, as the store already takes care they do.
  defp api_key_refusal(reason) when reason in [:invalid_key_format, :invalid_key],
    do: :invalid_credential

  defp api_key_refusal(reason) when reason in [:revoked, :channel_closed], do: :revoked
  defp api_key_refusal(:ip_not_allowed), do: :ip_not_allowed
  defp api_key_refusal(:database_error), do: :unavailable

  # The token opens the tincture it was minted for and no other. A route
  # that names none (the access-token mint) has nothing to compare.
  defp names_tincture(_payload, nil), do: :ok
  defp names_tincture(_payload, {nil, nil}), do: :ok
  defp names_tincture(%{p: publisher, t: name}, {publisher, name}), do: :ok
  defp names_tincture(_payload, _tincture), do: {:error, :wrong_tincture}

  # A signature says who minted the token, not what they may still do. A
  # token exchanged for a person's session is held to that person's standing
  # — the door and their seat here — exactly as a session load is, so a deny
  # or a removal stops it rather than being outlived by the hour. One
  # exchanged for an API key is held to the key's own rule: the athanor is
  # open and the creator is not denied, but a key outlives its creator's
  # membership on purpose.
  defp standing(%Context{} = ctx, athanor_id, :api_key) do
    if Sanctum.Tenancy.channel_active?(athanor_id, ctx.user_id),
      do: {:ok, ctx},
      else: {:error, :not_standing}
  end

  defp standing(%Context{} = ctx, athanor_id, _person) do
    case Sanctum.Tenancy.revalidate(ctx) do
      {:ok, %Context{authenticated: true, athanor_id: ^athanor_id} = current} -> {:ok, current}
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :not_standing}
    end
  end

  defp do_establish(token, opts) do
    case Session.load(token, surface: Keyword.get(opts, :surface, :console)) do
      {:ok, %Context{} = ctx} ->
        with {:ok, established} <- establish_context(ctx, opts) do
          maybe_refresh(token, opts)
          {:ok, established}
        end

      {:error, reason} when reason in [:namespace_unavailable, :database_error] ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :unauthenticated}
    end
  end

  @doc """
  Establish a Context that already exists — a loaded session's, or one a
  configured auth provider synthesized (which never went through
  `Session.load/2`, so nothing about it can be assumed done).

  An unauthenticated context is `{:denied, ctx}` — the door stopped
  admitting its person after the session was minted.
  """
  @spec establish_context(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, refusal()}
  def establish_context(ctx, opts \\ [])

  def establish_context(%Context{authenticated: false} = ctx, _opts) do
    {:error, {:denied, ensure_namespace(ctx)}}
  end

  def establish_context(%Context{} = ctx, opts) do
    # Distinguish a retryable membership-read failure from having no athanor membership.
    with {:ok, ctx} <- resolve(ctx),
         ctx = ensure_namespace(ctx),
         :ok <- tenant_ok(ctx),
         {:ok, ctx} <- focus(ctx, Keyword.get(opts, :focus)) do
      {:ok, ctx}
    end
  end

  defp resolve(ctx) do
    case Sanctum.Tenancy.resolve_status(ctx) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @doc """
  A light look at who a session belongs to — the identity fields and the
  publisher namespace, if any — with none of the establish work. For
  surfaces that need only the person (the claim and legal flows), not a
  working Context.
  """
  @spec peek(String.t() | nil) ::
          {:ok,
           %{
             user_id: String.t() | nil,
             provider: String.t() | nil,
             email: String.t() | nil,
             namespace: String.t() | nil
           }}
          | {:error, :unauthenticated | :unavailable}
  def peek(token) when token in [nil, ""], do: {:error, :unauthenticated}

  def peek(token) when is_binary(token) do
    case Session.load(token, surface: :console) do
      {:ok, %Context{} = ctx} ->
        {:ok,
         %{
           user_id: ctx.user_id,
           provider: ctx.provider,
           email: ctx.email,
           namespace: ctx.namespace
         }}

      {:error, reason} when reason in [:namespace_unavailable, :database_error] ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :unauthenticated}
    end
  end

  @doc """
  Drop every established-context memo for a session row key.

  Called by the session mutations (`Sanctum.Session.destroy/1`,
  `destroy_by_hash/1`, `use_athanor/2`, `revoke_all_for_user/1`) so a
  revoked or repointed session is a next-request fact rather than a
  TTL-bounded one — the same invalidate-on-write discipline
  `Sanctum.Namespace.invalidate/1` applies to its cache.
  """
  @spec invalidate_hash(binary()) :: :ok
  def invalidate_hash(hash) when is_binary(hash) do
    Arca.Cache.delete_match(Arca.Cache.Keys.match_established(hash))
    :ok
  end

  defp memo_key(token, opts) do
    Arca.Cache.Keys.established(
      Session.token_hash(token),
      Keyword.get(opts, :surface, :console),
      memo_coord(Keyword.get(opts, :focus))
    )
  end

  defp memo_coord(%{id: id}), do: id
  defp memo_coord(other), do: other

  defp tenant_ok(ctx) do
    case Context.tenant_ok(ctx) do
      :ok -> :ok
      {:error, :missing_tenant} -> {:error, :no_athanor}
    end
  end

  defp focus(ctx, nil), do: {:ok, ctx}
  defp focus(ctx, coordinate), do: Context.focus(ctx, coordinate)

  # `Session.load/2` populates the namespace from the users row, but a
  # provider-synthesized Context never saw the load — refresh from the
  # row when it is missing.
  defp ensure_namespace(%Context{namespace: ns} = ctx) when is_binary(ns) and ns != "", do: ctx

  defp ensure_namespace(%Context{} = ctx),
    do: %{ctx | namespace: Sanctum.Namespace.lookup(ctx.user_id)}

  # Activity-based sliding refresh, fire-and-forget so the hot path never
  # waits on the write; `Session.refresh_if_stale/1` no-ops unless due.
  defp maybe_refresh(token, opts) do
    with true <- Keyword.get(opts, :refresh, true),
         supervisor when not is_nil(supervisor) <- Keyword.get(opts, :task_supervisor) do
      logger_metadata = Cyfr.LoggerContext.capture()

      case Task.Supervisor.start_child(supervisor, fn ->
             Cyfr.LoggerContext.restore(logger_metadata)
             Session.refresh_if_stale(token)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.debug("[Sanctum.Caller] session refresh task not started: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end
end
