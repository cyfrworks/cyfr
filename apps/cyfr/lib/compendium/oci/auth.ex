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

  alias Compendium.Registry.CredentialStore

  @doc """
  Build authorization headers for an OCI registry request.

  Returns bearer headers for the current user and registry, or `[]` when no credential is available.
  """
  @spec auth_headers(String.t(), String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, [{String.t(), String.t()}]}
  def auth_headers(registry, _repository, namespace_slug, ctx \\ nil) do
    case fetch_credential(registry, namespace_slug, ctx) do
      {:ok, %{type: :push_token, token: token}} when is_binary(token) and token != "" ->
        {:ok, [{"authorization", "Bearer #{token}"}]}

      _ ->
        # No credential → anonymous. Server will 401 if auth is required.
        {:ok, []}
    end
  end

  @doc """
  Fetch the per-namespace push-token credential for a user.

  Returns `{:ok, credential}` or `:anonymous`. A nil context or missing
  `user_id` returns `:anonymous`; credentials are never shared across users.

  A credential that cannot be read (the store is down, or the stored row
  does not open) also sends the request anonymously — the OCI transport
  always sends one — but says so in the log, so a 401 that follows is not
  mistaken for a missing sign-in.
  """
  @spec fetch_credential(String.t(), String.t(), Sanctum.Context.t() | nil) ::
          {:ok, map()} | :anonymous
  def fetch_credential(registry, namespace_slug, ctx)
      when is_binary(registry) and is_binary(namespace_slug) do
    case ctx do
      %Sanctum.Context{user_id: user_id} = ctx when is_binary(user_id) and user_id != "" ->
        case CredentialStore.get(ctx, registry, namespace_slug) do
          {:ok, cred} ->
            {:ok, cred}

          {:error, :not_found} ->
            :anonymous

          {:error, reason} ->
            Logger.warning(
              "[Compendium.OCI.Auth] push token for namespace #{inspect(namespace_slug)} " <>
                "unreadable (#{inspect(reason)}) — request goes anonymous"
            )

            :anonymous
        end

      _ ->
        :anonymous
    end
  end
end
