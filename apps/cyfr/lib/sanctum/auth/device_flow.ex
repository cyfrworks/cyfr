defmodule Sanctum.Auth.DeviceFlow do
  @moduledoc """
  OAuth 2.0 Device Authorization Grant for CLI authentication.

  Implements the Device Flow (RFC 8628) for GitHub OAuth,
  allowing CLI users to authenticate without exposing client secrets.

  ## Usage

  This module is typically called via MCP session tool actions:
  - `device-init` - Start device flow, returns codes for user
  - `device-poll` - Poll for completion, returns session when authorized

  ## Flow

  1. Request device code from GitHub
  2. Display verification URL and user code to user (CLI responsibility)
  3. Poll for token while user authorizes in browser
  4. Fetch user info with access token
  5. Create Sanctum session

  ## Configuration

  Configure via environment variables:

      CYFR_GITHUB_CLIENT_ID=your_github_client_id

  GitHub's Device Flow does not support refresh tokens. Access tokens have a
  default expiration of 8 hours.
  """

  require Logger

  alias Sanctum.{Session, User}

  # GitHub Device Flow endpoints
  @github_device_url "https://github.com/login/device/code"
  @github_token_url "https://github.com/login/oauth/access_token"
  @github_user_url "https://api.github.com/user"

  # Default scopes
  @github_scope "read:user user:email"

  # Default polling configuration
  @default_poll_interval 5

  @type provider :: :github | String.t()
  @type device_code_response :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          expires_in: integer(),
          interval: integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Initialize device flow - request device code from provider.

  Returns device code info that should be displayed to the user.

  ## Examples

      {:ok, info} = DeviceFlow.init_device_flow("github")
      # info contains: device_code, user_code, verification_uri, expires_in, interval

  """
  @spec init_device_flow(provider()) :: {:ok, device_code_response()} | {:error, term()}
  def init_device_flow(provider) do
    provider = normalize_provider(provider)

    case get_client_id(provider) do
      nil ->
        {:error, {:client_id_not_configured, provider}}

      client_id ->
        request_device_code(provider, client_id)
    end
  end

  @doc """
  Poll for token and create session if authorized.

  Returns one of:
  - `{:ok, %{status: "pending"}}` - User hasn't authorized yet
  - `{:ok, %{status: "complete", session_id: id, user: user_info}}` - Authorized
  - `{:ok, %{status: "expired"}}` - Device code expired
  - `{:ok, %{status: "denied"}}` - User denied authorization

  ## Examples

      case DeviceFlow.poll_for_session("github", device_code) do
        {:ok, %{status: "pending"}} ->
          # Keep polling
        {:ok, %{status: "complete", session_id: sid}} ->
          # Success!
        {:ok, %{status: "expired"}} ->
          # Need to restart flow
      end

  """
  @spec poll_for_session(provider(), String.t()) :: {:ok, map()} | {:error, term()}
  def poll_for_session(provider, device_code) do
    provider = normalize_provider(provider)

    case get_client_id(provider) do
      nil ->
        {:error, {:client_id_not_configured, provider}}

      client_id ->
        case request_token(provider, client_id, device_code) do
          {:ok, tokens} ->
            # Got tokens - fetch user info and create session
            with {:ok, user_info} <- fetch_user_info(provider, tokens),
                 {:ok, session} <- create_session(user_info, provider) do
              # Exchange OAuth token for registry JWT — fail loudly but don't block login
              {registry_token, registry_error} =
                case exchange_registry_token(provider, tokens.access_token) do
                  {:ok, jwt} ->
                    # Store credentials server-side via CredentialStore
                    Compendium.Registry.CredentialStore.put(
                      user_info.id,
                      "registry.cyfr.run",
                      %{
                        type: :basic,
                        username: user_info.email || "cyfr",
                        password: jwt
                      }
                    )

                    {jwt, nil}

                  {:error, {:registry_token_exchange, reason}} ->
                    {nil, reason}
                end

              result = %{
                status: "complete",
                session_id: session.token,
                registry_token: registry_token,
                user: %{
                  id: user_info.id,
                  email: user_info.email,
                  name: user_info.name
                }
              }

              result =
                if registry_error,
                  do: Map.put(result, :registry_error, registry_error),
                  else: result

              {:ok, result}
            else
              {:error, :user_not_allowed} ->
                {:ok, %{status: "denied"}}

              error ->
                error
            end

          {:error, :authorization_pending} ->
            {:ok, %{status: "pending"}}

          {:error, :slow_down} ->
            {:ok, %{status: "pending", slow_down: true}}

          {:error, :expired_token} ->
            {:ok, %{status: "expired"}}

          {:error, :access_denied} ->
            {:ok, %{status: "denied"}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ============================================================================
  # Device Code Request
  # ============================================================================

  defp request_device_code(:github, client_id) do
    body =
      URI.encode_query(%{
        client_id: client_id,
        scope: @github_scope
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case http_post(@github_device_url, headers, body) do
      {:ok,
       %{
         "device_code" => device_code,
         "user_code" => user_code,
         "verification_uri" => verification_uri
       } = resp} ->
        {:ok,
         %{
           device_code: device_code,
           user_code: user_code,
           verification_uri: verification_uri,
           expires_in: resp["expires_in"] || 900,
           interval: resp["interval"] || @default_poll_interval
         }}

      {:ok, %{"error" => error}} ->
        {:error, {:device_code_error, error}}

      {:error, reason} ->
        {:error, {:device_code_request_failed, reason}}
    end
  end

  # ============================================================================
  # Token Request
  # ============================================================================

  defp request_token(:github, client_id, device_code) do
    body =
      URI.encode_query(%{
        client_id: client_id,
        device_code: device_code,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code"
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case http_post(@github_token_url, headers, body) do
      {:ok, %{"access_token" => access_token} = resp} ->
        {:ok,
         %{
           access_token: access_token,
           token_type: normalize_token_type(resp["token_type"]),
           scope: resp["scope"] || "",
           refresh_token: resp["refresh_token"],
           expires_in: resp["expires_in"]
         }}

      {:ok, %{"error" => "authorization_pending"}} ->
        {:error, :authorization_pending}

      {:ok, %{"error" => "slow_down"}} ->
        {:error, :slow_down}

      {:ok, %{"error" => "expired_token"}} ->
        {:error, :expired_token}

      {:ok, %{"error" => "access_denied"}} ->
        {:error, :access_denied}

      {:ok, %{"error" => error}} ->
        {:error, {:token_error, error}}

      {:error, reason} ->
        {:error, {:token_request_failed, reason}}
    end
  end

  # ============================================================================
  # User Info Fetching
  # ============================================================================

  defp fetch_user_info(:github, tokens) do
    headers = [
      {"authorization", "Bearer #{tokens.access_token}"},
      {"accept", "application/json"},
      {"user-agent", "cyfr-server"}
    ]

    case http_get(@github_user_url, headers) do
      {:ok, %{"id" => id} = user_data} ->
        # Also fetch email if not in public profile
        email = user_data["email"] || fetch_github_email(tokens.access_token)

        {:ok,
         %{
           id: to_string(id),
           email: email,
           name: user_data["name"] || user_data["login"]
         }}

      {:ok, %{"message" => message}} ->
        {:error, {:user_info_error, message}}

      {:error, reason} ->
        {:error, {:user_info_failed, reason}}
    end
  end

  defp fetch_github_email(access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/json"},
      {"user-agent", "cyfr-server"}
    ]

    case http_get("https://api.github.com/user/emails", headers) do
      {:ok, emails} when is_list(emails) ->
        case Enum.find(emails, &(&1["primary"] == true)) do
          %{"email" => email} -> email
          _ -> nil
        end

      {:ok, %{"message" => message}} ->
        Logger.warning("Failed to fetch GitHub email: #{message}")
        nil

      {:error, reason} ->
        Logger.warning("Failed to fetch GitHub email: #{inspect(reason)}")
        nil
    end
  end

  # ============================================================================
  # Session Creation
  # ============================================================================

  defp create_session(user_info, provider) do
    user = %User{
      id: user_info.id,
      email: user_info.email,
      provider: to_string(provider),
      permissions: [:*]
    }

    Session.create(user)
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  defp get_client_id(:github) do
    Application.get_env(:cyfr, :github_client_id) ||
      System.get_env("CYFR_GITHUB_CLIENT_ID")
  end

  defp normalize_provider("github"), do: :github
  defp normalize_provider(:github), do: :github
  defp normalize_provider(other), do: other

  defp normalize_token_type(nil), do: "bearer"
  defp normalize_token_type(type) when is_binary(type), do: String.downcase(type)

  # ============================================================================
  # Registry Token Exchange
  # ============================================================================

  defp exchange_registry_token(provider, access_token) do
    url = registry_token_url()

    case Jason.encode(%{access_token: access_token, provider: to_string(provider)}) do
      {:error, _} ->
        {:error, {:registry_token_exchange, "failed to encode request body"}}

      {:ok, body} ->
        headers = [
          {"content-type", "application/json"},
          {"accept", "application/json"}
        ]

        case http_post_json(url, headers, body) do
          {:ok, %{"access_token" => jwt}} when is_binary(jwt) and jwt != "" ->
            {:ok, jwt}

          {:ok, resp} ->
            Logger.error("Registry token exchange returned unexpected response: #{inspect(resp)}")

            {:error,
             {:registry_token_exchange, "unexpected response from #{url}: #{inspect(resp)}"}}

          {:error, reason} ->
            Logger.error("Registry token exchange failed: #{inspect(reason)}")
            {:error, {:registry_token_exchange, "request to #{url} failed: #{inspect(reason)}"}}
        end
    end
  end

  defp registry_token_url do
    Application.get_env(:cyfr, :registry_token_url, "https://registry.cyfr.run/v1/auth/token")
  end

  # ============================================================================
  # HTTP Client
  # ============================================================================

  defp http_post_json(url, headers, body) do
    :inets.start()
    :ssl.start()

    httpc_headers =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request = {String.to_charlist(url), httpc_headers, ~c"application/json", body}
    timeout = Application.get_env(:cyfr, :http_timeout_ms, 30_000)

    case :httpc.request(:post, request, [timeout: timeout], []) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} when status in 200..299//1 ->
        parse_json_response(resp_body)

      {:ok, {{_version, _status, _reason}, _resp_headers, resp_body}} ->
        case parse_json_response(resp_body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, {:http_error, to_string(resp_body)}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp http_post(url, headers, body) do
    :inets.start()
    :ssl.start()

    # Convert headers to charlist format for :httpc
    httpc_headers =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request =
      {String.to_charlist(url), httpc_headers, ~c"application/x-www-form-urlencoded", body}

    timeout = Application.get_env(:cyfr, :http_timeout_ms, 30_000)

    case :httpc.request(:post, request, [timeout: timeout], []) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} when status in 200..299//1 ->
        parse_json_response(resp_body)

      {:ok, {{_version, _status, _reason}, _resp_headers, resp_body}} ->
        # Try to parse error response as JSON (OAuth returns structured errors)
        case parse_json_response(resp_body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, {:http_error, to_string(resp_body)}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp http_get(url, headers) do
    :inets.start()
    :ssl.start()

    httpc_headers =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request = {String.to_charlist(url), httpc_headers}
    timeout = Application.get_env(:cyfr, :http_timeout_ms, 30_000)

    case :httpc.request(:get, request, [timeout: timeout], []) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} when status in 200..299//1 ->
        parse_json_response(resp_body)

      {:ok, {{_version, _status, _reason}, _resp_headers, resp_body}} ->
        case parse_json_response(resp_body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, {:http_error, to_string(resp_body)}}
        end

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_json_response(body) do
    body
    |> to_string()
    |> Jason.decode()
  end
end
