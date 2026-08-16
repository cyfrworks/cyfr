# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  Works against both the apex cyfr.run and a self-hosted cyfr.run — the
  REST host is sourced from `:cyfr, :registry_url` and is build-agnostic.
  """

  require Logger

  alias Compendium.Registry, as: CompendiumRegistry
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
  Replaces the fragile _catalog approach for default-mode deployments.
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
               registry: CompendiumRegistry.canonical_host(),
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
      {:ok, 200, _h, resp_body} ->
        parse_json_body(resp_body, "probe_identity")

      {:ok, 401, _h, _resp_body} ->
        {:error, :invalid_access_token}

      {:ok, status, _h, resp_body} ->
        {:error, Errors.from_api_response(status, resp_body, "probe_identity")}

      {:error, %Errors{} = err} ->
        {:error, err}
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

  # -- Component status moderation (deprecate / yank) --

  @doc """
  Call `POST /v1/components/{slug}/{type}/{name}/{version}/deprecate`.

  Marks a component version as deprecated. Pinned pulls still succeed with a
  warning header; non-pinned resolution demotes deprecated versions behind
  active ones. Reason is required and surfaced on pull.

  Auth: push token for `{slug}` (the component's owning namespace). Token
  namespace must match the URL slug or server returns 403 NAMESPACE_MISMATCH.

  Errors: `:taken_down_locked` (409) when the component is already taken down,
  `:not_found` (404) when the version doesn't exist, `:invalid_reason` (400).
  """
  @spec deprecate_component(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, map()} | {:error, Errors.t()}
  def deprecate_component(slug, type, name, version, reason, bearer_token) do
    transition_component_status(slug, type, name, version, "deprecate", reason, bearer_token)
  end

  @doc """
  Call `POST /v1/components/{slug}/{type}/{name}/{version}/yank`.

  Marks a component version as yanked — stronger signal than deprecate.
  Yanked versions are excluded from search and non-pinned resolution; pinned
  pulls still succeed (reproducibility). Reason optional (empty string allowed).

  Auth: push token for `{slug}` scoped to the component's owning namespace.
  """
  @spec yank_component(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def yank_component(slug, type, name, version, reason, bearer_token) do
    transition_component_status(slug, type, name, version, "yank", reason, bearer_token)
  end

  defp transition_component_status(slug, type, name, version, action, reason, bearer_token) do
    body = Jason.encode!(%{reason: reason})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url =
      api_base_url() <>
        "/v1/components/#{URI.encode(slug)}/#{URI.encode(type)}/#{URI.encode(name)}/#{URI.encode(version)}/#{action}"

    do_request(:post, url, headers, body, 0)
    |> interpret_response("#{action}_component")
  end

  # -- Abuse reports --

  @doc """
  Call `POST /v1/abuse-reports`. Auth: any valid push token (user must hold
  at least one — verified server-side). Body carries category + target +
  details; `reporter_created_via` is captured server-side from the bearer.

  At least one of `target_namespace` or `target_component_id` must be set.
  """
  @spec create_abuse_report(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, Errors.t()}
  def create_abuse_report(category, target_namespace, target_component_id, details, bearer_token) do
    body =
      Jason.encode!(%{
        category: category,
        target_namespace: target_namespace,
        target_component_id: target_component_id,
        details: details
      })

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url = api_base_url() <> "/v1/abuse-reports"
    do_request(:post, url, headers, body, 0) |> interpret_response("create_abuse_report")
  end

  @doc """
  Call `GET /v1/abuse-reports/mine`. Auth: any valid push token. Returns
  the caller's own abuse reports (scoped server-side by the token's
  identity tuple), newest-first, paginated.

  Options:
    * `:limit` — page size, default 50, max 200.
    * `:offset` — starting row, default 0.
  """
  @spec list_my_reports(String.t(), keyword()) :: {:ok, map()} | {:error, Errors.t()}
  def list_my_reports(bearer_token, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query =
      URI.encode_query(%{
        "limit" => Integer.to_string(limit),
        "offset" => Integer.to_string(offset)
      })

    headers = [
      {"authorization", "Bearer #{bearer_token}"}
    ]

    url = api_base_url() <> "/v1/abuse-reports/mine?" <> query
    do_request(:get, url, headers, "", 0) |> interpret_response("list_my_reports")
  end

  @doc """
  Call `GET /v1/legal/{name}`. Auth: optional (the endpoint sits inside
  the /v1/* router with optional auth). Returns the legal page as
  `{name, title, content_markdown}`. The cyfr client renders the
  markdown locally; cyfr.run hosts no /legal/* HTML pages under the
  closed-platform posture.
  """
  @spec get_legal_page(String.t()) :: {:ok, map()} | {:error, Errors.t()}
  def get_legal_page(name) when is_binary(name) do
    url = api_base_url() <> "/v1/legal/" <> URI.encode(name)
    do_request(:get, url, [], "", 0) |> interpret_response("get_legal_page")
  end

  @doc """
  Call `GET /v1/legal/version`. Returns `{policy_version, policies}` where
  `policies` is a list of `{name, title, sha256}` for the current bundled
  set. Drives the clickwrap UI in prism / codex.
  """
  @spec get_legal_version() :: {:ok, map()} | {:error, Errors.t()}
  def get_legal_version do
    url = api_base_url() <> "/v1/legal/version"
    do_request(:get, url, [], "", 0) |> interpret_response("get_legal_version")
  end

  @doc """
  Call `POST /v1/legal/accept`. Records an explicit clickwrap acceptance
  for the authenticated identity at the current `policy_version`. Token
  verification mirrors namespace claim — the OAuth `access_token` (or
  `id_token` for OIDC) is in the body and verified server-side via
  provider userinfo.

  Idempotent: a second call under the same (provider, subject, version)
  returns 200 with the same row's id; first call returns 201.

  Errors that callers should surface:
    * `:policy_version_mismatch` (412) — server's current `policy_version`
      differs from the one we posted; client re-fetches `get_legal_version`
      and re-prompts the user.
    * `:unauthorized` (403 IDENTITY_BANNED) — surface ban response.
    * `:invalid_access_token` (401) — IdP token expired; route to OAuth.
  """
  @spec accept_policies(
          atom() | String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t()
        ) :: {:ok, map()} | {:error, Errors.t()}
  def accept_policies(provider, access_token, id_token, policy_version) do
    body =
      Jason.encode!(%{
        provider: to_string(provider),
        access_token: access_token,
        id_token: id_token,
        policy_version: policy_version
      })

    headers = [{"content-type", "application/json"}]
    url = api_base_url() <> "/v1/legal/accept"
    do_request(:post, url, headers, body, 0) |> interpret_access_token_response("accept_policies")
  end

  @doc """
  Call `POST /v1/appeals`. Closed-platform appeal flow: cyfr client
  drives the OAuth round-trip (DeviceFlow) itself and posts the
  resulting access_token here. cyfr.run verifies via provider userinfo
  and binds to the action's rightful appellant.
  """
  @spec create_appeal(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, Errors.t()}
  def create_appeal(provider, access_token, id_token, action_type, action_ref, argument) do
    body =
      Jason.encode!(%{
        provider: provider,
        access_token: access_token,
        id_token: id_token,
        action_type: action_type,
        action_ref: action_ref,
        argument: argument
      })

    headers = [{"content-type", "application/json"}]
    url = api_base_url() <> "/v1/appeals"
    do_request(:post, url, headers, body, 0) |> interpret_response("create_appeal")
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
  # `/auth/reauthenticate`.
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
    # address (e.g. "127.0.0.1:19") to force connection-refused errors, or at
    # a Bypass HTTP server (with :registry_scheme override) for wire-level
    # happy-path tests. Host comes from `Compendium.Registry.canonical_rest_host/0` so
    # Identity + Client share a single source of truth.
    "#{scheme()}://#{CompendiumRegistry.canonical_rest_host()}"
  end

  # `https` in production; tests override to `http` to talk to a Bypass
  # server without a TLS dance.
  defp scheme, do: Application.get_env(:cyfr, :registry_scheme, "https")

  # Resolves a push token from CredentialStore and emits `Bearer` for REST API
  # calls. For non-namespace-scoped endpoints (e.g. `/v1/identity/probe`,
  # `/v1/search`), picks the head of `list_for_user/2` — which is the user's
  # personal-namespace token when present, falling back to the first publisher
  # membership token.
  defp auth_headers(ctx) do
    registry = CompendiumRegistry.canonical_host()

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
