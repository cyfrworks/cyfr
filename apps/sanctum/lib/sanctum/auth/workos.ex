# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.WorkOS do
  @moduledoc """
  WorkOS standalone single sign-on as a company's issuer
  (`Sanctum.CompanyLogin.Issuer`).

  Configured by `CYFR_WORKOS_CLIENT_ID`, `CYFR_WORKOS_API_KEY` and
  `CYFR_WORKOS_ORGANIZATION`, all three or none (`:sanctum, :workos`).

  WorkOS's standalone SSO is not OpenID Connect toward CYFR: its
  authorize endpoint answers a code, and posting that code to
  `/sso/token` with the API key as the client secret answers an access
  token and a profile, with no ID token. So the company sign-in's state,
  attempt and binding are `Sanctum.CompanyLogin`'s, and none of the OpenID
  Connect token checks apply:

    * `authorize_url/2` is `https://api.workos.com/sso/authorize` with the
      client id, the redirect URI, `response_type=code`, the attempt's
      state and the configured organization;
    * `complete/2` posts the code to `/sso/token` through
      `Sanctum.Egress`'s pinned request, from the server, and accepts the
      profile only when its `organization_id` is the configured
      organization. The subject is the profile's `id`, the key WorkOS says
      to persist, and the configuration names the organization and the
      connection the profile came through. The profile's email is never
      read.

  The API's base URL is `https://api.workos.com`; a test stands in its own
  at `:sanctum, :workos_api_url`, a seam deliberately undeclared in
  config.
  """

  @behaviour Sanctum.CompanyLogin.Issuer

  require Logger

  @api "https://api.workos.com"
  @request_ms 15_000
  @response_bytes 65_536

  @doc "The configured WorkOS organization, or nil when WorkOS is not configured."
  @spec organization() :: String.t() | nil
  def organization, do: settings()[:organization]

  @impl Sanctum.CompanyLogin.Issuer
  def authorize_url(attempt, state) do
    case settings() do
      %{client_id: client_id, organization: organization} ->
        query =
          URI.encode_query(%{
            "client_id" => client_id,
            "redirect_uri" => attempt.redirect_uri,
            "response_type" => "code",
            "state" => state,
            "organization" => organization
          })

        {:ok, api() <> "/sso/authorize?" <> query}

      _unconfigured ->
        {:error, :unavailable}
    end
  end

  @impl Sanctum.CompanyLogin.Issuer
  def complete(code, _attempt) do
    case settings() do
      %{client_id: client_id, api_key: api_key, organization: organization} ->
        body =
          URI.encode_query(%{
            "client_id" => client_id,
            "client_secret" => api_key,
            "grant_type" => "authorization_code",
            "code" => code
          })

        :post
        |> Sanctum.Egress.pinned_request(
          api() <> "/sso/token",
          [
            {"content-type", "application/x-www-form-urlencoded"},
            {"accept", "application/json"}
          ],
          body,
          private_policy: :operator,
          receive_timeout: @request_ms,
          max_response_bytes: @response_bytes
        )
        |> profile(organization)

      _unconfigured ->
        {:error, :unavailable}
    end
  end

  defp profile({:ok, 200, _headers, body}, organization) do
    case Jason.decode(body) do
      {:ok,
       %{
         "profile" => %{
           "id" => subject,
           "organization_id" => answered,
           "connection_id" => connection
         }
       }}
      when is_binary(subject) and subject != "" and is_binary(connection) and connection != "" ->
        if answered == organization,
          do: {:ok, %{configuration: {:workos, organization, connection}, subject: subject}},
          else: {:error, :wrong_organization}

      _malformed ->
        Logger.warning("[Sanctum.Auth.WorkOS] the token endpoint answered no usable profile")
        {:error, :issuer_refused}
    end
  end

  defp profile({:ok, status, _headers, _body}, _organization) when status in 400..499 do
    Logger.info("[Sanctum.Auth.WorkOS] the token endpoint refused the code with HTTP #{status}")
    {:error, :issuer_refused}
  end

  defp profile({:ok, status, _headers, _body}, _organization) do
    Logger.warning("[Sanctum.Auth.WorkOS] the token endpoint answered HTTP #{status}")
    {:error, :unavailable}
  end

  defp profile({:error, reason}, _organization) do
    Logger.warning(
      "[Sanctum.Auth.WorkOS] the token endpoint could not be reached: " <>
        Prima.LogFilter.inspect_reason(reason)
    )

    {:error, :unavailable}
  end

  defp settings, do: Application.get_env(:sanctum, :workos) || %{}
  defp api, do: Application.get_env(:sanctum, :workos_api_url, @api)
end
