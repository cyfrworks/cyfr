defmodule Sanctum.Context do
  @moduledoc """
  Execution context that flows through all CYFR service calls.

  Sanctum uses `local/0` which grants all permissions.
  Managed/Enterprise constructs context from JWT claims via `from_jwt/1`.

  ## Usage

  Every service function takes context as its first argument:

      Opus.execute(ctx, reference, input)
      Locus.build(ctx, source, target)
      Arca.get(ctx, path)

  This enables multi-tenant-ready code from day one. When adding tenancy later,
  you change *how* context is constructed—not every function that uses it.
  """

  require Logger

  @type scope :: :personal | :org
  @type auth_method :: :local | :oidc | :api_key | nil
  @type api_key_type :: :public | :application | :secret | :admin | nil

  @type t :: %__MODULE__{
          user_id: String.t(),
          org_id: String.t() | nil,
          permissions: MapSet.t(atom()),
          scope: scope(),
          auth_method: auth_method(),
          api_key_type: api_key_type(),
          request_id: String.t() | nil,
          session_id: String.t() | nil,
          authenticated: boolean()
        }

  defstruct [:user_id, :org_id, :permissions, :scope, :auth_method, :api_key_type, :request_id, :session_id, authenticated: false]

  @doc """
  Default context for Sanctum (single-tenant, all permissions).

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> ctx.user_id
      "local_user"
      iex> Sanctum.Context.has_permission?(ctx, :execute)
      true

  """
  def local do
    %__MODULE__{
      user_id: "local_user",
      org_id: nil,
      permissions: MapSet.new([:*]),
      scope: :personal,
      auth_method: :local,
      api_key_type: nil,
      request_id: nil,
      session_id: nil,
      authenticated: true
    }
  end

  @doc """
  Construct context from JWT token.

  Verifies the JWT signature using the configured signing key and extracts
  user information from the claims.

  ## Required Configuration

  Set the signing key via environment variable or config:

      # Environment variable
      export CYFR_JWT_SIGNING_KEY="your-256-bit-secret"

      # Or in config/runtime.exs
      config :sanctum, :jwt_signing_key, "your-256-bit-secret"

  ## Expected Claims

  The JWT should contain:
  - `sub` - User ID (required)
  - `org` - Organization ID (optional)
  - `permissions` - List of permission strings (optional)
  - `scope` - "org" or "personal" (optional, defaults to "personal")

  ## Examples

      # Generate a valid JWT
      key = Application.get_env(:sanctum, :jwt_signing_key)
      claims = %{"sub" => "user_123", "permissions" => ["execute", "read"]}
      {_, jwt} = JOSE.JWT.sign(JOSE.JWK.from_oct(key), claims) |> JOSE.JWS.compact()

      # Parse and verify
      {:ok, ctx} = Sanctum.Context.from_jwt(jwt)
      ctx.user_id
      #=> "user_123"

  """
  @spec from_jwt(String.t()) :: {:ok, t()} | {:error, term()}
  def from_jwt(token) when is_binary(token) do
    with {:ok, jwk} <- get_signing_key(),
         {:ok, claims} <- verify_and_decode(token, jwk) do
      build_context_from_claims(claims)
    end
  end

  def from_jwt(_), do: {:error, :invalid_token}

  # ============================================================================
  # JWT Private Functions
  # ============================================================================

  defp get_signing_key do
    case Application.get_env(:sanctum, :jwt_signing_key) do
      nil ->
        {:error, :no_signing_key_configured}

      key when is_binary(key) and byte_size(key) >= 32 ->
        {:ok, JOSE.JWK.from_oct(key)}

      key when is_binary(key) ->
        # Reject short keys in all environments - padding is a security risk
        Logger.warning(
          "JWT signing key is too short (#{byte_size(key)} bytes). " <>
            "Use at least 32 bytes for security."
        )

        {:error, {:jwt_key_too_short, byte_size(key)}}
    end
  end

  defp verify_and_decode(token, jwk) do
    case JOSE.JWT.verify_strict(jwk, ["HS256", "HS384", "HS512"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        {:ok, claims}

      {false, _, _} ->
        {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_token_format}
  end

  defp build_context_from_claims(claims) do
    # Validate required claims
    case claims do
      %{"sub" => user_id} when is_binary(user_id) and user_id != "" ->
        # Validate expiration if present
        with :ok <- validate_expiration(claims),
             :ok <- validate_session_not_revoked(claims) do
          permissions =
            claims
            |> Map.get("permissions", [])
            |> Enum.map(&safe_to_atom/1)
            |> MapSet.new()

          scope =
            case Map.get(claims, "scope") do
              "org" -> :org
              _ -> :personal
            end

          {:ok,
           %__MODULE__{
             user_id: user_id,
             org_id: Map.get(claims, "org"),
             permissions: permissions,
             scope: scope,
             auth_method: :oidc,
             api_key_type: nil,
             request_id: nil,
             session_id: Map.get(claims, "session_id"),
             authenticated: true
           }}
        end

      _ ->
        {:error, :missing_sub_claim}
    end
  end

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    clock_skew = get_clock_skew_seconds()

    if exp + clock_skew >= now do
      :ok
    else
      {:error, :token_expired}
    end
  end

  # No exp claim - token doesn't expire (or we don't enforce expiration)
  defp validate_expiration(_claims), do: :ok

  # Maximum allowed clock skew to prevent security issues with overly permissive JWT validation
  @max_clock_skew_seconds 300

  defp get_clock_skew_seconds do
    configured = Application.get_env(:sanctum, :jwt_clock_skew_seconds, 60)
    min(configured, @max_clock_skew_seconds)
  end

  defp validate_session_not_revoked(%{"session_id" => session_id}) when is_binary(session_id) do
    if Sanctum.Session.revoked?(session_id) do
      {:error, :session_revoked}
    else
      :ok
    end
  end

  # No session_id claim - skip revocation check
  defp validate_session_not_revoked(_claims), do: :ok

  defp safe_to_atom(value), do: Sanctum.Atoms.safe_to_permission_atom(value)

  @doc """
  Check if context has a specific permission.

  The wildcard permission `:*` grants all permissions.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Context.has_permission?(ctx, :execute)
      true
      iex> Sanctum.Context.has_permission?(ctx, :any_permission)
      true

  """
  def has_permission?(%__MODULE__{permissions: perms}, permission) do
    MapSet.member?(perms, :*) or MapSet.member?(perms, permission)
  end

  @doc """
  Require permission, raises `Sanctum.UnauthorizedError` if missing.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Context.require_permission!(ctx, :execute)
      :ok

  """
  def require_permission!(ctx, permission) do
    unless has_permission?(ctx, permission) do
      raise Sanctum.UnauthorizedError, permission: permission
    end

    :ok
  end
end
