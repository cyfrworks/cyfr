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
          {:ok, Context.t()} | {:error, :unauthenticated | :no_org}
  def authenticate_session(nil), do: {:error, :unauthenticated}

  def authenticate_session(token) when is_binary(token) do
    case Session.load(token) do
      {:ok, ctx} ->
        ctx =
          ctx
          |> maybe_resolve_membership()
          |> ensure_namespace()

        case Application.fetch_env!(:cyfr, :tenant_policy).require_org(ctx) do
          {:error, _} ->
            {:error, :no_org}

          :ok ->
            Cyfr.LoggerContext.set_from_context(ctx)
            {:ok, ctx}
        end

      _ ->
        {:error, :unauthenticated}
    end
  end

  # Populate ctx.namespace from CredentialStore via Sanctum.Namespace.lookup/1.
  # Session.load/1 already attempts this in row_to_context, but going through a
  # plug pipeline that re-resolves membership may have rebuilt the context with
  # a stale namespace; this is a belt-and-suspenders refresh.
  defp ensure_namespace(%Context{namespace: ns} = ctx) when is_binary(ns) and ns != "", do: ctx
  defp ensure_namespace(%Context{} = ctx), do: %{ctx | namespace: Sanctum.Namespace.lookup(ctx.user_id)}

  # If a context has no org_id, ask the configured membership resolver.
  # Core's Sanctum.NoopMembershipResolver always returns :no_membership (no-op);
  # Arx's Arx.Sanctum.MembershipResolver hits the memberships table.
  defp maybe_resolve_membership(%Context{org_id: org_id} = ctx)
       when is_binary(org_id) and org_id != "",
       do: ctx

  defp maybe_resolve_membership(%Context{} = ctx) do
    case Application.fetch_env!(:cyfr, :membership_resolver).resolve(ctx.user_id) do
      %{org_id: org_id} ->
        %{ctx | org_id: org_id, project_id: ctx.project_id}

      :no_membership ->
        ctx

      {:error, reason} ->
        Logger.error(
          "[AuthHelpers] Failed to resolve membership for user #{ctx.user_id}: #{inspect(reason)}"
        )

        ctx
    end
  end

  @doc """
  Return the user's personal-namespace slug on cyfr.run, or `nil` when they
  have not claimed one yet.

  Delegates to `Sanctum.Namespace.lookup/1` (Sanctum-level seam) so any
  module can call it without a PrismWeb dependency.
  """
  @spec personal_namespace_slug(String.t() | nil) :: String.t() | nil
  defdelegate personal_namespace_slug(user_id), to: Sanctum.Namespace, as: :lookup
end
