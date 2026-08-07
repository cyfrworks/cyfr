# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderCredentials do
  @moduledoc """
  OAuth provider client credentials — the operator's OAuth app
  (client id/secret at Google, GitHub, ...), one sealed blob per
  `(tenant, provider)`.

  These are deployment-level credentials, not component-delegable secrets.
  They used to live in the `secrets` table and were read under the
  *executing caller's* context during token refresh, which let any
  execute-permission context (public tinctures, webhooks, cron) read the
  client secret by name. This store separates the planes:

  - **Management** (`put/4`, `delete/2`, `configured?/2`) is caller-gated:
    tenant scope plus `:secrets_write` / `:secrets_read`.
  - **Use** (`fetch_for_oauth/4`) takes explicit tenant coordinates and no
    caller context at all — it is reachable only from the host's OAuth
    exchange/refresh plane, never through a caller's permission set, and
    every read emits telemetry.

  `fetch_for_oauth/4` falls back to the legacy secret names a manifest's
  oauth block declares (`client_id_secret` / `client_secret_secret`) and
  copies a hit forward into this store, so existing installs keep working
  without re-entry. `mix cyfr.migrate_provider_creds` performs the eager
  copy and deletes the legacy rows.
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.Context

  @doc """
  Store (or replace) a provider's client credentials for the caller's tenant.

  `client_secret` may be nil — public OAuth clients have no secret.
  """
  @spec put(Context.t(), String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def put(%Context{} = ctx, provider, client_id, client_secret \\ nil) do
    with :ok <- Context.require_permission(ctx, :secrets_write),
         :ok <- validate_provider(provider),
         :ok <- validate_client_id(client_id) do
      {_scope, org_id, project_id} = Sanctum.TenantScope.extract(ctx)
      payload = Jason.encode!(%{"client_id" => client_id, "client_secret" => client_secret})

      {:ok, ciphertext} =
        Sanctum.Cipher.encrypt(payload, CipherAAD.provider_credential(org_id, project_id, provider))

      Arca.ProviderCredentialStorage.put(%{
        org_id: org_id,
        project_id: project_id,
        provider: provider,
        payload_ciphertext: ciphertext,
        created_by: ctx.user_id
      })
    end
  end

  @doc "Delete a provider's client credentials for the caller's tenant."
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, provider) do
    with :ok <- Context.require_permission(ctx, :secrets_write),
         :ok <- validate_provider(provider) do
      {_scope, org_id, project_id} = Sanctum.TenantScope.extract(ctx)
      Arca.ProviderCredentialStorage.delete(org_id, project_id, provider)
    end
  end

  @doc "Whether client credentials are stored for a provider (presence only)."
  @spec configured?(Context.t(), String.t()) :: boolean() | {:error, term()}
  def configured?(%Context{} = ctx, provider) do
    with :ok <- Context.require_permission(ctx, :secrets_read),
         :ok <- validate_provider(provider) do
      {_scope, org_id, project_id} = Sanctum.TenantScope.extract(ctx)
      Arca.ProviderCredentialStorage.exists?(org_id, project_id, provider)
    end
  end

  @doc """
  System-plane read for token exchange and refresh.

  Deliberately takes tenant coordinates instead of a `Context` — no caller
  permission set can reach the client secret through this function, and the
  executing component's context never touches it. `legacy_names` is the
  manifest oauth block's `{client_id_secret, client_secret_secret}` pair;
  a legacy hit is copied forward into this store.

  Returns `{:ok, %{"client_id" => ..., "client_secret" => ... | nil}}`.
  """
  @spec fetch_for_oauth(
          String.t() | nil,
          String.t() | nil,
          String.t(),
          {String.t() | nil, String.t() | nil} | nil
        ) :: {:ok, map()} | {:error, String.t()}
  def fetch_for_oauth(org_id, project_id, provider, legacy_names \\ nil) do
    with :ok <- validate_provider(provider) do
      case Arca.ProviderCredentialStorage.get(org_id, project_id, provider) do
        {:ok, row} ->
          emit_fetch(provider, :store)
          unseal(row)

        {:error, :not_found} ->
          case legacy_lookup(org_id, project_id, legacy_names) do
            {:ok, creds} ->
              emit_fetch(provider, :legacy)
              copy_forward(org_id, project_id, provider, creds)
              {:ok, creds}

            nil ->
              {:error, not_configured_message(provider, legacy_names)}
          end

        {:error, reason} ->
          {:error, "failed to read OAuth provider credentials: #{inspect(reason)}"}
      end
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp unseal(row) do
    aad = CipherAAD.provider_credential(row.org_id, row.project_id, row.provider)

    with {:ok, payload} <- Sanctum.Cipher.decrypt(row.payload_ciphertext, aad),
         {:ok, %{"client_id" => _} = creds} <- Jason.decode(payload) do
      {:ok, Map.take(creds, ["client_id", "client_secret"])}
    else
      _ ->
        # Fail closed: an undecryptable or malformed blob is corruption or
        # tampering, never something to fall through past.
        {:error, "stored OAuth provider credentials for '#{row.provider}' failed to unseal"}
    end
  end

  # The legacy rows were written under whatever scope partition the writer's
  # context carried (console users :project or :org, platform admins
  # :platform), so the lookup cascades the partitions in fixed order.
  defp legacy_lookup(org_id, project_id, {id_name, secret_name}) when is_binary(id_name) do
    Enum.find_value([:project, :org, :platform], fn scope ->
      ctx = legacy_ctx(org_id, project_id, scope)

      case Sanctum.Secrets.get(ctx, id_name) do
        {:ok, client_id} ->
          client_secret =
            if is_binary(secret_name) do
              case Sanctum.Secrets.get(ctx, secret_name) do
                {:ok, val} -> val
                _ -> nil
              end
            end

          {:ok, %{"client_id" => client_id, "client_secret" => client_secret}}

        _ ->
          nil
      end
    end)
  end

  defp legacy_lookup(_org_id, _project_id, _names), do: nil

  defp legacy_ctx(org_id, project_id, scope) do
    Context.internal(
      user_id: "system:provider_creds",
      org_id: org_id,
      project_id: project_id,
      scope: scope,
      permissions: [:secrets_read]
    )
  end

  defp copy_forward(org_id, project_id, provider, %{"client_id" => client_id} = creds) do
    payload = Jason.encode!(Map.take(creds, ["client_id", "client_secret"]))

    {:ok, ciphertext} =
      Sanctum.Cipher.encrypt(payload, CipherAAD.provider_credential(org_id, project_id, provider))

    result =
      Arca.ProviderCredentialStorage.put(%{
        org_id: org_id,
        project_id: project_id,
        provider: provider,
        payload_ciphertext: ciphertext,
        created_by: "system:legacy_migration"
      })

    case result do
      :ok ->
        Logger.info(
          "[ProviderCredentials] migrated legacy client credentials for provider '#{provider}' " <>
            "into the provider-credential store (client_id #{String.slice(client_id, 0, 6)}…)"
        )

      {:error, reason} ->
        Logger.warning(
          "[ProviderCredentials] failed to copy legacy credentials forward for '#{provider}': #{inspect(reason)}"
        )
    end

    :ok
  end

  defp not_configured_message(provider, {id_name, _}) when is_binary(id_name) do
    "OAuth provider credentials not configured for '#{provider}' — " <>
      "run oauth.set_client (or set legacy secret '#{id_name}')"
  end

  defp not_configured_message(provider, _legacy) do
    "OAuth provider credentials not configured for '#{provider}' — run oauth.set_client"
  end

  defp emit_fetch(provider, source) do
    :telemetry.execute(
      [:cyfr, :sanctum, :provider_credentials, :fetch],
      %{system_time: System.system_time()},
      %{provider: provider, source: source}
    )
  end

  defp validate_provider(provider) when is_binary(provider) do
    if String.trim(provider) == "" do
      {:error, "provider name must be a non-empty string"}
    else
      :ok
    end
  end

  defp validate_provider(_), do: {:error, "provider name must be a non-empty string"}

  defp validate_client_id(client_id) when is_binary(client_id) and client_id != "", do: :ok
  defp validate_client_id(_), do: {:error, "client_id must be a non-empty string"}
end
