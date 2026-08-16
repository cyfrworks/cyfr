# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ApiKey do
  @moduledoc """
  API key management for CYFR.

  Provides an interface for creating, retrieving, and managing API keys.
  Keys are stored via `Arca.ApiKeyStorage` (through MCP boundary).
  The actual key value is never stored — only a SHA-256 hash for validation
  lookups and a 12-char prefix for redacted display.

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Create a new API key
      {:ok, %{api_key: "cyfr_pk_...", name: "frontend-key"}} =
        Sanctum.ApiKey.create(ctx, %{name: "frontend-key", type: :application, scope: ["execution"]})

      # List all keys (keys are redacted)
      {:ok, [%{name: "frontend-key", scope: [...], created_at: ...}]} = Sanctum.ApiKey.list(ctx)

      # Get a specific key by name
      {:ok, %{name: "frontend-key", ...}} = Sanctum.ApiKey.get(ctx, "frontend-key")

      # Revoke a key
      :ok = Sanctum.ApiKey.revoke(ctx, "frontend-key")

      # Rotate a key (creates new key, revokes old)
      {:ok, %{api_key: "cyfr_pk_...", name: "frontend-key"}} = Sanctum.ApiKey.rotate(ctx, "frontend-key")

      # Validate a key
      {:ok, %{name: "frontend-key", scope: [...]}} = Sanctum.ApiKey.validate("cyfr_pk_...")

      # Validate with IP check (for admin keys)
      {:ok, %{name: "admin-key", ...}} =
        Sanctum.ApiKey.validate("cyfr_ak_...", client_ip: "192.168.1.10")

  ## Storage

  Keys are stored via `Arca.ApiKeyStorage`.
  """

  require Logger

  alias Sanctum.Context

  # Key type prefixes
  @key_prefixes %{
    application: "cyfr_pk_",
    service: "cyfr_sk_",
    admin: "cyfr_ak_"
  }

  @valid_key_types [:application, :service, :admin]

  # Default scopes applied when none are specified
  @type_defaults %{
    application: ["execute", "component_read", "storage_read"],
    service: [
      "execute",
      "vault_read",
      "component_read",
      "storage_read",
      "storage_write"
    ],
    admin: ["*"]
  }

  # Maximum allowed scopes per key type
  @type_ceilings %{
    application: ["execute", "vault_read", "component_read", "storage_read"],
    service: [
      "execute",
      "vault_read",
      "vault_write",
      "component_read",
      "component_manage",
      "storage_read",
      "storage_write",
      "execution_write"
    ],
    admin: ["vault_read", "vault_write", "admin", "*"]
  }

  @doc false
  def type_defaults, do: @type_defaults
  @doc false
  def type_ceilings, do: @type_ceilings

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Returns the valid (ceiling) scopes for a key type.
  """
  def valid_scopes(key_type), do: Map.get(@type_ceilings, key_type, [])

  @doc """
  Returns the default scopes for a key type.
  """
  def default_scopes(key_type), do: Map.get(@type_defaults, key_type, [])

  @doc """
  Create a new API key.

  ## Options

  - `:name` - Required. Human-readable name for the key.
  - `:type` - Key type: `:application` (default), `:service`, or `:admin`
  - `:scope` - List of permissions (e.g., ["execution", "component.search"])
  - `:rate_limit` - Rate limit string (e.g., "100/1m")
  - `:ip_allowlist` - List of allowed IPs/CIDRs (e.g., ["192.168.1.0/24", "10.0.0.1"])

  ## Key Types

  - `:application` (`cyfr_pk_`) - Frontend apps, client-side use
  - `:service` (`cyfr_sk_`) - Backend services
  - `:admin` (`cyfr_ak_`) - CI/CD, automation (recommended with IP allowlist)

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> {:ok, result} = Sanctum.ApiKey.create(ctx, %{name: "my-key", scope: ["execution"]})
      iex> String.starts_with?(result.key, "cyfr_pk_")
      true

      iex> ctx = Sanctum.TestContext.local()
      iex> {:ok, result} = Sanctum.ApiKey.create(ctx, %{name: "backend-key", type: :service})
      iex> String.starts_with?(result.key, "cyfr_sk_")
      true

  """
  def create(%Context{} = ctx, %{name: name} = opts) when is_binary(name) do
    case Context.tenant_ok(ctx) do
      {:error, :missing_tenant} -> {:error, :athanor_required}
      :ok -> create_validated(ctx, name, opts)
    end
  end

  def create(_ctx, _opts), do: {:error, "name is required"}

  defp create_validated(ctx, name, opts) do
    key_type = Map.get(opts, :type, :application)

    cond do
      key_type not in @valid_key_types ->
        {:error, {:invalid_key_type, key_type}}

      true ->
        case validate_consent_capability(ctx, Map.get(opts, :consent_capability)) do
          {:ok, capability_json} ->
            create_scoped(ctx, name, key_type, Map.put(opts, :capability_json, capability_json))

          {:error, _} = err ->
            err
        end
    end
  end

  # A consent capability is itself a grant of consent authority, so minting
  # one requires the interactive class — an admin key must not be able to
  # mint the thing that substitutes for interactivity. The envelope is one
  # exact commit digest plus a mandatory expiry (§4.1).
  defp validate_consent_capability(_ctx, nil), do: {:ok, nil}

  defp validate_consent_capability(ctx, %{commit_digest: digest, expires_at: expires_at})
       when is_binary(digest) do
    with {:ok, :interactive} <- Sanctum.Consent.Authz.authorize_interactive(ctx),
         :ok <- check_digest_shape(digest),
         {:ok, expiry} <- parse_expiry(expires_at) do
      {:ok,
       Jason.encode!(%{
         "consent" => %{
           "commit_digest" => digest,
           "expires_at" => DateTime.to_iso8601(expiry)
         }
       })}
    end
  end

  defp validate_consent_capability(_ctx, _other), do: {:error, :invalid_consent_capability}

  defp check_digest_shape("sha256:" <> rest) when byte_size(rest) == 64, do: :ok
  defp check_digest_shape(_), do: {:error, :invalid_consent_capability}

  defp parse_expiry(%DateTime{} = dt), do: check_future(dt)

  defp parse_expiry(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> check_future(dt)
      _ -> {:error, :invalid_consent_capability}
    end
  end

  defp parse_expiry(_), do: {:error, :invalid_consent_capability}

  defp check_future(dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt do
      {:ok, dt}
    else
      {:error, :capability_already_expired}
    end
  end

  defp create_scoped(ctx, name, key_type, opts) do
    # Reject a malformed :scope (not a string / list-of-strings) instead of
    # silently coercing it to [] → type defaults, which would mask a caller
    # error and grant unintended (default) scopes. An absent/empty scope is
    # legitimately "use the type defaults".
    case normalize_scope(Map.get(opts, :scope, [])) do
      {:error, :invalid_scope} = err ->
        err

      {:ok, normalized} ->
        scope_list =
          if normalized == [], do: Map.get(@type_defaults, key_type, []), else: normalized

        ceiling = Map.get(@type_ceilings, key_type, [])

        if not scope_within_ceiling?(scope_list, ceiling) do
          {:error, {:scope_exceeds_ceiling, scope_list, ceiling}}
        else
          create_key(ctx, name, key_type, scope_list, opts)
        end
    end
  end

  defp create_key(ctx, name, key_type, scope_list, opts) do
    key = generate_key(key_type)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    ip_allowlist = Map.get(opts, :ip_allowlist)
    athanor_id = athanor!(ctx)

    attrs = %{
      name: name,
      key_hash: hash_key(key),
      key_prefix: String.slice(key, 0, 12),
      type: to_string(key_type),
      scope: safe_encode(scope_list),
      rate_limit: Map.get(opts, :rate_limit),
      ip_allowlist: if(ip_allowlist, do: safe_encode(ip_allowlist)),
      capability: Map.get(opts, :capability_json),
      created_by: ctx.user_id,
      athanor_id: athanor_id
    }

    case Arca.ApiKeyStorage.create_key(attrs) do
      :ok ->
        {:ok, %{api_key: key, name: name, type: key_type, scope: scope_list, created_at: now}}

      {:error, :already_exists} ->
        # The unique index is partial (WHERE NOT revoked), so a violation
        # always means an ACTIVE key holds the name; revoked keys no longer
        # reserve theirs.
        {:error, :already_exists}

      error ->
        error
    end
  end

  @doc """
  The consent capability carried by a key, in the shape
  `Sanctum.Consent.Authz` consumes: `%{commit_digest, expires_at}` —
  or nil when the key carries none. Malformed stored JSON reads as no
  capability (fail closed).
  """
  @spec consent_capability(Context.t(), String.t() | nil) ::
          {:ok, %{commit_digest: String.t(), expires_at: DateTime.t() | nil} | nil}
  def consent_capability(_ctx, nil), do: {:ok, nil}

  def consent_capability(%Context{} = ctx, api_key_id) when is_binary(api_key_id) do
    with {:ok, row} <- Arca.ApiKeyStorage.get_key_by_id(athanor!(ctx), api_key_id),
         {:ok, %{"consent" => %{"commit_digest" => digest} = consent}} <-
           Jason.decode(row.capability || "null"),
         true <- is_binary(digest),
         # The expiry is mandatory at mint; a stored capability without a
         # parseable one reads as no capability, never as a non-expiring one.
         {:ok, expires_at, _} <- DateTime.from_iso8601(consent["expires_at"] || "") do
      {:ok, %{commit_digest: digest, expires_at: expires_at}}
    else
      _ -> {:ok, nil}
    end
  end

  @doc """
  Get a key by name (key value is redacted).
  """
  def get(%Context{} = ctx, name) when is_binary(name) do
    case Arca.ApiKeyStorage.get_key(name, athanor!(ctx)) do
      {:ok, row} ->
        {:ok, redact_key(row)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  List all keys (key values are redacted).
  """
  def list(%Context{} = ctx) do
    case Arca.ApiKeyStorage.list_keys(athanor!(ctx)) do
      {:ok, rows} ->
        entries = Enum.map(rows, &redact_key/1)
        {:ok, entries}

      error ->
        error
    end
  end

  @doc """
  Revoke a key by name.
  """
  def revoke(%Context{} = ctx, name) when is_binary(name) do
    Arca.ApiKeyStorage.revoke_key(name, athanor!(ctx))
  end

  @doc "Revoke every live key a person created — part of denying them on this server."
  @spec revoke_all_created_by(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_created_by(user_id) when is_binary(user_id) do
    Arca.ApiKeyStorage.revoke_all_created_by(user_id)
  end

  @doc "Revoke every live key of an athanor."
  @spec revoke_all_for_athanor(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_for_athanor(athanor_id) when is_binary(athanor_id) do
    Arca.ApiKeyStorage.revoke_all_for_athanor(athanor_id)
  end

  @doc """
  Rotate a key - creates a new key with the same name and settings.
  """
  def rotate(%Context{} = ctx, name) when is_binary(name) do
    athanor_id = athanor!(ctx)

    case Arca.ApiKeyStorage.get_key(name, athanor_id) do
      {:ok, row} ->
        case parse_key_type(row.type) do
          {:ok, key_type} ->
            new_key = generate_key(key_type)
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            scope_list = decode_json(row.scope, [])

            case Arca.ApiKeyStorage.rotate_key(
                   name,
                   athanor_id,
                   hash_key(new_key),
                   String.slice(new_key, 0, 12)
                 ) do
              :ok ->
                {:ok,
                 %{api_key: new_key, name: name, type: key_type, scope: scope_list, rotated_at: now}}

              error ->
                error
            end

          {:error, _} = error ->
            error
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp parse_key_type("application"), do: {:ok, :application}
  defp parse_key_type("service"), do: {:ok, :service}
  defp parse_key_type("admin"), do: {:ok, :admin}
  defp parse_key_type(unknown), do: {:error, {:unknown_key_type, unknown}}

  @doc """
  Validate an API key and return its metadata.

  This function checks if the key exists and is not revoked.
  Also detects key type from prefix.

  ## Options

  - `:client_ip` - The caller's resolved client IP. A key with an IP
    allowlist is rejected when this is absent: no IP means the restriction
    cannot be proven satisfied, so validation fails closed.

  ## Examples

      iex> {:ok, meta} = Sanctum.ApiKey.validate("cyfr_pk_...")
      iex> meta.name
      "my-key"

      iex> {:ok, meta} = Sanctum.ApiKey.validate("cyfr_ak_...", client_ip: "192.168.1.10")
      iex> meta.name
      "admin-key"

  """
  def validate(key, opts \\ []) when is_binary(key) do
    key_type = detect_key_type(key)
    client_ip = Keyword.get(opts, :client_ip)

    if key_type == :unknown do
      # Equalize the malformed-key fast path with the store-lookup path so a
      # missing/foreign prefix is not distinguishable by response timing.
      _ = hash_key(key)
      {:error, :invalid_key_format}
    else
      validate_key_against_store(key, key_type, client_ip)
    end
  end

  # API keys are athanor credentials: the key hash (192-bit, globally unique)
  # IS the credential, and the athanor is read back FROM the stored key row —
  # never from the request or the creating user's current membership. A
  # single untenanted hash lookup is therefore correct and authoritative; the
  # tenant binding is enforced on the resulting Context via require_tenant!
  # (see Sanctum.ApiKey.context_from_metadata/1), not at lookup time.
  #
  # A key is a standing channel of its athanor: it stops when the athanor is
  # archived or its creator is denied on this server (its creator merely
  # leaving the group leaves it running for the members who remain).
  defp validate_key_against_store(key, key_type, client_ip) do
    case Arca.ApiKeyStorage.get_key_by_hash(hash_key(key)) do
      {:error, :not_found} ->
        {:error, :invalid_key}

      {:ok, %{revoked: true}} ->
        {:error, :revoked}

      {:ok, row} ->
        ip_allowlist = decode_json(row.ip_allowlist, nil)

        cond do
          not Sanctum.Tenancy.channel_active?(row.athanor_id, row.created_by) ->
            {:error, :channel_closed}

          ip_allowlist in [nil, []] ->
            {:ok, build_key_metadata(row, key_type)}

          # An allowlisted key with no caller-supplied IP fails closed:
          # absence of the IP is not proof the restriction is satisfied
          # (Sanctum.ClientIp.resolve/1 is total, so every request path
          # can supply one).
          client_ip == nil ->
            {:error, :ip_not_allowed}

          ip_allowed?(client_ip, ip_allowlist) ->
            {:ok, build_key_metadata(row, key_type)}

          true ->
            {:error, :ip_not_allowed}
        end
    end
  end

  @doc """
  Build an athanor-scoped `Sanctum.Context` from validated API-key metadata.

  Single source of truth for the API-key→Context mapping (used by the MCP
  session plug and the tincture auth resolver — previously two divergent
  copies). API keys belong to an **athanor**: `athanor_id` comes from the
  stored key row (set at creation, gated by the tenant gate), NEVER from the
  request or the creating user's *current* membership. The namespace segment
  is the creator's personal slug (`Sanctum.Namespace.lookup/1`) with a
  `"_system"` orphan fallback when the creator's CredentialStore entry is gone
  (deleted user / wiped slug) so storage path construction fails safe rather
  than crashing.

  The caller is responsible for the tenant gate
  (`Sanctum.Context.require_tenant!/1`) after building — an athanor-less key
  is rejected by `Sanctum.TenantPolicy`.
  """
  @spec context_from_metadata(map()) :: Sanctum.Context.t()
  def context_from_metadata(metadata) when is_map(metadata) do
    permissions =
      metadata.scope
      |> List.wrap()
      |> Enum.map(&Sanctum.Atoms.safe_to_permission_atom/1)
      |> Enum.filter(&is_atom/1)

    # namespace is identity-only (not path-bearing), so a nil is fine. An
    # orphaned key (owner's CredentialStore entry gone) still works — log it so
    # operators can spot keys worth revoking.
    namespace = Sanctum.Namespace.lookup(metadata[:user_id])

    if is_nil(namespace) do
      Logger.warning(
        "[Sanctum.ApiKey] API key namespace lookup returned nil — " <>
          "user_id=#{inspect(metadata[:user_id])} " <>
          "api_key_id=#{inspect(metadata[:id])}. The owning user's " <>
          "CredentialStore entry is missing; consider revoking the key."
      )
    end

    Context.build(
      user_id: metadata[:user_id],
      namespace: namespace,
      athanor_id: metadata[:athanor_id],
      permissions: permissions,
      scope: :athanor,
      auth_method: :api_key,
      api_key_type: metadata.type,
      api_key_id: metadata[:id],
      authenticated: true
    )
  end

  defp build_key_metadata(row, key_type) do
    %{
      id: row.id,
      name: row.name,
      type: key_type,
      scope: decode_json(row.scope, []),
      rate_limit: row.rate_limit,
      ip_allowlist: decode_json(row.ip_allowlist, nil),
      user_id: row.created_by,
      athanor_id: row.athanor_id
    }
  end

  @doc """
  Check if a client IP is allowed by the key's IP allowlist.

  Supports:
  - Exact IP match (e.g., "192.168.1.10")
  - CIDR notation (e.g., "192.168.1.0/24")

  ## Examples

      iex> Sanctum.ApiKey.ip_allowed?("192.168.1.10", ["192.168.1.0/24"])
      true

      iex> Sanctum.ApiKey.ip_allowed?("10.0.0.1", ["192.168.1.0/24"])
      false

      iex> Sanctum.ApiKey.ip_allowed?("192.168.1.10", ["192.168.1.10"])
      true

  """
  def ip_allowed?(client_ip, allowlist) when is_binary(client_ip) and is_list(allowlist) do
    Enum.any?(allowlist, fn pattern ->
      ip_matches?(client_ip, pattern)
    end)
  end

  defp ip_matches?(client_ip, pattern) when is_binary(client_ip) and is_binary(pattern) do
    cond do
      # Exact match
      client_ip == pattern ->
        true

      # CIDR notation
      String.contains?(pattern, "/") ->
        ip_in_cidr?(client_ip, pattern)

      # No match
      true ->
        false
    end
  end

  # Exact-IP match stays a string compare in ip_matches?/2; only the CIDR
  # arithmetic is delegated to the Sanctum.Cidr SSOT. The operator-facing
  # misconfig warning is preserved (fires whenever the IP or CIDR is
  # unparseable, exactly as before). ip_in_network?/3 is used directly (no
  # v4-mapped unwrap) to keep this path's prior behaviour identical.
  defp ip_in_cidr?(ip_string, cidr_string) do
    case {Sanctum.Cidr.parse_ip(ip_string), Sanctum.Cidr.parse_cidr(cidr_string)} do
      {{:ok, ip}, {:ok, {network, prefix_length}}} ->
        Sanctum.Cidr.ip_in_network?(ip, network, prefix_length)

      _ ->
        Logger.warning(
          "[Sanctum.ApiKey] Failed to parse IP/CIDR for allowlist check. " <>
            "IP: #{inspect(ip_string)}, CIDR: #{inspect(cidr_string)}. " <>
            "Expected format: IP like '192.168.1.10', CIDR like '192.168.1.0/24'"
        )

        false
    end
  end

  @doc """
  True when `key` carries a recognized `cyfr_` API-key prefix.

  Single source of truth for "is this string an API key at all", shared by the
  authentication plug and the tincture auth resolver so the prefix check cannot
  drift between entry points.
  """
  @spec looks_like_key?(term()) :: boolean()
  def looks_like_key?(key) when is_binary(key), do: detect_key_type(key) != :unknown
  def looks_like_key?(_), do: false

  defp detect_key_type("cyfr_pk_" <> _), do: :application
  defp detect_key_type("cyfr_sk_" <> _), do: :service
  defp detect_key_type("cyfr_ak_" <> _), do: :admin
  defp detect_key_type(_), do: :unknown

  # ============================================================================
  # Scope normalization & validation
  # ============================================================================

  defp normalize_scope(nil), do: {:ok, []}
  defp normalize_scope(scope) when is_binary(scope), do: {:ok, [scope]}

  defp normalize_scope(scope) when is_list(scope) do
    if Enum.all?(scope, &is_binary/1), do: {:ok, scope}, else: {:error, :invalid_scope}
  end

  defp normalize_scope(_), do: {:error, :invalid_scope}

  defp scope_within_ceiling?(scope_list, _ceiling) when scope_list == [], do: true
  defp scope_within_ceiling?(_scope_list, ceiling) when ceiling == [], do: false

  defp scope_within_ceiling?(scope_list, ceiling) do
    "*" in ceiling or Enum.all?(scope_list, &(&1 in ceiling))
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp generate_key(type) do
    prefix = Map.fetch!(@key_prefixes, type)
    random = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    prefix <> random
  end

  defp hash_key(key), do: :crypto.hash(:sha256, key)

  defp redact_key(row) do
    key_type =
      case parse_key_type(row.type) do
        {:ok, type} -> type
        {:error, _} -> :unknown
      end

    %{
      name: row.name,
      type: key_type,
      key_prefix: (row.key_prefix || "") <> "...",
      scope: decode_json(row.scope, []),
      rate_limit: row.rate_limit,
      ip_allowlist: decode_json(row.ip_allowlist, nil),
      created_at: format_datetime(row.inserted_at),
      rotated_at: format_datetime(row.rotated_at)
    }
  end

  defp decode_json(nil, default), do: default

  defp decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} ->
        value

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.ApiKey] Failed to decode JSON field: #{inspect(reason)}, input: #{String.slice(json, 0, 100)}. Using default: #{inspect(default)}"
        )

        default
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: other

  # The athanor every key path keys on, behind the tenant chokepoint: an
  # athanor-less context raises before it can touch any row.
  defp athanor!(%Context{} = ctx), do: Context.athanor!(ctx)

  defp safe_encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> "[]"
    end
  end
end
