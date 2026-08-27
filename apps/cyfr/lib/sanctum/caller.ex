# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Caller do
  @moduledoc """
  One verb that establishes who is calling and where they work.

  `Session.load/2` answers "which session is this"; what a surface needs
  is the finished Context — membership resolved, namespace present, the
  tenant gate passed, optionally focused on an athanor. Seven consumers
  used to hand-assemble their own subsets of that recipe, and none could
  tell from the load's interface which steps it had already done: the
  resolve is a no-op on one path and load-bearing on another, the
  namespace refresh likewise. The recipe lives here; a caller gets a
  Context or a named refusal its adapter maps to a halt, a redirect, or
  a status code.

  Refusals:

    * `:unauthenticated` — no token, or not a session this server issued.
    * `{:claim_pending, ctx}` — a valid session whose person has not
      claimed a namespace yet. The pre-claim context rides along because
      the claim flow needs its fields; nothing tenant-gated may act on it.
    * `{:denied, ctx}` — a namespace-holding session whose person the
      door no longer admits. The context rides along for surfaces that
      forward it to the anonymous surface rather than halting.
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
          | {:claim_pending, Context.t()}
          | {:denied, Context.t()}
          | :no_athanor
          | :not_member
          | :archived
          | :not_found
          | :unavailable

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
  @spec establish(String.t() | nil, keyword()) :: {:ok, Context.t()} | {:error, refusal()}
  def establish(token, opts \\ [])

  def establish(token, _opts) when token in [nil, ""], do: {:error, :unauthenticated}

  def establish(token, opts) when is_binary(token) do
    ttl = Application.get_env(:cyfr, :establish_cache_ms, 2_000)

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

  A pre-claim context (`authenticated: false`, no namespace) comes back
  as `{:error, {:claim_pending, ctx}}` with its namespace refreshed; an
  unauthenticated context that holds a namespace is `{:denied, ctx}` —
  the door stopped admitting its person after the session was minted.
  """
  @spec establish_context(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, refusal()}
  def establish_context(ctx, opts \\ [])

  def establish_context(%Context{authenticated: false} = ctx, _opts) do
    case ensure_namespace(ctx) do
      %Context{namespace: nil} = ctx -> {:error, {:claim_pending, ctx}}
      %Context{} = ctx -> {:error, {:denied, ctx}}
    end
  end

  def establish_context(%Context{} = ctx, opts) do
    ctx =
      ctx
      |> Sanctum.Tenancy.resolve_into()
      |> ensure_namespace()

    with :ok <- tenant_ok(ctx),
         {:ok, ctx} <- focus(ctx, Keyword.get(opts, :focus)) do
      {:ok, ctx}
    end
  end

  @doc """
  A light look at who a session belongs to — the identity fields and
  whether the claim is still pending — with none of the establish work.
  For surfaces that need only the person (the claim and legal flows),
  not a working Context.
  """
  @spec peek(String.t() | nil) ::
          {:ok,
           %{
             user_id: String.t() | nil,
             provider: String.t() | nil,
             email: String.t() | nil,
             claim_pending?: boolean()
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
           claim_pending?: not ctx.authenticated and is_nil(ctx.namespace)
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
    Arca.Cache.delete_match({:established, hash, :_, :_})
    :ok
  end

  defp memo_key(token, opts) do
    {:established, Session.token_hash(token), Keyword.get(opts, :surface, :console),
     memo_coord(Keyword.get(opts, :focus))}
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

  # `Session.load/2` populates the namespace on its authenticated path, but
  # a provider-synthesized Context never saw the load, and the pre-claim
  # row carries none — refresh from the users row when it is missing.
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
