# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  alias Sanctum.Auth.Identity
  alias Sanctum.{Context, Session}

  # Device-flow endpoints — per-provider URLs and scopes.
  @provider_urls %{
    github: %{
      device: "https://github.com/login/device/code",
      token: "https://github.com/login/oauth/access_token",
      userinfo: "https://api.github.com/user",
      scope: "read:user user:email"
    },
    google: %{
      device: "https://oauth2.googleapis.com/device/code",
      token: "https://oauth2.googleapis.com/token",
      userinfo: "https://www.googleapis.com/oauth2/v3/userinfo",
      scope: "openid email profile"
    }
  }

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
  Poll for the IdP token; once authorized, run the door, sign-in and the
  one sign-in decision (`Sanctum.SignIn.complete/3`).

  Returns one of:
  - `{:ok, %{status: "pending"}}` - User hasn't authorized yet
  - `{:ok, %{status: "complete", session_token: token, user: user_info,
      needs_personal_namespace: bool, suggested_username: string | nil,
      needs_policy_acceptance: true (optional), required_policy_version: string | nil,
      access_token: string (optional), probe_error: string (optional),
      reauthenticate: true (optional),
      credential_store_warnings: [slug] (optional)}}` - Authorized.
    `needs_personal_namespace: true` (first sign-in, no namespace on
    cyfr.run yet) and `needs_policy_acceptance: true` are the two cases that
    carry `access_token`, once, so the CLI can forward it to
    `registry.claim_personal` / `registry.legal_accept`; consumer discards
    it after the call. `reauthenticate: true` (with no `session_token`): the
    IdP token was refused; the CLI restarts the flow. `probe_error` without
    `reauthenticate`: a returning person is signed in but the cyfr.run probe
    failed transiently — push tokens refresh on the next probe.
    `credential_store_warnings` lists namespaces whose push tokens were
    issued but not cached locally.
  - `{:ok, %{status: "registry_unavailable", message: string}}` - A
    first-time person and cyfr.run could not be reached: nothing was set
    up, no session; run `cyfr login` again.
  - `{:ok, %{status: "expired"}}` - Device code expired
  - `{:ok, %{status: "denied"}}` - User denied authorization, or the door
    refused them

  ## Examples

      case DeviceFlow.poll_for_session("github", device_code) do
        {:ok, %{status: "pending"}} ->
          # Keep polling
        {:ok, %{status: "complete", session_token: token}} ->
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
            # Got tokens: user info, the door, what sign-in records, then the
            # one decision both sign-in paths take.
            with {:ok, user_info} <- fetch_user_info(provider, tokens),
                 {:ok, user, ctx} <- admit(user_info, provider) do
              {:ok, complete(user, ctx, user_info, provider, tokens.access_token)}
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

  @doc """
  Poll for a raw provider access token without creating a Sanctum
  session. Used by the closed-platform appeal flow: an appellant has
  already lost their push tokens (the takedown cascade revoked them),
  but they still need to prove they are the action's rightful subject
  to cyfr.run's `POST /v1/appeals`. cyfr.run verifies the access_token
  against the provider's userinfo endpoint, so we surface it here
  without the session-creation side effects.

  Returns one of:
  - `{:ok, %{status: "pending"}}`
  - `{:ok, %{status: "complete", access_token: string, subject: string,
      provider: provider}}`
  - `{:ok, %{status: "expired"}}`
  - `{:ok, %{status: "denied"}}`
  - `{:error, reason}`
  """
  @spec poll_for_access_token(provider(), String.t()) :: {:ok, map()} | {:error, term()}
  def poll_for_access_token(provider, device_code) do
    provider = normalize_provider(provider)

    case get_client_id(provider) do
      nil ->
        {:error, {:client_id_not_configured, provider}}

      client_id ->
        case request_token(provider, client_id, device_code) do
          {:ok, tokens} ->
            with {:ok, user_info} <- fetch_user_info(provider, tokens) do
              {:ok,
               %{
                 status: "complete",
                 access_token: tokens.access_token,
                 subject: to_string(user_info.id),
                 provider: provider
               }}
            else
              error -> error
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

  defp request_device_code(provider, client_id) when provider in [:github, :google] do
    urls = @provider_urls[provider]

    body =
      URI.encode_query(%{
        client_id: client_id,
        scope: urls.scope
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case http_post(urls.device, headers, body) do
      {:ok, %{"device_code" => device_code} = resp} ->
        {:ok,
         %{
           device_code: device_code,
           # GitHub returns `user_code` + `verification_uri`; Google returns
           # `user_code` + `verification_url`. Normalize to the GitHub shape.
           user_code: resp["user_code"],
           verification_uri: resp["verification_uri"] || resp["verification_url"],
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

  defp request_token(provider, client_id, device_code) when provider in [:github, :google] do
    urls = @provider_urls[provider]

    # Google's device-flow token endpoint REQUIRES client_secret in the body
    # or returns {"error": "invalid_request"}; GitHub's device-flow tokens
    # exchange doesn't accept a client_secret at all. Conditional merge keeps
    # both paths spec-correct.
    base_params = %{
      client_id: client_id,
      device_code: device_code,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code"
    }

    params =
      case get_client_secret(provider) do
        secret when is_binary(secret) and secret != "" ->
          Map.put(base_params, :client_secret, secret)

        _ ->
          base_params
      end

    body = URI.encode_query(params)

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case http_post(urls.token, headers, body) do
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

    case http_get(@provider_urls[:github].userinfo, headers) do
      {:ok, %{"id" => id} = user_data} ->
        # The public profile email carries no verification signal; the
        # primary from /user/emails does, and the door needs it.
        {email, verified} =
          case fetch_github_email(tokens.access_token) do
            {:ok, primary, verified} -> {primary, verified}
            :none -> {user_data["email"], :unknown}
          end

        {:ok,
         %{
           id: to_string(id),
           email: email,
           verified: verified,
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
      {"authorization", "Bearer #{tokens.access_token}"},
      {"accept", "application/json"}
    ]

    case http_get(@provider_urls[:google].userinfo, headers) do
      {:ok, %{"sub" => sub, "email_verified" => true} = user_data} ->
        {:ok,
         %{
           id: to_string(sub),
           email: user_data["email"],
           verified: true,
           name: user_data["name"] || user_data["given_name"] || user_data["email"]
         }}

      {:ok, %{"sub" => _sub, "email_verified" => false}} ->
        {:error, {:user_info_error, "Google account email is not verified"}}

      {:ok, %{"error" => error}} ->
        {:error, {:user_info_error, error}}

      {:ok, _other} ->
        {:error, {:user_info_error, "unexpected Google userinfo response"}}

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
          %{"email" => email} = primary -> {:ok, email, primary["verified"] == true}
          _ -> :none
        end

      {:ok, %{"message" => message}} ->
        Logger.warning("Failed to fetch GitHub email: #{message}")
        :none

      {:error, reason} ->
        Logger.warning("Failed to fetch GitHub email: #{inspect(reason)}")
        :none
    end
  end

  # ============================================================================
  # Session Creation
  # ============================================================================

  # The door runs before the session exists and before cyfr.run hears of the
  # identity: a refused sign-in leaves no row and makes no call.
  defp admit(user_info, provider) do
    user_id = Identity.builtin_user_id(provider, user_info.id)
    user_info = Map.merge(user_info, %{id: user_id, provider: provider})

    with {:ok, verdict} <- Sanctum.Door.admit_identity(user_id, user_info),
         {:ok, user} <- Sanctum.SignIn.admitted(user_info, verdict) do
      ctx =
        Context.build(
          user_id: user_id,
          email: user_info.email,
          provider: to_string(provider),
          # Start athanor-less; resolve_into/2 fills the athanor from memberships.
          athanor_id: nil,
          permissions: [:*]
        )

      {:ok, user, ctx}
    end
  end

  # What follows the door. The sign-in outcome travels intact on the
  # result — surfaces branch on it, never on a re-derived flag; `wire/1`
  # flattens it for the CLI. A session is minted only for an outcome the
  # person can act on with one; the IdP token travels only for the claim
  # or the policy acceptance it is needed for.
  defp complete(user, ctx, user_info, provider, access_token) do
    base = %{
      status: "complete",
      user: %{id: user_info.id, email: user_info.email, name: user_info.name}
    }

    case Sanctum.SignIn.complete(user, provider, access_token) do
      {:proceed, user, report} ->
        with_session(base, %{ctx | namespace: user.namespace}, %{outcome: {:proceed, report}})

      {:needs_legal, version} ->
        with_session(base, ctx, %{
          outcome: {:needs_legal, version},
          access_token: access_token
        })

      {:needs_claim, suggested} ->
        with_session(base, ctx, %{
          outcome: {:needs_claim, suggested},
          access_token: access_token
        })

      {:reauthenticate, reason} ->
        Map.put(base, :outcome, {:reauthenticate, reason})

      {:unavailable, reason} ->
        Map.put(base, :outcome, {:unavailable, reason})
    end
  end

  @doc """
  The CLI poll response, field for field.

  `cyfr login` reads these exact keys (`apps/codex/cmd/login.go`), so this
  flattening is a wire contract: one adapter, byte-stable, exercised by
  its own test. The browser page consumes the rich result directly; only
  the MCP session tool's `device_poll` flattens through here. Total over
  every poll status — a result without an outcome passes through.
  """
  @spec wire(map()) :: map()
  def wire(%{outcome: outcome} = result) do
    base = %{status: "complete", user: result.user}

    base =
      case result do
        %{session_token: token} -> Map.put(base, :session_token, token)
        _ -> base
      end

    case outcome do
      {:proceed, report} ->
        base |> Map.put(:needs_personal_namespace, false) |> put_report(report)

      {:needs_legal, version} ->
        Map.merge(base, %{
          needs_policy_acceptance: true,
          required_policy_version: version,
          needs_personal_namespace: false,
          access_token: result[:access_token]
        })

      {:needs_claim, suggested} ->
        Map.merge(base, %{
          needs_personal_namespace: true,
          suggested_username: suggested,
          access_token: result[:access_token]
        })

      {:reauthenticate, _reason} ->
        Map.merge(base, %{
          reauthenticate: true,
          probe_error: "invalid_access_token",
          needs_personal_namespace: true
        })

      {:unavailable, reason} ->
        %{status: "registry_unavailable", message: unavailable_message(reason)}
    end
  end

  def wire(result), do: result

  defp with_session(base, ctx, extras) do
    ctx = Sanctum.Tenancy.resolve_into(ctx, force: true)

    case Session.create(ctx) do
      {:ok, session} ->
        base
        |> Map.put(:session_token, session.token)
        |> Map.merge(extras)

      {:error, reason} ->
        Logger.error("[Sanctum.Auth.DeviceFlow] session create failed: #{inspect(reason)}")
        %{status: "error", message: "The session could not be created. Run `cyfr login` again."}
    end
  end

  # What the registry said, as stable client-facing fields: namespaces
  # whose push tokens didn't land locally, and a probe that failed or was
  # refused (`cyfr whoami` re-probes). Never an inspected internal error.
  defp put_report(fields, %{unsynced: unsynced, probe: probe}) do
    fields =
      if unsynced == [], do: fields, else: Map.put(fields, :credential_store_warnings, unsynced)

    case probe do
      :failed -> Map.put(fields, :probe_error, "probe_failed")
      :invalid_token -> Map.put(fields, :probe_error, "invalid_access_token")
      _ -> fields
    end
  end

  defp unavailable_message(:no_access_token),
    do:
      "Your identity provider returned no access token, so cyfr.run could not be asked " <>
        "for your namespace. Nothing was set up. Run `cyfr login` again."

  defp unavailable_message(:namespace_conflict),
    do:
      "cyfr.run names you by a namespace another identity on this server already holds. " <>
        "Ask the operator to sort it out."

  defp unavailable_message(_),
    do:
      "cyfr.run could not be reached to find or claim your namespace. Nothing was set up. " <>
        "Run `cyfr login` again in a moment."

  # ============================================================================
  # Configuration
  # ============================================================================

  # App-env only, no System.get_env fallback: runtime.exs resolves the
  # CYFR_* vars through Dotenvy's merged .env sources, which are NOT
  # exported to the OS environment — a direct read here would consult a
  # second, divergent config universe.
  defp get_client_id(:github), do: Application.get_env(:cyfr, :github_client_id)

  defp get_client_id(:google), do: Application.get_env(:cyfr, :google_client_id)

  # Google's device-flow token endpoint requires client_secret in the POST
  # body; GitHub's does not (GitHub device-flow OAuth apps are issued
  # without a secret by design). Returns nil on GitHub.
  defp get_client_secret(:github), do: nil

  defp get_client_secret(:google), do: Application.get_env(:cyfr, :google_client_secret)

  defp normalize_provider("github"), do: :github
  defp normalize_provider(:github), do: :github
  defp normalize_provider("google"), do: :google
  defp normalize_provider(:google), do: :google
  defp normalize_provider(other), do: other

  defp normalize_token_type(nil), do: "bearer"
  defp normalize_token_type(type) when is_binary(type), do: String.downcase(type)

  # ============================================================================
  # HTTP Client
  # ============================================================================
  #
  # Uses the `Sanctum.Auth.Finch` pool (started in `Cyfr.Application`) for
  # outbound GitHub / Google OAuth calls, so the auth sliver's only permitted
  # edge into Compendium stays the post-`Session.create/1` probe +
  # CredentialStore.put handoff.
  #
  # Success responses are parsed as JSON. Non-2xx responses are also parsed
  # as JSON when possible because OAuth surfaces structured errors
  # (`{error: "authorization_pending"}`, `{error: "slow_down"}`, etc.) in
  # the body — callers pattern-match on these.

  @finch_pool Sanctum.Auth.Finch

  # One reader for the timeout, so the two verbs cannot come to disagree
  # about how long an IdP is allowed to take.
  defp http_timeout_ms, do: Application.get_env(:cyfr, :http_timeout_ms, 30_000)

  defp http_post(url, headers, body) do
    :post
    |> Finch.build(url, headers, body)
    |> finch_request_json(http_timeout_ms())
  end

  defp http_get(url, headers) do
    :get
    |> Finch.build(url, headers)
    |> finch_request_json(http_timeout_ms())
  end

  defp finch_request_json(req, timeout) do
    case Finch.request(req, @finch_pool, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        parse_json_response(resp_body)

      {:ok, %Finch.Response{body: resp_body}} ->
        case parse_json_response(resp_body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, {:http_error, to_string(resp_body)}}
        end

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, {:request_failed, reason}}

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
