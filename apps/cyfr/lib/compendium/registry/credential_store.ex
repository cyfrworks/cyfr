defmodule Compendium.Registry.CredentialStore do
  @moduledoc """
  Encrypted server-side registry credential storage.

  Uses `Sanctum.Secrets` (AES-256-GCM via `Sanctum.Crypto`) over `Arca.SecretStorage`.
  No migration needed — reuses the existing `secrets` table.

  ## Stored shape

  Post-auth-refactor, only push tokens are stored. A user legitimately holds
  multiple entries — one personal-namespace token plus one per publisher
  membership. Keys are `_registry.{registry}.{user_id}.{namespace_slug}` so
  each namespace gets an independent credential slot.

  Stored value:

      %{type: :push_token, token: "cyfr_pt_...", namespace: "alice",
        issued_at: iso8601, label: "host-name"}

  `get_for_registry/1` has been removed: the cross-user fallback was a privacy
  leak in multi-user Core, and with single-registry scope (cyfr.run apex or a
  self-deployed cyfr.run) there is no cross-registry fallback use case either.
  """

  require Logger

  alias Sanctum.{Context, Secrets}

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
    ctx = system_context()
    name = secret_name(registry, user_id, namespace_slug)
    value = encode_credential(credential)

    Secrets.set(ctx, name, value)
  end

  @doc """
  Get a credential for a specific user, registry, and namespace.

  Returns `{:ok, credential_map}` or `:not_found`.
  """
  @spec get(String.t(), String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(user_id, registry, namespace_slug)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) do
    ctx = system_context()
    name = secret_name(registry, user_id, namespace_slug)

    case Secrets.get(ctx, name) do
      {:ok, value} -> decode_credential(value)
      {:error, :not_found} -> :not_found
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
    ctx = system_context()
    prefix = "_registry.#{registry}.#{user_id}."

    case Secrets.list(ctx) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&{&1, String.trim_leading(&1, prefix)})
        |> Enum.sort_by(fn {_name, slug} ->
          # Personal + reserved (no dot) come before publisher (has dot),
          # then alphabetical within each bucket.
          {if(String.contains?(slug, "."), do: 1, else: 0), slug}
        end)
        |> Enum.flat_map(fn {name, _slug} ->
          case Secrets.get(ctx, name) do
            {:ok, value} ->
              case decode_credential(value) do
                {:ok, cred} -> [cred]
                :not_found -> []
              end

            _ ->
              []
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
    ctx = system_context()
    name = secret_name(registry, user_id, namespace_slug)
    Secrets.delete(ctx, name)
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

  defp secret_name(registry, user_id, namespace_slug) do
    "_registry.#{registry}.#{user_id}.#{namespace_slug}"
  end

  defp system_context do
    # Platform scope: secret bootstrap crosses tenant boundaries (the same
    # CredentialStore stores entries for every user on the instance).
    # No namespace required — this context only writes to the `secrets` DB
    # table via Arca.SecretStorage; never a user-scoped FS path.
    Context.build(
      user_id: "system",
      namespace: "_system",
      permissions: [:secrets_write, :secrets_read],
      scope: :platform,
      auth_method: :local,
      authenticated: true
    )
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
