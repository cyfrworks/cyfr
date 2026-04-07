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
    case Sanctum.Session.get_user(token) do
      {:ok, user} ->
        {:ok, context_from_session_user(user)}

      _ ->
        :skip
    end
  end

  defp context_from_session_user(user) do
    Context.build(
      user_id: user.id,
      org_id: user.org_id,
      project_id: user.project_id,
      permissions: user.permissions,
      scope: :project,
      auth_method: :session,
      authenticated: true
    )
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

    Context.build(
      user_id: metadata[:user_id],
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
end
