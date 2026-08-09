# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.CredentialStore do
  @moduledoc """
  Encrypted server-side registry credential storage.

  Backed by the `registry_tokens` table via `Arca.RegistryTokenStorage`;
  values are sealed here with the configured `Sanctum.Cipher` under the
  `:registry_token` AAD purpose (the storage layer holds ciphertext only).

  ## Stored shape

  Post-auth-refactor, only push tokens are stored. A user legitimately holds
  multiple entries — one personal-namespace token plus one per publisher
  membership, keyed `(user_id, registry, namespace_slug)` so each namespace
  gets an independent credential slot.

  Stored value:

      %{type: :push_token, token: "cyfr_pt_...", namespace: "alice",
        issued_at: iso8601, label: "host-name"}

  `get_for_registry/1` has been removed: the cross-user fallback was a
  privacy leak in any shared-deployment scenario, and with single-registry
  scope (cyfr.run apex or a self-deployed cyfr.run) there is no
  cross-registry fallback use case either.
  """

  require Logger

  alias Arca.RegistryTokenStorage
  alias Sanctum.CipherAAD

  # Keys in the stored credential map. `:type` carries the credential shape
  # (currently always `:push_token`); it is a value, not a key, so don't list
  # it here.
  @valid_keys ~w(type token namespace issued_at label role)a

  @doc """
  Store a credential for a user, registry, and namespace.

      CredentialStore.put(
        "github|https://github.com|12345678",
        "registry.cyfr.run",
        "alice",
        %{type: :push_token, token: "cyfr_pt_...", namespace: "alice",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          label: "laptop"}
      )

  """
  @spec put(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(user_id, registry, namespace_slug, credential)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) do
    value = encode_credential(credential)
    aad = CipherAAD.registry_token(user_id, registry, namespace_slug)
    {:ok, ciphertext} = Sanctum.Cipher.encrypt(value, aad)

    RegistryTokenStorage.put(%{
      user_id: user_id,
      registry: registry,
      namespace_slug: namespace_slug,
      credential_ciphertext: ciphertext,
      issued_at: credential_issued_at(credential)
    })
  end

  @doc """
  Build a push-token credential and store it, best-effort.

  Shared by the OAuth callback and the CLI device flow — both cache the same
  push-token shape after the identity probe. Failures, including a raised
  encryption/keyring misconfiguration, degrade to `{:error, reason}` rather than
  crashing the caller, which then decides whether to re-auth. A non-binary slug
  or token yields `:skipped`.
  """
  @spec put_push_token(String.t(), String.t(), term(), term(), String.t()) ::
          :ok | {:error, term()} | :skipped
  def put_push_token(user_id, registry, slug, token, role)
      when is_binary(slug) and is_binary(token) do
    cred = %{
      type: :push_token,
      token: token,
      namespace: slug,
      role: role,
      issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      label: Compendium.Registry.Client.device_label()
    }

    case put(user_id, registry, slug, cred) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "[CredentialStore] push-token write failed for #{slug}: #{inspect(reason)} — " <>
            "leaving orphan cyfr.run token (server-side reaper backstop)"
        )

        err
    end
  rescue
    e ->
      Logger.warning(
        "[CredentialStore] push-token write raised for #{slug}: #{Exception.message(e)} — " <>
          "treating as a failed credential write"
      )

      {:error, :exception}
  end

  def put_push_token(_user_id, _registry, _slug, _token, _role), do: :skipped

  @doc """
  Get a credential for a specific user, registry, and namespace.

  Returns `{:ok, credential_map}` or `:not_found`.
  """
  @spec get(String.t(), String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(user_id, registry, namespace_slug)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) do
    case RegistryTokenStorage.get(user_id, registry, namespace_slug) do
      {:ok, row} -> unseal(row)
      {:error, _} -> :not_found
    end
  end

  @doc """
  List all credentials a user holds for a registry, one per namespace.

  Returns a list ordered personal-first then publisher-alphabetical.
  Empty list if the user has no credentials.

  Used by:
  - The web claim-gate plug to detect whether a user has any personal-namespace
    credential (bare slug, no dot) and skip the gate.
  - `Compendium.Registry.Client.auth_headers/1` to pick a bearer for
    non-namespace-scoped calls (e.g. `/v1/identity/probe`).
  - Registry `whoami` to present personal + membership identity.
  """
  @spec list_for_user(String.t(), String.t()) :: [map()]
  def list_for_user(user_id, registry)
      when is_binary(user_id) and is_binary(registry) do
    case RegistryTokenStorage.list(user_id, registry) do
      {:ok, rows} ->
        rows
        |> Enum.sort_by(fn row ->
          # Personal + reserved (no dot) come before publisher (has dot),
          # then alphabetical within each bucket.
          {if(String.contains?(row.namespace_slug, "."), do: 1, else: 0), row.namespace_slug}
        end)
        |> Enum.flat_map(fn row ->
          case unseal(row) do
            {:ok, cred} -> [cred]
            :not_found -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Delete a credential for a user, registry, and namespace.
  """
  @spec delete(String.t(), String.t(), String.t()) :: :ok
  def delete(user_id, registry, namespace_slug)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) do
    case RegistryTokenStorage.delete(user_id, registry, namespace_slug) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @doc """
  Returns true if the user has a credential under a personal-namespace slug
  on this registry.

  A personal slug is bare (no dot); publisher slugs are dotted (`stripe.com`).
  Reserved slugs are also bare, but reserved-slug claims require admin approval
  and never end up in a regular user's CredentialStore — so a bare-slug
  credential here is, in practice, the user's personal namespace.

  Used by the claim-namespace gate (HTTP plug + LiveView on_mount) to decide
  whether the user has finished post-OAuth claim and can access the dashboard.
  """
  @spec has_personal?(String.t(), String.t()) :: boolean()
  def has_personal?(user_id, registry)
      when is_binary(user_id) and is_binary(registry) do
    list_for_user(user_id, registry)
    |> Enum.any?(fn cred ->
      slug = personal_slug(cred)
      is_binary(slug) and slug != "" and not String.contains?(slug, ".")
    end)
  end

  defp personal_slug(%{namespace: slug}), do: slug
  defp personal_slug(%{"namespace" => slug}), do: slug
  defp personal_slug(_), do: nil

  # ============================================================================
  # Internal
  # ============================================================================

  defp unseal(row) do
    aad = CipherAAD.registry_token(row.user_id, row.registry, row.namespace_slug)

    case Sanctum.Cipher.decrypt(row.credential_ciphertext, aad) do
      {:ok, value} ->
        decode_credential(value)

      {:error, reason} ->
        Logger.warning(
          "[CredentialStore] decrypt failed for user=#{row.user_id} " <>
            "namespace=#{row.namespace_slug}: #{inspect(reason)}"
        )

        :not_found
    end
  end

  defp credential_issued_at(credential) do
    raw = credential[:issued_at] || credential["issued_at"]

    with true <- is_binary(raw),
         {:ok, dt, _offset} <- DateTime.from_iso8601(raw) do
      DateTime.truncate(dt, :microsecond)
    else
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp encode_credential(credential) when is_map(credential) do
    # Normalize atom keys to strings for JSON encoding.
    normalized =
      credential
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_value(v)}
        {k, v} -> {k, normalize_value(v)}
      end)
      |> Map.new()

    case Jason.encode(normalized) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp normalize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_value(v), do: v

  defp decode_credential(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        credential =
          map
          |> Enum.reduce(%{}, fn {k, v}, acc ->
            atom_key = safe_atom(k)
            if atom_key in @valid_keys, do: Map.put(acc, atom_key, v), else: acc
          end)
          |> Map.update(:type, :push_token, &normalize_type/1)

        {:ok, credential}

      _ ->
        :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  # Coerce stored `type` to a known atom. `nil`/unknown values default to
  # `:push_token` (the only legal type post-auth-refactor) but are logged so
  # data corruption doesn't get silently masked.
  defp normalize_type(t) when is_atom(t), do: t

  defp normalize_type(t) when is_binary(t) do
    case safe_atom(t) do
      nil ->
        Logger.warning(
          "[CredentialStore] credential type=#{inspect(t)} not a known atom; " <>
            "coercing to :push_token (likely stale row predating auth-refactor)"
        )

        :push_token

      atom ->
        atom
    end
  end

  defp normalize_type(other) do
    Logger.warning(
      "[CredentialStore] credential type=#{inspect(other)} unexpected shape; " <>
        "coercing to :push_token"
    )

    :push_token
  end

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(a) when is_atom(a), do: a
end
