defmodule Sanctum.Secrets do
  @moduledoc """
  Encrypted secrets storage for CYFR.

  Provides a simple interface for storing and retrieving secrets
  backed by SQLite via `Arca.SecretStorage`.
  Secrets are encrypted per-row using AES-256-GCM via `Sanctum.Crypto`.

  ## Usage

      ctx = Sanctum.TestContext.local()

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

  require Logger

  alias Sanctum.Context

  @system_secret_prefix "_"

  @doc """
  Returns true if the secret name is a system-internal secret.
  System secrets use a `_` prefix and cannot be managed via MCP.
  """
  @spec system_secret?(String.t()) :: boolean()
  def system_secret?(name) when is_binary(name) do
    String.starts_with?(String.trim(name), @system_secret_prefix)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Store a secret.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  Secret names must be non-empty and cannot be whitespace-only.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.set(ctx, "API_KEY", "secret")
      :ok

  """
  def set(%Context{} = ctx, name, value) when is_binary(name) and is_binary(value) do
    with {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Sanctum.Crypto.encrypt(value) do
        {:ok, encrypted} ->
          Arca.SecretStorage.put_secret(normalized_name, encrypted, scope, org_id, project_id)

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Retrieve a secret by name.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.set(ctx, "API_KEY", "secret")
      :ok
      iex> Sanctum.Secrets.get(ctx, "API_KEY")
      {:ok, "secret"}

  """
  def get(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Arca.SecretStorage.get_secret(normalized_name, scope, org_id, project_id) do
        {:ok, encrypted} ->
          Sanctum.Crypto.decrypt(encrypted)

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  List all secret names (not values).
  """
  def list(%Context{} = ctx) do
    {scope, org_id, project_id} = extract_scope(ctx)
    Arca.SecretStorage.list_secrets(scope, org_id, project_id)
  end

  @doc """
  Delete a secret.

  Returns `:ok` on success (even if secret didn't exist).
  """
  def delete(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id, project_id} = extract_scope(ctx)
      Arca.SecretStorage.delete_secret(normalized_name, scope, org_id, project_id)
    end
  end

  @doc """
  Check if a secret exists.

  Returns `true` if the secret exists, `false` if not found or invalid name,
  or `{:error, reason}` for unexpected system errors.
  """
  @spec exists?(Context.t(), String.t()) :: boolean() | {:error, term()}
  def exists?(%Context{} = ctx, name) when is_binary(name) do
    case get(ctx, name) do
      {:ok, _} -> true
      {:error, :not_found} -> false
      {:error, :invalid_name} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Grant/Revoke API
  # ============================================================================

  @doc """
  Grant a component access to a secret.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.grant(ctx, "API_KEY", "local.stripe-catalyst:1.0.0")
      :ok

  """
  def grant(%Context{} = ctx, secret_name, component_ref)
      when is_binary(secret_name) and is_binary(component_ref) do
    with {:ok, normalized_name} <- validate_name(secret_name),
         {:ok, normalized_ref} <- validate_component_ref(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Arca.SecretStorage.put_grant(normalized_name, normalized_ref, scope, org_id, project_id) do
        :ok ->
          :telemetry.execute(
            [:cyfr, :sanctum, :secret, :grant],
            %{system_time: System.system_time()},
            %{
              secret_name: normalized_name,
              component_ref: normalized_ref,
              org_id: org_id,
              project_id: project_id,
              user_id: ctx.user_id
            }
          )

          :ok

        other ->
          other
      end
    end
  end

  @doc """
  Revoke a component's access to a secret.

  Returns `{:ok, :revoked}` if the grant existed and was removed,
  `{:ok, :not_granted}` if the component didn't have access,
  or `{:error, reason}` on failure.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.revoke(ctx, "API_KEY", "local.stripe-catalyst:1.0.0")
      {:ok, :revoked}

  """
  def revoke(%Context{} = ctx, secret_name, component_ref)
      when is_binary(secret_name) and is_binary(component_ref) do
    with {:ok, normalized_name} <- validate_name(secret_name),
         {:ok, normalized_ref} <- validate_component_ref(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Arca.SecretStorage.list_grants(normalized_name, scope, org_id, project_id) do
        {:ok, grants} ->
          if normalized_ref in grants do
            case Arca.SecretStorage.delete_grant(
                   normalized_name,
                   normalized_ref,
                   scope,
                   org_id,
                   project_id
                 ) do
              :ok ->
                :telemetry.execute(
                  [:cyfr, :sanctum, :secret, :revoke],
                  %{system_time: System.system_time()},
                  %{
                    secret_name: normalized_name,
                    component_ref: normalized_ref,
                    org_id: org_id,
                    project_id: project_id,
                    user_id: ctx.user_id
                  }
                )

                {:ok, :revoked}

              error ->
                error
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

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.list_grants(ctx, "API_KEY")
      {:ok, ["local.stripe-catalyst:1.0.0", "local.openai-catalyst:1.0.0"]}

  """
  def list_grants(%Context{} = ctx, secret_name) when is_binary(secret_name) do
    with {:ok, normalized_name} <- validate_name(secret_name) do
      {scope, org_id, project_id} = extract_scope(ctx)
      Arca.SecretStorage.list_grants(normalized_name, scope, org_id, project_id)
    end
  end

  @doc """
  List all secrets that a component has been granted access to.

  Returns `{:ok, [secret_name, ...]}` containing the names of secrets
  that the given component has been granted access to.
  """
  def list_component_grants(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    with {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize_or_name_ref(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      with {:ok, exact_names} <-
             Arca.SecretStorage.grants_for_component(normalized_ref, scope, org_id, project_id),
           {:ok, name_level_names} <-
             fetch_name_level_component_grants(normalized_ref, scope, org_id, project_id) do
        {:ok, Enum.uniq(exact_names ++ name_level_names)}
      end
    end
  end

  @doc """
  Resolve all granted secrets for a component into an in-memory map.

  Returns `{:ok, %{"SECRET_NAME" => "value", ...}}` containing only the secrets
  that the given component has been granted access to.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.resolve_granted_secrets(ctx, "local.stripe-catalyst:1.0.0")
      {:ok, %{"STRIPE_API_KEY" => "sk_live_..."}}

  """
  def resolve_granted_secrets(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    with {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      # Cascade: check exact-ref grants, then name-level grants
      with {:ok, exact_names} <- fetch_grants(ctx, normalized_ref, scope, org_id, project_id),
           {:ok, name_level_names} <-
             fetch_name_level_grants(ctx, normalized_ref, scope, org_id, project_id) do
        # Merge both grant sets (exact-version takes precedence via ordering)
        secret_names = Enum.uniq(exact_names ++ name_level_names)

        {resolved, failed} =
          Enum.reduce(secret_names, {%{}, []}, fn name, {acc, failures} ->
            case Arca.SecretStorage.get_secret(name, scope, org_id, project_id) do
              {:ok, encrypted} ->
                case Sanctum.Crypto.decrypt(encrypted) do
                  {:ok, value} ->
                    {Map.put(acc, name, value), failures}

                  {:error, reason} ->
                    Logger.warning(
                      "[Sanctum.Secrets] Failed to decrypt secret '#{name}' for #{component_ref}: #{inspect(reason)}"
                    )

                    {acc, [name | failures]}
                end

              {:error, reason} ->
                Logger.warning(
                  "[Sanctum.Secrets] Failed to fetch secret '#{name}' for #{component_ref}: #{inspect(reason)}"
                )

                {acc, [name | failures]}
            end
          end)

        {:ok, %{secrets: resolved, failed: Enum.reverse(failed)}}
      end
    end
  end

  @doc """
  Check if a component can access a secret.

  Returns `{:ok, true}` if access is granted, `{:ok, false}` if not,
  or `{:error, reason}` if there was a problem checking access.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Secrets.can_access?(ctx, "API_KEY", "local.stripe-catalyst:1.0.0")
      {:ok, false}

  """
  def can_access?(%Context{} = ctx, secret_name, component_ref)
      when is_binary(secret_name) and is_binary(component_ref) do
    with {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize(component_ref) do
      case list_grants(ctx, secret_name) do
        {:ok, grants} ->
          # Check exact ref first, then name-level ref
          if normalized_ref in grants do
            {:ok, true}
          else
            case Sanctum.ComponentRef.to_name_ref(normalized_ref) do
              {:ok, name_ref} -> {:ok, name_ref in grants}
              _ -> {:ok, false}
            end
          end

        {:error, reason} ->
          {:error, reason}
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
    Sanctum.ComponentRef.normalize_or_name_ref(ref)
  end

  # ============================================================================
  # Internal - Scope Extraction
  # ============================================================================

  defp extract_scope(%Context{scope: :org, org_id: nil}) do
    raise ArgumentError,
          "org_id cannot be nil when scope is :org. " <>
            "Either set an org_id or use scope :project."
  end

  defp extract_scope(%Context{scope: scope, org_id: org_id, project_id: project_id}) do
    {to_string(scope), org_id, project_id || "default"}
  end

  # ============================================================================
  # Internal - Grant Fetching
  # ============================================================================

  defp fetch_grants(_ctx, component_ref, scope, org_id, project_id) do
    case Arca.SecretStorage.grants_for_component(component_ref, scope, org_id, project_id) do
      {:ok, secret_names} ->
        {:ok, secret_names}

      {:error, reason} ->
        {:error, "Failed to fetch grants for #{component_ref}: #{inspect(reason)}"}
    end
  end

  defp fetch_name_level_grants(ctx, normalized_ref, scope, org_id, project_id) do
    case Sanctum.ComponentRef.to_name_ref(normalized_ref) do
      {:ok, name_ref} when name_ref != normalized_ref ->
        fetch_grants(ctx, name_ref, scope, org_id, project_id)

      _ ->
        {:ok, []}
    end
  end

  defp fetch_name_level_component_grants(normalized_ref, scope, org_id, project_id) do
    case Sanctum.ComponentRef.to_name_ref(normalized_ref) do
      {:ok, name_ref} when name_ref != normalized_ref ->
        Arca.SecretStorage.grants_for_component(name_ref, scope, org_id, project_id)

      _ ->
        {:ok, []}
    end
  end
end
