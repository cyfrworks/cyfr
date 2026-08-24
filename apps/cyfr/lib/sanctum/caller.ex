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
    * `:denied` — a namespace-holding session whose person the door no
      longer admits.
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
          | :denied
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
  unauthenticated context that holds a namespace is `:denied` — the door
  stopped admitting its person after the session was minted.
  """
  @spec establish_context(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, refusal()}
  def establish_context(ctx, opts \\ [])

  def establish_context(%Context{authenticated: false} = ctx, _opts) do
    case ensure_namespace(ctx) do
      %Context{namespace: nil} = ctx -> {:error, {:claim_pending, ctx}}
      %Context{} -> {:error, :denied}
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
