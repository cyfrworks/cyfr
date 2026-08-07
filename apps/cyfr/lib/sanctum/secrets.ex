# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Secrets do
  @moduledoc """
  Encrypted secrets storage for CYFR.

  Provides a simple interface for storing and retrieving secrets
  backed by `Arca.SecretStorage`.
  Secrets are encrypted per-row via the configured `Sanctum.Cipher`.

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
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_write),
         {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id, project_id} = extract_scope(ctx)

      {:ok, encrypted} =
        Sanctum.Cipher.encrypt(value, secret_aad(scope, org_id, project_id, normalized_name))

      Arca.SecretStorage.put_secret(normalized_name, encrypted, scope, org_id, project_id)
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
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_read),
         {:ok, normalized_name} <- validate_name(name) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Arca.SecretStorage.get_secret(normalized_name, scope, org_id, project_id) do
        {:ok, encrypted} ->
          Sanctum.Cipher.decrypt(
            encrypted,
            secret_aad(scope, org_id, project_id, normalized_name)
          )

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  List all secret names (not values).
  """
  def list(%Context{} = ctx) do
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_read) do
      {scope, org_id, project_id} = extract_scope(ctx)
      Arca.SecretStorage.list_secrets(scope, org_id, project_id)
    end
  end

  @doc """
  Delete a secret.

  Returns `:ok` on success (even if secret didn't exist).
  """
  def delete(%Context{} = ctx, name) when is_binary(name) do
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_write),
         {:ok, normalized_name} <- validate_name(name) do
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
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_write),
         {:ok, normalized_name} <- validate_name(secret_name),
         {:ok, normalized_ref} <- validate_component_ref(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Arca.SecretStorage.put_grant(
             normalized_name,
             normalized_ref,
             scope,
             org_id,
             project_id
           ) do
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
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_write),
         {:ok, normalized_name} <- validate_name(secret_name),
         {:ok, normalized_ref} <- validate_component_ref(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      case Arca.SecretStorage.list_grants(normalized_name, scope, org_id, project_id) do
        {:error, _} = error ->
          error

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
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_read),
         {:ok, normalized_name} <- validate_name(secret_name) do
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
    with :ok <- deny_anonymous(ctx),
         :ok <- Context.require_permission(ctx, :secrets_read),
         {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize_or_name_ref(component_ref) do
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
    # Gated on :execute, not :secrets_read: this is the execution plane,
    # authorized by the per-component GRANT — every execution context
    # (webhook, cron, tincture) carries :execute, while gating on
    # :secrets_read would force widening those contexts and thereby unlock
    # the by-name secret.get plane for code running under them.
    with :ok <- Context.require_permission(ctx, :execute),
         {:ok, normalized_ref} <- Sanctum.ComponentRef.normalize(component_ref) do
      {scope, org_id, project_id} = extract_scope(ctx)

      # Cascade: check exact-ref grants, then name-level grants
      with {:ok, exact_names} <- fetch_grants(ctx, normalized_ref, scope, org_id, project_id),
           {:ok, name_level_names} <-
             fetch_name_level_grants(ctx, normalized_ref, scope, org_id, project_id) do
        # Merge both grant sets (exact-version takes precedence via ordering)
        secret_names = Enum.uniq(exact_names ++ name_level_names)

        # Anonymous callers never receive credentials — but a secret-less
        # component (no grants) keeps working publicly: the empty map short-
        # circuits before the anonymous check so the execution proceeds with
        # nothing to resolve, while a granted component fails loudly at
        # preload instead of leaking.
        resolve_secret_names(ctx, secret_names, scope, org_id, project_id, component_ref)
      end
    end
  end

  defp resolve_secret_names(_ctx, [], _scope, _org_id, _project_id, _component_ref),
    do: {:ok, %{secrets: %{}}}

  defp resolve_secret_names(%Context{anonymous: true}, _names, _s, _o, _p, component_ref) do
    {:error,
     "anonymous_denied: public invocations cannot receive granted secrets (#{component_ref})"}
  end

  defp resolve_secret_names(_ctx, secret_names, scope, org_id, project_id, component_ref) do
    {resolved, failed} =
      Enum.reduce(secret_names, {%{}, []}, fn name, {acc, failures} ->
        case Arca.SecretStorage.get_secret(name, scope, org_id, project_id) do
          {:ok, encrypted} ->
            case Sanctum.Cipher.decrypt(
                   encrypted,
                   secret_aad(scope, org_id, project_id, name)
                 ) do
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

    # Fail closed on ANY partial decrypt/fetch failure. Returning
    # `{:ok, %{secrets, failed}}` let loose callers (e.g. the output
    # secret-masker) silently proceed with an INCOMPLETE secret set — a
    # secret that failed to resolve would then go un-masked in component
    # output. The explicit error contract forces every caller to handle it.
    case Enum.reverse(failed) do
      [] -> {:ok, %{secrets: resolved}}
      failed_names -> {:error, {:partial_decrypt, failed_names}}
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

  # A context marked anonymous (public tincture invocation) never touches
  # the secret plane — regardless of what permissions the ingress minted.
  defp deny_anonymous(%Context{anonymous: true}), do: {:error, :anonymous_denied}
  defp deny_anonymous(%Context{}), do: :ok

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

  # Single source of truth — see Sanctum.TenantScope (was duplicated here and
  # in Sanctum.OAuth; a security chokepoint that must not drift).
  defp extract_scope(%Context{} = ctx), do: Sanctum.TenantScope.extract(ctx)

  # AAD binds a secret row's canonical storage partition key — see
  # `Sanctum.CipherAAD` for the single tuple definition.
  defp secret_aad(scope, org_id, project_id, name),
    do: Sanctum.CipherAAD.secret(scope, org_id, project_id, name)

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
