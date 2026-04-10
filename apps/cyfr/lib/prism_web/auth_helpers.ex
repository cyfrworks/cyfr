defmodule PrismWeb.AuthHelpers do
  @moduledoc """
  Shared authentication logic for LiveView hooks and controller plugs.

  Extracts token→user→context logic from LiveAuth so it can be reused
  by both LiveView `on_mount` and controller `Plug` pipelines.
  """

  require Logger

  alias Sanctum.{Session, Context}

  @doc """
  Authenticate a session token and build a Sanctum.Context.

  Returns `{:ok, user, context}` on success, `{:error, reason}` on failure.
  """
  @spec authenticate_session(String.t() | nil) ::
          {:ok, map(), Context.t()} | {:error, :unauthenticated | :no_org}
  def authenticate_session(nil), do: {:error, :unauthenticated}

  def authenticate_session(token) when is_binary(token) do
    case Session.get_user(token) do
      {:ok, user} ->
        user = maybe_resolve_membership(user)

        context =
          Context.build(
            user_id: user.id,
            org_id: user.org_id,
            project_id: user.project_id,
            permissions: user.permissions,
            scope: :project,
            auth_method: :oidc,
            authenticated: true
          )

        if arx_mode?() and (is_nil(context.org_id) or context.org_id == "") do
          {:error, :no_org}
        else
          Cyfr.LoggerContext.set_from_context(context)
          {:ok, user, context}
        end

      _ ->
        {:error, :unauthenticated}
    end
  end

  # In Arx mode, if a session's user has no org_id, try to re-resolve membership.
  defp maybe_resolve_membership(user) do
    if arx_mode?() and Code.ensure_loaded?(SanctumArx.Memberships) and
         (is_nil(user.org_id) or user.org_id == "") do
      case SanctumArx.Memberships.list_by_user(user.id) do
        memberships when is_list(memberships) and memberships != [] ->
          membership =
            Enum.find(memberships, List.first(memberships), fn m ->
              m.accepted_at != nil
            end)

          %{user | org_id: membership.org_id, project_id: user.project_id || "default"}

        [] ->
          user

        {:error, reason} ->
          Logger.error(
            "[AuthHelpers] Failed to resolve membership for user #{user.id}: #{inspect(reason)}"
          )

          user
      end
    else
      user
    end
  end

  defp arx_mode?, do: Application.get_env(:cyfr, :edition, :core) == :arx
end
