# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuth do
  @moduledoc """
  Unified tincture authentication.

  Resolves credentials and delegates to existing Sanctum infrastructure (API
  keys, Sanctum session tokens).

  Auth priority (header- and token-preferred so live credentials do not travel
  in URL query strings / access logs):

  1. `Authorization: Bearer …` header — an API key or a session token, told
     apart by the `cyfr_` prefix. The only way to present an account credential.
  2. `?_t=` — short-lived, single-purpose tincture access token

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

  import Plug.Conn, only: [get_req_header: 2]

  alias Sanctum.Context

  # Distinct from the `/_s/` asset token (tincture_controller.ex,
  # @token_salt "tincture_asset_v2"): a single-purpose, minimal-payload,
  # athanor-scoped :execute token. The Prism picker bakes the URL at
  # render time and the user may click a tincture minutes later, so the
  # lifetime must comfortably outlast an open picker session. 1h is still a
  # dramatic improvement over the prior raw session token in the URL (which
  # carried the full-TTL session credential); this token grants only
  # tincture :execute for one athanor and expires regardless.
  @access_token_salt "tincture_access_v3"
  @access_token_max_age 3600

  @doc "Access-token lifetime in seconds — the value verify enforces and the API reports."
  @spec access_token_max_age() :: pos_integer()
  def access_token_max_age, do: @access_token_max_age

  @doc """
  Mint a short-lived tincture access token from an authenticated context.

  The payload is the minimum needed to rebuild an athanor-scoped, `:execute`
  tincture context — never the API key, never the raw session id. Useless for
  the MCP API and expires in #{@access_token_max_age}s, so even if logged it
  is low-value and short-lived.
  """
  @spec issue_access_token(Context.t()) :: String.t()
  def issue_access_token(%Context{} = ctx) do
    Phoenix.Token.sign(EmissaryWeb.Endpoint, @access_token_salt, %{
      u: ctx.user_id,
      a: ctx.athanor_id,
      n: ctx.namespace,
      # What was exchanged for it, so the standing it is held to is the
      # standing of the credential behind it — a person's session or an
      # athanor-owned key are not the same thing.
      m: mint_kind(ctx.auth_method)
    })
  end

  defp mint_kind(:api_key), do: :api_key
  defp mint_kind(_), do: :person

  @spec authenticate(Plug.Conn.t()) :: {:ok, Context.t()} | :unauthenticated
  def authenticate(conn) do
    with :skip <- try_bearer_header(conn),
         :skip <- try_access_token(conn) do
      :unauthenticated
    else
      # Single tenant chokepoint. Every path builds a `scope: :athanor`
      # context without a tenant check; a context that names no athanor
      # must not authenticate for tincture access.
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
  # parameter.

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

  # --- ?_t= short-lived tincture access token ---

  defp try_access_token(conn) do
    # namespace is identity-only (may be nil); the tenant gate in authenticate/1
    # (tenant_resolved?) is the real control, so no namespace guard here.
    with token when is_binary(token) and token != "" <- query_param(conn, "_t"),
         {:ok, %{u: user_id, a: athanor_id, n: namespace} = payload} <-
           Phoenix.Token.verify(EmissaryWeb.Endpoint, @access_token_salt, token,
             max_age: @access_token_max_age
           ) do
      Context.build(
        user_id: user_id,
        namespace: namespace,
        athanor_id: athanor_id,
        permissions: [:execute],
        scope: :athanor,
        auth_method: :tincture,
        authenticated: true
      )
      |> still_standing(athanor_id, Map.get(payload, :m, :person))
    else
      _ -> :skip
    end
  end

  # A signature says who minted the token, not what they may still do. A
  # token exchanged for a person's session is held to that person's standing
  # — the door and their seat here — exactly as a session load is, so a deny
  # or a removal stops it rather than being outlived by the hour. One
  # exchanged for an API key is held to the key's own rule (D15): the
  # athanor is open and the creator is not denied, but a key outlives its
  # creator's membership on purpose.
  defp still_standing(%Context{} = ctx, athanor_id, :api_key) do
    if Sanctum.Tenancy.channel_active?(athanor_id, ctx.user_id), do: {:ok, ctx}, else: :skip
  end

  defp still_standing(%Context{} = ctx, athanor_id, _person) do
    case Sanctum.Tenancy.revalidate(ctx) do
      %Context{authenticated: true, athanor_id: ^athanor_id} = current -> {:ok, current}
      _ -> :skip
    end
  end

  defp try_sanctum_session(token) do
    case Sanctum.Session.load(token, surface: :tincture) do
      {:ok, ctx} ->
        # The :tincture surface stamps auth_method :session in the loader.
        # Tincture access always runs athanor-scoped and authenticated,
        # regardless of the operator's restored console session (and for
        # a not-yet-claimed user, whose load yields authenticated: false).
        {:ok, %{ctx | auth_method: :session, scope: :athanor, authenticated: true}}

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
