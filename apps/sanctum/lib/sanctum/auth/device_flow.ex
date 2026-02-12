defmodule Sanctum.Auth.DeviceFlow do
  @moduledoc """
  OAuth 2.0 Device Authorization Grant for CLI authentication.

  Implements the Device Flow (RFC 8628) for GitHub and Google OAuth providers,
  allowing CLI users to authenticate without exposing client secrets.

  ## Usage

  This module is typically called via MCP session tool actions:
  - `device-init` - Start device flow, returns codes for user
  - `device-poll` - Poll for completion, returns session when authorized

  ## Flow

  1. Request device code from provider
  2. Display verification URL and user code to user (CLI responsibility)
  3. Poll for token while user authorizes in browser
  4. Fetch user info with access token
  5. Create Sanctum session

  ## Configuration

  Configure via environment variables:

      CYFR_GITHUB_CLIENT_ID=your_github_client_id
      CYFR_GOOGLE_CLIENT_ID=your_google_client_id

  ## Provider-Specific Notes

  ### GitHub

  GitHub's Device Flow does not support refresh tokens. Access tokens have a
  default expiration of 8 hours.

  ### Google

  Google's Device Flow supports refresh tokens for longer-lived sessions.
  """

  require Logger

  alias Sanctum.{Session, User}

  # GitHub Device Flow endpoints
  @github_device_url "https://github.com/login/device/code"
  @github_token_url "https://github.com/login/oauth/access_token"
  @github_user_url "https://api.github.com/user"

  # Google Device Flow endpoints
  @google_device_url "https://oauth2.googleapis.com/device/code"
  @google_token_url "https://oauth2.googleapis.com/token"
  @google_userinfo_url "https://www.googleapis.com/oauth2/v3/userinfo"

  # Default scopes
  @github_scope "read:user user:email"
  @google_scope "openid email profile"

  # Default polling configuration
  @default_poll_interval 5

  @type provider :: :github | :google | String.t()
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
              {:ok, %{
                status: "complete",
                session_id: session.token,
                user: %{
                  id: user_info.id,
                  email: user_info.email,
                  name: user_info.name
                }
              }}
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
    body = URI.encode_query(%{
      client_id: client_id,
      scope: @github_scope
    })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case http_post(@github_device_url, headers, body) do
      {:ok, %{"device_code" => device_code, "user_code" => user_code, "verification_uri" => verification_uri} = resp} ->
        {:ok, %{
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

  defp request_device_code(:google, client_id) do
    body = URI.encode_query(%{
      client_id: client_id,
      scope: @google_scope
    })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    case http_post(@google_device_url, headers, body) do
      {:ok, %{"device_code" => device_code, "user_code" => user_code} = resp} ->
        # Google uses verification_url, but may also provide verification_uri
        verification_uri = resp["verification_url"] || resp["verification_uri"]

        if verification_uri do
          {:ok, %{
            device_code: device_code,
            user_code: user_code,
            verification_uri: verification_uri,
            expires_in: resp["expires_in"] || 1800,
            interval: resp["interval"] || @default_poll_interval
          }}
        else
          {:error, {:device_code_error, :missing_verification_uri}}
        end

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
    body = URI.encode_query(%{
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
        {:ok, %{
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

  defp request_token(:google, client_id, device_code) do
    body = URI.encode_query(%{
      client_id: client_id,
      device_code: device_code,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code"
    })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    case http_post(@google_token_url, headers, body) do
      {:ok, %{"access_token" => access_token} = resp} ->
        {:ok, %{
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

        {:ok, %{
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

  defp fetch_user_info(:google, tokens) do
    headers = [
      {"authorization", "Bearer #{tokens.access_token}"}
    ]

    case http_get(@google_userinfo_url, headers) do
      {:ok, %{"sub" => id} = user_data} ->
        {:ok, %{
          id: to_string(id),
          email: user_data["email"],
          name: user_data["name"]
        }}

      {:ok, %{"error" => error}} ->
        {:error, {:user_info_error, error}}

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
    Application.get_env(:sanctum, :github_client_id) ||
      System.get_env("CYFR_GITHUB_CLIENT_ID")
  end

  defp get_client_id(:google) do
    Application.get_env(:sanctum, :google_client_id) ||
      System.get_env("CYFR_GOOGLE_CLIENT_ID")
  end

  defp normalize_provider("github"), do: :github
  defp normalize_provider("google"), do: :google
  defp normalize_provider(:github), do: :github
  defp normalize_provider(:google), do: :google
  defp normalize_provider(other), do: other

  defp normalize_token_type(nil), do: "bearer"
  defp normalize_token_type(type) when is_binary(type), do: String.downcase(type)

  # ============================================================================
  # HTTP Client
  # ============================================================================

  defp http_post(url, headers, body) do
    :inets.start()
    :ssl.start()

    # Convert headers to charlist format for :httpc
    httpc_headers = Enum.map(headers, fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)

    request = {String.to_charlist(url), httpc_headers, ~c"application/x-www-form-urlencoded", body}
    timeout = Application.get_env(:sanctum, :http_timeout_ms, 30_000)

    case :httpc.request(:post, request, [timeout: timeout], []) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} when status in 200..299 ->
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

    httpc_headers = Enum.map(headers, fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)

    request = {String.to_charlist(url), httpc_headers}
    timeout = Application.get_env(:sanctum, :http_timeout_ms, 30_000)

    case :httpc.request(:get, request, [timeout: timeout], []) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} when status in 200..299 ->
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
