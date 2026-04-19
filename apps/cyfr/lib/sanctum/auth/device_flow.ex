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
  Poll for token and create session if authorized.

  Returns one of:
  - `{:ok, %{status: "pending"}}` - User hasn't authorized yet
  - `{:ok, %{status: "complete", session_id: id, user: user_info,
      needs_personal_namespace: bool, suggested_username: string | nil,
      access_token: string (optional), probe_error: string (optional),
      reauthenticate: true (optional),
      credential_store_warnings: [slug] (optional)}}` - Authorized. When
    `reauthenticate: true` is present, the IdP access_token expired during
    probe; the CLI MUST discard the device_code and restart DeviceFlow from
    scratch. When `probe_error` is present without `reauthenticate`, the
    session exists but the cyfr.run probe failed transiently; the CLI should
    offer a "Retry probe" action. `credential_store_warnings` lists namespace
    slugs whose push tokens were issued by cyfr.run but not cached locally —
    the user should re-run `cyfr whoami` to retry storage.
    `access_token` (string) is included only when `needs_personal_namespace: true`
    so the CLI can forward it once to `registry.claim-personal`. This matches
    the signed-cookie flow used by the web callback; consumer discards after
    the claim call. Omitted when the probe already seeded a personal namespace
    (in which case no claim is needed) or when `reauthenticate: true` (the
    IdP token is dead and must be re-obtained via a fresh DeviceFlow).
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
              # Accepted cross-layer coupling: DeviceFlow is part of the auth
              # sliver but invokes Compendium.Registry.Client after Session.create
              # to seed CredentialStore with push tokens. See auth_refactor.md
              # §"Accepted cross-layer coupling".
              {probe_fields, probe_error} =
                probe_after_session(provider, tokens.access_token, session)

              base = %{
                status: "complete",
                session_id: session.token,
                user: %{
                  id: user_info.id,
                  email: user_info.email,
                  name: user_info.name
                }
              }

              # Session creation succeeded; surface any probe error so the CLI
              # can offer a retry (re-run DeviceFlow). Absence of `:probe_error`
              # means the probe itself succeeded — `needs_personal_namespace`
              # then reflects actual server state, not a network failure.
              # `:invalid_access_token` is a distinct outcome: the IdP token is
              # unrecoverable; probe_fields already carries `reauthenticate: true`.
              extras =
                case probe_error do
                  nil -> probe_fields
                  :invalid_access_token -> Map.put(probe_fields, :probe_error, "invalid_access_token")
                  err -> Map.put(probe_fields, :probe_error, inspect(err))
                end

              # Option X — when the server reports `needs_personal_namespace: true`,
              # the CLI has to forward the IdP access_token to `registry.claim-personal`
              # to prove provider identity at claim time. The web path stashes this
              # in a signed cookie (see EmissaryWeb.AuthController); the CLI path
              # returns it once in the poll response. Consumer discards after the
              # claim call. Only include when a claim is actually required — don't
              # expose the token when the user is already fully set up.
              extras =
                if Map.get(extras, :needs_personal_namespace) == true and
                     not Map.has_key?(extras, :reauthenticate) and
                     is_binary(tokens.access_token) do
                  Map.put(extras, :access_token, tokens.access_token)
                else
                  extras
                end

              {:ok, Map.merge(base, extras)}
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
      id: User.build_id(provider, User.provider_iss(provider), user_info.id),
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

  defp get_client_id(:google) do
    Application.get_env(:cyfr, :google_client_id) ||
      System.get_env("CYFR_GOOGLE_CLIENT_ID")
  end

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
  # outbound GitHub / Google OAuth calls. This is a dedicated pool distinct
  # from `Compendium.Finch` so the auth-sliver layering invariant holds —
  # DeviceFlow doesn't reach into Compendium's supervised state (§4 clause
  # 12 only permits the accepted probe + CredentialStore.put handoff after
  # `Session.create/1`; the HTTP client is an independent concern).
  #
  # Success responses are parsed as JSON. Non-2xx responses are also parsed
  # as JSON when possible because OAuth surfaces structured errors
  # (`{error: "authorization_pending"}`, `{error: "slow_down"}`, etc.) in
  # the body — callers pattern-match on these.

  @finch_pool Sanctum.Auth.Finch

  defp http_post(url, headers, body) do
    timeout = Application.get_env(:cyfr, :http_timeout_ms, 30_000)

    :post
    |> Finch.build(url, headers, body)
    |> finch_request_json(timeout)
  end

  defp http_get(url, headers) do
    timeout = Application.get_env(:cyfr, :http_timeout_ms, 30_000)

    :get
    |> Finch.build(url, headers)
    |> finch_request_json(timeout)
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

  # ============================================================================
  # Post-session registry probe (accepted cross-layer coupling)
  # ============================================================================

  # Invokes cyfr.run's /v1/identity/probe to exchange the IdP access_token for
  # per-namespace push tokens, then stores them via CredentialStore.put/4.
  # Returns a map of extra MCP response fields (needs_personal_namespace,
  # suggested_username, reauthenticate, credential_store_warnings) plus an
  # optional error (logged, non-blocking).
  defp probe_after_session(provider, access_token, session) do
    registry = Compendium.Edition.cyfr_run_registry()

    case Compendium.Registry.Client.probe_identity(provider, access_token) do
      {:ok, %{} = body} ->
        personal = body["personal_namespace"]
        memberships = body["memberships"] || []

        %{personal_stored?: _, membership_failures: failures} =
          store_probe_results(session.user_id, registry, personal, memberships)

        base =
          case personal do
            nil ->
              %{
                needs_personal_namespace: true,
                suggested_username: suggest_username(provider, session)
              }

            _ ->
              %{needs_personal_namespace: false}
          end

        extra =
          if failures == [] do
            base
          else
            Map.put(base, :credential_store_warnings, Enum.map(failures, &elem(&1, 0)))
          end

        {extra, nil}

      {:error, :invalid_access_token} ->
        # IdP access_token expired or was revoked between OAuth completion and
        # probe. Cannot recover without user re-auth — surface `reauthenticate`
        # so codex / Porta can discard the device_code and re-run `cyfr login`.
        # See auth_refactor.md §3 step 6.
        Logger.warning(
          "[Sanctum.Auth.DeviceFlow] probe_identity returned 401 invalid_access_token; " <>
            "user must re-authenticate"
        )

        {%{
           needs_personal_namespace: true,
           reauthenticate: true
         }, :invalid_access_token}

      {:error, err} ->
        Logger.warning(
          "[Sanctum.Auth.DeviceFlow] probe_identity failed — #{inspect(err)}; " <>
            "continuing with session but CredentialStore is unseeded"
        )

        # Session still succeeds; user hits the claim-gate or re-probes later.
        {%{needs_personal_namespace: true}, err}
    end
  end

  # Returns `%{personal_stored?: boolean, membership_failures: [{slug, reason}]}`.
  # Partial failures don't abort the loop — every namespace is attempted; caller
  # surfaces failures as `credential_store_warnings` so the user can re-probe.
  defp store_probe_results(user_id, registry, personal, memberships) do
    personal_result =
      if personal do
        slug = personal["slug"] || personal[:slug]
        token = personal["token"] || personal[:token]

        if is_binary(slug) and is_binary(token) do
          put_credential(user_id, registry, slug, token, "personal")
        else
          :skipped
        end
      else
        :skipped
      end

    membership_failures =
      memberships
      |> Enum.map(fn m ->
        slug = m["slug"] || m[:slug]
        token = m["token"] || m[:token]
        role = m["role"] || m[:role] || "member"

        result =
          if is_binary(slug) and is_binary(token) do
            put_credential(user_id, registry, slug, token, role)
          else
            :skipped
          end

        {slug, result}
      end)
      |> Enum.reject(fn {_slug, result} -> result == :ok or result == :skipped end)

    %{personal_stored?: personal_result == :ok, membership_failures: membership_failures}
  end

  defp put_credential(user_id, registry, slug, token, role) do
    cred = %{
      type: :push_token,
      token: token,
      namespace: slug,
      role: role,
      issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      label: Compendium.Registry.Client.device_label()
    }

    case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "[Sanctum.Auth.DeviceFlow] CredentialStore.put failed for #{slug}: " <>
            "#{inspect(reason)} — leaving orphan cyfr.run token (server-side reaper backstop)"
        )

        err
    end
  end

  defp suggest_username(provider, session) do
    # Email local-part is the handle we have at this layer. `User.suggest_slug/1`
    # normalizes it to match the server-side `INVALID_USERNAME` rules (bare
    # `[a-z0-9-]+`, no leading/trailing/consecutive hyphens, ≤39 chars) so the
    # default doesn't doom-submit when the local-part has dots / `+` / etc.
    # Returns `nil` on un-derivable input; caller (probe_after_session) passes
    # that through and the UI falls back to a blank field.
    case User.suggest_slug(session.email) do
      nil -> "user-#{to_string(provider)}" |> User.suggest_slug()
      slug -> slug
    end
  end
end
