# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.CredentialStore do
  @moduledoc """
  The component domain's door to a person's registry push tokens.

  The tokens are identity's: `Sanctum.RegistryCredentials` seals, stores
  and opens them, keyed by the person the caller's context names. This
  module adds what only this domain knows — the device label a token is
  issued under — and the logging a best-effort cache write needs. Every
  function takes the caller's established context; none takes a user id.

  Reads keep their three failures apart from absence (`:unavailable`,
  `:corrupt`, `:not_found`), and a listing keeps a row that cannot be
  opened as `%{id: id, status: :corrupt}`.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.RegistryCredentials

  @doc """
  Human-readable label for the device this credential was issued to.

  Precedence (first non-nil wins):

  1. `:cyfr, :device_label` application env (test seam + ops override).
  2. `CYFR_DEVICE_LABEL` OS env var (runtime override).
  3. `:inet.gethostname/0` (the machine's configured hostname).
  4. Literal `"cyfr-host"` fallback.

  It rides along on every stored credential and on the token-minting requests
  that produce them, so it is named here rather than at either call site.
  Labels are NOT unique — two devices with the same hostname produce
  duplicate-labeled tokens; distinguish by token id + `last_used_at` via
  `cyfr registry tokens list <ns>`.
  """
  @spec device_label() :: String.t()
  def device_label do
    # :device_label is set by runtime.exs from CYFR_DEVICE_LABEL through
    # Dotenvy — one environment pipeline for OS env and .env files alike.
    Application.get_env(:cyfr, :device_label) ||
      case :inet.gethostname() do
        {:ok, host} -> to_string(host)
        _ -> "cyfr-host"
      end
  end

  @doc """
  Store a push token for the caller under this device's label,
  best-effort.

  Shared by the OAuth callback, the claim flow and the CLI's re-probe —
  all cache the same push-token shape after the identity probe. A failed
  write degrades to `{:error, reason}` rather than crashing the caller,
  which then decides whether to re-auth. A non-binary slug, or a token
  that is not a non-empty string, yields `:skipped`.
  """
  @spec put_push_token(Context.t(), String.t(), term(), term(), String.t()) ::
          :ok | :skipped | {:error, :unavailable | :forbidden}
  def put_push_token(%Context{} = ctx, registry, slug, token, role) do
    case RegistryCredentials.put_push_token(ctx, registry, slug, token, role,
           label: device_label()
         ) do
      {:error, reason} = err ->
        Logger.warning(
          "[CredentialStore] push-token write failed for #{inspect(slug)}: #{inspect(reason)} — " <>
            "leaving orphan cyfr.run token (server-side reaper backstop)"
        )

        err

      stored_or_skipped ->
        stored_or_skipped
    end
  end

  @doc """
  The caller's credential for one registry and namespace.
  """
  @spec get(Context.t(), String.t(), String.t()) ::
          {:ok, RegistryCredentials.credential()}
          | {:error, :not_found | :unavailable | :corrupt | :forbidden}
  defdelegate get(ctx, registry, namespace_slug), to: RegistryCredentials

  @doc """
  Every credential the caller holds for a registry, one per namespace,
  personal first then publisher-alphabetical. Used by:
  - `Compendium.Registry.Client` to pick a bearer for non-namespace-scoped
    calls (e.g. `/v1/identity/probe`).
  - Registry `whoami` to present personal + membership identity.
  """
  @spec list_for_user(Context.t(), String.t()) ::
          {:ok, [RegistryCredentials.credential() | RegistryCredentials.corrupt()]}
          | {:error, :unavailable | :forbidden}
  def list_for_user(%Context{} = ctx, registry), do: RegistryCredentials.list(ctx, registry)

  @doc """
  The usable push tokens of a listing, in its order: a row the decoder
  refused (`%{status: :corrupt}`) is skipped when choosing a bearer — it
  is still in the listing, for a caller that reports it. Every credential
  the decoder hands back carries a non-empty token.
  """
  @spec push_tokens([map()]) :: [RegistryCredentials.credential()]
  def push_tokens(entries) when is_list(entries) do
    Enum.filter(entries, &match?(%{type: :push_token, token: token} when is_binary(token), &1))
  end

  @doc """
  Delete the caller's credential for one registry and namespace.

  A failed delete is a failed REVOCATION — it surfaces, never reports `:ok`.
  """
  @spec delete(Context.t(), String.t(), String.t()) :: :ok | {:error, :unavailable | :forbidden}
  defdelegate delete(ctx, registry, namespace_slug), to: RegistryCredentials
end
