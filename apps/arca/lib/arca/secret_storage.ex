defmodule Arca.SecretStorage do
  @moduledoc """
  SQLite storage operations for encrypted secrets and grants.

  This module provides the database layer for secret storage.
  It's called by `Sanctum.Secrets` which handles encryption/decryption
  via `Sanctum.Crypto`.

  Values are stored as encrypted binaries. Names, scopes, and grants
  are stored as plaintext for queryability.
  """

  import Ecto.Query

  @doc """
  Get a secret's encrypted value by name, scope, and org_id.

  Returns `{:ok, encrypted_value}` or `{:error, :not_found}`.
  """
  @spec get_secret(String.t(), String.t(), String.t() | nil) ::
          {:ok, binary()} | {:error, :not_found}
  def get_secret(name, scope, org_id) do
    cache_key = {:secret, {name, scope, org_id}}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_secret_from_db(name, scope, org_id)
    end
  end

  defp get_secret_from_db(name, scope, org_id) do
    query =
      from(s in "secrets",
        where: s.name == ^name and s.scope == ^scope,
        limit: 1,
        select: s.encrypted_value
      )

    query = where_org_id(query, org_id)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      encrypted_value ->
        Arca.Cache.put({:secret, {name, scope, org_id}}, encrypted_value)
        {:ok, encrypted_value}
    end
  rescue
    Ecto.QueryError -> {:error, :not_found}
    DBConnection.ConnectionError -> {:error, :not_found}
  end

  @doc """
  Upsert a secret. Inserts or updates on `(name, scope, org_id)` conflict.
  """
  @spec put_secret(String.t(), binary(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def put_secret(name, encrypted_value, scope, org_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      name: name,
      encrypted_value: encrypted_value,
      scope: scope,
      org_id: normalize_org_id(org_id),
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(
      "secrets",
      [attrs],
      on_conflict: {:replace, [:encrypted_value, :updated_at]},
      conflict_target: [:name, :scope, :org_id]
    )

    Arca.Cache.invalidate({:secret, {name, scope, org_id}})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Delete a secret by name, scope, and org_id.
  """
  @spec delete_secret(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def delete_secret(name, scope, org_id) do
    query = from(s in "secrets", where: s.name == ^name and s.scope == ^scope)
    query = where_org_id(query, org_id)

    Arca.Repo.delete_all(query)
    Arca.Cache.invalidate({:secret, {name, scope, org_id}})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  List all secret names for a given scope and org_id.
  """
  @spec list_secrets(String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def list_secrets(scope, org_id) do
    query =
      from(s in "secrets",
        where: s.scope == ^scope,
        select: s.name,
        order_by: s.name
      )

    query = where_org_id(query, org_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    _ -> {:ok, []}
  end

  # ============================================================================
  # Grants
  # ============================================================================

  @doc """
  Insert a grant. Ignores conflict (idempotent).
  """
  @spec put_grant(String.t(), String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def put_grant(secret_name, component_ref, scope, org_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      secret_name: secret_name,
      component_ref: component_ref,
      scope: scope,
      org_id: normalize_org_id(org_id),
      inserted_at: now
    }

    Arca.Repo.insert_all("secret_grants", [attrs], on_conflict: :nothing,
      conflict_target: [:secret_name, :component_ref, :scope, :org_id])

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Delete a grant.
  """
  @spec delete_grant(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def delete_grant(secret_name, component_ref, scope, org_id) do
    query =
      from(g in "secret_grants",
        where:
          g.secret_name == ^secret_name and
            g.component_ref == ^component_ref and
            g.scope == ^scope
      )

    query = where_org_id(query, org_id)

    Arca.Repo.delete_all(query)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  List component_refs granted access to a secret.
  """
  @spec list_grants(String.t(), String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def list_grants(secret_name, scope, org_id) do
    query =
      from(g in "secret_grants",
        where: g.secret_name == ^secret_name and g.scope == ^scope,
        select: g.component_ref
      )

    query = where_org_id(query, org_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    _ -> {:ok, []}
  end

  @doc """
  List secret_names that a component has been granted access to.
  Used by `resolve_granted_secrets`.
  """
  @spec grants_for_component(String.t(), String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def grants_for_component(component_ref, scope, org_id) do
    query =
      from(g in "secret_grants",
        where: g.component_ref == ^component_ref and g.scope == ^scope,
        select: g.secret_name
      )

    query = where_org_id(query, org_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    _ -> {:ok, []}
  end

  # ============================================================================
  # Private
  # ============================================================================

  # SQLite treats NULL != NULL in unique indexes, so we use "" as sentinel
  # for nil org_id to ensure conflict detection works correctly.
  defp normalize_org_id(nil), do: ""
  defp normalize_org_id(org_id), do: org_id

  defp where_org_id(query, nil) do
    from(q in query, where: q.org_id == "")
  end

  defp where_org_id(query, org_id) do
    from(q in query, where: q.org_id == ^org_id)
  end
end
