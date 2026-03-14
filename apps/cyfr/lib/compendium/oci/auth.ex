defmodule Compendium.OCI.Auth do
  @moduledoc """
  OCI Distribution authentication.

  Handles the Docker/OCI token-based authentication flow:
  1. Client makes a request, gets 401 with `Www-Authenticate: Bearer realm=...`
  2. Client exchanges credentials at the realm endpoint for a bearer token
  3. Client retries the original request with `Authorization: Bearer <token>`

  Credential resolution order:
  1. App config (`:compendium, :registry`)
  2. `~/.cyfr/oci-credentials.json`
  3. `~/.docker/config.json` fallback
  """

  require Logger

  @token_cache :compendium_oci_token_cache

  @doc """
  Start the token cache ETS table. Called from Application.start/2.
  """
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.whereis(@token_cache) == :undefined do
      :ets.new(@token_cache, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Get an authorization header for a registry request.

  Returns `{:ok, headers}` with an Authorization header if credentials are
  available, or `{:ok, []}` for anonymous access.
  """
  @spec auth_headers(String.t(), String.t()) :: {:ok, [{String.t(), String.t()}]}
  def auth_headers(registry, repository) do
    case get_cached_token(registry, repository) do
      {:ok, token} ->
        {:ok, [{"authorization", "Bearer #{token}"}]}

      :miss ->
        case resolve_credentials(registry) do
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
  @spec handle_challenge(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, term()}
  def handle_challenge(registry, repository, response_headers) do
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
            exchange_token(registry, repository, params)

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

  Checks in order:
  1. App config `:compendium, :registry`
  2. `~/.cyfr/oci-credentials.json`
  3. `~/.docker/config.json`
  """
  @spec resolve_credentials(String.t()) :: {:ok, %{username: String.t(), password: String.t()}} | :anonymous
  def resolve_credentials(registry) do
    with :not_found <- from_app_config(registry),
         :not_found <- from_cyfr_credentials(registry),
         :not_found <- from_docker_config(registry) do
      :anonymous
    end
  end

  # ============================================================================
  # Token Cache
  # ============================================================================

  defp get_cached_token(registry, repository) do
    key = {registry, repository}

    case safe_ets_lookup(key) do
      [{^key, token, expires_at}] ->
        now = System.system_time(:second)

        if expires_at > now + 30 do
          {:ok, token}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  @doc false
  def cache_token(registry, repository, token, expires_in) do
    key = {registry, repository}
    expires_at = System.system_time(:second) + (expires_in || 300)

    if :ets.whereis(@token_cache) != :undefined do
      :ets.insert(@token_cache, {key, token, expires_at})
    end

    :ok
  end

  defp safe_ets_lookup(key) do
    if :ets.whereis(@token_cache) != :undefined do
      :ets.lookup(@token_cache, key)
    else
      []
    end
  end

  # ============================================================================
  # Token Exchange
  # ============================================================================

  defp exchange_token(registry, repository, params) do
    realm = params["realm"]
    service = params["service"]
    scope = params["scope"] || "repository:#{repository}:pull,push"

    url =
      realm
      |> URI.parse()
      |> Map.put(:query, URI.encode_query(%{
        "service" => service || registry,
        "scope" => scope
      }))
      |> URI.to_string()

    headers =
      case resolve_credentials(registry) do
        {:ok, %{username: u, password: p}} ->
          [{"authorization", "Basic #{Base.encode64("#{u}:#{p}")}"}]

        :anonymous ->
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
  # Credential Resolution
  # ============================================================================

  defp from_app_config(registry) do
    case Application.get_env(:cyfr, :registry) do
      nil ->
        :not_found

      config ->
        config_url = Keyword.get(config, :url, "")
        username = Keyword.get(config, :username)
        password = Keyword.get(config, :password)

        if username && password && registry_matches?(config_url, registry) do
          {:ok, %{username: username, password: password}}
        else
          :not_found
        end
    end
  end

  defp from_cyfr_credentials(registry) do
    path = Path.join([System.user_home!(), ".cyfr", "oci-credentials.json"])
    read_credentials_file(path, registry)
  end

  defp from_docker_config(registry) do
    path = Path.join([System.user_home!(), ".docker", "config.json"])

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"auths" => auths}} ->
            find_docker_auth(auths, registry)

          _ ->
            :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  defp read_credentials_file(path, registry) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"registries" => registries}} ->
            case Map.get(registries, registry) do
              %{"username" => u, "password" => p} when is_binary(u) and is_binary(p) ->
                {:ok, %{username: u, password: p}}

              _ ->
                :not_found
            end

          _ ->
            :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  defp find_docker_auth(auths, registry) do
    # Docker config uses various key formats: "registry.io", "https://registry.io/v1/", etc.
    match =
      Enum.find(auths, fn {key, _val} ->
        registry_matches?(key, registry)
      end)

    case match do
      {_key, %{"auth" => auth_b64}} when is_binary(auth_b64) ->
        case Base.decode64(auth_b64) do
          {:ok, decoded} ->
            case String.split(decoded, ":", parts: 2) do
              [username, password] ->
                {:ok, %{username: username, password: password}}

              _ ->
                :not_found
            end

          :error ->
            :not_found
        end

      {_key, %{"username" => u, "password" => p}} when is_binary(u) and is_binary(p) ->
        {:ok, %{username: u, password: p}}

      _ ->
        :not_found
    end
  end

  defp registry_matches?(config_url, registry) do
    # Normalize both for comparison
    normalized_config = config_url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
    normalized_registry = registry |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
    normalized_config == normalized_registry
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
