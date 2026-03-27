defmodule Sanctum.OAuth do
  @moduledoc """
  Host-managed OAuth token lifecycle for CYFR catalysts.

  Manages the full OAuth 2.0 flow: provider setup, authorization,
  token exchange, refresh, and revocation. WASM catalysts only ever
  receive short-lived access tokens — client credentials and refresh
  tokens are never exposed.

  ## Storage

  All OAuth data is stored in the `oauth_credentials` table via
  `Arca.OAuthStorage`, encrypted at rest using `Sanctum.Crypto`.
  Completely separate from the secrets system.

  ## Usage

      ctx = Sanctum.Context.local()

      # One-time: store client credentials for a provider
      :ok = Sanctum.OAuth.setup_provider(ctx, "google", "client-id", "client-secret")

      # One-time: initiate authorization for a component
      {:ok, %{url: url}} = Sanctum.OAuth.authorize_url(ctx, "catalyst:local.gmail:0.1.0", "google")
      # User visits url, grants consent, callback stores tokens

      # Runtime: get a fresh access token (host function calls this)
      {:ok, "ya29..."} = Sanctum.OAuth.get_access_token(ctx, "catalyst:local.gmail:0.1.0", "google")
  """

  require Logger

  alias Sanctum.Context

  @pending_ttl_ms 600_000
  @expiry_buffer_seconds 60
  @max_expires_in 86_400 * 365

  # ============================================================================
  # Authorization Flow
  # ============================================================================

  @doc """
  Build an OAuth authorization URL for a component+provider.

  Returns the URL the user should visit and a random state token.
  The pending auth is cached for 10 minutes.
  """
  @spec authorize_url(Context.t(), String.t(), String.t()) ::
          {:ok, %{url: String.t(), state: String.t()}} | {:error, term()}
  def authorize_url(%Context{} = ctx, component_ref, provider) do
    with {:ok, oauth_config} <- get_manifest_oauth_config(ctx, component_ref),
         {:ok, provider_config} <- fetch_provider_config(oauth_config, provider),
         {:ok, creds} <- get_provider_creds(ctx, provider_config) do
      state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      redirect_uri = build_redirect_uri()

      pending = %{
        component_ref: component_ref,
        provider: provider,
        provider_config: provider_config,
        redirect_uri: redirect_uri,
        user_id: ctx.user_id,
        org_id: ctx.org_id,
        project_id: ctx.project_id
      }

      Arca.Cache.put({:oauth_pending, state}, pending, @pending_ttl_ms)

      params =
        %{
          "client_id" => creds["client_id"],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(provider_config["scopes"], " "),
          "state" => state
        }
        |> Map.merge(provider_config["extra_params"] || %{})

      url = provider_config["authorize_url"] <> "?" <> URI.encode_query(params)
      {:ok, %{url: url, state: state, redirect_uri: redirect_uri}}
    end
  end

  @doc """
  Exchange an authorization code for tokens.

  Called by the OAuth callback route. Validates the state parameter,
  exchanges the code with the provider's token endpoint, and stores
  the encrypted token bundle. State is only invalidated after successful
  storage — if exchange fails, the user can retry.
  """
  @spec exchange_code(Context.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(%Context{} = _ctx, state, code, redirect_uri) do
    with {:ok, pending} <- fetch_pending(state),
         :ok <- validate_redirect_uri(pending, redirect_uri),
         {:ok, creds} <- get_provider_creds_raw(pending),
         {:ok, token_data} <- do_token_exchange(pending, creds, code, redirect_uri),
         :ok <- store_token_bundle(pending, token_data) do
      # Invalidate state AFTER successful storage — if exchange failed above,
      # the state remains valid and the user can retry
      Arca.Cache.invalidate({:oauth_pending, state})
      {:ok, %{provider: pending.provider, component_ref: pending.component_ref}}
    end
  end

  # ============================================================================
  # Token Access (Hot Path)
  # ============================================================================

  @doc """
  Get a valid access token for a component+provider.

  Checks cache first, then storage. Refreshes automatically if expired.
  """
  @spec get_access_token(Context.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_access_token(%Context{} = ctx, component_ref, provider) do
    {_scope, org_id, project_id} = extract_scope(ctx)
    dec_cache_key = {:oauth_token_dec, {component_ref, provider, org_id, project_id}}

    token_data =
      case Arca.Cache.get(dec_cache_key) do
        {:ok, cached} -> cached
        :miss -> load_and_cache_token(ctx, component_ref, provider, dec_cache_key)
      end

    case token_data do
      nil ->
        {:error,
         "authorization_required: run oauth.authorize for #{component_ref} provider #{provider}"}

      data ->
        if token_valid?(data) do
          {:ok, data["access_token"]}
        else
          refresh_access_token(ctx, component_ref, provider, data, dec_cache_key)
        end
    end
  end

  # ============================================================================
  # Revoke & Status
  # ============================================================================

  @doc """
  Delete the stored token bundle for a component+provider.
  """
  @spec revoke(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke(%Context{} = ctx, component_ref, provider) do
    {_scope, org_id, project_id} = extract_scope(ctx)
    Arca.OAuthStorage.delete_token(component_ref, provider, org_id, project_id)
  end

  @doc """
  Get authorization status for all declared OAuth providers of a component.
  """
  @spec status(Context.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def status(%Context{} = ctx, component_ref) do
    with {:ok, oauth_config} <- get_manifest_oauth_config(ctx, component_ref) do
      {_scope, org_id, project_id} = extract_scope(ctx)

      providers =
        Enum.map(oauth_config, fn {provider, config} ->
          status =
            case Arca.OAuthStorage.get_token(component_ref, provider, org_id, project_id) do
              {:ok, encrypted} ->
                case Sanctum.Crypto.decrypt(encrypted) do
                  {:ok, json} ->
                    case Jason.decode(json) do
                      {:ok, data} -> compute_status(data)
                      {:error, _} -> :decrypt_error
                    end

                  _ ->
                    :decrypt_error
                end

              {:error, :not_found} ->
                :not_authorized
            end

          %{
            provider: provider,
            status: status,
            scopes: config["scopes"] || []
          }
        end)

      {:ok, providers}
    end
  end

  @doc """
  Extract the oauth config block from a component's manifest.
  """
  @spec get_manifest_oauth_config(Context.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_manifest_oauth_config(%Context{} = ctx, component_ref) do
    case resolve_component(ctx, component_ref) do
      {:ok, component} ->
        manifest = Compendium.Manifest.decode(component[:manifest] || component["manifest"])

        case Map.get(manifest, "oauth") do
          nil -> {:error, "no oauth block in manifest for #{component_ref}"}
          oauth when is_map(oauth) -> {:ok, oauth}
          _ -> {:error, "invalid oauth block in manifest for #{component_ref}"}
        end

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Internal — Token Resolution
  # ============================================================================

  defp load_and_cache_token(ctx, component_ref, provider, dec_cache_key) do
    {_scope, org_id, project_id} = extract_scope(ctx)

    case Arca.OAuthStorage.get_token(component_ref, provider, org_id, project_id) do
      {:ok, encrypted} ->
        case Sanctum.Crypto.decrypt(encrypted) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, data} when is_map(data) ->
                Arca.Cache.put(dec_cache_key, data)
                data

              _ ->
                Logger.error(
                  "[Sanctum.OAuth] Corrupted token data for #{component_ref}/#{provider}"
                )

                nil
            end

          {:error, _} ->
            Logger.error(
              "[Sanctum.OAuth] Failed to decrypt token for #{component_ref}/#{provider}"
            )

            nil
        end

      {:error, :not_found} ->
        nil
    end
  end

  # No expires_at or nil = never expires (e.g. some API tokens)
  defp token_valid?(%{"expires_at" => nil}), do: true

  defp token_valid?(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} ->
        DateTime.diff(dt, DateTime.utc_now()) > @expiry_buffer_seconds

      _ ->
        false
    end
  end

  defp token_valid?(%{"access_token" => token}) when is_binary(token), do: true
  defp token_valid?(_), do: false

  defp refresh_access_token(ctx, component_ref, provider, token_data, dec_cache_key) do
    case token_data["refresh_token"] do
      nil ->
        {:error,
         "authorization_required: token expired and no refresh_token for #{component_ref} provider #{provider}"}

      _refresh_token ->
        with {:ok, oauth_config} <- get_manifest_oauth_config(ctx, component_ref),
             {:ok, provider_config} <- fetch_provider_config(oauth_config, provider),
             {:ok, creds} <- get_provider_creds(ctx, provider_config) do
          do_refresh(ctx, component_ref, provider, provider_config, creds, token_data, dec_cache_key)
        end
    end
  end

  defp do_refresh(ctx, component_ref, provider, provider_config, creds, token_data, dec_cache_key) do
    token_url = provider_config["token_url"]
    auth_style = provider_config["auth_style"] || "params"

    body_params = %{
      "grant_type" => "refresh_token",
      "refresh_token" => token_data["refresh_token"]
    }

    {headers, body_params} = apply_auth_style(auth_style, creds, body_params)
    body = URI.encode_query(body_params)
    headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]

    case do_http_post(token_url, headers, body) do
      {:ok, response} ->
        new_data = %{
          "access_token" => response["access_token"],
          "refresh_token" => response["refresh_token"] || token_data["refresh_token"],
          "expires_at" => compute_expires_at(response["expires_in"]),
          "scopes" => token_data["scopes"],
          "token_type" => response["token_type"] || "bearer"
        }

        pending = %{
          component_ref: component_ref,
          provider: provider,
          org_id: ctx.org_id,
          project_id: ctx.project_id
        }

        case store_token_bundle(pending, new_data) do
          :ok ->
            Arca.Cache.put(dec_cache_key, new_data)

            :telemetry.execute(
              [:cyfr, :opus, :oauth, :token_refresh],
              %{system_time: System.system_time()},
              %{component_ref: component_ref, provider: provider, status: :ok}
            )

            {:ok, new_data["access_token"]}

          {:error, _} = error ->
            error
        end

      {:error, reason} ->
        :telemetry.execute(
          [:cyfr, :opus, :oauth, :token_refresh],
          %{system_time: System.system_time()},
          %{component_ref: component_ref, provider: provider, status: :error}
        )

        {:error,
         "authorization_required: refresh failed for #{component_ref} provider #{provider}: #{reason}"}
    end
  end

  # ============================================================================
  # Internal — Token Exchange
  # ============================================================================

  defp fetch_pending(state) do
    # Non-destructive read — state is invalidated only after successful exchange
    case Arca.Cache.get({:oauth_pending, state}) do
      {:ok, pending} -> {:ok, pending}
      :miss -> {:error, "invalid or expired state parameter"}
    end
  end

  defp validate_redirect_uri(pending, redirect_uri) do
    if pending[:redirect_uri] == redirect_uri do
      :ok
    else
      {:error, "redirect_uri mismatch"}
    end
  end

  defp get_provider_creds_raw(pending) do
    # Build a temporary context for secrets lookup
    ctx = Sanctum.Context.build(
      user_id: pending.user_id,
      org_id: pending.org_id,
      project_id: pending.project_id,
      permissions: [:secrets_read],
      authenticated: true
    )

    get_provider_creds(ctx, pending.provider_config)
  end

  defp do_token_exchange(pending, creds, code, redirect_uri) do
    provider_config = pending.provider_config
    token_url = provider_config["token_url"]
    auth_style = provider_config["auth_style"] || "params"

    body_params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri
    }

    {headers, body_params} = apply_auth_style(auth_style, creds, body_params)
    body = URI.encode_query(body_params)
    headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]

    case do_http_post(token_url, headers, body) do
      {:ok, response} ->
        token_data = %{
          "access_token" => response["access_token"],
          "refresh_token" => response["refresh_token"],
          "expires_at" => compute_expires_at(response["expires_in"]),
          "scopes" => provider_config["scopes"],
          "token_type" => response["token_type"] || "bearer"
        }

        {:ok, token_data}

      {:error, reason} ->
        {:error, "token exchange failed: #{reason}"}
    end
  end

  defp store_token_bundle(pending, token_data) do
    org_id = pending.org_id
    project_id = pending.project_id || "default"

    case Jason.encode(token_data) do
      {:ok, json} ->
        case Sanctum.Crypto.encrypt(json) do
          {:ok, encrypted} ->
            Arca.OAuthStorage.put_token(
              pending.component_ref,
              pending.provider,
              encrypted,
              org_id,
              project_id
            )

          {:error, _} = error ->
            error
        end

      {:error, _} ->
        {:error, "failed to encode token data"}
    end
  end

  # ============================================================================
  # Internal — HTTP
  # ============================================================================

  defp do_http_post(url, headers, body) do
    if not String.starts_with?(url, "https://") do
      {:error, "token_url must use https://"}
    else
      req = Finch.build(:post, url, headers, body)

      case Finch.request(req, Compendium.Finch, receive_timeout: 15_000) do
        {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, data} -> {:ok, data}
            {:error, _} -> {:error, "invalid JSON response from token endpoint"}
          end

        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          Logger.warning(
            "[Sanctum.OAuth] Token endpoint returned #{status}: #{String.slice(resp_body, 0, 500)}"
          )

          {:error, "token exchange failed (status #{status})"}

        {:error, reason} ->
          Logger.warning("[Sanctum.OAuth] HTTP request failed: #{inspect(reason)}")
          {:error, "token endpoint unreachable"}
      end
    end
  end

  defp apply_auth_style("header", creds, body_params) do
    encoded = Base.encode64("#{creds["client_id"]}:#{creds["client_secret"] || ""}")
    {[{"authorization", "Basic #{encoded}"}], body_params}
  end

  defp apply_auth_style(_params, creds, body_params) do
    params = %{"client_id" => creds["client_id"]}
    params = if creds["client_secret"], do: Map.put(params, "client_secret", creds["client_secret"]), else: params
    {[], Map.merge(body_params, params)}
  end

  # ============================================================================
  # Internal — Helpers
  # ============================================================================

  defp get_provider_creds(ctx, provider_config) do
    id_name = provider_config["client_id_secret"]
    secret_name = provider_config["client_secret_secret"]

    if is_nil(id_name) do
      {:error, "manifest oauth block missing client_id_secret"}
    else
      with {:ok, client_id} <- Sanctum.Secrets.get(ctx, id_name) do
        # client_secret is optional (public OAuth clients don't need it)
        client_secret =
          if secret_name do
            case Sanctum.Secrets.get(ctx, secret_name) do
              {:ok, val} -> val
              {:error, :not_found} -> nil
            end
          end

        {:ok, %{"client_id" => client_id, "client_secret" => client_secret}}
      else
        {:error, :not_found} ->
          {:error,
           "OAuth client ID not configured — set secret '#{id_name}' via cyfr setup"}

        {:error, reason} ->
          {:error, "failed to read OAuth client credentials: #{inspect(reason)}"}
      end
    end
  end

  defp fetch_provider_config(oauth_config, provider) do
    case Map.get(oauth_config, provider) do
      nil -> {:error, "provider '#{provider}' not declared in manifest oauth block"}
      config -> {:ok, config}
    end
  end

  defp resolve_component(ctx, component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{name: name, type: type}} ->
        Compendium.Registry.get_latest(ctx, name, nil, type)

      _ ->
        {:error, "invalid component reference: #{component_ref}"}
    end
  end

  defp compute_expires_at(nil), do: nil

  defp compute_expires_at(expires_in)
       when is_integer(expires_in) and expires_in > 0 and expires_in <= @max_expires_in do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.to_iso8601()
  end

  defp compute_expires_at(_), do: nil

  defp compute_status(%{"expires_at" => nil}), do: :authorized

  defp compute_status(%{"expires_at" => expires_at}) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} ->
        if DateTime.diff(dt, DateTime.utc_now()) > 0, do: :authorized, else: :expired

      _ ->
        :authorized
    end
  end

  defp compute_status(_), do: :not_authorized

  defp build_redirect_uri do
    case function_exported?(EmissaryWeb.Endpoint, :url, 0) do
      true -> EmissaryWeb.Endpoint.url() <> "/auth/oauth/callback"
      false -> "http://localhost:4000/auth/oauth/callback"
    end
  end

  # Match Sanctum.Secrets.extract_scope exactly
  defp extract_scope(%Context{scope: :org, org_id: nil}) do
    raise ArgumentError,
          "org_id cannot be nil when scope is :org. " <>
            "Either set an org_id or use scope :project."
  end

  defp extract_scope(%Context{scope: scope, org_id: org_id, project_id: project_id}) do
    {to_string(scope), org_id, project_id || "default"}
  end
end
