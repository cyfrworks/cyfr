defmodule Compendium.Registry.Client do
  @moduledoc """
  REST client for the cyfr.run registry API.

  Sibling of `Compendium.Registry.Identity` (reads identity from stored push
  tokens) and `Compendium.Registry.CredentialStore` (persists those tokens).
  This module talks the wire protocol; the other two own local state.

  Handles search, discover, component metadata, identity probe, namespace
  claim/verify, tokens, and members endpoints (`/v1/*`). Push and pull use
  OCI protocol through the gateway (`registry.cyfr.run/v2/`) via
  `Compendium.OCI.Client`.

  Used by both Core (apex cyfr.run) and Arx (self-hosted cyfr.run) — the
  REST host is sourced from `:cyfr, :registry_url` and is edition-agnostic.
  """

  require Logger

  alias Compendium.Edition
  alias Compendium.OCI.Errors
  alias Sanctum.Context

  @max_retries 3
  @base_delay_ms 500
  @receive_timeout 30_000

  # -- Public API --

  @doc """
  Search for components on the cyfr.run registry.

  Sends GET /v1/components with query parameters (q, type, category, tags, license, limit, offset).
  Auth is not required for search (public endpoint).
  """
  @spec search(Context.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def search(%Context{} = ctx, params) when is_map(params) do
    query = build_search_query(params)
    path = "/v1/components" <> query

    case request(:get, path, [], nil, ctx) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"components" => components} = data} ->
            {:ok, %{components: components, total: data["total"] || length(components)}}

          {:ok, unexpected} ->
            {:error, Errors.parse_error("search", unexpected)}

          {:error, reason} ->
            {:error, Errors.parse_error("search", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "search")}

      {:error, %Errors{} = err} ->
        {:error, err}
    end
  end

  @doc """
  Discover components on the cyfr.run registry.

  Sends GET /v1/components with publisher/namespace filter.
  Replaces the fragile _catalog approach for Core edition.
  """
  @spec discover(Context.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def discover(%Context{} = ctx, params) when is_map(params) do
    query = build_discover_query(params)
    path = "/v1/components" <> query

    case request(:get, path, [], nil, ctx) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"components" => components} = data} ->
            {:ok,
             %{
               registry: Edition.cyfr_run_registry(),
               components: components,
               total: data["total"] || length(components)
             }}

          {:ok, unexpected} ->
            {:error, Errors.parse_error("discover", unexpected)}

          {:error, reason} ->
            {:error, Errors.parse_error("discover", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "discover")}

      {:error, %Errors{} = err} ->
        {:error, err}
    end
  end

  @doc """
  Get component metadata from the cyfr.run index.

  Sends GET /v1/components/:type/:publisher/:name[/:version].
  """
  @spec get_component(Context.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Errors.t()}
  def get_component(%Context{} = ctx, type, publisher, name, version \\ nil) do
    path =
      if version do
        "/v1/components/#{URI.encode(type)}/#{URI.encode(publisher)}/#{URI.encode(name)}/#{URI.encode(version)}"
      else
        "/v1/components/#{URI.encode(type)}/#{URI.encode(publisher)}/#{URI.encode(name)}"
      end

    case request(:get, path, [], nil, ctx) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, component} when is_map(component) ->
            {:ok, component}

          {:ok, unexpected} ->
            {:error, Errors.parse_error("get_component", unexpected)}

          {:error, reason} ->
            {:error, Errors.parse_error("get_component", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "get_component")}

      {:error, %Errors{} = err} ->
        {:error, err}
    end
  end

  @doc """
  Call `POST /v1/identity/probe`.

  Exchanges an IdP access_token for a fresh set of push tokens — one for the
  user's personal namespace (if claimed) and one per publisher membership.
  Called automatically by `Sanctum.Auth.DeviceFlow.poll_for_session/2` and
  `EmissaryWeb.AuthController.callback/2` after `Session.create/1`.

  The `access_token` is passed in the request body, NOT in the Authorization
  header — probe is a bootstrap call for users who don't have a push token yet.
  """
  @spec probe_identity(atom() | String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Errors.t()}
  def probe_identity(provider, access_token, label \\ nil) do
    label = label || device_label()

    body =
      Jason.encode!(%{
        provider: to_string(provider),
        access_token: access_token,
        label: label
      })

    headers = [{"content-type", "application/json"}]
    url = api_base_url() <> "/v1/identity/probe"

    case do_request(:post, url, headers, body, 0) do
      {:ok, 200, _h, resp_body} -> parse_json_body(resp_body, "probe_identity")
      {:ok, 401, _h, _resp_body} -> {:error, :invalid_access_token}
      {:ok, status, _h, resp_body} -> {:error, Errors.from_api_response(status, resp_body, "probe_identity")}
      {:error, %Errors{} = err} -> {:error, err}
    end
    |> tap(&log_token_returning_result("probe_identity", &1))
  end

  @doc """
  Call `POST /v1/namespaces/personal/claim`.

  Claims a personal namespace (1:1 with the user's provider identity) and
  returns a fresh push token for it. The `access_token` is passed in the body
  to prove provider identity at claim time.

  Errors: `:slug_taken` (409), `:already_claimed` (409), `:invalid_label` (400).
  """
  @spec claim_personal_namespace(
          String.t(),
          atom() | String.t(),
          String.t(),
          String.t() | nil
        ) :: {:ok, map()} | {:error, Errors.t()}
  def claim_personal_namespace(username, provider, access_token, label \\ nil) do
    label = label || device_label()

    body =
      Jason.encode!(%{
        username: username,
        provider: to_string(provider),
        access_token: access_token,
        label: label
      })

    headers = [{"content-type", "application/json"}]
    url = api_base_url() <> "/v1/namespaces/personal/claim"

    do_request(:post, url, headers, body, 0)
    |> interpret_access_token_response("claim_personal_namespace")
    |> tap(&log_token_returning_result("claim_personal_namespace", &1))
  end

  @doc """
  Call `POST /v1/namespaces/publisher/claim`.

  Initiates DNS-verified publisher claim. Requires a valid bearer for the
  caller's personal namespace. Returns a TXT challenge to install in DNS.
  """
  @spec claim_publisher_namespace(String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def claim_publisher_namespace(slug, bearer_token) do
    body =
      Jason.encode!(%{slug: slug})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url = api_base_url() <> "/v1/namespaces/publisher/claim"
    do_request(:post, url, headers, body, 0) |> interpret_response("claim_publisher_namespace")
  end

  @doc """
  Call `POST /v1/namespaces/publisher/verify`.

  Verifies the DNS TXT challenge. On success, the caller becomes the sole
  admin of the namespace and receives the first push token for it.
  """
  @spec verify_publisher_namespace(String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def verify_publisher_namespace(slug, bearer_token) do
    body = Jason.encode!(%{slug: slug})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url = api_base_url() <> "/v1/namespaces/publisher/verify"

    do_request(:post, url, headers, body, 0)
    |> interpret_response("verify_publisher_namespace")
    |> tap(&log_token_returning_result("verify_publisher_namespace", &1))
  end

  @doc """
  Call `GET /v1/namespaces/{slug}`. Public endpoint, no auth required.
  """
  @spec get_namespace(String.t()) :: {:ok, map()} | {:error, Errors.t()}
  def get_namespace(slug) do
    url = api_base_url() <> "/v1/namespaces/#{URI.encode(slug)}"
    do_request(:get, url, [], nil, 0) |> interpret_response("get_namespace")
  end

  @doc """
  Call `GET /v1/namespaces/{slug}/tokens`. Lists push tokens for the namespace.

  Auth: Bearer for `{slug}`. The server only lists tokens for the namespace
  the bearer authorizes (403 otherwise). Response shape:
  `{"tokens": [{id, label, created_at, last_used_at, revoked_at, created_via}, ...]}`.
  The response contains token IDs and metadata only — no raw secrets — so
  there is no log-redaction wrapper around this call.
  """
  @spec list_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, Errors.t()}
  def list_tokens(slug, bearer_token) do
    headers = [{"authorization", "Bearer #{bearer_token}"}]
    url = api_base_url() <> "/v1/namespaces/#{URI.encode(slug)}/tokens"
    do_request(:get, url, headers, nil, 0) |> interpret_response("list_tokens")
  end

  @doc """
  Call `POST /v1/namespaces/{slug}/tokens`. Issues an additional push token.
  """
  @spec issue_additional_token(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Errors.t()}
  def issue_additional_token(slug, bearer_token, label \\ nil) do
    label = label || device_label()
    body = Jason.encode!(%{label: label})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url = api_base_url() <> "/v1/namespaces/#{URI.encode(slug)}/tokens"

    do_request(:post, url, headers, body, 0)
    |> interpret_response("issue_additional_token")
    |> tap(&log_token_returning_result("issue_additional_token", &1))
  end

  @doc """
  Call `DELETE /v1/namespaces/{slug}/tokens/{id}`.
  """
  @spec revoke_token(String.t(), String.t(), String.t()) :: :ok | {:error, Errors.t()}
  def revoke_token(slug, token_id, bearer_token) do
    headers = [{"authorization", "Bearer #{bearer_token}"}]
    url = api_base_url() <> "/v1/namespaces/#{URI.encode(slug)}/tokens/#{URI.encode(token_id)}"

    case do_request(:delete, url, headers, nil, 0) do
      {:ok, status, _h, _body} when status in 200..299 -> :ok
      {:ok, status, _h, body} -> {:error, Errors.from_api_response(status, body, "revoke_token")}
      {:error, %Errors{} = err} -> {:error, err}
    end
  end

  @doc """
  Call `POST /v1/namespaces/{slug}/members`. Admin-only.
  """
  @spec add_member(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def add_member(slug, target_personal_slug, role, bearer_token) do
    body = Jason.encode!(%{target_personal_slug: target_personal_slug, role: role})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url = api_base_url() <> "/v1/namespaces/#{URI.encode(slug)}/members"
    do_request(:post, url, headers, body, 0) |> interpret_response("add_member")
  end

  @doc """
  Call `PATCH /v1/namespaces/{slug}/members/{target}`. Admin-only.
  """
  @spec update_member(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def update_member(slug, target_personal_slug, role, bearer_token) do
    body = Jason.encode!(%{role: role})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url =
      api_base_url() <>
        "/v1/namespaces/#{URI.encode(slug)}/members/#{URI.encode(target_personal_slug)}"

    do_request(:patch, url, headers, body, 0) |> interpret_response("update_member")
  end

  @doc """
  Call `DELETE /v1/namespaces/{slug}/members/{target}`. Admin-only.

  Server atomically revokes the removed user's tokens for the namespace.
  """
  @spec remove_member(String.t(), String.t(), String.t()) :: :ok | {:error, Errors.t()}
  def remove_member(slug, target_personal_slug, bearer_token) do
    headers = [{"authorization", "Bearer #{bearer_token}"}]

    url =
      api_base_url() <>
        "/v1/namespaces/#{URI.encode(slug)}/members/#{URI.encode(target_personal_slug)}"

    case do_request(:delete, url, headers, nil, 0) do
      {:ok, status, _h, _body} when status in 200..299 -> :ok
      {:ok, status, _h, body} -> {:error, Errors.from_api_response(status, body, "remove_member")}
      {:error, %Errors{} = err} -> {:error, err}
    end
  end

  @doc """
  Call `GET /v1/namespaces/{slug}/members`. Requires a valid bearer for the
  namespace (admin or member).
  """
  @spec list_members(String.t(), String.t()) :: {:ok, map()} | {:error, Errors.t()}
  def list_members(slug, bearer_token) do
    headers = [{"authorization", "Bearer #{bearer_token}"}]
    url = api_base_url() <> "/v1/namespaces/#{URI.encode(slug)}/members"
    do_request(:get, url, headers, nil, 0) |> interpret_response("list_members")
  end

  # -- Transport --

  defp request(method, path, extra_headers, body, ctx) do
    url = api_base_url() <> path
    headers = auth_headers(ctx) ++ extra_headers
    do_request(method, url, headers, body, 0)
  end

  defp interpret_response({:ok, status, _h, body}, op) when status in 200..299 do
    parse_json_body(body, op)
  end

  defp interpret_response({:ok, status, _h, body}, op) do
    {:error, Errors.from_api_response(status, body, op)}
  end

  defp interpret_response({:error, %Errors{} = err}, _op), do: {:error, err}

  # Access-token endpoints (`/v1/identity/probe`, `/v1/namespaces/personal/claim`)
  # accept the IdP access_token in the request body, NOT a push_token bearer.
  # A 401 from these specifically means "IdP access_token expired or revoked"
  # and must route the user back through OAuth — a push_token re-probe would
  # not help. Surface as a structured tag so callers can redirect to
  # `/auth/reauthenticate`. See auth_refactor.md §3 step 6.
  defp interpret_access_token_response({:ok, status, _h, body}, op) when status in 200..299 do
    parse_json_body(body, op)
  end

  defp interpret_access_token_response({:ok, 401, _h, _body}, _op),
    do: {:error, :invalid_access_token}

  defp interpret_access_token_response({:ok, status, _h, body}, op) do
    {:error, Errors.from_api_response(status, body, op)}
  end

  defp interpret_access_token_response({:error, %Errors{} = err}, _op), do: {:error, err}

  defp parse_json_body("", _op), do: {:ok, %{}}

  defp parse_json_body(body, op) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, Errors.parse_error(op, reason)}
    end
  end

  @doc """
  Human-readable label for the device issuing this probe / token request.

  Precedence (first non-nil wins):

  1. `:cyfr, :device_label` application env (test seam + ops override).
  2. `CYFR_DEVICE_LABEL` OS env var (runtime override).
  3. `:inet.gethostname/0` (the machine's configured hostname).
  4. Literal `"cyfr-host"` fallback.

  Shared single source of truth across `DeviceFlow`, `AuthController`, and
  `ClaimNamespaceController`. Labels are NOT unique — two devices with the
  same hostname produce duplicate-labeled tokens; distinguish by token id +
  `last_used_at` via `cyfr registry tokens list <ns>`.
  """
  @spec device_label() :: String.t()
  def device_label do
    Application.get_env(:cyfr, :device_label) ||
      System.get_env("CYFR_DEVICE_LABEL") ||
      case :inet.gethostname() do
        {:ok, host} -> to_string(host)
        _ -> "cyfr-host"
      end
  end

  # Wraps calls to token-returning endpoints so we never log raw tokens.
  # Phoenix's :filter_parameters only covers inbound request params; outbound
  # response bodies must be redacted explicitly.
  defp log_token_returning_result(op, {:ok, body}) do
    Logger.info("[Compendium.Registry.Client] #{op} succeeded — body=#{inspect(redact(body))}")
    {:ok, body}
  end

  defp log_token_returning_result(op, {:error, err}) do
    Logger.warning("[Compendium.Registry.Client] #{op} failed — err=#{inspect(err)}")
    {:error, err}
  end

  defp log_token_returning_result(_op, other), do: other

  @sensitive_keys ~w(token push_token access_token refresh_token client_secret password)

  defp redact(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} ->
      cond do
        is_binary(k) and k in @sensitive_keys -> {k, "[REDACTED]"}
        is_atom(k) and Atom.to_string(k) in @sensitive_keys -> {k, "[REDACTED]"}
        is_map(v) -> {k, redact(v)}
        is_list(v) -> {k, Enum.map(v, &redact/1)}
        true -> {k, v}
      end
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(other), do: other

  defp do_request(_method, _url, _headers, _body, attempt) when attempt >= @max_retries do
    Logger.error(
      "[Compendium.Registry.Client] All #{@max_retries} retries exhausted for cyfr.run API"
    )

    {:error, Errors.api_connection_error(:max_retries_exceeded)}
  end

  defp do_request(method, url, headers, body, attempt) do
    req =
      Finch.build(method, url, headers, body)

    case Finch.request(req, Compendium.Finch, receive_timeout: @receive_timeout) do
      {:ok, %Finch.Response{status: status, headers: _resp_headers, body: resp_body}}
      when status >= 500 ->
        if attempt + 1 < @max_retries do
          delay = @base_delay_ms * Integer.pow(2, attempt)

          Logger.warning(
            "[Compendium.Registry.Client] #{status} from cyfr.run, retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
          )

          Process.sleep(delay)
          do_request(method, url, headers, body, attempt + 1)
        else
          Logger.error(
            "[Compendium.Registry.Client] #{status} from cyfr.run on final attempt — giving up"
          )

          {:error, Errors.from_api_response(status, resp_body, "request")}
        end

      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, %Mint.TransportError{reason: reason}} ->
        if attempt + 1 < @max_retries do
          delay = @base_delay_ms * Integer.pow(2, attempt)

          Logger.warning(
            "[Compendium.Registry.Client] Connection error: #{inspect(reason)}, retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
          )

          Process.sleep(delay)
          do_request(method, url, headers, body, attempt + 1)
        else
          Logger.error(
            "[Compendium.Registry.Client] Connection error: #{inspect(reason)} — giving up after #{@max_retries} attempts"
          )

          {:error, Errors.api_connection_error(reason)}
        end

      {:error, reason} ->
        if attempt + 1 < @max_retries do
          delay = @base_delay_ms * Integer.pow(2, attempt)

          Logger.warning(
            "[Compendium.Registry.Client] Error: #{inspect(reason)}, retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})"
          )

          Process.sleep(delay)
          do_request(method, url, headers, body, attempt + 1)
        else
          Logger.error(
            "[Compendium.Registry.Client] Error: #{inspect(reason)} — giving up after #{@max_retries} attempts"
          )

          {:error, Errors.api_connection_error(reason)}
        end
    end
  end

  defp api_base_url do
    # REST API host (e.g. "cyfr.run"). Tests point this at a non-routable
    # address (e.g. "127.0.0.1:19") to force connection-refused errors.
    # Sourced from `Compendium.Edition.rest_host/0` so Identity + Client
    # share a single source of truth for the REST host — see §D4 in
    # auth_refactor.md's completion plan.
    "https://#{Edition.rest_host()}"
  end

  # Resolves a push token from CredentialStore and emits `Bearer` for REST API
  # calls. For non-namespace-scoped endpoints (e.g. `/v1/identity/probe`,
  # `/v1/search`), picks the head of `list_for_user/2` — which is the user's
  # personal-namespace token when present, falling back to the first publisher
  # membership token.
  defp auth_headers(ctx) do
    registry = Edition.cyfr_run_registry()

    case ctx do
      %Sanctum.Context{user_id: user_id} when is_binary(user_id) and user_id != "" ->
        case Compendium.Registry.CredentialStore.list_for_user(user_id, registry) do
          [%{type: :push_token, token: token} | _] when is_binary(token) and token != "" ->
            [{"authorization", "Bearer #{token}"}]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp build_search_query(params) do
    pairs =
      [
        {"q", params[:query]},
        {"type", params[:type]},
        {"category", params[:category]},
        {"license", params[:license]},
        {"limit", params[:limit]},
        {"offset", params[:offset]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    pairs =
      case params[:tags] do
        tags when is_list(tags) and tags != [] ->
          pairs ++ Enum.map(tags, fn tag -> {"tags", tag} end)

        _ ->
          pairs
      end

    if pairs == [] do
      ""
    else
      "?" <> URI.encode_query(pairs)
    end
  end

  defp build_discover_query(params) do
    pairs =
      [
        {"publisher", params[:namespace]},
        {"type", params[:type]},
        {"limit", params[:limit]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if pairs == [] do
      ""
    else
      "?" <> URI.encode_query(pairs)
    end
  end
end
