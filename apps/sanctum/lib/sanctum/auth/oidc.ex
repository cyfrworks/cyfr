# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OIDC do
  @moduledoc """
  The OpenID Connect issuer of a company's sign-in
  (`Sanctum.CompanyLogin.Issuer`), when this CYFR requires one and WorkOS
  is not configured. It signs no one in here and confirms nothing: a
  person signs in with their account (`Sanctum.SignIn`), and the company
  sign-in is a standing condition on them.

  ## Configuration

  Offered exactly when all three are set; a partly set issuer refuses the
  boot:

      export CYFR_OIDC_ISSUER=https://auth.example.com
      export CYFR_OIDC_CLIENT_ID=xxx
      export CYFR_OIDC_CLIENT_SECRET=xxx

  ## The exchange

    * `authorize_url/2` asks the issuer for an ordinary login, neither
      `prompt=login` nor `max_age=0`, carrying the attempt's state, nonce
      and PKCE challenge, with the redirect URI
      `<origin>/auth/company/callback`, which the issuer lists;
    * `complete/2` redeems the code for the ID token `Oidcc` validates,
      and answers its `sub` under the configured issuer and client id
      once the token's issuer is this one and its nonce the attempt's.

  The exchange with the issuer is `Sanctum.Auth.OIDC.Oidcc`'s. A test
  stands in its own issuer through `:sanctum, :oidc_reauth_client`, a seam
  deliberately undeclared in config: every check of the answer is this
  module's either way.
  """

  @behaviour Sanctum.CompanyLogin.Issuer

  defmodule Oidcc do
    @moduledoc """
    The exchange a company sign-in makes with the issuer, over `Oidcc`,
    against the `:cyfr_oidc` provider configuration worker
    `ueberauth_oidcc` starts from the issuer `runtime.exs` configures,
    with the client id and secret `runtime.exs` pins
    (`Sanctum.Auth.OIDC.client_credentials/0`):

      * `authorize_url/1` — the issuer's authorization URL, for a request's
        `redirect_uri`, `nonce`, `state` and `pkce_verifier`: a login
        forced fresh unless the request says `fresh: false`;
      * `redeem/2` — the claims of the ID token a code redeems for,
        validated for signature, audience, expiry and the request's nonce.

    A test's stand-in (`:sanctum, :oidc_reauth_client`) answers the same
    two functions.
    """

    @doc "The issuer's authorization URL, for a login forced fresh unless `fresh: false`."
    @spec authorize_url(map()) :: {:ok, String.t()} | {:error, :unavailable}
    def authorize_url(request) do
      with {:ok, {client_id, client_secret}} <- Sanctum.Auth.OIDC.client_credentials() do
        case Elixir.Oidcc.create_redirect_url(:cyfr_oidc, client_id, client_secret, %{
               redirect_uri: request.redirect_uri,
               nonce: request.nonce,
               state: request.state,
               pkce_verifier: request.pkce_verifier,
               scopes: ["openid"],
               url_extension: fresh(request)
             }) do
          {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
          {:error, _reason} -> {:error, :unavailable}
        end
      end
    end

    @doc "The validated ID token claims `code` redeems for."
    @spec redeem(String.t(), map()) :: {:ok, map()} | {:error, :reauth_refused | :unavailable}
    def redeem(code, request) do
      with {:ok, {client_id, client_secret}} <- Sanctum.Auth.OIDC.client_credentials() do
        case Elixir.Oidcc.retrieve_token(code, :cyfr_oidc, client_id, client_secret, %{
               redirect_uri: request.redirect_uri,
               nonce: request.nonce,
               pkce_verifier: request.pkce_verifier
             }) do
          {:ok, token} -> id_claims(token)
          {:error, _reason} -> {:error, :reauth_refused}
        end
      end
    end

    defp fresh(%{fresh: false}), do: []
    defp fresh(_request), do: [{"prompt", "login"}, {"max_age", "0"}]

    # An answer with no ID token carries no `nonce` or `auth_time`, so it
    # proves nothing. `Oidcc.Token`'s type omits that case, which `oidcc`
    # answers with the atom `none`, so the field is read, not matched.
    defp id_claims(token) do
      case Map.get(token, :id) do
        %{claims: claims} when is_map(claims) -> {:ok, claims}
        _no_id_token -> {:error, :reauth_refused}
      end
    end
  end

  @impl Sanctum.CompanyLogin.Issuer
  def authorize_url(attempt, state) do
    client().authorize_url(%{
      redirect_uri: attempt.redirect_uri,
      nonce: attempt.nonce,
      state: state,
      pkce_verifier: attempt.pkce_verifier,
      fresh: false
    })
  end

  @impl Sanctum.CompanyLogin.Issuer
  def complete(code, %{nonce: nonce} = attempt) when is_binary(nonce) do
    request = %{
      redirect_uri: attempt.redirect_uri,
      nonce: nonce,
      pkce_verifier: attempt.pkce_verifier
    }

    with {:ok, {client_id, _secret}} <- client_credentials(),
         {:ok, claims} <- client().redeem(code, request) do
      company_subject(claims, nonce, client_id)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _refused} -> {:error, :issuer_refused}
    end
  end

  def complete(_code, _attempt), do: {:error, :issuer_refused}

  # The token is this issuer's, for this attempt; its subject is the one
  # the issuer names the person by, never an email.
  defp company_subject(%{"iss" => iss, "sub" => sub, "nonce" => nonce}, nonce, client_id)
       when is_binary(sub) and sub != "" do
    case issuer() do
      ^iss -> {:ok, %{configuration: {:oidc, iss, client_id}, subject: sub}}
      _another -> {:error, :issuer_refused}
    end
  end

  defp company_subject(_claims, _nonce, _client_id), do: {:error, :issuer_refused}

  @doc """
  The operator-configured issuer (`:sanctum, :oidc_issuer`, pinned at boot
  from `CYFR_OIDC_ISSUER`), or `nil` when none is set.
  """
  @spec issuer() :: String.t() | nil
  def issuer, do: Application.get_env(:sanctum, :oidc_issuer)

  @doc """
  The client id and secret of the configured issuer (`:sanctum,
  :oidc_client`, pinned at boot from `CYFR_OIDC_CLIENT_ID` and
  `CYFR_OIDC_CLIENT_SECRET`). `{:error, :unavailable}` when this CYFR
  names no issuer.
  """
  @spec client_credentials() :: {:ok, {String.t(), String.t()}} | {:error, :unavailable}
  def client_credentials do
    case Application.get_env(:sanctum, :oidc_client) do
      %{client_id: id, client_secret: secret}
      when is_binary(id) and id != "" and is_binary(secret) ->
        {:ok, {id, secret}}

      _none ->
        {:error, :unavailable}
    end
  end

  defp client, do: Application.get_env(:sanctum, :oidc_reauth_client, __MODULE__.Oidcc)
end
