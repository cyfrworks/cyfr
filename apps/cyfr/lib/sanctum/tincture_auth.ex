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
  - `:unauthenticated` — no credential was presented at all
  - `{:error, refusal}` — a credential was presented and is dead or
    refused; the surface renders the named refusal instead of silently
    serving the anonymous fallback
  """

  alias Sanctum.Context

  @typedoc """
  Why a *presented* credential was refused. Distinct from
  `:unauthenticated` (nothing presented), so a caller holding a dead
  credential learns so.
  """
  @type refusal ::
          :invalid_credential
          | :expired_token
          | :denied
          | :not_standing
          | :no_athanor
          | :wrong_tincture
          | :unavailable

  # A sibling of the `/_s/` asset token (tincture_controller.ex,
  # @token_salt "tincture_asset_v2") and scoped the same way: one publisher
  # and one name, not a whole athanor. It travels in a URL into a sandboxed
  # iframe, where the tincture's own scripts can read `location.search` and
  # send it to any origin its manifest put in `connect-src` — so an
  # athanor-wide grant would make any one tincture's leak open every other
  # tincture in that athanor, private ones included. The Prism picker bakes
  # the URL at render time and the user may click minutes later, so the
  # lifetime outlasts an open picker session; v4 is the scoped payload, and
  # the salt bump retires every unscoped token still in flight.
  @access_token_salt "tincture_access_v4"
  @access_token_max_age 3600

  @doc "Access-token lifetime in seconds — the value verify enforces and the API reports."
  @spec access_token_max_age() :: pos_integer()
  def access_token_max_age, do: @access_token_max_age

  @doc """
  The key both tincture tokens are signed with.

  From config, not from the web endpoint's module: the auth domain must not
  reach into the web layer for key material. In every deployed env this is
  the same secret the endpoint signs with (runtime.exs and dev.exs set both
  from one value), read through the domain's own key.

  Provides the signing key shared by tincture access and asset tokens.
  """
  @spec signing_secret() :: binary()
  def signing_secret, do: Application.fetch_env!(:cyfr, :secret_key_base)

  @doc """
  Mint a short-lived access token for ONE tincture, from an authenticated
  context.

  The payload is the minimum needed to rebuild an `:execute` tincture context
  bound to `publisher`/`tincture_name` — never the API key, never the raw
  session id. Useless for the MCP API, refused on any other tincture, and
  expires in #{@access_token_max_age}s, so even if it leaks out of the iframe
  that carried it, what it opens is the one page the holder was already
  looking at.
  """
  @spec issue_access_token(Context.t(), String.t(), String.t()) :: String.t()
  def issue_access_token(%Context{} = ctx, publisher, tincture_name)
      when is_binary(publisher) and is_binary(tincture_name) do
    Phoenix.Token.sign(signing_secret(), @access_token_salt, %{
      u: ctx.user_id,
      a: ctx.athanor_id,
      n: ctx.namespace,
      # The one tincture this token opens.
      p: publisher,
      t: tincture_name,
      # What was exchanged for it, so the standing it is held to is the
      # standing of the credential behind it — a person's session or an
      # athanor-owned key are not the same thing.
      m: mint_kind(ctx.auth_method)
    })
  end

  defp mint_kind(:api_key), do: :api_key
  defp mint_kind(_), do: :person

  @spec authenticate(Plug.Conn.t()) ::
          {:ok, Context.t()} | :unauthenticated | {:error, refusal()}
  def authenticate(conn) do
    with :skip <- try_bearer_header(conn),
         :skip <- try_access_token(conn) do
      :unauthenticated
    else
      # Single tenant chokepoint. Every path builds a `scope: :athanor`
      # context without a tenant check; a context that names no athanor
      # must not authenticate for tincture access.
      {:ok, %Context{} = ctx} ->
        if tenant_resolved?(ctx), do: {:ok, ctx}, else: {:error, :no_athanor}

      {:error, _} = refusal ->
        refusal
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
    case Sanctum.BearerToken.read(conn) do
      token when is_binary(token) ->
        if Sanctum.ApiKey.looks_like_key?(token) do
          validate_api_key(token, conn)
        else
          try_sanctum_session(token)
        end

      nil ->
        :skip
    end
  end

  defp validate_api_key(token, conn) do
    case Sanctum.Caller.establish({:api_key, token}, client_ip: Sanctum.ClientIp.resolve(conn)) do
      {:ok, %Context{} = ctx} -> {:ok, ctx}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _} -> {:error, :invalid_credential}
    end
  end

  # --- ?_t= short-lived tincture access token ---

  # The request's own tincture comes from the router's path params, so the
  # token is held to it on every `/t/:athanor/:publisher/:tincture_name`
  # route — index, asset and invoke — and a route that names none (the
  # `/t/access-token` mint) refuses minted tokens on its own account.
  defp try_access_token(conn) do
    case query_param(conn, "_t") do
      token when is_binary(token) and token != "" ->
        tincture = {path_param(conn, "publisher"), path_param(conn, "tincture_name")}

        case Sanctum.Caller.establish({:tincture_token, token}, tincture: tincture) do
          {:ok, %Context{} = ctx} -> {:ok, ctx}
          {:error, :expired_credential} -> {:error, :expired_token}
          {:error, _} = refusal -> refusal
        end

      _ ->
        :skip
    end
  end

  @doc """
  What a `?_t=` token says, once its signature and age check out: the
  payload `issue_access_token/3` signed. The one place the token is
  verified; `Sanctum.Caller` builds the context it names and holds it to
  its standing.
  """
  @spec verify_access_token(String.t()) ::
          {:ok, map()} | {:error, :expired_credential | :invalid_credential}
  def verify_access_token(token) when is_binary(token) do
    case Phoenix.Token.verify(signing_secret(), @access_token_salt, token,
           max_age: @access_token_max_age
         ) do
      {:ok, %{u: _, a: _, n: _, p: _, t: _} = payload} -> {:ok, payload}
      {:error, :expired} -> {:error, :expired_credential}
      _ -> {:error, :invalid_credential}
    end
  end

  defp path_param(%Plug.Conn{path_params: params}, key) when is_map(params),
    do: Map.get(params, key)

  defp path_param(_conn, _key), do: nil

  # A session token goes through the one door — `Sanctum.Caller.establish/2`
  # — so the memo, the door/denied refusal mapping and the tenant resolve
  # are the same ones every other surface uses (the `:tincture` surface
  # stamps auth_method `:session` in the loader). `denied` — the door
  # stopped admitting this person after the session was minted — is
  # refused; nothing here upgrades what loaded.
  defp try_sanctum_session(token) do
    case Sanctum.Caller.establish(token, surface: :tincture, refresh: false) do
      {:ok, %Context{} = ctx} ->
        {:ok, ctx}

      {:error, {:denied, _ctx}} ->
        {:error, :denied}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, :no_athanor} ->
        {:error, :no_athanor}

      {:error, _} ->
        {:error, :invalid_credential}
    end
  end

  @sensitive_query_keys ~w(_t _key _session)

  @doc """
  The credential query params this surface accepts or has to scrub.

  `Sanctum.RedactionRosterTest` holds `Cyfr.Sanitizer` to this list: the
  same names arrive again as decoded params, where the query-string scrub
  below cannot reach them.
  """
  @spec sensitive_query_keys() :: [String.t()]
  def sensitive_query_keys, do: @sensitive_query_keys

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
