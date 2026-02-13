defmodule Sanctum.Secrets do
  @moduledoc """
  Encrypted secrets storage for CYFR.

  Provides a simple interface for storing and retrieving secrets
  backed by SQLite via `Arca.SecretStorage` (through MCP boundary).
  Secrets are encrypted per-row using AES-256-GCM via `Sanctum.Crypto`.

  ## Usage

      ctx = Sanctum.Context.local()

      # Store a secret
      :ok = Sanctum.Secrets.set(ctx, "API_KEY", "sk-secret123")

      # Retrieve a secret
      {:ok, "sk-secret123"} = Sanctum.Secrets.get(ctx, "API_KEY")

      # List secret names
      {:ok, ["API_KEY"]} = Sanctum.Secrets.list(ctx)

      # Delete a secret
      :ok = Sanctum.Secrets.delete(ctx, "API_KEY")

  ## Storage

  Secrets are stored in the Arca SQLite database. Values are encrypted
  per-row; names and grants are plaintext for queryability.

  ## Security

  In production, a valid `CYFR_SECRET_KEY_BASE` environment variable is required.
  The application will fail to start if this is not configured.
  """

  alias Sanctum.Context

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Store a secret.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  Secret names must be non-empty and cannot be whitespace-only.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.set(ctx, "API_KEY", "secret")
      :ok

  """
  def set(%Context{} = ctx, name, value) when is_binary(name) and is_binary(value) do
    with {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id} = extract_scope(ctx)

      case Sanctum.Crypto.encrypt(value) do
        {:ok, encrypted} ->
          case Arca.MCP.handle("secret_store", ctx, %{
            "action" => "put",
            "name" => normalized_name,
            "encrypted_value" => Base.encode64(encrypted),
            "scope" => scope,
            "org_id" => org_id
          }) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Retrieve a secret by name.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.set(ctx, "API_KEY", "secret")
      :ok
      iex> Sanctum.Secrets.get(ctx, "API_KEY")
      {:ok, "secret"}

  """
  def get(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id} = extract_scope(ctx)

      case Arca.MCP.handle("secret_store", ctx, %{
        "action" => "get",
        "name" => normalized_name,
        "scope" => scope,
        "org_id" => org_id
      }) do
        {:ok, %{encrypted_value: b64_encrypted}} ->
          encrypted = Base.decode64!(b64_encrypted)
          Sanctum.Crypto.decrypt(encrypted)
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  @doc """
  List all secret names (not values).
  """
  def list(%Context{} = ctx) do
    {scope, org_id} = extract_scope(ctx)

    case Arca.MCP.handle("secret_store", ctx, %{
      "action" => "list",
      "scope" => scope,
      "org_id" => org_id
    }) do
      {:ok, %{names: names}} -> {:ok, names}
    end
  end

  @doc """
  Delete a secret.

  Returns `:ok` on success (even if secret didn't exist).
  """
  def delete(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id} = extract_scope(ctx)

      case Arca.MCP.handle("secret_store", ctx, %{
        "action" => "delete",
        "name" => normalized_name,
        "scope" => scope,
        "org_id" => org_id
      }) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Check if a secret exists.

  Returns `true` if the secret exists, `false` otherwise.
  Returns `false` for invalid names (empty/whitespace).
  """
  def exists?(%Context{} = ctx, name) when is_binary(name) do
    case get(ctx, name) do
      {:ok, _} -> true
      {:error, :not_found} -> false
      {:error, :invalid_name} -> false
      {:error, _reason} -> false
    end
  end

  # ============================================================================
  # Grant/Revoke API
  # ============================================================================

  @doc """
  Grant a component access to a secret.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.grant(ctx, "API_KEY", "local.stripe-catalyst:1.0.0")
      :ok

  """
  def grant(%Context{} = ctx, secret_name, component_ref)
      when is_binary(secret_name) and is_binary(component_ref) do
    with {:ok, normalized_name} <- validate_name(secret_name),
         {:ok, normalized_ref} <- validate_component_ref(component_ref) do
      {scope, org_id} = extract_scope(ctx)

      case Arca.MCP.handle("secret_store", ctx, %{
        "action" => "put_grant",
        "name" => normalized_name,
        "component_ref" => normalized_ref,
        "scope" => scope,
        "org_id" => org_id
      }) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Revoke a component's access to a secret.

  Returns `{:ok, :revoked}` if the grant existed and was removed,
  `{:ok, :not_granted}` if the component didn't have access,
  or `{:error, reason}` on failure.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.revoke(ctx, "API_KEY", "local.stripe-catalyst:1.0.0")
      {:ok, :revoked}

  """
  def revoke(%Context{} = ctx, secret_name, component_ref)
      when is_binary(secret_name) and is_binary(component_ref) do
    with {:ok, normalized_name} <- validate_name(secret_name),
         {:ok, normalized_ref} <- validate_component_ref(component_ref) do
      {scope, org_id} = extract_scope(ctx)

      case Arca.MCP.handle("secret_store", ctx, %{
        "action" => "list_grants",
        "name" => normalized_name,
        "scope" => scope,
        "org_id" => org_id
      }) do
        {:ok, %{grants: grants}} ->
          if normalized_ref in grants do
            case Arca.MCP.handle("secret_store", ctx, %{
              "action" => "delete_grant",
              "name" => normalized_name,
              "component_ref" => normalized_ref,
              "scope" => scope,
              "org_id" => org_id
            }) do
              {:ok, _} -> {:ok, :revoked}
              error -> error
            end
          else
            {:ok, :not_granted}
          end
      end
    end
  end

  @doc """
  List all grants for a secret.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.list_grants(ctx, "API_KEY")
      {:ok, ["local.stripe-catalyst:1.0.0", "local.openai-catalyst:1.0.0"]}

  """
  def list_grants(%Context{} = ctx, secret_name) when is_binary(secret_name) do
    with {:ok, normalized_name} <- validate_name(secret_name) do
      {scope, org_id} = extract_scope(ctx)

      case Arca.MCP.handle("secret_store", ctx, %{
        "action" => "list_grants",
        "name" => normalized_name,
        "scope" => scope,
        "org_id" => org_id
      }) do
        {:ok, %{grants: grants}} -> {:ok, grants}
      end
    end
  end

  @doc """
  Resolve all granted secrets for a component into an in-memory map.

  Returns `{:ok, %{"SECRET_NAME" => "value", ...}}` containing only the secrets
  that the given component has been granted access to.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.resolve_granted_secrets(ctx, "local.stripe-catalyst:1.0.0")
      {:ok, %{"STRIPE_API_KEY" => "sk_live_..."}}

  """
  def resolve_granted_secrets(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    with {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize(component_ref) do
      {scope, org_id} = extract_scope(ctx)

      with {:ok, %{secret_names: secret_names}} <- Arca.MCP.handle("secret_store", ctx, %{
             "action" => "grants_for_component",
             "component_ref" => normalized_ref,
             "scope" => scope,
             "org_id" => org_id
           }) do
      resolved =
        Enum.reduce(secret_names, %{}, fn name, acc ->
          case Arca.MCP.handle("secret_store", ctx, %{
            "action" => "get",
            "name" => name,
            "scope" => scope,
            "org_id" => org_id
          }) do
            {:ok, %{encrypted_value: b64_encrypted}} ->
              encrypted = Base.decode64!(b64_encrypted)
              case Sanctum.Crypto.decrypt(encrypted) do
                {:ok, value} -> Map.put(acc, name, value)
                {:error, _} -> acc
              end

            {:error, _} ->
              acc
          end
        end)

      {:ok, resolved}
      end
    end
  end

  @doc """
  Check if a component can access a secret.

  Returns `{:ok, true}` if access is granted, `{:ok, false}` if not,
  or `{:error, reason}` if there was a problem checking access.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Sanctum.Secrets.can_access?(ctx, "API_KEY", "local.stripe-catalyst:1.0.0")
      {:ok, false}

  """
  def can_access?(%Context{} = ctx, secret_name, component_ref)
      when is_binary(secret_name) and is_binary(component_ref) do
    with {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize(component_ref) do
      case list_grants(ctx, secret_name) do
        {:ok, grants} -> {:ok, normalized_ref in grants}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ============================================================================
  # Internal - Validation
  # ============================================================================

  defp validate_name(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      {:error, :invalid_name}
    else
      {:ok, trimmed}
    end
  end

  defp validate_component_ref(ref) do
    Sanctum.ComponentRef.normalize(ref)
  end

  # ============================================================================
  # Internal - Scope Extraction
  # ============================================================================

  defp extract_scope(%Context{scope: :org, org_id: nil}) do
    raise ArgumentError,
          "org_id cannot be nil when scope is :org. " <>
            "Either set an org_id or use scope :personal."
  end

  defp extract_scope(%Context{scope: scope, org_id: org_id}) do
    {to_string(scope), org_id}
  end
end
