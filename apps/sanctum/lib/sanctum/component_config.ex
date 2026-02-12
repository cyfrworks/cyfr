defmodule Sanctum.ComponentConfig do
  @moduledoc """
  Component configuration storage for CYFR.

  Provides per-component configuration storage, separate from Host Policy.
  While Policy defines security constraints (what a component CAN do),
  ComponentConfig stores operational settings (HOW a component behaves).

  ## Configuration vs Policy

  | Aspect | Policy | ComponentConfig |
  |--------|--------|-----------------|
  | Purpose | Security constraints | Operational settings |
  | Who controls | Host/Admin | Component author or user |
  | Example | allowed_domains, rate_limit | api_version, feature_flags |

  ## Storage

  - `components/{type}s/{publisher}/{name}/{version}/config.json` — immutable developer defaults (filesystem)
  - `data/cyfr.db` → `component_configs` table — mutable user/project overrides (SQLite)

  The merged result (defaults + overrides) is returned by `get_all/2`.

  ## Usage

      ctx = Sanctum.Context.local()

      # Set a config value (writes to data/cyfr.db → component_configs)
      :ok = Sanctum.ComponentConfig.set(ctx, "local.stripe-catalyst:1.0.0", "api_version", "2023-10-16")

      # Get a config value (merged config.json + SQLite overrides)
      {:ok, "2023-10-16"} = Sanctum.ComponentConfig.get(ctx, "local.stripe-catalyst:1.0.0", "api_version")

      # Get all config for a component
      {:ok, %{"api_version" => "2023-10-16"}} = Sanctum.ComponentConfig.get_all(ctx, "local.stripe-catalyst:1.0.0")

      # Delete a config key
      :ok = Sanctum.ComponentConfig.delete(ctx, "local.stripe-catalyst:1.0.0", "api_version")

  """

  alias Sanctum.Context

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get a specific config value for a component.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, value} = Sanctum.ComponentConfig.get(ctx, "local.my-component:1.0.0", "api_key")

  """
  @spec get(Context.t(), String.t(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def get(%Context{} = ctx, component_ref, key) when is_binary(component_ref) and is_binary(key) do
    with {:ok, config} <- load_config(ctx, component_ref) do
      case Map.get(config, key) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end
  end

  @doc """
  Get all config for a component.

  Returns the merged result of config.json (developer defaults) and
  user overrides from SQLite (data/cyfr.db → component_configs table).

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, config} = Sanctum.ComponentConfig.get_all(ctx, "local.my-component:1.0.0")
      iex> config["api_version"]
      "2023-10-16"

  """
  @spec get_all(Context.t(), String.t()) :: {:ok, map()}
  def get_all(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    load_config(ctx, component_ref)
  end

  @doc """
  Set a config value for a component.

  Writes to SQLite (data/cyfr.db → component_configs table).
  Never modifies config.json.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> :ok = Sanctum.ComponentConfig.set(ctx, "local.stripe-catalyst:1.0.0", "api_version", "2023-10-16")

  """
  @spec set(Context.t(), String.t(), String.t(), term()) :: :ok | {:error, term()}
  def set(%Context{} = _ctx, component_ref, key, value)
      when is_binary(component_ref) and is_binary(key) do
    case Arca.MCP.handle("component_config_store", nil, %{
      "action" => "put",
      "component_ref" => component_ref,
      "key" => key,
      "value" => value
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Set multiple config values for a component at once.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> :ok = Sanctum.ComponentConfig.set_all(ctx, "local.stripe-catalyst:1.0.0", %{
      ...>   "api_version" => "2023-10-16",
      ...>   "webhook_secret" => "whsec_..."
      ...> })

  """
  @spec set_all(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def set_all(%Context{} = _ctx, component_ref, values)
      when is_binary(component_ref) and is_map(values) do
    Enum.reduce_while(values, :ok, fn {key, value}, :ok ->
      case Arca.MCP.handle("component_config_store", nil, %{
        "action" => "put",
        "component_ref" => component_ref,
        "key" => key,
        "value" => value
      }) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Delete a config key for a component.

  Removes the key from SQLite (data/cyfr.db → component_configs table).

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> :ok = Sanctum.ComponentConfig.delete(ctx, "local.stripe-catalyst:1.0.0", "api_version")

  """
  @spec delete(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = _ctx, component_ref, key)
      when is_binary(component_ref) and is_binary(key) do
    case Arca.MCP.handle("component_config_store", nil, %{
      "action" => "delete",
      "component_ref" => component_ref,
      "key" => key
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete all user config for a component.

  Removes all overrides from SQLite (config.json developer defaults remain).

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> :ok = Sanctum.ComponentConfig.delete_all(ctx, "local.stripe-catalyst:1.0.0")

  """
  @spec delete_all(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete_all(%Context{} = _ctx, component_ref) when is_binary(component_ref) do
    case Arca.MCP.handle("component_config_store", nil, %{
      "action" => "delete_all",
      "component_ref" => component_ref
    }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List all components that have config stored.

  Queries Arca.ComponentStorage for the list of registered components.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, refs} = Sanctum.ComponentConfig.list_components(ctx)
      iex> refs
      ["local.stripe-catalyst:1.0.0", "local.github-events:1.0.0"]

  """
  @spec list_components(Context.t()) :: {:ok, [String.t()]}
  def list_components(%Context{} = ctx) do
    case Arca.MCP.handle("component_store", ctx, %{"action" => "list"}) do
      {:ok, %{components: components}} ->
        refs =
          components
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, refs}
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp component_storage_prefix(component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %Sanctum.ComponentRef{namespace: namespace, name: name, version: version}} ->
        case Arca.MCP.handle("component_store", Sanctum.Context.local(), %{
          "action" => "get",
          "name" => name,
          "version" => version
        }) do
          {:ok, %{component: component}} ->
            type = component.component_type
            publisher = Map.get(component, :publisher, namespace)
            {:ok, ["components", "#{type}s", publisher, name, version]}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_config(ctx, component_ref) do
    # Read immutable developer defaults from config.json on filesystem
    defaults = case component_storage_prefix(component_ref) do
      {:ok, prefix} -> read_storage_json(ctx, prefix ++ ["config.json"])
      {:error, _} -> %{}
    end

    # Read mutable user overrides from SQLite
    {:ok, overrides} = Arca.MCP.handle("component_config_store", nil, %{
      "action" => "get_all",
      "component_ref" => component_ref
    })

    {:ok, Map.merge(defaults, overrides.config)}
  end

  defp read_storage_json(ctx, path) do
    case Arca.MCP.handle("storage", ctx, %{"action" => "read", "path" => path}) do
      {:ok, %{content: b64_content}} -> Jason.decode!(Base.decode64!(b64_content))
      {:error, _} -> %{}
    end
  end
end
