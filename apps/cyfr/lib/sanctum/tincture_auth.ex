# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuth do
  @moduledoc """
  Unified tincture authentication.

  Resolves credentials and delegates to existing Sanctum infrastructure (MCP
  sessions, API keys, Sanctum session tokens).

  Auth priority (header- and token-preferred so live credentials do not travel
  in URL query strings / access logs):

  1. `Authorization: Bearer …` header — an API key or a session token, told
     apart by the `cyfr_` prefix. The only way to present an account credential.
  2. `Mcp-Session-Id` header — MCP / Sanctum session id
  3. `?_t=` — short-lived, single-purpose tincture access token

  **An account credential is never accepted from a query string.** An iframe or
  `<img>` cannot send headers, so those URLs carry a `?_t=` token instead:
  minted by `issue_access_token/1` (or `GET /t/access-token`) from an
  already-authenticated caller, it lasts an hour and grants only tincture
  `:execute` for one tenant. A URL ends up in browser history, `Referer` and
  every intermediary's logs, so what goes there has to be worth leaking.

  ## Returns

  - `{:ok, %Sanctum.Context{}}` — Authenticated context
  - `:unauthenticated` — No valid credentials found
  """

  @compile {:no_warn_undefined, [Emissary.MCP.Session]}

  import Plug.Conn, only: [get_req_header: 2]

  alias Sanctum.Context

  # Distinct from the 24h `/_s/` asset token (tincture_controller.ex,
  # @token_salt "tincture_access"): a single-purpose, minimal-payload,
  # project-scoped :execute token. The Prism picker bakes the URL at
  # render time and the user may click a tincture minutes later, so the
  # lifetime must comfortably outlast an open picker session. 1h is still a
  # dramatic improvement over the prior raw session token in the URL (which
  # carried the full-TTL session credential); this token grants only
  # tincture :execute for one tenant and expires regardless.
  @access_token_salt "tincture_access_v2"
  @access_token_max_age 3600

  @doc """
  Mint a short-lived tincture access token from an authenticated context.

  The payload is the minimum needed to rebuild a project-scoped, `:execute`
  tincture context — never the API key, never the raw session id. Useless for
  the MCP API and expires in #{@access_token_max_age}s, so even if logged it
  is low-value and short-lived.
  """
  @spec issue_access_token(Context.t()) :: String.t()
  def issue_access_token(%Context{} = ctx) do
    Phoenix.Token.sign(EmissaryWeb.Endpoint, @access_token_salt, %{
      u: ctx.user_id,
      o: ctx.org_id,
      p: ctx.project_id,
      n: ctx.namespace
    })
  end

  @spec authenticate(Plug.Conn.t()) :: {:ok, Context.t()} | :unauthenticated
  def authenticate(conn) do
    with :skip <- try_bearer_header(conn),
         :skip <- try_session_id_header(conn),
         :skip <- try_access_token(conn) do
      :unauthenticated
    else
      # Single tenant chokepoint. Every path builds a `scope: :project`
      # context without a tenant check; when an auth provider is configured, an
      # org-less context must not authenticate for tincture access. No-op for
      # single-user installs.
      {:ok, %Context{} = ctx} ->
        if tenant_resolved?(ctx), do: {:ok, ctx}, else: :unauthenticated

      other ->
        other
    end
  end

  defp tenant_resolved?(%Context{} = ctx) do
    Sanctum.Context.tenant_ok(ctx) == :ok
  end

  # --- Authorization: Bearer header (preferred) ---
  #
  # Carries either kind of credential, told apart by the `cyfr_` prefix, so a
  # caller has one place to put it. This is what lets a client mint a scoped
  # `?_t=` token from `GET /t/access-token` without falling back to a query
  # parameter or the retired `Mcp-Session-Id` header.

  defp try_bearer_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" ->
        if Sanctum.ApiKey.looks_like_key?(token) do
          validate_api_key(token, conn)
        else
          try_sanctum_session(token)
        end

      _ ->
        :skip
    end
  end

  defp validate_api_key(token, conn) do
    case Sanctum.ApiKey.validate(token, client_ip: Sanctum.ClientIp.resolve(conn)) do
      {:ok, metadata} -> {:ok, Sanctum.ApiKey.context_from_metadata(metadata)}
      _ -> :skip
    end
  end

  # --- Mcp-Session-Id header ---

  defp try_session_id_header(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id | _] when is_binary(id) and id != "" -> resolve_session(id)
      _ -> :skip
    end
  end

  # --- ?_t= short-lived tincture access token ---

  defp try_access_token(conn) do
    # namespace is identity-only (may be nil); the tenant gate in authenticate/1
    # (tenant_resolved?) is the real control, so no namespace guard here.
    with token when is_binary(token) and token != "" <- query_param(conn, "_t"),
         {:ok, %{u: user_id, o: org_id, p: project_id, n: namespace}} <-
           Phoenix.Token.verify(EmissaryWeb.Endpoint, @access_token_salt, token,
             max_age: @access_token_max_age
           ) do
      {:ok,
       Context.build(
         user_id: user_id,
         namespace: namespace,
         org_id: org_id,
         project_id: project_id,
         permissions: [:execute],
         scope: :project,
         auth_method: :tincture,
         authenticated: true
       )}
    else
      _ -> :skip
    end
  end

  # MCP session id first, then Sanctum session token.
  defp resolve_session(id) do
    case Emissary.MCP.Session.get(id) do
      {:ok, session} -> {:ok, session.context}
      {:error, :not_found} -> try_sanctum_session(id)
    end
  end

  defp try_sanctum_session(token) do
    case Sanctum.Session.load(token, surface: :tincture) do
      {:ok, ctx} ->
        # The :tincture surface stamps auth_method :session in the loader.
        # Tincture access always runs project-scoped and authenticated,
        # regardless of the operator's restored console workspace (and for
        # a not-yet-claimed user, whose load yields authenticated: false).
        {:ok, %{ctx | auth_method: :session, scope: :project, authenticated: true}}

      _ ->
        :skip
    end
  end

  @sensitive_query_keys ~w(_t _key _session)

  @doc """
  Redact tincture credential query params (`_t`, `_key`, `_session`) in a
  query string, replacing each value with `[REDACTED]`.

  Defense-in-depth: even with header-preferred auth, a stray credential query
  param must never reach an access log / error report. Operators should ALSO
  redact these keys at their reverse proxy (documented in the deploy notes).
  """
  @spec redact_query_string(String.t() | nil) :: String.t()
  def redact_query_string(qs) when is_binary(qs) and qs != "" do
    qs
    |> URI.decode_query()
    |> Enum.map_join("&", fn {k, v} ->
      v = if k in @sensitive_query_keys, do: "[REDACTED]", else: v
      URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v)
    end)
  end

  def redact_query_string(_), do: ""

  @doc """
  Replace `conn.query_string` with its redacted form so any downstream log
  sink / error renderer never observes a raw tincture credential. Call AFTER
  `authenticate/1` (which needs the original query string).
  """
  @spec scrub_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def scrub_conn(%Plug.Conn{} = conn) do
    %{conn | query_string: redact_query_string(conn.query_string)}
  end

  # --- Helpers ---

  defp query_param(conn, key) do
    case conn.query_string do
      qs when is_binary(qs) and qs != "" -> URI.decode_query(qs)[key]
      _ -> nil
    end
  end
end
