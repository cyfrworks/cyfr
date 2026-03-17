defmodule Compendium.OCI.Auth do
  @moduledoc """
  OCI Distribution authentication.

  Handles the Docker/OCI token-based authentication flow:
  1. Client makes a request, gets 401 with `Www-Authenticate: Bearer realm=...`
  2. Client exchanges credentials at the realm endpoint for a bearer token
  3. Client retries the original request with `Authorization: Bearer <token>`

  Credentials are resolved from `Compendium.Registry.CredentialStore` (encrypted,
  server-side storage). All operations accept an optional `Sanctum.Context` for
  per-user credential resolution.
  """

  require Logger

  alias Compendium.Registry.CredentialStore

  @doc """
  Get an authorization header for a registry request.

  Returns `{:ok, headers}` with an Authorization header if credentials are
  available, or `{:ok, []}` for anonymous access.
  """
  @spec auth_headers(String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, [{String.t(), String.t()}]}
  def auth_headers(registry, repository, ctx \\ nil) do
    case get_cached_token(registry, repository) do
      {:ok, token} ->
        {:ok, [{"authorization", "Bearer #{token}"}]}

      :miss ->
        case resolve_credentials(registry, ctx) do
          {:ok, %{type: :basic, username: username, password: password}} ->
            basic = Base.encode64("#{username}:#{password}")
            {:ok, [{"authorization", "Basic #{basic}"}]}

          {:ok, %{type: :bearer, token: token}} ->
            {:ok, [{"authorization", "Bearer #{token}"}]}

          {:ok, %{type: :oauth2_client} = cred} ->
            exchange_client_credentials(registry, repository, cred)

          {:ok, %{type: :key_pair}} ->
            Logger.warning("[OCI.Auth] key_pair auth not yet implemented")
            {:ok, []}

          # Legacy map format (from Identity resolution fallback)
          {:ok, %{username: username, password: password}} ->
            basic = Base.encode64("#{username}:#{password}")
            {:ok, [{"authorization", "Basic #{basic}"}]}

          :anonymous ->
            {:ok, []}
        end
    end
  end

  @doc """
  Handle a 401 response by parsing the WWW-Authenticate challenge,
  exchanging credentials for a token, and caching it.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec handle_challenge(
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          Sanctum.Context.t() | nil
        ) ::
          {:ok, String.t()} | {:error, term()}
  def handle_challenge(registry, repository, response_headers, ctx \\ nil) do
    www_auth =
      Enum.find_value(response_headers, fn
        {"www-authenticate", value} -> value
        _ -> nil
      end)

    case www_auth do
      nil ->
        {:error, "No WWW-Authenticate header in 401 response"}

      challenge ->
        case parse_bearer_challenge(challenge) do
          {:ok, params} ->
            exchange_token(registry, repository, params, ctx)

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Parse a `WWW-Authenticate: Bearer realm=...,service=...,scope=...` header.
  """
  @spec parse_bearer_challenge(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_bearer_challenge(challenge) do
    trimmed = String.trim(challenge)

    cond do
      String.starts_with?(trimmed, "Bearer ") ->
        params_str = String.trim_leading(trimmed, "Bearer ")
        params = parse_challenge_params(params_str)

        case params["realm"] do
          nil -> {:error, "Bearer challenge missing realm parameter"}
          _ -> {:ok, params}
        end

      String.starts_with?(trimmed, "Basic") ->
        {:error, "Basic auth challenge — use credentials directly"}

      true ->
        {:error, "Unsupported auth challenge: #{trimmed}"}
    end
  end

  @doc """
  Resolve credentials for a registry.

  Uses `CredentialStore` as the single source of truth.
  When `ctx` is provided, looks up by user_id first.
  When `ctx` is nil, looks up any credential for the registry.
  """
  @spec resolve_credentials(String.t(), Sanctum.Context.t() | nil) ::
          {:ok, map()} | :anonymous
  def resolve_credentials(registry, ctx \\ nil) do
    case ctx do
      %Sanctum.Context{user_id: user_id} when is_binary(user_id) ->
        case CredentialStore.get(user_id, registry) do
          {:ok, cred} -> {:ok, cred}
          :not_found -> resolve_any_credential(registry)
        end

      _ ->
        resolve_any_credential(registry)
    end
  end

  # ============================================================================
  # Token Cache
  # ============================================================================

  defp get_cached_token(registry, repository) do
    key = {:oci_token, registry, repository}

    case Arca.Cache.get(key) do
      {:ok, token} -> {:ok, token}
      :miss -> :miss
    end
  end

  @doc false
  def cache_token(registry, repository, token, expires_in) do
    key = {:oci_token, registry, repository}
    # Subtract 30s buffer to avoid using nearly-expired tokens
    ttl_ms = max(((expires_in || 300) - 30) * 1_000, 1_000)
    Arca.Cache.put(key, token, ttl_ms)
    :ok
  end

  # ============================================================================
  # Token Exchange
  # ============================================================================

  defp exchange_token(registry, repository, params, ctx) do
    realm = params["realm"]
    service = params["service"]
    scope = params["scope"] || "repository:#{repository}:pull,push"

    url =
      realm
      |> URI.parse()
      |> Map.put(
        :query,
        URI.encode_query(%{
          "service" => service || registry,
          "scope" => scope
        })
      )
      |> URI.to_string()

    headers =
      case resolve_credentials(registry, ctx) do
        {:ok, %{type: :basic, username: u, password: p}} ->
          [{"authorization", "Basic #{Base.encode64("#{u}:#{p}")}"}]

        {:ok, %{type: :bearer, token: t}} ->
          [{"authorization", "Bearer #{t}"}]

        {:ok, %{username: u, password: p}} ->
          [{"authorization", "Basic #{Base.encode64("#{u}:#{p}")}"}]

        _ ->
          []
      end

    request = Finch.build(:get, url, headers)

    case Finch.request(request, Compendium.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"token" => token} = resp} ->
            expires_in = resp["expires_in"] || 300
            cache_token(registry, repository, token, expires_in)
            {:ok, token}

          {:ok, %{"access_token" => token} = resp} ->
            expires_in = resp["expires_in"] || 300
            cache_token(registry, repository, token, expires_in)
            {:ok, token}

          {:ok, _} ->
            {:error, "Token response missing 'token' or 'access_token' field"}

          {:error, reason} ->
            {:error, "Failed to parse token response: #{inspect(reason)}"}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "Token exchange failed with status #{status}: #{body}"}

      {:error, reason} ->
        {:error, "Token exchange request failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Client Credentials Exchange (oauth2_client type)
  # ============================================================================

  defp exchange_client_credentials(registry, repository, cred) do
    token_url = cred[:token_url] || cred["token_url"]
    client_id = cred[:client_id] || cred["client_id"]
    client_secret = cred[:client_secret] || cred["client_secret"]

    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => client_id,
        "client_secret" => client_secret,
        "scope" => "repository:#{repository}:pull,push"
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    request = Finch.build(:post, token_url, headers, body)

    case Finch.request(request, Compendium.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"access_token" => token} = resp} ->
            expires_in = resp["expires_in"] || 300
            cache_token(registry, repository, token, expires_in)
            {:ok, [{"authorization", "Bearer #{token}"}]}

          _ ->
            {:ok, []}
        end

      _ ->
        Logger.warning("[OCI.Auth] oauth2_client credential exchange failed for #{registry}")
        {:ok, []}
    end
  end

  # ============================================================================
  # Credential Resolution
  # ============================================================================

  defp resolve_any_credential(registry) do
    case CredentialStore.get_for_registry(registry) do
      {:ok, cred} -> {:ok, cred}
      :not_found -> :anonymous
    end
  end

  # ============================================================================
  # Challenge Parsing
  # ============================================================================

  defp parse_challenge_params(str) do
    # Parse key="value" pairs, handling commas within quoted values
    Regex.scan(~r/(\w+)="([^"]*)"/, str)
    |> Enum.into(%{}, fn [_, key, value] -> {key, value} end)
  end
end
