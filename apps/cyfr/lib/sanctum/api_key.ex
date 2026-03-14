defmodule Sanctum.ApiKey do
  @moduledoc """
  API key management for CYFR.

  Provides an interface for creating, retrieving, and managing API keys.
  Keys are stored in SQLite via `Arca.ApiKeyStorage` (through MCP boundary).
  The actual key value is never stored — only a SHA-256 hash for validation
  lookups and a 12-char prefix for redacted display.

  ## Usage

      ctx = Sanctum.Context.local()

      # Create a new API key
      {:ok, %{key: "cyfr_pk_...", name: "frontend-key"}} =
        Sanctum.ApiKey.create(ctx, %{name: "frontend-key", type: :application, scope: ["execution"]})

      # List all keys (keys are redacted)
      {:ok, [%{name: "frontend-key", scope: [...], created_at: ...}]} = Sanctum.ApiKey.list(ctx)

      # Get a specific key by name
      {:ok, %{name: "frontend-key", ...}} = Sanctum.ApiKey.get(ctx, "frontend-key")

      # Revoke a key
      :ok = Sanctum.ApiKey.revoke(ctx, "frontend-key")

      # Rotate a key (creates new key, revokes old)
      {:ok, %{key: "cyfr_pk_...", name: "frontend-key"}} = Sanctum.ApiKey.rotate(ctx, "frontend-key")

      # Validate a key
      {:ok, %{name: "frontend-key", scope: [...]}} = Sanctum.ApiKey.validate("cyfr_pk_...")

      # Validate with IP check (for admin keys)
      {:ok, %{name: "admin-key", ...}} =
        Sanctum.ApiKey.validate("cyfr_ak_...", client_ip: "192.168.1.10")

  ## Storage

  Keys are stored in SQLite via `Arca.ApiKeyStorage`.
  """

  import Bitwise
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
    application: [],
    service: ["secrets_read"],
    admin: ["*"]
  }

  # Maximum allowed scopes per key type
  @type_ceilings %{
    application: ["execute", "secrets_read", "policy_read", "storage_read"],
    service: ["execute", "secrets_read", "secrets_write", "policy_read", "policy_manage",
              "users_read", "storage_read", "storage_write", "execution_write"],
    admin: ["secrets_read", "secrets_write", "users_manage", "admin", "*"]
  }

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

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, result} = Sanctum.ApiKey.create(ctx, %{name: "my-key", scope: ["execution"]})
      iex> String.starts_with?(result.key, "cyfr_pk_")
      true

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, result} = Sanctum.ApiKey.create(ctx, %{name: "backend-key", type: :service})
      iex> String.starts_with?(result.key, "cyfr_sk_")
      true

  """
  def create(%Context{} = ctx, %{name: name} = opts) when is_binary(name) do
    if Application.get_env(:cyfr, :edition, :core) == :arx and ctx.org_id == nil do
      {:error, :org_id_required}
    else
      create_validated(ctx, name, opts)
    end
  end

  def create(_ctx, _opts), do: {:error, "name is required"}

  defp create_validated(ctx, name, opts) do
    key_type = Map.get(opts, :type, :application)

    if key_type not in @valid_key_types do
      {:error, {:invalid_key_type, key_type}}
    else
      scope_list = Map.get(opts, :scope, []) |> normalize_scope()
      scope_list = if scope_list == [], do: Map.get(@type_defaults, key_type, []), else: scope_list
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

    attrs = %{
      name: name,
      key_hash: hash_key(key),
      key_prefix: String.slice(key, 0, 12),
      type: to_string(key_type),
      scope: safe_encode(scope_list),
      rate_limit: Map.get(opts, :rate_limit),
      ip_allowlist: if(ip_allowlist, do: safe_encode(ip_allowlist)),
      created_by: ctx.user_id,
      scope_type: scope_type(ctx),
      org_id: org_id(ctx)
    }

    case Arca.ApiKeyStorage.create_key(attrs) do
      :ok ->
        {:ok, %{key: key, name: name, type: key_type, scope: scope_list, created_at: now}}

      {:error, :already_exists} ->
        {:error, :already_exists}

      error ->
        error
    end
  end

  @doc """
  Get a key by name (key value is redacted).
  """
  def get(%Context{} = ctx, name) when is_binary(name) do
    case Arca.ApiKeyStorage.get_key(name, scope_type(ctx), org_id(ctx)) do
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
    case Arca.ApiKeyStorage.list_keys(scope_type(ctx), org_id(ctx)) do
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
    Arca.ApiKeyStorage.revoke_key(name, scope_type(ctx), org_id(ctx))
  end

  @doc """
  Rotate a key - creates a new key with the same name and settings.
  """
  def rotate(%Context{} = ctx, name) when is_binary(name) do
    case Arca.ApiKeyStorage.get_key(name, scope_type(ctx), org_id(ctx)) do
      {:ok, row} ->
        case parse_key_type(row[:type]) do
          {:ok, key_type} ->
            new_key = generate_key(key_type)
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            scope_list = decode_json(row[:scope], [])

            case Arca.ApiKeyStorage.rotate_key(name, scope_type(ctx), org_id(ctx), hash_key(new_key), String.slice(new_key, 0, 12)) do
              :ok ->
                {:ok, %{key: new_key, name: name, type: key_type, scope: scope_list, rotated_at: now}}

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

  - `:client_ip` - If provided and key has an IP allowlist, validates the IP.

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
    org_id = Keyword.get(opts, :org_id)

    if key_type == :unknown do
      {:error, :invalid_key_format}
    else
      validate_key_internal(key, key_type, client_ip, org_id)
    end
  end

  defp validate_key_internal(key, key_type, client_ip, org_id) do
    if Application.get_env(:cyfr, :edition, :core) == :arx and org_id == nil do
      {:error, :org_id_required}
    else
      validate_key_against_store(key, key_type, client_ip, org_id)
    end
  end

  defp validate_key_against_store(key, key_type, client_ip, org_id) do
    hash = hash_key(key)

    result =
      if org_id != nil and Application.get_env(:cyfr, :edition, :core) == :arx do
        Arca.ApiKeyStorage.get_key_by_hash(hash, org_id)
      else
        Arca.ApiKeyStorage.get_key_by_hash(hash)
      end

    case result do
      {:error, :not_found} ->
        {:error, :invalid_key}

      {:ok, %{revoked: true}} ->
        {:error, :revoked}

      {:ok, row} ->
        ip_allowlist = decode_json(row[:ip_allowlist], nil)

        if client_ip != nil and ip_allowlist != nil and ip_allowlist != [] do
          if ip_allowed?(client_ip, ip_allowlist) do
            {:ok, build_key_metadata(row, key_type)}
          else
            {:error, :ip_not_allowed}
          end
        else
          {:ok, build_key_metadata(row, key_type)}
        end
    end
  end

  defp build_key_metadata(row, key_type) do
    %{
      name: row[:name],
      type: key_type,
      scope: decode_json(row[:scope], []),
      rate_limit: row[:rate_limit],
      ip_allowlist: decode_json(row[:ip_allowlist], nil),
      user_id: row[:created_by],
      org_id: row[:org_id],
      scope_type: row[:scope_type]
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

  defp ip_in_cidr?(ip_string, cidr_string) do
    with {:ok, ip} <- parse_ip(ip_string),
         {:ok, {network, prefix_length}} <- parse_cidr(cidr_string) do
      ip_in_network?(ip, network, prefix_length)
    else
      _ ->
        Logger.warning(
          "[Sanctum.ApiKey] Failed to parse IP/CIDR for allowlist check. " <>
            "IP: #{inspect(ip_string)}, CIDR: #{inspect(cidr_string)}. " <>
            "Expected format: IP like '192.168.1.10', CIDR like '192.168.1.0/24'"
        )

        false
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp parse_cidr(cidr_string) do
    case String.split(cidr_string, "/") do
      [ip_part, prefix_part] ->
        with {:ok, network} <- parse_ip(ip_part),
             {prefix_length, ""} <- Integer.parse(prefix_part) do
          {:ok, {network, prefix_length}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp ip_in_network?(ip, network, prefix_length) do
    ip_bits = ip_to_integer(ip)
    network_bits = ip_to_integer(network)

    # Determine bit size based on IP version
    # IPv4: 4-tuple of 8-bit values = 32 bits
    # IPv6: 8-tuple of 16-bit values = 128 bits
    bit_size = case tuple_size(ip) do
      4 -> 32
      8 -> 128
    end

    # Create mask for the prefix
    mask = bnot(bsl(1, bit_size - prefix_length) - 1) &&& (bsl(1, bit_size) - 1)

    (ip_bits &&& mask) == (network_bits &&& mask)
  end

  defp ip_to_integer({a, b, c, d}) do
    bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    bsl(a, 112) + bsl(b, 96) + bsl(c, 80) + bsl(d, 64) +
      bsl(e, 48) + bsl(f, 32) + bsl(g, 16) + h
  end

  defp detect_key_type("cyfr_pk_" <> _), do: :application
  defp detect_key_type("cyfr_sk_" <> _), do: :service
  defp detect_key_type("cyfr_ak_" <> _), do: :admin
  defp detect_key_type(_), do: :unknown

  # ============================================================================
  # Scope normalization & validation
  # ============================================================================

  defp normalize_scope(scope) when is_binary(scope), do: [scope]
  defp normalize_scope(scope) when is_list(scope), do: scope
  defp normalize_scope(_), do: []

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
      case parse_key_type(row[:type]) do
        {:ok, type} -> type
        {:error, _} -> :unknown
      end

    %{
      name: row[:name],
      type: key_type,
      key_prefix: (row[:key_prefix] || "") <> "...",
      scope: decode_json(row[:scope], []),
      rate_limit: row[:rate_limit],
      ip_allowlist: decode_json(row[:ip_allowlist], nil),
      created_at: format_datetime(row[:inserted_at]),
      rotated_at: format_datetime(row[:rotated_at])
    }
  end

  defp decode_json(nil, default), do: default
  defp decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} ->
        value
      {:error, reason} ->
        Logger.warning("[Sanctum.ApiKey] Failed to decode JSON field: #{inspect(reason)}, input: #{String.slice(json, 0, 100)}. Using default: #{inspect(default)}")
        default
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
  defp format_datetime(other), do: other

  defp scope_type(ctx), do: to_string(ctx.scope)
  defp org_id(ctx), do: ctx.org_id

  defp safe_encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> "[]"
    end
  end
end
