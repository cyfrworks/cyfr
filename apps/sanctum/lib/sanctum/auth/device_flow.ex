# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.DeviceFlow do
  @moduledoc """
  OAuth 2.0 Device Authorization Grant for CLI authentication.

  Implements the Device Flow (RFC 8628) for GitHub OAuth,
  allowing CLI users to authenticate without exposing client secrets.

  ## Usage

  This module is called through the MCP session tool's actions:
  - `device_init` - Start device flow, returns codes for user
  - `device_poll` - Poll for completion, returns session when authorized

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

  # The device-flow providers: `Prima.SignInProviders.device_flow/0`'s
  # that have endpoints above, in its order.
  @known_providers for provider <- Prima.SignInProviders.device_flow(),
                       provider in Enum.map(Map.keys(@provider_urls), &Atom.to_string/1),
                       do: provider

  # The same providers as atoms, each one a key of `@provider_urls`.
  @provider_atoms Enum.map(@known_providers, &String.to_existing_atom/1)
  @provider_by_name Map.new(@provider_atoms, &{Atom.to_string(&1), &1})

  # The endpoints a flow talks to. A suite points them at a stand-in IdP
  # with `config :sanctum, :device_flow_endpoints, %{github: %{token: url}}`,
  # so the sign-in it drives is this module's own; like `impl/0` it is a
  # test seam, not an operator setting.
  defp urls(provider) do
    overrides = Application.get_env(:sanctum, :device_flow_endpoints, %{})
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
  def impl, do: Application.get_env(:sanctum, :device_flow, __MODULE__)

  @doc """
  Initialize device flow - request device code from provider.

  Returns device code info that should be displayed to the user.

  `client_ip` is the address the budget is charged to, from
  `Sanctum.ClientIp`. Pass `nil` only from a surface its transport
  already meters per address. It is a
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
           Prima.RateLimiter.check({:device_init, :all}, @init_global_max, @poll_window_ms) do
      :ok
    else
      # Typed, as the other sign-in capacity refusals are: the caller is told
      # to wait, in whole seconds rounded up.
      {:deny, retry_ms} -> {:error, {:rate_limited, div(retry_ms + 999, 1000)}}
    end
  end

  # A caller whose ingress knew no address (a context with no `client_ip`)
  # has no bucket to charge; it still passes the global one.
  defp check_ip_budget({_bucket, nil}, _max), do: :ok

  defp check_ip_budget({bucket, client_ip}, max) when is_binary(client_ip) do
    Prima.RateLimiter.check({bucket, client_ip}, max, @poll_window_ms)
  end

  @doc """
  Poll for the IdP token; once authorized, unlock the person the identity
  names (`Sanctum.SignIn.unlock/1`, which asks the door about them) and
  open the session. A device flow never makes a person: an identity no
  person here has linked is refused `:no_person`. `command_line:`
  names the machine a command line's sign-in runs on
  (`Sanctum.CliSignIn.machine/1` checked it), which the session records
  so its person lists and revokes it; the browser's sign-in names none.

  Returns one of:
  - `{:ok, %{status: "pending"}}` - User hasn't authorized yet
  - `{:ok, %{status: "complete", session_token: token, user: user_info}}` -
    Authorized and signed in. Nothing here speaks to the registry.
  - `{:ok, %{status: "expired"}}` - Device code expired
  - `{:ok, %{status: "denied"}}` - User denied authorization

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
  @spec poll_for_session(provider(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def poll_for_session(provider, device_code, client_ip, opts \\ []) when is_list(opts) do
    with :ok <- check_poll_budget(device_code, client_ip),
         {:ok, provider, client_id} <- usable(provider) do
      case request_token(provider, client_id, device_code) do
        {:ok, tokens} ->
          # Got tokens: user info, then the unlock. A refusal
          # (`{:error, {:door, reason}}`, `{:error, :no_person}`) passes up
          # as it is, and `Sanctum.Providers.Session` renders it.
          with {:ok, user_info} <- fetch_user_info(provider, tokens),
               {:ok, user, ctx} <- unlock(user_info, provider) do
            {:ok, complete(user, ctx, user_info, Keyword.get(opts, :command_line))}
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
  Poll a device flow begun to link a door for the person signed in on
  `ctx`, instead of signing anyone in: once the provider authorizes, the
  identity it names is handed to `Sanctum.SignIn.link_ticket/2`, which
  binds a single-use link ticket to that person and session.
  No person is minted and no session is created; the ticket is answered
  to the page that polled, which presents it to `person.link_door`.

  Returns `{:ok, %{status: "pending"}}`, `{:ok, %{status: "complete",
  provider:, ticket:}}`, `{:ok, %{status: "expired" | "denied"}}`, or a
  refusal: the poll's own, and `link_ticket/2`'s (`:unauthenticated`,
  `:not_linkable`, `:unavailable`). The budget is the
  sign-in poll's.
  """
  @spec poll_for_link(provider(), String.t(), String.t() | nil, Context.t()) ::
          {:ok, map()} | {:error, term()}
  def poll_for_link(provider, device_code, client_ip, %Context{} = ctx) do
    with :ok <- check_poll_budget(device_code, client_ip),
         {:ok, provider, client_id} <- usable(provider) do
      case request_token(provider, client_id, device_code) do
        {:ok, tokens} ->
          with {:ok, user_info} <- fetch_user_info(provider, tokens),
               {:ok, ticket} <-
                 Sanctum.SignIn.link_ticket(ctx, %{
                   key: Identity.builtin_key(provider, user_info.id),
                   provider: Atom.to_string(provider),
                   email: user_info.email,
                   verified: user_info.verified
                 }) do
            {:ok, %{status: "complete", provider: Atom.to_string(provider), ticket: ticket}}
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
    per_code_key = {:device_poll, Prima.Digest.sha256_hex(device_code)}

    with :ok <- Prima.RateLimiter.check(per_code_key, @poll_per_code_max, @poll_window_ms),
         :ok <- check_ip_budget({:device_poll, client_ip}, @poll_per_ip_max),
         :ok <- Prima.RateLimiter.check({:device_poll, :all}, @poll_global_max, @poll_window_ms) do
      :ok
    else
      {:deny, _retry_ms} -> {:budget, :slow_down}
    end
  end

  # ============================================================================
  # Device Code Request
  # ============================================================================

  defp request_device_code(provider, client_id) when provider in @provider_atoms do
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

  defp request_token(provider, client_id, device_code) when provider in @provider_atoms do
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
      {:ok, %{"access_token" => access_token}} ->
        {:ok, %{access_token: access_token}}

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
        # primary from /user/emails does, and only a proved address is
        # written to the person's contact email.
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
      {:ok, %{"sub" => sub} = user_data} ->
        {:ok,
         %{
           id: to_string(sub),
           email: user_data["email"],
           verified: user_data["email_verified"] == true,
           name: user_data["name"] || user_data["given_name"] || user_data["email"]
         }}

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

  # The unlock runs before the session exists: a refused sign-in writes
  # nothing and makes no call.
  defp unlock(user_info, provider) do
    identity = Identity.builtin_key(provider, user_info.id)
    user_info = Map.merge(user_info, %{id: identity, provider: provider})

    with {:ok, user} <- Sanctum.SignIn.unlock(user_info) do
      ctx =
        Context.build(
          user_id: user.id,
          door: identity,
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

  # What follows the unlock: the session. The IdP token never travels:
  # nothing after the unlock needs it, and no sign-in speaks to the registry.
  defp complete(user, ctx, user_info, machine) do
    base = %{
      status: "complete",
      user: %{id: user_info.id, email: user_info.email, name: user_info.name}
    }

    with_session(base, %{ctx | namespace: user.namespace}, machine)
  end

  @doc """
  The CLI poll response, field for field: a signed-in result is its
  `status`, `user` and `session_token`, and every other poll status passes
  through as it is.

  `cyfr login` reads these exact keys (`apps/codex/cmd/login.go`), so this
  projection is a wire contract: one adapter, byte-stable, exercised by
  its own test. The browser page consumes the result directly; only the
  MCP session tool's `device_poll` projects through here.
  """
  @spec wire(map()) :: map()
  def wire(%{status: "complete", user: user, session_token: token}),
    do: %{status: "complete", user: user, session_token: token}

  def wire(result), do: result

  # A command line's sign-in names the machine it runs on, so its person
  # lists and revokes its session (`Sanctum.CliSignIn`); the browser's
  # sign-in page names none.
  defp with_session(base, ctx, machine) do
    case Sanctum.Tenancy.resolve_status(ctx, force: true) do
      {:ok, ctx} ->
        case Session.create(ctx, command_line: machine) do
          {:ok, session} ->
            Map.put(base, :session_token, session.token)

          # What the sign-in stood on went while it ran: the door it came
          # through was retired, by a recovery of the person's keys that
          # the session's fresh read found or by an unlink, or the
          # person's standing changed (`Sanctum.Session.create/2`). A
          # refusal of the sign-in, never a fault: the person signs in
          # again, as the browser's callback tells them
          # (`CyfrWeb.SignInResponse`).
          {:error, :unauthenticated} ->
            %{
              status: "error",
              message:
                "What this sign-in came through no longer admits you here. " <>
                  "Run `cyfr login` again."
            }

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

  # ============================================================================
  # Configuration
  # ============================================================================

  # App-env only, no System.get_env fallback: runtime.exs resolves the
  # CYFR_* vars through Dotenvy's merged .env sources, which are NOT
  # exported to the OS environment — a direct read here would consult a
  # second, divergent config universe.
  defp get_client_id(:github), do: Application.get_env(:sanctum, :github_client_id)

  defp get_client_id(:google), do: Application.get_env(:sanctum, :google_client_id)

  # Google's device-flow token endpoint requires client_secret in the POST
  # body; GitHub's does not (GitHub device-flow OAuth apps are issued
  # without a secret by design). Returns nil on GitHub.
  defp get_client_secret(:github), do: nil

  defp get_client_secret(:google), do: Application.get_env(:sanctum, :google_client_secret)

  @doc """
  The device-flow providers this module knows how to speak to: those of
  `Prima.SignInProviders.device_flow/0` that have device-flow endpoints.

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
  def configured_providers, do: Enum.filter(@provider_atoms, &configured?/1)

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

  defp normalize_provider(name) when is_binary(name), do: Map.get(@provider_by_name, name, name)
  defp normalize_provider(other), do: other

  # ============================================================================
  # HTTP Client
  # ============================================================================
  #
  # Uses the `Sanctum.Auth.Finch` pool (`Sanctum.Supervisor` starts it) for
  # outbound GitHub / Google OAuth calls.
  #
  # Success responses are parsed as JSON. Non-2xx responses are also parsed
  # as JSON when possible because OAuth surfaces structured errors
  # (`{error: "authorization_pending"}`, `{error: "slow_down"}`, etc.) in
  # the body — callers pattern-match on these.

  @finch_pool Sanctum.Auth.Finch

  # How long an IdP may take to answer either verb.
  @http_timeout_ms 30_000

  defp http_post(url, headers, body) do
    :post
    |> Finch.build(url, headers, body)
    |> finch_request_json(@http_timeout_ms)
  end

  defp http_get(url, headers) do
    :get
    |> Finch.build(url, headers)
    |> finch_request_json(@http_timeout_ms)
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
