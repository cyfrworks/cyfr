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
      one the request is for; `{nil, nil}` on a route that names none;
      `client_ip:` for a key's allowlist). A narrowed derivative of the
      session or key it was minted from, held to that credential's rows as
      they are now (`derived_standing/2`): a retired source, a denial or
      an archive since, or the membership its focus rested on gone,
      refuses it for good.
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
      # only bounds reads that race the mutation itself, and, on a peer,
      # an announcement the bus did not deliver. What is cached is an
      # AUTHORIZATION decision, so the TTL is a security bound and not a
      # tuning knob: it is how long a revoked authority may outlive its
      # revocation anywhere in the cell.
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
    with {:ok, claims} <- Sanctum.TinctureAuth.verify_access_token(token),
         :ok <- names_tincture(claims, Keyword.get(opts, :tincture)),
         {:ok, _standing} <- token_standing(claims, Keyword.get(opts, :client_ip)) do
      # The namespace is display, reread from the person's row; the token
      # carries no authority beyond what the checked rows still grant.
      ctx =
        Context.build(
          user_id: claims.user_id,
          namespace: Sanctum.Namespace.lookup(claims.user_id),
          athanor_id: claims.athanor_id,
          permissions: [:execute],
          scope: :athanor,
          auth_method: :tincture,
          credential_binding: Sanctum.TinctureAuth.claims_binding(claims),
          credential_deadline: claims.expires_at,
          authenticated: true
        )

      with :ok <- tenant_ok(ctx), do: {:ok, ctx}
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
  defp names_tincture(_claims, nil), do: :ok
  defp names_tincture(_claims, {nil, nil}), do: :ok
  defp names_tincture(%{publisher: publisher, tincture_name: name}, {publisher, name}), do: :ok
  defp names_tincture(_claims, _tincture), do: {:error, :wrong_tincture}

  # An access token opens nothing its source no longer would: the refusals
  # a request is answered with.
  defp token_standing(claims, client_ip) do
    case derived_standing(claims, client_ip: client_ip) do
      {:ok, standing} -> {:ok, standing}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :ip_not_allowed} -> {:error, :ip_not_allowed}
      {:error, _retired} -> {:error, :not_standing}
    end
  end

  @doc """
  Whether the credential a derived token names still stands: the one
  authoritative check behind every tincture access and asset token, at
  mint and at every use. Never answered from the establish memo.

  `claims` name the person, the estate and their generations as read at
  mint, the source credential (`:session` with its base64url token hash,
  or `:api_key` with its row id) and the focus basis (the membership row
  id, or `:key`). The rows are locked and reread in the standing order
  (`Arca.CredentialBindings.check/3`), with the database's own time read
  after the locks, and must hold:

    * the person exists, is active, at the generation read — a person
      denied and allowed again is a new generation;
    * the estate exists, is active, at the generation read — an estate
      archived and reopened is a new generation;
    * a session source still exists for this person and has not
      expired; a key source is unrevoked, the estate's, the person's,
      and its allowlist admits `client_ip:`;
    * the membership a session's focus rested on is still that active
      seat (a rejoin is a new row); a key's focus is the key, so its
      creator leaving the estate does not end it.

  `{:ok, %{now: now, source_expires_at: expiry | nil}}`, or a refusal:
  `:not_standing`, `:not_member` (the focus membership is gone),
  `:ip_not_allowed`, or `:unavailable` when the store cannot answer —
  never read as either verdict.
  """
  @spec derived_standing(map(), keyword()) ::
          {:ok, %{now: DateTime.t(), source_expires_at: DateTime.t() | nil}}
          | {:error, :not_standing | :not_member | :ip_not_allowed | :unavailable}
  def derived_standing(claims, opts \\ []) do
    binding = %{
      user_id: claims.user_id,
      athanor_id: claims.athanor_id,
      membership_id: if(is_binary(claims.focus_basis), do: claims.focus_basis),
      source: source_row(claims)
    }

    case Arca.CredentialBindings.check(Cyfr.Actor.system(), binding,
           verify: &derived_policy(&1, claims, Keyword.get(opts, :client_ip))
         ) do
      {:ok, standing} -> {:ok, standing}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_row(%{source_kind: :session, source_id: id}) do
    case Base.url_decode64(id, padding: false) do
      {:ok, hash} -> {:session, hash}
      :error -> {:session, <<>>}
    end
  end

  defp source_row(%{source_kind: :api_key, source_id: id}), do: {:api_key, id}

  defp derived_policy(rows, claims, client_ip) do
    with :ok <- derived_person(rows.user, claims),
         :ok <- derived_estate(rows.athanor, claims),
         :ok <- derived_focus(rows.membership, claims),
         {:ok, expires_at} <- derived_source(rows.source, rows.now, claims, client_ip) do
      {:ok, %{now: rows.now, source_expires_at: expires_at}}
    end
  end

  defp derived_person(%{status: "active", security_generation: generation}, %{
         user_generation: generation
       }),
       do: :ok

  defp derived_person(_user, _claims), do: {:error, :not_standing}

  defp derived_estate(%{status: "active", security_generation: generation}, %{
         athanor_generation: generation
       }),
       do: :ok

  defp derived_estate(_athanor, _claims), do: {:error, :not_standing}

  defp derived_focus(nil, %{focus_basis: :key, source_kind: :api_key}), do: :ok

  defp derived_focus(
         %{status: "active", user_id: user_id, scope: "athanor", athanor_id: athanor_id},
         %{user_id: user_id, athanor_id: athanor_id, source_kind: :session}
       ),
       do: :ok

  defp derived_focus(
         %{status: "active", user_id: user_id, scope: "platform"},
         %{user_id: user_id, source_kind: :session}
       ),
       do: :ok

  defp derived_focus(_membership, _claims), do: {:error, :not_member}

  defp derived_source(
         %{kind: :session, row: %{user_id: user_id} = row},
         now,
         %{
           user_id: user_id
         },
         _client_ip
       ) do
    if DateTime.compare(row.expires_at, now) == :gt,
      do: {:ok, row.expires_at},
      else: {:error, :not_standing}
  end

  defp derived_source(
         %{
           kind: :api_key,
           row: %{revoked: false, athanor_id: athanor_id, created_by: user_id} = row
         },
         _now,
         %{athanor_id: athanor_id, user_id: user_id},
         client_ip
       ) do
    case Cyfr.Json.decode_or(row.ip_allowlist, nil, "Sanctum.Caller") do
      allowlist when allowlist in [nil, []] -> {:ok, nil}
      allowlist when is_binary(client_ip) and is_list(allowlist) -> allowed(client_ip, allowlist)
      _ -> {:error, :ip_not_allowed}
    end
  end

  defp derived_source(_source, _now, _claims, _client_ip), do: {:error, :not_standing}

  defp allowed(client_ip, allowlist) do
    if Sanctum.ApiKey.ip_allowed?(client_ip, allowlist),
      do: {:ok, nil},
      else: {:error, :ip_not_allowed}
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
  Drop every established-context memo for a session row key, on this
  member and on every other.

  Called by the session mutations (`Sanctum.Session.destroy/1`,
  `destroy_by_hash/1`, `use_athanor/2`, `revoke_all_for_user/1`,
  `invalidate_memo_for_user/1` — which is what archiving an athanor uses)
  so a revoked or repointed session is a next-request fact rather than a
  TTL-bounded one — the same invalidate-on-write discipline
  `Sanctum.Namespace.invalidate/1` applies to its cache.

  The memo table is each member's own, so this member's copy goes first
  and synchronously, before this returns: the caller is usually mid-way
  through an authorization change and must not depend on a round trip.
  The rest of the cell is reached by announcement — a foundation below
  the host emits telemetry and the host puts it on the bus
  (`Cyfr.StandingWatch`). A delivery that never arrives leaves a peer
  serving its memo for the rest of its TTL and no longer: the TTL is the
  bound, the announcement is what makes the usual case immediate.
  """
  @spec invalidate_hash(binary()) :: :ok
  def invalidate_hash(hash) when is_binary(hash) do
    drop_memo(hash)
    Sanctum.Telemetry.caller_invalidated(hash)
  end

  @doc """
  Drop this member's established-context memos for a session row key,
  announcing nothing.

  What a member does when it HEARS an invalidation
  (`Cyfr.StandingWatch`), and the first half of `invalidate_hash/1`. Kept
  apart from it so hearing an announcement cannot make another.
  """
  @spec drop_memo(binary()) :: :ok
  def drop_memo(hash) when is_binary(hash) do
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
