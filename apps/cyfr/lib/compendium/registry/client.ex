# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.Client do
  @moduledoc """
  REST client for the cyfr.run registry API.

  Sibling of `Compendium.Registry.Identity` (reads identity from stored push
  tokens) and `Compendium.Registry.CredentialStore` (persists those tokens).
  This module talks the wire protocol; the other two own local state.

  Handles search, discover, component metadata, namespace, tokens and
  members endpoints (`/v1/*`), and every operation a person signs
  (`signed/3`, `Prima.RegistryRequest`): no identity provider's token is
  ever sent. Push and pull use OCI protocol through the gateway
  (`registry.cyfr.run/v2/`) via `Compendium.OCI.Client`.

  Works against both the apex cyfr.run and a self-hosted cyfr.run — the
  REST host is sourced from `:cyfr, :registry_url` and is build-agnostic.
  """

  require Logger

  alias Compendium.OCI.Errors
  alias Compendium.Registry.CredentialStore
  alias Compendium.Registry.Transport
  alias Sanctum.Context

  # -- Public API --

  # The caller's stored push token does not open: nothing is sent, under
  # this token or any other.
  @type corrupt :: {:corrupt, :registry_credential}

  @doc """
  Search for components on the cyfr.run registry.

  Sends GET /v1/components with query parameters (q, type, category, tags, license, limit, offset).
  Auth is not required for search (public endpoint).
  """
  @spec search(Context.t(), map()) :: {:ok, map()} | {:error, Errors.t() | corrupt()}
  def search(%Context{} = ctx, params) when is_map(params) do
    query = build_search_query(params)
    path = "/v1/components" <> query

    case request(:get, path, [], nil, ctx) do
      {:ok, 200, _headers, body} ->
        case listing(body) do
          {:ok, components, total} -> {:ok, %{components: components, total: total}}
          {:error, reason} -> {:error, Errors.parse_error("search", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "search")}

      {:error, %Errors{} = err} ->
        {:error, err}

      {:error, {:corrupt, :registry_credential}} = corrupt ->
        corrupt
    end
  end

  @doc """
  Discover components on the cyfr.run registry.

  Sends GET /v1/components with publisher/namespace filter.
  """
  @spec discover(Context.t(), map()) :: {:ok, map()} | {:error, Errors.t() | corrupt()}
  def discover(%Context{} = ctx, params) when is_map(params) do
    query = build_discover_query(params)
    path = "/v1/components" <> query

    case request(:get, path, [], nil, ctx) do
      {:ok, 200, _headers, body} ->
        case listing(body) do
          {:ok, components, total} ->
            {:ok,
             %{
               registry: Compendium.RegistryHost.canonical_host(),
               components: components,
               total: total
             }}

          {:error, reason} ->
            {:error, Errors.parse_error("discover", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "discover")}

      {:error, %Errors{} = err} ->
        {:error, err}

      {:error, {:corrupt, :registry_credential}} = corrupt ->
        corrupt
    end
  end

  @doc """
  Get component metadata from the cyfr.run index.

  Sends GET /v1/components/:type/:publisher/:name/:version.
  """
  @spec get_component(Context.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t() | corrupt()}
  def get_component(%Context{} = ctx, type, publisher, name, version) do
    path = "/v1/components/#{seg(type)}/#{seg(publisher)}/#{seg(name)}/#{seg(version)}"

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

      {:error, {:corrupt, :registry_credential}} = corrupt ->
        corrupt
    end
  end

  # Each operation a person signs, and the route the registry takes it at.
  @routes %{
    "handle.claim" => "/v1/namespaces/personal/claim",
    "tokens.mint" => "/v1/tokens/mint",
    "address.set" => "/v1/handles/address",
    "policy.accept" => "/v1/legal/accept",
    "appeal.file" => "/v1/appeals",
    "publisher.claim" => "/v1/namespaces/publisher/claim",
    "publisher.verify" => "/v1/namespaces/publisher/verify"
  }

  # The operations whose answer carries a push token: their log line is
  # redacted.
  @token_answers ["tokens.mint", "publisher.verify"]

  @typedoc """
  Why a signed operation did not complete: the signer's refusals
  (`Sanctum.Person.sign_registry_request/3`), the registry's
  (`Prima.RegistryRequest.refusals/0`, `policy_required` carrying the
  version the registry requires), `:registry_unavailable` for no usable
  answer, and `:malformed_answer` for an answer that cannot be read.
  """
  @type signed_refusal ::
          Prima.RegistryRequest.refusal()
          | {:policy_required, String.t() | nil}
          | :no_registry
          | :not_enrolled
          | :remote
          | :not_found
          | :unavailable
          | :registry_unavailable
          | :malformed_answer
          | {:invalid_argument, String.t()}

  @doc """
  Sign `operation` with `body` as the person `user_id`
  (`Sanctum.Person.sign_registry_request/3`) and send it to the route
  the registry takes it at. Answers the registry's decoded answer, or a
  refusal (`t:signed_refusal/0`). A request the registry refuses as
  `stale_key_epoch`, the person's keys having rotated between the signing
  and the registry's read, is signed again under the new head and sent
  once more. Nothing is written here: what the answer means is the
  caller's.

  The request runs in the calling process, so it stops with it; a
  registry that cannot be reached, or answers 5xx, is
  `:registry_unavailable` and a `POST` is never replayed after the
  registry may have acted on it (`Compendium.Registry.Transport`).
  """
  @spec signed(String.t(), String.t(), map()) :: {:ok, map()} | {:error, signed_refusal()}
  def signed(user_id, operation, body)
      when is_binary(user_id) and is_map_key(@routes, operation) and is_map(body) do
    result =
      case send_signed(user_id, operation, body) do
        {:error, :stale_key_epoch} -> send_signed(user_id, operation, body)
        result -> result
      end

    log_signed(operation, result)
    result
  end

  defp send_signed(user_id, operation, body) do
    with {:ok, bytes} <- Sanctum.Person.sign_registry_request(user_id, operation, body) do
      :post
      |> Transport.request(url(Map.fetch!(@routes, operation)), json_headers(), bytes)
      |> signed_answer()
    end
  end

  defp signed_answer({:ok, status, _headers, body}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{} = answer} -> {:ok, answer}
      _unreadable -> {:error, :malformed_answer}
    end
  end

  defp signed_answer({:ok, status, _headers, body}) do
    case Prima.RegistryRequest.refusal(body) do
      {:ok, :policy_required} -> {:error, {:policy_required, required_version(body)}}
      {:ok, refusal} -> {:error, refusal}
      {:error, :malformed_answer} when status >= 500 -> {:error, :registry_unavailable}
      {:error, :malformed_answer} -> {:error, :malformed_answer}
    end
  end

  defp signed_answer({:error, %Errors{reason: :registry_unconfigured}}),
    do: {:error, :no_registry}

  defp signed_answer({:error, %Errors{}}), do: {:error, :registry_unavailable}

  # The version a `POLICY_ACCEPTANCE_REQUIRED` envelope carries beside its
  # errors, when it is text.
  defp required_version(body) do
    case Jason.decode(body) do
      {:ok, %{"required_version" => version}} when is_binary(version) -> version
      _none -> nil
    end
  end

  defp log_signed(operation, {:ok, answer}) when operation in @token_answers,
    do: log_token_returning_result(operation, {:ok, answer})

  defp log_signed(_operation, {:ok, _answer}), do: :ok

  defp log_signed(operation, {:error, reason}),
    do: Logger.warning("[Compendium.Registry.Client] #{operation} refused — #{inspect(reason)}")

  @doc """
  Call `GET /v1/namespaces/{slug}`. Public endpoint, no auth required.
  """
  @spec get_namespace(String.t()) :: {:ok, map()} | {:error, Errors.t()}
  def get_namespace(slug) do
    url = url("/v1/namespaces/#{seg(slug)}")
    Transport.request(:get, url, [], nil) |> interpret_response("get_namespace")
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
    headers = bearer(bearer_token)
    url = url("/v1/namespaces/#{seg(slug)}/tokens")
    Transport.request(:get, url, headers, nil) |> interpret_response("list_tokens")
  end

  @doc """
  Call `POST /v1/namespaces/{slug}/tokens`. Issues an additional push token.
  """
  @spec issue_additional_token(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Errors.t()}
  def issue_additional_token(slug, bearer_token, label \\ nil) do
    label = label || CredentialStore.device_label()
    body = Jason.encode!(%{label: label})

    headers = json_headers() ++ bearer(bearer_token)

    url = url("/v1/namespaces/#{seg(slug)}/tokens")

    Transport.request(:post, url, headers, body)
    |> interpret_response("issue_additional_token")
    |> tap(&log_token_returning_result("issue_additional_token", &1))
  end

  @doc """
  Call `DELETE /v1/namespaces/{slug}/tokens/{id}`.
  """
  @spec revoke_token(String.t(), String.t(), String.t()) :: :ok | {:error, Errors.t()}
  def revoke_token(slug, token_id, bearer_token) do
    headers = bearer(bearer_token)
    url = url("/v1/namespaces/#{seg(slug)}/tokens/#{seg(token_id)}")

    case Transport.request(:delete, url, headers, nil) do
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

    headers = json_headers() ++ bearer(bearer_token)

    url = url("/v1/namespaces/#{seg(slug)}/members")
    Transport.request(:post, url, headers, body) |> interpret_response("add_member")
  end

  @doc """
  Call `PATCH /v1/namespaces/{slug}/members/{target}`. Admin-only.
  """
  @spec update_member(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Errors.t()}
  def update_member(slug, target_personal_slug, role, bearer_token) do
    body = Jason.encode!(%{role: role})

    headers = json_headers() ++ bearer(bearer_token)

    url = url("/v1/namespaces/#{seg(slug)}/members/#{seg(target_personal_slug)}")

    Transport.request(:patch, url, headers, body) |> interpret_response("update_member")
  end

  @doc """
  Call `DELETE /v1/namespaces/{slug}/members/{target}`. Admin-only.

  Server atomically revokes the removed user's tokens for the namespace.
  """
  @spec remove_member(String.t(), String.t(), String.t()) :: :ok | {:error, Errors.t()}
  def remove_member(slug, target_personal_slug, bearer_token) do
    headers = bearer(bearer_token)

    url = url("/v1/namespaces/#{seg(slug)}/members/#{seg(target_personal_slug)}")

    case Transport.request(:delete, url, headers, nil) do
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
    headers = bearer(bearer_token)
    url = url("/v1/namespaces/#{seg(slug)}/members")
    Transport.request(:get, url, headers, nil) |> interpret_response("list_members")
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

    headers = json_headers() ++ bearer(bearer_token)

    url = url("/v1/components/#{seg(slug)}/#{seg(type)}/#{seg(name)}/#{seg(version)}/#{action}")

    Transport.request(:post, url, headers, body)
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

    headers = json_headers() ++ bearer(bearer_token)

    url = url("/v1/abuse-reports")
    Transport.request(:post, url, headers, body) |> interpret_response("create_abuse_report")
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

    headers = bearer(bearer_token)

    url = url("/v1/abuse-reports/mine?" <> query)
    Transport.request(:get, url, headers, "") |> interpret_response("list_my_reports")
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
    url = url("/v1/legal/" <> seg(name))
    Transport.request(:get, url, [], "") |> interpret_response("get_legal_page")
  end

  @doc """
  Call `GET /v1/legal/version`. Returns `{policy_version, policies}` where
  `policies` is a list of `{name, title, sha256}` for the current bundled
  set. Drives the clickwrap UI in prism / codex.
  """
  @spec get_legal_version() :: {:ok, map()} | {:error, Errors.t()}
  def get_legal_version do
    url = url("/v1/legal/version")
    Transport.request(:get, url, [], "") |> interpret_response("get_legal_version")
  end

  # -- Transport --

  defp seg(value), do: Transport.path_segment(value)

  # The three shapes every endpoint builds. Spelled once so a new endpoint
  # cannot reach a different host, or send a bearer the log redaction and the
  # `auth_headers/1` lookup do not know about.
  defp url(path), do: api_base_url() <> path
  defp bearer(token), do: [{"authorization", "Bearer #{token}"}]
  defp json_headers, do: [{"content-type", "application/json"}]

  defp request(method, path, extra_headers, body, ctx) do
    with {:ok, auth} <- auth_headers(ctx) do
      Transport.request(method, url(path), auth ++ extra_headers, body)
    end
  end

  defp interpret_response({:ok, status, _h, body}, op) when status in 200..299 do
    parse_json_body(body, op)
  end

  defp interpret_response({:ok, status, _h, body}, op) do
    {:error, Errors.from_api_response(status, body, op)}
  end

  defp interpret_response({:error, %Errors{} = err}, _op), do: {:error, err}

  defp parse_json_body("", _op), do: {:ok, %{}}

  defp parse_json_body(body, op) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, Errors.parse_error(op, reason)}
    end
  end

  # Wraps calls to token-returning endpoints so we never log raw tokens.
  # Phoenix's :filter_parameters only covers inbound request params; outbound
  # response bodies are redacted here, by the same vocabulary.
  defp log_token_returning_result(op, {:ok, body}) do
    Logger.info(
      "[Compendium.Registry.Client] #{op} succeeded — body=#{inspect(Prima.Sanitizer.sanitize(body))}"
    )

    {:ok, body}
  end

  defp log_token_returning_result(op, {:error, err}) do
    Logger.warning("[Compendium.Registry.Client] #{op} failed — err=#{inspect(err)}")
    {:error, err}
  end

  # The REST API host (`Compendium.RegistryHost.canonical_rest_host/0`, the
  # one source Identity reads too), under the scheme its host takes.
  defp api_base_url,
    do: Compendium.RegistryHost.base_url(Compendium.RegistryHost.canonical_rest_host())

  # Resolves a push token from CredentialStore and emits `Bearer` for REST API
  # calls. For non-namespace-scoped endpoints (e.g. `/v1/search`), picks the first usable token of `list_for_user/2` — the
  # user's personal-namespace token when present, falling back to the first
  # publisher membership token. A store that cannot be read, or a listing
  # holding a damaged row, refuses the request before it leaves: sending it
  # anonymously, or under another namespace's token, would come back as
  # some other refusal.
  defp auth_headers(ctx) do
    registry = Compendium.RegistryHost.canonical_host()

    case ctx do
      %Sanctum.Context{user_id: user_id} when is_binary(user_id) and user_id != "" ->
        case CredentialStore.list_for_user(ctx, registry) do
          {:ok, entries} ->
            case CredentialStore.push_tokens(entries) do
              {:ok, [%{token: token} | _]} when token != "" -> {:ok, bearer(token)}
              {:ok, _none} -> {:ok, []}
              {:error, {:corrupt, :registry_credential}} = corrupt -> corrupt
            end

          {:error, _unreadable} ->
            {:error, credentials_unavailable()}
        end

      _ ->
        {:ok, []}
    end
  end

  defp credentials_unavailable do
    %Errors{
      reason: :registry_unavailable,
      message: "Your registry credentials could not be read — retry shortly",
      registry: nil,
      status: nil,
      detail: %{credential_store: :unavailable}
    }
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

  # A cyfr.run component entry as the atom-keyed row a tool result
  # carries (`PrismWeb.Ops`' contract): the fields named here, and nothing
  # else of the entry. The wire names the owning slug `namespace_slug`;
  # the row carries it under that name and as `publisher`, the name every
  # local row uses, so a merged listing reads one field for both.
  @component_fields ~w(id name version component_type namespace_slug description digest
                       size tags category license status status_reason created_at updated_at)a

  # A `/v1/components` answer: its entries, each an object, and its total.
  defp listing(body) do
    case Jason.decode(body) do
      {:ok, %{"components" => entries, "total" => total} = answer}
      when is_list(entries) and is_integer(total) ->
        if Enum.all?(entries, &is_map/1),
          do: {:ok, Enum.map(entries, &component_row/1), total},
          else: {:error, answer}

      {:ok, unexpected} ->
        {:error, unexpected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp component_row(entry) do
    row =
      for field <- @component_fields, Map.has_key?(entry, Atom.to_string(field)), into: %{} do
        {field, Map.fetch!(entry, Atom.to_string(field))}
      end

    case row do
      %{namespace_slug: slug} -> Map.put(row, :publisher, slug)
      row -> row
    end
  end
end
