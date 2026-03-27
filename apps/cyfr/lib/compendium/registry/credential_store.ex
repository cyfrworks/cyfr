defmodule Compendium.Registry.CredentialStore do
  @moduledoc """
  Encrypted server-side registry credential storage.

  Uses `Sanctum.Secrets` (AES-256-GCM via `Sanctum.Crypto`) over `Arca.SecretStorage`.
  No migration needed — reuses the existing `secrets` table.

  ## Credential Types

  Supports multiple auth methods for extensibility:

  - `:basic` — username + password/token (GitHub device flow, manual login)
  - `:bearer` — direct bearer token (API tokens, service accounts)
  - `:oauth2_client` — client credentials grant (CI/CD, service-to-service)
  - `:key_pair` — asymmetric auth (future: sign challenges with private key)

  ## Storage

  Credentials are stored as encrypted JSON in the secrets table with a
  system-prefixed name: `_registry.{registry}.{user_id}`.
  """

  require Logger

  alias Sanctum.{Context, Secrets}

  @doc """
  Store a credential for a user and registry.

  ## Examples

      CredentialStore.put("user_123", "registry.cyfr.run", %{
        type: :basic,
        username: "email@example.com",
        password: "jwt_token"
      })

  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(user_id, registry, credential) when is_binary(user_id) and is_binary(registry) do
    ctx = system_context()
    name = secret_name(registry, user_id)
    value = encode_credential(credential)

    Secrets.set(ctx, name, value)
  end

  @doc """
  Get a credential for a specific user and registry.

  Returns `{:ok, credential_map}` or `:not_found`.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    ctx = system_context()
    name = secret_name(registry, user_id)

    case Secrets.get(ctx, name) do
      {:ok, value} -> decode_credential(value)
      {:error, :not_found} -> :not_found
      {:error, _} -> :not_found
    end
  end

  @doc """
  Get any credential for a registry (Core mode — any user).

  Searches for credentials stored by any user for the given registry.
  Returns the first match found.
  """
  @spec get_for_registry(String.t()) :: {:ok, map()} | :not_found
  def get_for_registry(registry) when is_binary(registry) do
    ctx = system_context()
    prefix = "_registry.#{registry}."

    case Secrets.list(ctx) do
      {:ok, names} ->
        matching = Enum.find(names, &String.starts_with?(&1, prefix))

        case matching do
          nil ->
            :not_found

          name ->
            case Secrets.get(ctx, name) do
              {:ok, value} -> decode_credential(value)
              _ -> :not_found
            end
        end

      {:error, _} ->
        :not_found
    end
  end

  @doc """
  Delete a credential for a user and registry.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    ctx = system_context()
    name = secret_name(registry, user_id)
    Secrets.delete(ctx, name)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp secret_name(registry, user_id) do
    "_registry.#{registry}.#{user_id}"
  end

  defp system_context do
    Context.build(
      user_id: "system",
      project_id: "default",
      permissions: [:secrets_write, :secrets_read],
      scope: :project,
      auth_method: :local,
      authenticated: true
    )
  end

  defp encode_credential(credential) when is_map(credential) do
    # Normalize atom keys to strings for JSON encoding
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
        # Convert "type" string back to atom for dispatch
        credential =
          map
          |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
          |> Map.update(:type, :basic, &String.to_existing_atom/1)

        {:ok, credential}

      _ ->
        :not_found
    end
  rescue
    ArgumentError -> :not_found
  end
end
