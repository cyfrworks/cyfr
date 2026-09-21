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

  # Supported providers; @provider_urls must have the same keys.
  @known_providers ~w(github google)

  # Device-flow endpoints — per-provider URLs and scopes.
  @provider_urls %{
    github: %{
      device: "https://github.com/login/device/code",
      token: "https://github.com/login/oauth/access_token",
      userinfo: "https://api.github.com/user",
      emails: "https://api.github.com/user/emails",
      scope: "read:user user:email"
    },
    google: %{
      device: "https://oauth2.googleapis.com/device/code",
      token: "https://oauth2.googleapis.com/token",
      userinfo: "https://www.googleapis.com/oauth2/v3/userinfo",
      scope: "openid email profile"
    }
  }

  # The endpoints a flow talks to. A suite points them at a stand-in IdP
  # with `config :cyfr, :device_flow_endpoints, %{github: %{token: url}}`,
  # so the sign-in it drives is this module's own; like `impl/0` it is a
  # test seam, not an operator setting.
  defp urls(provider) do
    overrides = Application.get_env(:cyfr, :device_flow_endpoints, %{})
    Map.merge(Map.fetch!(@provider_urls, provider), Map.get(overrides, provider, %{}))
  end

  # Default polling configuration
  @default_poll_interval 5

  # Check anonymous-surface budgets before contacting providers. Global
  # ceilings must exceed individual-client budgets. Counters are node-local,
  # so deployment-wide capacity scales with the number of nodes.
  @poll_per_code_max 30
  @poll_per_ip_max 90
  @poll_global_max 1_800
  @poll_window_ms 60_000
  @init_per_ip_max 20
  @init_global_max 600

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
  The module the callers actually dispatch through.

  A test seam, not an operator knob: suites stand in a fake flow rather
  than reach a provider over the network. Deliberately undeclared in
  config — declaring it would publish a module-swap hook as a supported
  setting.

  Resolves the configured device-flow implementation for start and poll calls.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:cyfr, :device_flow, __MODULE__)

  @doc """
  Initialize device flow - request device code from provider.

  Returns device code info that should be displayed to the user.

  `client_ip` is the address the budget is charged to, from
  `Sanctum.ClientIp`. Pass `nil` only from a surface that is already
  metered per address by the transport — today that is the MCP route
  behind `EmissaryWeb.Plugs.MCPRateLimit`, and nothing else. It is a
  required argument rather than an option because a caller that has no
  answer has to say so, and the next anonymous surface must not inherit
  "unbudgeted" by omission.

  ## Examples

      {:ok, info} = DeviceFlow.init_device_flow("github", "203.0.113.7")
      # info contains: device_code, user_code, verification_uri, expires_in, interval
  """
  @spec init_device_flow(provider(), String.t() | nil) ::
          {:ok, device_code_response()} | {:error, term()}
  def init_device_flow(provider, client_ip) do
    # The init round-trip is the same anonymous POST with this server's
    # client id that the polls are budgeted for. Two buckets, and the order
    # matters: the per-address one is what an abuser actually hits, and the
    # server-wide one is a circuit breaker for a distributed attempt —
    # never the other way round, because the client id's reputation at the
    # provider is spent by whoever asks.
    with :ok <- check_init_budget(client_ip),
         {:ok, provider, client_id} <- usable(provider) do
      request_device_code(provider, client_id)
    end
  end

  defp check_init_budget(client_ip) do
    with :ok <- check_ip_budget({:device_init, client_ip}, @init_per_ip_max),
         :ok <-
           Cyfr.RateLimiter.check({:device_init, :all}, @init_global_max, @poll_window_ms) do
      :ok
    else
      {:deny, _retry_ms} -> {:error, "Too many sign-in attempts — try again shortly"}
    end
  end

  # A surface with no address of its own (the MCP route, metered per IP by
  # its own plug) has no bucket to charge; it still passes the global one.
  defp check_ip_budget({_bucket, nil}, _max), do: :ok

  defp check_ip_budget({bucket, client_ip}, max) when is_binary(client_ip) do
    Cyfr.RateLimiter.check({bucket, client_ip}, max, @poll_window_ms)
  end

  @doc """
  Poll for the IdP token; once authorized, run the door, sign-in and the
  one sign-in decision (`Sanctum.SignIn.complete/3`).

  Returns one of:
  - `{:ok, %{status: "pending"}}` - User hasn't authorized yet
  - `{:ok, %{status: "complete", session_token: token, user: user_info,
      needs_personal_namespace: false, probe_error: string (optional),
      credential_store_warnings: [slug] (optional)}}` - Authorized and
    signed in. `probe_error` says the cyfr.run courtesy probe did not
    answer (`probe_failed`, `invalid_access_token`,
    `policy_acceptance_required`, `namespace_conflict`) — the session is
    good; `cyfr whoami` re-probes, and publishing asks for whatever is
    still owed. `credential_store_warnings` lists namespaces whose push
    tokens were issued but not cached locally. `needs_personal_namespace`
    is always false: a publisher namespace is claimed at first publish,
    never at the door.
  - `{:ok, %{status: "expired"}}` - Device code expired
  - `{:ok, %{status: "denied"}}` - User denied authorization, or the door
    refused them

  ## Examples

      case DeviceFlow.poll_for_session("github", device_code, client_ip) do
        {:ok, %{status: "pending"}} ->
          # Keep polling
        {:ok, %{status: "complete", session_token: token}} ->
          # Success!
        {:ok, %{status: "expired"}} ->
          # Need to restart flow
      end
  """
  @spec poll_for_session(provider(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def poll_for_session(provider, device_code, client_ip) do
    with :ok <- check_poll_budget(device_code, client_ip),
         {:ok, provider, client_id} <- usable(provider) do
      case request_token(provider, client_id, device_code) do
        {:ok, tokens} ->
          # Got tokens: user info, the door, what sign-in records, then the
          # one decision both sign-in paths take.
          with {:ok, user_info} <- fetch_user_info(provider, tokens),
               {:ok, user, ctx} <- admit(user_info, provider) do
            {:ok, complete(user, ctx, user_info, provider, tokens.access_token)}
          else
            # `Sanctum.Door.admit_identity/2` answers `{:error, {:door, reason}}`;
            # nothing produces a bare `:user_not_allowed`, so the arm that
            # matched it never ran. The door refusal falls through to `error`
            # and `Sanctum.MCP.SessionTool` renders it uniformly, which is
            # what a poller is meant to see.
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
    else
      {:budget, :slow_down} -> {:ok, %{status: "pending", slow_down: true}}
      {:error, reason} -> {:error, reason}
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
  @spec poll_for_access_token(provider(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def poll_for_access_token(provider, device_code, client_ip) do
    # The appeal flow's raw-token poll deliberately bypasses the Door — an
    # appellant is by definition someone the takedown cascade already
    # revoked, and they must still be able to prove who they are to
    # cyfr.run. The Door exemption is the point; the poll BUDGET below is
    # not exempt, and neither is its per-address half: this flow's only
    # caller is a LiveView, which passes no rate-limit plug.
    with :ok <- check_poll_budget(device_code, client_ip),
         {:ok, provider, client_id} <- usable(provider) do
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
    else
      {:budget, :slow_down} -> {:ok, %{status: "pending", slow_down: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Both poll surfaces are anonymous, and every poll POSTs to the IdP
  # with THIS server's client id — unbudgeted, an abuser could spend the
  # client id's reputation at the provider. Three buckets, narrowest
  # first: a well-behaved client polls every 5s, so 30/min per device code
  # leaves generous headroom; the per-address budget bounds a swarm of
  # fabricated codes from one origin, which the per-code bucket cannot
  # see; and the server-wide ceiling is the distributed-attempt circuit
  # breaker, deliberately far above what any one address may spend. An
  # over-budget poll answers the protocol's own back-pressure shape
  # without contacting the provider. (The budget attributes live at the
  # top of the module — init reads them too, and attributes must be
  # defined before use.)
  defp check_poll_budget(device_code, client_ip) do
    per_code_key = {:device_poll, Cyfr.Digest.sha256_hex(device_code)}

    with :ok <- Cyfr.RateLimiter.check(per_code_key, @poll_per_code_max, @poll_window_ms),
         :ok <- check_ip_budget({:device_poll, client_ip}, @poll_per_ip_max),
         :ok <- Cyfr.RateLimiter.check({:device_poll, :all}, @poll_global_max, @poll_window_ms) do
      :ok
    else
      {:deny, _retry_ms} -> {:budget, :slow_down}
    end
  end

  # ============================================================================
  # Device Code Request
  # ============================================================================

  defp request_device_code(provider, client_id) when provider in [:github, :google] do
    urls = urls(provider)

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
    urls = urls(provider)

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

    case http_get(urls(:github).userinfo, headers) do
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

    case http_get(urls(:google).userinfo, headers) do
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

    case http_get(urls(:github).emails, headers) do
      {:ok, emails} when is_list(emails) ->
        case Enum.find(emails, &(&1["primary"] == true)) do
          %{"email" => email} = primary -> {:ok, email, primary["verified"] == true}
          _ -> :none
        end

      {:ok, %{"message" => message}} ->
        Logger.warning("[Auth.DeviceFlow] Failed to fetch GitHub email: #{message}")
        :none

      {:error, reason} ->
        Logger.warning("[Auth.DeviceFlow] Failed to fetch GitHub email: #{inspect(reason)}")
        :none
    end
  end

  # ============================================================================
  # Session Creation
  # ============================================================================

  # The door runs before the session exists and before cyfr.run hears of the
  # identity: a refused sign-in leaves no row and makes no call.
  defp admit(user_info, provider) do
    identity = Identity.builtin_key(provider, user_info.id)
    user_info = Map.merge(user_info, %{id: identity, provider: provider})

    with {:ok, verdict} <- Sanctum.Door.admit_identity(identity, user_info),
         {:ok, user} <- Sanctum.SignIn.admitted(user_info, verdict) do
      ctx =
        Context.build(
          user_id: user.id,
          email: user_info.email,
          provider: to_string(provider),
          # Start athanor-less; the establish recipe fills the athanor from
          # memberships (`Sanctum.Caller.establish/2`).
          athanor_id: nil,
          permissions: Context.person_permissions()
        )

      {:ok, user, ctx}
    end
  end

  # What follows the door. The sign-in report travels intact on the result
  # — surfaces read it, never a re-derived flag; `wire/1` flattens it for
  # the CLI. The IdP token never travels: nothing after the door needs it.
  #
  # And nothing here probes cyfr.run. The probe is the component domain's
  # (`Compendium.SignInSync`), which sits above Sanctum and cannot be
  # called from inside it; reaching it would mean handing the IdP token up
  # out of the door, which is the one thing this module's own invariant
  # forbids. So a CLI sign-in reports `:skipped` and records no namespace
  # and no push token. The `registry` tool's re-probe does both on request,
  # which is an explicit ask rather than a credential travelling silently.
  defp complete(user, ctx, user_info, _provider, _access_token) do
    base = %{
      status: "complete",
      user: %{id: user_info.id, email: user_info.email, name: user_info.name}
    }

    report = %{unsynced: [], probe: :skipped}
    with_session(base, %{ctx | namespace: user.namespace}, %{outcome: {:proceed, report}})
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

    {:proceed, report} = outcome
    base |> Map.put(:needs_personal_namespace, false) |> put_report(report)
  end

  def wire(result), do: result

  defp with_session(base, ctx, extras) do
    case Sanctum.Tenancy.resolve_status(ctx, force: true) do
      {:ok, ctx} ->
        case Session.create(ctx) do
          {:ok, session} ->
            base
            |> Map.put(:session_token, session.token)
            |> Map.merge(extras)

          {:error, reason} ->
            Logger.error("[Auth.DeviceFlow] session create failed: #{inspect(reason)}")

            %{
              status: "error",
              message: "The session could not be created. Run `cyfr login` again."
            }
        end

      {:error, :unavailable} ->
        # A transient membership read, not a refusal: no session was minted,
        # and the person is told to retry rather than that they belong
        # nowhere. The CLI treats "error" as terminal-with-message.
        %{
          status: "error",
          message:
            "The server could not read memberships just now. " <>
              "Run `cyfr login` again in a moment."
        }
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
      :legal_required -> Map.put(fields, :probe_error, "policy_acceptance_required")
      :namespace_conflict -> Map.put(fields, :probe_error, "namespace_conflict")
      _ -> fields
    end
  end

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

  @doc """
  The device-flow providers this module knows how to speak to — the one
  roster; the web surfaces validate against it instead of each carrying
  its own ["github", "google"] literal.

  Knowing a provider is not the same as being able to use it. For the
  subset the operator has actually supplied credentials for, which is what
  a sign-in page should offer, see `configured_providers/0`.
  """
  @spec providers() :: [String.t()]
  def providers, do: @known_providers

  @doc "Whether `value` names a known device-flow provider."
  @spec provider?(term()) :: boolean()
  def provider?(value) when is_binary(value), do: value in @known_providers
  def provider?(value) when is_atom(value), do: Atom.to_string(value) in @known_providers
  def provider?(_), do: false

  @doc """
  The providers this server can actually start a flow with, as atoms.

  Google device flow requires both the client id and token-exchange secret.
  """
  @spec configured_providers() :: [atom()]
  def configured_providers, do: Enum.filter([:github, :google], &configured?/1)

  # GitHub issues device-flow apps without a secret by design; Google's token
  # endpoint requires one, so a Google client id on its own is not a usable
  # provider.
  defp configured?(:github), do: present?(get_client_id(:github))

  defp configured?(:google),
    do: present?(get_client_id(:google)) and present?(get_client_secret(:google))

  defp configured?(_), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # Require a known provider with the credentials needed for token exchange.
  defp usable(provider) do
    provider = normalize_provider(provider)

    cond do
      not provider?(provider) -> {:error, {:unknown_provider, provider}}
      not configured?(provider) -> {:error, {:client_id_not_configured, provider}}
      true -> {:ok, provider, get_client_id(provider)}
    end
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
  # about how long an IdP is allowed to take. It was an
  # `Application.get_env(:cyfr, :http_timeout_ms)` that nothing set — a
  # constant under a name general enough that the next module to want an
  # HTTP timeout would have read this one by accident.
  @http_timeout_ms 30_000

  defp http_timeout_ms, do: @http_timeout_ms

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
