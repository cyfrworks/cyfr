# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.Auth do
  @moduledoc """
  OCI Distribution authentication — push-token only.

  Uses opaque push tokens for the configured registry, either cyfr.run
  or a self-deployed instance. Credentials are scoped by user and namespace.

  Authentication flow:

  1. Client resolves the per-namespace push token from `CredentialStore`.
  2. Client emits `Authorization: Bearer <cyfr_pt_...>` on every request.
  3. On 401, caller surfaces `:token_revoked` (or similar) and prompts the
     user to re-probe — no automatic refresh.

  `Authorization: Basic base64(anyuser:token)` is also accepted server-side
  for Docker/OCI client compatibility; cyfr itself always uses Bearer.
  """

  require Logger

  alias Compendium.OCI.Errors
  alias Compendium.Registry.CredentialStore
  alias Sanctum.RegistryCredentials

  @doc """
  Build authorization headers for an OCI registry request.

  Returns bearer headers for the caller's push token, `[]` when the
  caller has none (an anonymous request), or a `:registry_unavailable`
  refusal when the stored token cannot be read — the store is down or the
  row does not open. That refusal is never sent anonymously: the 401 that
  would follow reads as a missing sign-in.
  """
  @spec auth_headers(String.t(), String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, Errors.t()}
  def auth_headers(registry, _repository, namespace_slug, ctx \\ nil) do
    case fetch_credential(registry, namespace_slug, ctx) do
      {:ok, %{type: :push_token, token: token}} when is_binary(token) and token != "" ->
        {:ok, [{"authorization", "Bearer #{token}"}]}

      :anonymous ->
        {:ok, []}

      # The decoder refuses a push token with no usable token; one that got
      # past it is still damaged, never a reason to go anonymous.
      {:ok, _unusable} ->
        {:error, credential_unreadable(:corrupt, namespace_slug)}

      {:error, reason} ->
        {:error, credential_unreadable(reason, namespace_slug)}
    end
  end

  @doc """
  Fetch the per-namespace push-token credential for a user.

  `:anonymous` means the caller holds no credential here: no context, no
  signed-in person, or no token stored for the namespace. Credentials are
  never shared across users.

  A credential that cannot be read is not absent: `{:error, :unavailable}`
  when the store cannot answer and `{:error, :corrupt}` when the stored
  row does not open. Either is logged, without the token, and the caller
  refuses rather than going anonymous.
  """
  @spec fetch_credential(String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, RegistryCredentials.credential()}
          | :anonymous
          | {:error, :unavailable | :corrupt}
  def fetch_credential(registry, namespace_slug, ctx)
      when is_binary(registry) and is_binary(namespace_slug) do
    case ctx do
      %Sanctum.Context{user_id: user_id} = ctx when is_binary(user_id) and user_id != "" ->
        case CredentialStore.get(ctx, registry, namespace_slug) do
          {:ok, cred} -> {:ok, cred}
          {:error, :not_found} -> :anonymous
          {:error, :corrupt} -> unreadable(namespace_slug, :corrupt)
          {:error, _unavailable} -> unreadable(namespace_slug, :unavailable)
        end

      _ ->
        :anonymous
    end
  end

  defp unreadable(namespace_slug, reason) do
    Logger.warning(
      "[Compendium.OCI.Auth] push token for namespace #{inspect(namespace_slug)} " <>
        "unreadable (#{reason}) — request refused"
    )

    {:error, reason}
  end

  defp credential_unreadable(:unavailable, _namespace_slug) do
    %Errors{
      reason: :registry_unavailable,
      message: "Your registry credentials could not be read — retry shortly",
      registry: nil,
      status: nil,
      detail: %{credential_store: :unavailable}
    }
  end

  defp credential_unreadable(:corrupt, namespace_slug) do
    %Errors{
      reason: :registry_unavailable,
      message:
        "The push token stored for namespace '#{namespace_slug}' could not be opened — " <>
          "sign in again to re-mint it",
      registry: nil,
      status: nil,
      detail: %{credential_store: :corrupt}
    }
  end
end
