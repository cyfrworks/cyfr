# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RegistryCredentials do
  @moduledoc """
  A person's registry push tokens: one per `(registry, namespace)` they
  publish to, sealed at rest.

  The person is the caller's context — every function keys by
  `ctx.user_id` and takes no user from its arguments, so no caller can
  read or write another person's token. A context without a person is
  `{:error, :forbidden}`.

  Values are sealed with `Sanctum.Cipher` under the `:registry_token`
  purpose, whose AAD binds the user, the registry and the namespace, so a
  row copied under another key does not open. The storage layer
  (`Arca.RegistryTokenStorage`) holds ciphertext only.

  A read keeps three failures apart from absence: `:unavailable` (the
  store could not answer), `:corrupt` (a row that does not decrypt, or
  decrypts to anything but a push token) and `:not_found`. A caller that
  collapsed them would tell a person whose token is damaged, or whose
  server is down, to sign in again.

  ## Stored shape

      %{type: :push_token, token: "cyfr_pt_...", namespace: "alice",
        role: "personal", issued_at: iso8601, label: "host-name"}

  `label` is stored only when the caller gives one.
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.Context

  # The keys a stored credential may carry. `:type` is always
  # `:push_token`; any other stored type is a damaged row.
  @valid_keys ~w(type token namespace issued_at label role)a

  @typedoc "One decrypted push-token credential."
  @type credential :: %{
          required(:type) => :push_token,
          optional(:token) => term(),
          optional(:namespace) => term(),
          optional(:issued_at) => term(),
          optional(:label) => term(),
          optional(:role) => term()
        }

  @typedoc "A stored row that could not be opened: its id, and nothing it held."
  @type corrupt :: %{required(:id) => String.t(), required(:status) => :corrupt}

  @doc """
  Seal and store a push token for the caller, replacing the one the same
  `(registry, namespace_slug)` held. A non-binary slug or token stores
  nothing and answers `:skipped`.

  `opts`: `:label`, the name of the device the token was issued to.
  """
  @spec put_push_token(Context.t(), String.t(), term(), term(), String.t(), keyword()) ::
          :ok | :skipped | {:error, :unavailable | :forbidden}
  def put_push_token(ctx, registry, namespace_slug, token, role, opts \\ [])

  def put_push_token(%Context{} = ctx, registry, namespace_slug, token, role, opts)
      when is_binary(registry) and is_binary(namespace_slug) and is_binary(token) and
             is_list(opts) do
    with {:ok, user_id} <- person(ctx) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      credential =
        %{
          "type" => "push_token",
          "token" => token,
          "namespace" => namespace_slug,
          "role" => role,
          "issued_at" => DateTime.to_iso8601(now)
        }
        |> put_label(Keyword.get(opts, :label))

      seal_and_store(user_id, registry, namespace_slug, credential, now)
    end
  end

  def put_push_token(%Context{}, _registry, _namespace_slug, _token, _role, _opts), do: :skipped

  @doc """
  The caller's credential for one `(registry, namespace_slug)`.
  """
  @spec get(Context.t(), String.t(), String.t()) ::
          {:ok, credential()} | {:error, :not_found | :unavailable | :corrupt | :forbidden}
  def get(%Context{} = ctx, registry, namespace_slug)
      when is_binary(registry) and is_binary(namespace_slug) do
    with {:ok, user_id} <- person(ctx) do
      case Arca.RegistryTokenStorage.get(user_id, registry, namespace_slug) do
        {:ok, row} ->
          case unseal(row) do
            {:ok, credential} -> {:ok, credential}
            :corrupt -> {:error, :corrupt}
          end

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, _unreadable} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  Every credential the caller holds for a registry, personal and reserved
  namespaces first, then publisher namespaces, alphabetical within each.

  A row that cannot be opened is present as `%{id: id, status: :corrupt}`
  where its credential would have been, never dropped.
  """
  @spec list(Context.t(), String.t()) ::
          {:ok, [credential() | corrupt()]} | {:error, :unavailable | :forbidden}
  def list(%Context{} = ctx, registry) when is_binary(registry) do
    with {:ok, user_id} <- person(ctx) do
      case Arca.RegistryTokenStorage.list(user_id, registry) do
        {:ok, rows} ->
          {:ok,
           rows
           |> Enum.sort_by(&{publisher_rank(&1.namespace_slug), &1.namespace_slug})
           |> Enum.map(fn row ->
             case unseal(row) do
               {:ok, credential} -> credential
               :corrupt -> %{id: row.id, status: :corrupt}
             end
           end)}

        {:error, _unreadable} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  Delete the caller's credential for one `(registry, namespace_slug)`.
  Idempotent. A failed delete is a failed revocation and never reads as
  `:ok`.
  """
  @spec delete(Context.t(), String.t(), String.t()) :: :ok | {:error, :unavailable | :forbidden}
  def delete(%Context{} = ctx, registry, namespace_slug)
      when is_binary(registry) and is_binary(namespace_slug) do
    with {:ok, user_id} <- person(ctx) do
      case Arca.RegistryTokenStorage.delete(user_id, registry, namespace_slug) do
        :ok -> :ok
        {:error, _unreadable} -> {:error, :unavailable}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp person(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "",
    do: {:ok, user_id}

  defp person(%Context{}), do: {:error, :forbidden}

  defp put_label(credential, label) when is_binary(label), do: Map.put(credential, "label", label)
  defp put_label(credential, _label), do: credential

  # A keyring that cannot seal raises; it is the store being unable to
  # take the write, reported as such, and the token is not logged.
  defp seal_and_store(user_id, registry, namespace_slug, credential, issued_at) do
    aad = CipherAAD.registry_token(user_id, registry, namespace_slug)
    {:ok, ciphertext} = Sanctum.Cipher.encrypt(Jason.encode!(credential), aad)

    case Arca.RegistryTokenStorage.put(%{
           user_id: user_id,
           registry: registry,
           namespace_slug: namespace_slug,
           credential_ciphertext: ciphertext,
           issued_at: issued_at
         }) do
      :ok -> :ok
      {:error, _unreadable} -> {:error, :unavailable}
    end
  rescue
    e ->
      Logger.warning(
        "[Sanctum.RegistryCredentials] push-token seal for #{namespace_slug} raised " <>
          "#{inspect(e.__struct__)} — not stored"
      )

      {:error, :unavailable}
  end

  defp unseal(row) do
    aad = CipherAAD.registry_token(row.user_id, row.registry, row.namespace_slug)

    with {:ok, value} <- Sanctum.Cipher.decrypt(row.credential_ciphertext, aad),
         {:ok, %{"type" => "push_token"} = map} <- Jason.decode(value) do
      credential =
        for key <- @valid_keys,
            Map.has_key?(map, Atom.to_string(key)),
            into: %{},
            do: {key, Map.fetch!(map, Atom.to_string(key))}

      {:ok, %{credential | type: :push_token}}
    else
      _unopened ->
        Logger.warning(
          "[Sanctum.RegistryCredentials] stored credential #{row.id} " <>
            "(namespace #{row.namespace_slug}) could not be opened"
        )

        :corrupt
    end
  end

  # Personal and reserved namespaces carry no dot; publisher namespaces do.
  defp publisher_rank(slug), do: if(String.contains?(slug, "."), do: 1, else: 0)
end
