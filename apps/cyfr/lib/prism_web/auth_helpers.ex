# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AuthHelpers do
  @moduledoc """
  Shared authentication logic for LiveView hooks and controller plugs.

  Extracts token→user→context logic from LiveAuth so it can be reused
  by both LiveView `on_mount` and controller `Plug` pipelines.
  """

  require Logger

  alias Sanctum.{Session, Context}

  @doc """
  Authenticate a session token and load a Sanctum.Context.

  Returns `{:ok, ctx}` on success, `{:error, reason}` on failure.
  """
  @spec authenticate_session(String.t() | nil) ::
          {:ok, Context.t()} | {:error, :unauthenticated | :no_org | :namespace_unavailable}
  def authenticate_session(nil), do: {:error, :unauthenticated}

  def authenticate_session(token) when is_binary(token) do
    case Session.load(token, surface: :console) do
      {:ok, ctx} ->
        ctx =
          ctx
          |> Sanctum.Tenancy.resolve_into()
          |> ensure_namespace()

        case Sanctum.Context.tenant_ok(ctx) do
          {:error, :missing_tenant} ->
            {:error, :no_org}

          :ok ->
            Cyfr.LoggerContext.set_from_context(ctx)
            slide_session(token)
            {:ok, ctx}
        end

      {:error, :namespace_unavailable} ->
        # Transient CredentialStore/DB failure (distinct from "not claimed" /
        # "unauthenticated"). Propagate so the caller can return a retryable
        # 503 instead of bouncing a valid user to re-auth/claim.
        {:error, :namespace_unavailable}

      _ ->
        {:error, :unauthenticated}
    end
  end

  # Activity-based ("sliding window") session refresh. Fire-and-forget so the
  # hot path isn't blocked on a SQLite write; Session.refresh_if_stale/1 itself
  # no-ops unless the session is due for extension. Mirrors the MCP path
  # (EmissaryWeb.Plugs.MCPSession).
  defp slide_session(token) do
    logger_metadata = Cyfr.LoggerContext.capture()

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           Cyfr.LoggerContext.restore(logger_metadata)
           Sanctum.Session.refresh_if_stale(token)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.debug("[AuthHelpers] session refresh task not started: #{inspect(reason)}")
    end
  end

  # Populate ctx.namespace from CredentialStore via Sanctum.Namespace.lookup/1.
  # Session.load/1 already attempts this in row_to_context, but going through a
  # plug pipeline that re-resolves membership may have rebuilt the context with
  # a stale namespace; this is a belt-and-suspenders refresh.
  defp ensure_namespace(%Context{namespace: ns} = ctx) when is_binary(ns) and ns != "", do: ctx

  defp ensure_namespace(%Context{} = ctx),
    do: %{ctx | namespace: Sanctum.Namespace.lookup(ctx.user_id)}

  # If a context has no org_id, ask the configured tenancy resolver.
  # Without an auth provider this returns the seeded local/default workspace;
  # with one configured it queries the memberships table.

  @doc """
  Return the user's personal-namespace slug on cyfr.run, or `nil` when they
  have not claimed one yet.

  Delegates to `Sanctum.Namespace.lookup/1` (Sanctum-level seam) so any
  module can call it without a PrismWeb dependency.
  """
  @spec personal_namespace_slug(String.t() | nil) :: String.t() | nil
  defdelegate personal_namespace_slug(user_id), to: Sanctum.Namespace, as: :lookup
end
