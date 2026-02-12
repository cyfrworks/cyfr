defmodule Arca.ComponentConfigStorage do
  @moduledoc """
  SQLite storage operations for Component Config overrides.

  This module provides the database layer for per-component user configuration
  overrides. Reads are cached via `Arca.Cache` for performance.

  ## Schema

  The `component_configs` table stores:
  - id: Unique config entry ID (prefixed `ccfg_`)
  - component_ref: Component reference (e.g., "local.stripe-catalyst:1.0.0")
  - key: Configuration key name
  - value: JSON-encoded configuration value
  - updated_at: Timestamp of last update

  ## Design

  User config overrides were previously stored in `user.json` files inside
  the component version directory. This module moves them into SQLite to
  keep the component directory immutable (for signature integrity and OCI
  distribution).

  Developer defaults remain in `config.json` on the filesystem.
  """

  import Ecto.Query

  @doc """
  Get all config overrides for a component reference.

  Returns `{:ok, %{key => decoded_value}}` for all keys.
  """
  @spec get_all_config(String.t()) :: {:ok, map()}
  def get_all_config(component_ref) when is_binary(component_ref) do
    cache_key = {:component_config, component_ref}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_all_config_from_db(component_ref)
    end
  end

  defp get_all_config_from_db(component_ref) do
    query = from(c in "component_configs",
      where: c.component_ref == ^component_ref,
      select: %{key: c.key, value: c.value}
    )

    rows = Arca.Repo.all(query)

    config =
      Map.new(rows, fn %{key: key, value: value} ->
        {key, decode_value(value)}
      end)

    Arca.Cache.put({:component_config, component_ref}, config)
    {:ok, config}
  rescue
    Ecto.QueryError -> {:ok, %{}}
    DBConnection.ConnectionError -> {:ok, %{}}
  end

  @doc """
  Upsert a single config key for a component reference.

  The value is JSON-encoded before storage.
  """
  @spec put_config(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def put_config(component_ref, key, value)
      when is_binary(component_ref) and is_binary(key) do
    now = DateTime.utc_now()
    encoded_value = Jason.encode!(value)
    id = "ccfg_#{Ecto.UUID.generate()}"

    Arca.Repo.insert_all(
      "component_configs",
      [%{
        id: id,
        component_ref: component_ref,
        key: key,
        value: encoded_value,
        updated_at: now
      }],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:component_ref, :key]
    )

    Arca.Cache.invalidate({:component_config, component_ref})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Delete a single config key for a component reference.
  """
  @spec delete_config(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_config(component_ref, key)
      when is_binary(component_ref) and is_binary(key) do
    query = from(c in "component_configs",
      where: c.component_ref == ^component_ref and c.key == ^key
    )

    Arca.Repo.delete_all(query)
    Arca.Cache.invalidate({:component_config, component_ref})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Delete all config keys for a component reference.
  """
  @spec delete_all_config(String.t()) :: :ok | {:error, term()}
  def delete_all_config(component_ref) when is_binary(component_ref) do
    query = from(c in "component_configs",
      where: c.component_ref == ^component_ref
    )

    Arca.Repo.delete_all(query)
    Arca.Cache.invalidate({:component_config, component_ref})
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  List distinct component refs that have config overrides stored.
  """
  @spec list_component_refs() :: [String.t()]
  def list_component_refs do
    query = from(c in "component_configs",
      distinct: true,
      select: c.component_ref,
      order_by: c.component_ref
    )

    Arca.Repo.all(query)
  rescue
    _ -> []
  end

  defp decode_value(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, val} -> val
      _ -> json
    end
  end

  defp decode_value(val), do: val
end
