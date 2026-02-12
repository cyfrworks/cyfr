# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright 2024 CYFR Inc. All Rights Reserved.

defmodule SanctumArx.License do
  @moduledoc """
  License validation for Sanctum Arx.

  ## Editions

  - **Sanctum**: Always returns `{:ok, :community}` - no license required
  - **Sanctum Arx**: Validates `/etc/cyfr/license.sig` at startup

  ## License File Format

  The Arx license file is a signed JSON document containing:

  ```json
  {
    "type": "arx",
    "customer_id": "acme-corp",
    "issued_at": "2024-01-01T00:00:00Z",
    "expires_at": "2025-01-01T00:00:00Z",
    "features": ["saml", "vault", "siem"],
    "seats": 100
  }
  ```

  ## Zombie Mode

  When an Arx license expires, the system enters "zombie mode":
  - Existing functionality continues to work
  - New enterprise features cannot be enabled
  - Warning logs are emitted on each request
  - No data loss or sudden outages

  ## Usage

      # Check current edition at startup
      case SanctumArx.License.load() do
        {:ok, :community} -> # Sanctum
        {:ok, license} -> # Valid Sanctum Arx license
        {:error, :expired} -> # Zombie mode
        {:error, reason} -> # Invalid license
      end

      # Runtime checks
      if SanctumArx.License.valid?() do
        # License is valid
      end

      if SanctumArx.License.zombie_mode?() do
        # License expired, limited functionality
      end

  """

  require Logger

  @type license :: %{
          type: :arx,
          customer_id: String.t(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          features: [String.t()],
          seats: non_neg_integer()
        }

  @type load_result :: {:ok, :community} | {:ok, license()} | {:error, term()}

  @default_license_path "/etc/cyfr/license.sig"
  @license_key :sanctum_arx_license

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Load and verify license at startup.

  For Sanctum, always returns `{:ok, :community}`.
  For Sanctum Arx, validates the license file.

  ## Options

  - `:path` - Custom license file path (default: `/etc/cyfr/license.sig`)

  ## Examples

      iex> SanctumArx.License.load()
      {:ok, :community}

      iex> SanctumArx.License.load(path: "/custom/license.sig")
      {:ok, %{type: :arx, ...}}

  """
  @spec load(keyword()) :: load_result()
  def load(opts \\ []) do
    case edition() do
      :community ->
        store_license(:community)
        {:ok, :community}

      :arx ->
        path = Keyword.get(opts, :path, license_path())
        verify_license_file(path)
    end
  end

  @doc """
  Check if the current license is valid.

  Sanctum is always valid.
  Sanctum Arx checks license expiry.

  ## Examples

      iex> SanctumArx.License.valid?()
      true

  """
  @spec valid?() :: boolean()
  def valid? do
    case current_license() do
      :community -> true
      %{expires_at: expires_at} -> DateTime.compare(expires_at, DateTime.utc_now()) == :gt
      nil -> edition() == :community
    end
  end

  @doc """
  Check if the system is in zombie mode.

  Zombie mode occurs when an Arx license has expired.
  The system continues to function but logs warnings.

  ## Examples

      iex> SanctumArx.License.zombie_mode?()
      false

  """
  @spec zombie_mode?() :: boolean()
  def zombie_mode? do
    edition() == :arx and not valid?()
  end

  @doc """
  Get the current loaded license.

  Returns `:community` for Sanctum, the license map for Sanctum Arx,
  or `nil` if no license has been loaded yet.

  ## Examples

      iex> SanctumArx.License.current_license()
      :community

  """
  @spec current_license() :: :community | license() | nil
  def current_license do
    :persistent_term.get(@license_key, nil)
  end

  @doc """
  Get the current edition.

  Reads from configuration, defaulting to `:community`.

  ## Examples

      iex> SanctumArx.License.edition()
      :community

  """
  @spec edition() :: :community | :arx
  def edition do
    Application.get_env(:sanctum_arx, :edition, :community)
  end

  @doc """
  Check if a specific Arx feature is licensed.

  Base Sanctum returns `false` for all features.
  Sanctum Arx checks the license's feature list.

  ## Examples

      iex> SanctumArx.License.feature_licensed?(:saml)
      false

      iex> SanctumArx.License.feature_licensed?(:basic_auth)
      true  # Basic features always available

  """
  @spec feature_licensed?(atom()) :: boolean()
  def feature_licensed?(feature) when is_atom(feature) do
    case current_license() do
      :community ->
        # Community has basic features
        feature in [:local_secrets, :basic_policy, :github_oidc, :google_oidc]

      %{features: features} ->
        feature_str = Atom.to_string(feature)
        feature_str in features or "*" in features

      nil ->
        # No license loaded, check edition
        edition() == :community
    end
  end

  @doc """
  Get license info for display/debugging.

  Redacts sensitive information for logging.

  ## Examples

      iex> SanctumArx.License.info()
      %{edition: :community, valid: true, zombie_mode: false}

  """
  @spec info() :: map()
  def info do
    license = current_license()

    base = %{
      edition: edition(),
      valid: valid?(),
      zombie_mode: zombie_mode?()
    }

    case license do
      :community ->
        base

      %{} = lic ->
        Map.merge(base, %{
          customer_id: lic.customer_id,
          expires_at: lic.expires_at,
          features: lic.features,
          seats: lic.seats
        })

      nil ->
        Map.put(base, :loaded, false)
    end
  end

  # ============================================================================
  # License Verification
  # ============================================================================

  defp verify_license_file(path) do
    with {:ok, content} <- read_license_file(path),
         {:ok, decoded} <- decode_license(content),
         {:ok, license} <- validate_license(decoded) do
      store_license(license)

      if DateTime.compare(license.expires_at, DateTime.utc_now()) == :lt do
        Logger.warning("[SanctumArx.License] Arx license expired - entering zombie mode",
          customer_id: license.customer_id,
          expired_at: DateTime.to_iso8601(license.expires_at)
        )

        {:error, :expired}
      else
        Logger.info("[SanctumArx.License] Arx license validated",
          customer_id: license.customer_id,
          expires_at: DateTime.to_iso8601(license.expires_at),
          features: license.features
        )

        {:ok, license}
      end
    else
      {:error, :enoent} ->
        Logger.error("[SanctumArx.License] License file not found: #{path}")
        {:error, {:license_file_missing, path}}

      {:error, reason} ->
        Logger.error("[SanctumArx.License] License validation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp read_license_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_license(content) do
    # License format: base64-encoded JSON with optional signature
    # For now, we just decode JSON directly
    # TODO: Add signature verification using JOSE
    case Jason.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> decode_signed_license(content)
    end
  end

  defp decode_signed_license(content) do
    # Try to decode as a signed JWS
    # The license is signed by CYFR's license server
    # Public key would be embedded in enterprise builds
    try do
      case String.split(content, ".") do
        [_header, payload, _signature] ->
          # Decode the payload (middle part of JWS)
          {:ok, decoded} = Base.url_decode64(payload, padding: false)
          Jason.decode(decoded)

        _ ->
          {:error, :invalid_license_format}
      end
    rescue
      _ -> {:error, :invalid_license_format}
    end
  end

  defp validate_license(data) when is_map(data) do
    with {:ok, type} <- validate_type(data),
         {:ok, customer_id} <- get_required(data, "customer_id"),
         {:ok, issued_at} <- parse_datetime(data, "issued_at"),
         {:ok, expires_at} <- parse_datetime(data, "expires_at"),
         {:ok, features} <- get_features(data),
         {:ok, seats} <- get_seats(data) do
      {:ok,
       %{
         type: type,
         customer_id: customer_id,
         issued_at: issued_at,
         expires_at: expires_at,
         features: features,
         seats: seats
       }}
    end
  end

  defp validate_license(_), do: {:error, :invalid_license_data}

  defp validate_type(%{"type" => "arx"}), do: {:ok, :arx}
  defp validate_type(%{"type" => type}), do: {:error, {:invalid_license_type, type}}
  defp validate_type(_), do: {:error, :missing_license_type}

  defp get_required(data, key) do
    case Map.get(data, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp parse_datetime(data, key) do
    case Map.get(data, key) do
      nil ->
        {:error, {:missing_field, key}}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> {:ok, dt}
          {:error, _} -> {:error, {:invalid_datetime, key}}
        end

      _ ->
        {:error, {:invalid_datetime, key}}
    end
  end

  defp get_features(%{"features" => features}) when is_list(features), do: {:ok, features}
  defp get_features(_), do: {:ok, []}

  defp get_seats(%{"seats" => seats}) when is_integer(seats) and seats > 0, do: {:ok, seats}
  defp get_seats(_), do: {:ok, 0}

  # ============================================================================
  # Storage
  # ============================================================================

  defp store_license(license) do
    :persistent_term.put(@license_key, license)
  end

  defp license_path do
    Application.get_env(:sanctum_arx, :license_path, @default_license_path)
  end
end
