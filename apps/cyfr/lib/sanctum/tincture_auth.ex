defmodule Sanctum.TinctureAuth do
  @moduledoc """
  Unified tincture authentication.

  Resolves credentials from HTTP query parameters and delegates to existing
  Sanctum infrastructure (MCP sessions, API keys, Sanctum session tokens).

  Auth priority:
  1. Session (`?_session=`) — MCP session IDs or Sanctum session tokens
  2. API key (`?_key=cyfr_xxx`) — programmatic access (all key types)

  ## Returns

  - `{:ok, %Sanctum.Context{}}` — Authenticated context
  - `:unauthenticated` — No valid credentials found
  """

  @compile {:no_warn_undefined, [Emissary.MCP.Session]}

  alias Sanctum.Context

  @spec authenticate(Plug.Conn.t()) :: {:ok, Context.t()} | :unauthenticated
  def authenticate(conn) do
    with :skip <- try_session(conn),
         :skip <- try_api_key(conn) do
      :unauthenticated
    end
  end

  # --- Session (?_session=...) ---
  # Supports both MCP session IDs (sess_xxx) and Sanctum session tokens.
  # Clients pass whichever credential they have.

  defp try_session(conn) do
    case query_param(conn, "_session") do
      id when is_binary(id) and id != "" ->
        case Emissary.MCP.Session.get(id) do
          {:ok, session} ->
            {:ok, session.context}

          {:error, :not_found} ->
            try_sanctum_session(id)
        end

      _ ->
        :skip
    end
  end

  defp try_sanctum_session(token) do
    case Sanctum.Session.load(token) do
      {:ok, ctx} ->
        # Override auth_method to :session and ensure scope/authenticated are set.
        # Session.load defaults auth_method to :oidc; tincture access wants :session.
        {:ok, %{ctx | auth_method: :session, scope: :project, authenticated: true}}

      _ ->
        :skip
    end
  end

  # --- API key (?_key=cyfr_xxx) ---

  defp try_api_key(conn) do
    with key when is_binary(key) <- query_param(conn, "_key"),
         true <- String.starts_with?(key, "cyfr_"),
         {:ok, metadata} <- Sanctum.ApiKey.validate(key, client_ip: client_ip(conn)) do
      {:ok, api_key_context(metadata)}
    else
      _ -> :skip
    end
  end

  # --- Helpers ---

  defp query_param(conn, key) do
    case conn.query_string do
      qs when is_binary(qs) and qs != "" -> URI.decode_query(qs)[key]
      _ -> nil
    end
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  rescue
    _ -> nil
  end

  defp api_key_context(metadata) do
    permissions =
      metadata.scope
      |> List.wrap()
      |> Enum.map(&Sanctum.Atoms.safe_to_permission_atom/1)
      |> Enum.filter(&is_atom/1)

    namespace = resolve_namespace_or_system(metadata)

    Context.build(
      user_id: metadata[:user_id],
      namespace: namespace,
      org_id: metadata[:org_id],
      project_id: metadata[:project_id],
      permissions: permissions,
      scope: :project,
      auth_method: :api_key,
      api_key_type: metadata.type,
      api_key_id: metadata[:id],
      authenticated: true
    )
  end

  # Mirror MCPSession's `_system` fallback for orphaned API keys: the owner's
  # CredentialStore entry may be gone (deleted user / wiped slug) but the key
  # itself still validates. Fall through to the system namespace sentinel
  # rather than crashing tenant_segments downstream, and surface the orphan
  # so operators can revoke the key.
  defp resolve_namespace_or_system(metadata) do
    case Sanctum.Namespace.lookup(metadata[:user_id]) do
      ns when is_binary(ns) ->
        ns

      nil ->
        require Logger

        Logger.warning(
          "[Sanctum.TinctureAuth] API key namespace lookup failed; falling back to \"_system\" — " <>
            "user_id=#{inspect(metadata[:user_id])} api_key_id=#{inspect(metadata[:id])}. " <>
            "The owning user's CredentialStore entry is missing; consider revoking the key."
        )

        "_system"
    end
  end
end
