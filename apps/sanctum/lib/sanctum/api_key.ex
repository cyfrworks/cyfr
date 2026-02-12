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
        Sanctum.ApiKey.create(ctx, %{name: "frontend-key", scope: ["execution"]})

      # List all keys (keys are redacted)
      {:ok, [%{name: "frontend-key", scope: [...], created_at: ...}]} = Sanctum.ApiKey.list(ctx)

      # Get a specific key by name
      {:ok, %{name: "frontend-key", ...}} = Sanctum.ApiKey.get(ctx, "frontend-key")

      # Revoke a key
      :ok = Sanctum.ApiKey.revoke(ctx, "frontend-key")

      # Rotate a key (creates new key, revokes old)
      {:ok, %{key: "cyfr_pk_new...", name: "frontend-key"}} = Sanctum.ApiKey.rotate(ctx, "frontend-key")

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
    public: "cyfr_pk_",
    secret: "cyfr_sk_",
    admin: "cyfr_ak_"
  }

  @valid_key_types [:public, :secret, :admin]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new API key.

  ## Options

  - `:name` - Required. Human-readable name for the key.
  - `:type` - Key type: `:public` (default), `:secret`, or `:admin`
  - `:scope` - List of permissions (e.g., ["execution", "component.search"])
  - `:rate_limit` - Rate limit string (e.g., "100/1m")
  - `:ip_allowlist` - List of allowed IPs/CIDRs (e.g., ["192.168.1.0/24", "10.0.0.1"])

  ## Key Types

  - `:public` (`cyfr_pk_`) - Frontend apps, client-side use
  - `:secret` (`cyfr_sk_`) - Backend services
  - `:admin` (`cyfr_ak_`) - CI/CD, automation (recommended with IP allowlist)

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, result} = Sanctum.ApiKey.create(ctx, %{name: "my-key", scope: ["execution"]})
      iex> String.starts_with?(result.key, "cyfr_pk_")
      true

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, result} = Sanctum.ApiKey.create(ctx, %{name: "backend-key", type: :secret})
      iex> String.starts_with?(result.key, "cyfr_sk_")
      true

  """
  def create(%Context{} = ctx, %{name: name} = opts) when is_binary(name) do
    key_type = Map.get(opts, :type, :public)

    if key_type not in @valid_key_types do
      {:error, {:invalid_key_type, key_type}}
    else
      key = generate_key(key_type)
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      scope_list = Map.get(opts, :scope, [])
      ip_allowlist = Map.get(opts, :ip_allowlist)

      attrs = %{
        "name" => name,
        "key_hash" => Base.encode64(hash_key(key)),
        "key_prefix" => String.slice(key, 0, 12),
        "type" => to_string(key_type),
        "scope" => Jason.encode!(scope_list),
        "rate_limit" => Map.get(opts, :rate_limit),
        "ip_allowlist" => if(ip_allowlist, do: Jason.encode!(ip_allowlist)),
        "created_by" => ctx.user_id,
        "scope_type" => scope_type(ctx),
        "org_id" => org_id(ctx)
      }

      case Arca.MCP.handle("api_key_store", ctx, %{"action" => "create", "attrs" => attrs}) do
        {:ok, _} ->
          {:ok, %{key: key, name: name, type: key_type, scope: scope_list, created_at: now}}

        {:error, :already_exists} ->
          {:error, :already_exists}

        error ->
          error
      end
    end
  end

  def create(_ctx, _opts), do: {:error, "name is required"}

  @doc """
  Get a key by name (key value is redacted).
  """
  def get(%Context{} = ctx, name) when is_binary(name) do
    case Arca.MCP.handle("api_key_store", ctx, %{
      "action" => "get",
      "name" => name,
      "scope_type" => scope_type(ctx),
      "org_id" => org_id(ctx)
    }) do
      {:ok, %{key: row}} ->
        {:ok, redact_key(row)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  List all keys (key values are redacted).
  """
  def list(%Context{} = ctx) do
    case Arca.MCP.handle("api_key_store", ctx, %{
      "action" => "list",
      "scope_type" => scope_type(ctx),
      "org_id" => org_id(ctx)
    }) do
      {:ok, %{keys: rows}} ->
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
    case Arca.MCP.handle("api_key_store", ctx, %{
      "action" => "revoke",
      "name" => name,
      "scope_type" => scope_type(ctx),
      "org_id" => org_id(ctx)
    }) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rotate a key - creates a new key with the same name and settings.
  """
  def rotate(%Context{} = ctx, name) when is_binary(name) do
    case Arca.MCP.handle("api_key_store", ctx, %{
      "action" => "get",
      "name" => name,
      "scope_type" => scope_type(ctx),
      "org_id" => org_id(ctx)
    }) do
      {:ok, %{key: row}} ->
        case parse_key_type(row[:type]) do
          {:ok, key_type} ->
            new_key = generate_key(key_type)
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            scope_list = decode_json(row[:scope], [])

            case Arca.MCP.handle("api_key_store", ctx, %{
              "action" => "rotate",
              "name" => name,
              "scope_type" => scope_type(ctx),
              "org_id" => org_id(ctx),
              "new_key_hash" => Base.encode64(hash_key(new_key)),
              "new_key_prefix" => String.slice(new_key, 0, 12)
            }) do
              {:ok, _} ->
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

  defp parse_key_type("public"), do: {:ok, :public}
  defp parse_key_type("secret"), do: {:ok, :secret}
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

    if key_type == :unknown do
      {:error, :invalid_key_format}
    else
      validate_key_internal(key, key_type, client_ip)
    end
  end

  defp validate_key_internal(key, key_type, client_ip) do
    case Arca.MCP.handle("api_key_store", Sanctum.Context.local(), %{
      "action" => "get_by_hash",
      "key_hash" => Base.encode64(hash_key(key))
    }) do
      {:error, :not_found} ->
        {:error, :invalid_key}

      {:ok, %{key: %{revoked: true}}} ->
        {:error, :revoked}

      {:ok, %{key: row}} ->
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
      user_id: row[:created_by]
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

  defp detect_key_type("cyfr_pk_" <> _), do: :public
  defp detect_key_type("cyfr_sk_" <> _), do: :secret
  defp detect_key_type("cyfr_ak_" <> _), do: :admin
  defp detect_key_type(_), do: :unknown

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
      {:ok, value} -> value
      _ -> default
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
end
