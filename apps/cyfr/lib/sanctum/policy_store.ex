defmodule Sanctum.PolicyStore do
  @moduledoc """
  SQLite-backed storage for Host Policies.

  Policies are stored in the `policies` table via Arca. Caching is
  handled transparently by `Arca.Cache` inside the storage layer.

  ## Usage

      # Get a policy for a component
      {:ok, policy} = Sanctum.PolicyStore.get(ctx, "local.stripe-catalyst:1.0.0")

      # Save a policy
      :ok = Sanctum.PolicyStore.put(ctx, "local.stripe-catalyst:1.0.0", policy)

      # Delete a policy
      :ok = Sanctum.PolicyStore.delete(ctx, "local.stripe-catalyst:1.0.0")

      # List all policies
      {:ok, policies} = Sanctum.PolicyStore.list(ctx)

  ## Database Access

  This module calls through to `Arca.PolicyStorage` and `Arca.ComponentStorage`
  for actual database operations.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Policy
  alias Sanctum.Policy.FieldSchema

  @type_default_prefix "__type_default__"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get the policy for a component reference.

  Returns `{:ok, policy}` or `{:error, :not_found}`.
  """
  @spec get(Context.t(), String.t()) :: {:ok, Policy.t()} | {:error, :not_found}
  def get(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    with {:ok, component_ref} <- normalize_component_ref(component_ref) do
      case Arca.PolicyStorage.get_policy(ctx, component_ref) do
        {:ok, row} when is_map(row) ->
          case row_to_policy(row) do
            {:ok, policy} -> {:ok, policy}
            {:error, reason} -> {:error, {:corrupt_policy, reason}}
          end

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, {:store_error, reason}}
      end
    end
  end

  @doc """
  Save a policy for a component reference.

  Upserts the policy in SQLite and updates the cache.
  """
  @spec put(Context.t(), String.t(), Policy.t() | map()) :: :ok | {:error, term()}
  def put(%Context{} = ctx, component_ref, %Policy{} = policy) when is_binary(component_ref) do
    put(ctx, component_ref, policy_to_map(policy))
  end

  def put(%Context{} = ctx, component_ref, policy_map)
      when is_binary(component_ref) and is_map(policy_map) do
    with {:ok, component_ref} <- normalize_component_ref(component_ref),
         raw_type = Map.get(policy_map, :component_type, "reagent"),
         {:ok, component_type} <- validate_component_type(raw_type),
         :ok <- validate_restricted_tools(component_type, policy_map),
         {:ok, setup_policy} <- fetch_setup_policy_for_type(ctx, component_ref, component_type),
         :ok <- FieldSchema.validate_fields(policy_map, setup_policy),
         :ok <-
           Sanctum.Policy.Ceiling.validate(
             policy_map,
             Sanctum.Policy.Ceiling.effective_ceiling(ctx)
           ),
         {:ok, window_seconds} <- get_rate_limit_window_seconds(policy_map),
         {:ok, encoded} <- encode_policy_json_fields(policy_map) do
      now = DateTime.utc_now()
      id = generate_id(component_ref)

      attrs = %{
        id: id,
        component_ref: component_ref,
        component_type: component_type,
        allowed_domains: encoded.allowed_domains,
        allowed_methods: encoded.allowed_methods,
        rate_limit_requests: get_rate_limit_requests(policy_map),
        rate_limit_window_seconds: window_seconds,
        timeout: Map.get(policy_map, :timeout, "30s"),
        max_memory_bytes: Map.get(policy_map, :max_memory_bytes, 64 * 1024 * 1024),
        max_request_size: Map.get(policy_map, :max_request_size, 1_048_576),
        max_response_size: Map.get(policy_map, :max_response_size, 5_242_880),
        allowed_tools: encoded.allowed_tools,
        allowed_paths: encoded.allowed_paths,
        allowed_actions: encoded.allowed_actions,
        batch_timeout: Map.get(policy_map, :batch_timeout, "5m"),
        max_concurrent_tasks: Map.get(policy_map, :max_concurrent_tasks, 10),
        allowed_private_ips: encoded.allowed_private_ips,
        is_public: Map.get(policy_map, :is_public, false) == true,
        inserted_at: DateTime.to_iso8601(now),
        updated_at: DateTime.to_iso8601(now)
      }

      case Arca.PolicyStorage.put_policy(ctx, attrs) do
        {:ok, _} ->
          Arca.Cache.invalidate({:policy, component_ref, ctx.org_id, ctx.project_id})
          Sanctum.Telemetry.policy_event(:put, component_ref)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Delete a policy for a component reference.
  """
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    with {:ok, component_ref} <- normalize_component_ref(component_ref) do
      case Arca.PolicyStorage.delete_policy(ctx, component_ref) do
        :ok ->
          Arca.Cache.invalidate({:policy, component_ref, ctx.org_id, ctx.project_id})
          Sanctum.Telemetry.policy_event(:delete, component_ref)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List all stored policies.
  """
  @spec list(Context.t()) ::
          {:ok,
           [
             %{component_ref: String.t(), policy: Policy.t()}
             | %{component_ref: String.t(), error: :corrupt_policy, reason: term()}
           ]}
  def list(%Context{} = ctx) do
    case Arca.PolicyStorage.list_policies(ctx) do
      {:ok, rows} ->
        db_policies =
          rows
          |> Enum.reject(fn row ->
            String.starts_with?(row.component_ref, @type_default_prefix)
          end)
          |> Enum.reduce([], fn row, acc ->
            case row_to_policy(row) do
              {:ok, policy} ->
                [%{component_ref: row.component_ref, policy: policy} | acc]

              {:error, reason} ->
                Logger.error(
                  "[Sanctum.PolicyStore] Corrupt policy for #{row.component_ref}: #{reason}"
                )

                [
                  %{component_ref: row.component_ref, error: :corrupt_policy, reason: reason}
                  | acc
                ]
            end
          end)
          |> Enum.reverse()

        {:ok, db_policies}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update a single policy field for a component.

  Used by CLI commands like `cyfr policy set <ref> <key> <value>`.
  """
  @spec update_field(Context.t(), String.t(), String.t(), term()) :: :ok | {:error, term()}
  def update_field(%Context{} = ctx, component_ref, field, value) when is_binary(component_ref) do
    with {:ok, normalized_ref} <- normalize_component_ref(component_ref),
         {:ok, parsed} <- Sanctum.ComponentRef.parse(normalized_ref),
         {:ok, setup_policy} <- fetch_setup_policy_for_type(ctx, normalized_ref, parsed.type),
         :ok <- FieldSchema.validate_field(field, setup_policy) do
      # Get existing policy or create new one
      existing =
        case get(ctx, component_ref) do
          {:ok, policy} -> policy_to_map(policy)
          {:error, :not_found} -> %{}
        end

      # Update the field
      updated = update_policy_field(existing, field, value)

      # Save back
      put(ctx, component_ref, updated)
    end
  end

  # ============================================================================
  # Type Default CRUD
  # ============================================================================

  @doc """
  Returns the well-known ref for a type default policy.
  """
  def type_default_ref(type) when type in [:catalyst, :formula, :reagent, :tincture] do
    "#{@type_default_prefix}:#{type}"
  end

  @doc """
  Get the stored type default policy for a component type.

  Returns `{:ok, policy}` or `{:error, :not_found}`.
  """
  def get_type_default(%Context{} = ctx, type) when type in [:catalyst, :formula, :reagent, :tincture] do
    ref = type_default_ref(type)

    case Arca.PolicyStorage.get_policy(ctx, ref) do
      {:ok, row} when is_map(row) ->
        case row_to_policy(row) do
          {:ok, policy} -> {:ok, policy}
          {:error, reason} -> {:error, {:corrupt_policy, reason}}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:store_error, reason}}
    end
  end

  @doc """
  Persist a custom type default policy.
  """
  def put_type_default(%Context{} = ctx, type, %Policy{} = policy)
      when type in [:catalyst, :formula, :reagent, :tincture] do
    put_type_default(ctx, type, policy_to_map(policy))
  end

  def put_type_default(%Context{} = ctx, type, policy_map)
      when type in [:catalyst, :formula, :reagent, :tincture] and is_map(policy_map) do
    with :ok <- validate_restricted_tools(Atom.to_string(type), policy_map),
         :ok <-
           Sanctum.Policy.Ceiling.validate(
             policy_map,
             Sanctum.Policy.Ceiling.effective_ceiling(ctx)
           ),
         {:ok, window_seconds} <- get_rate_limit_window_seconds(policy_map),
         {:ok, encoded} <- encode_policy_json_fields(policy_map) do
      ref = type_default_ref(type)
      now = DateTime.utc_now()

      attrs = %{
        id: generate_id(ref),
        component_ref: ref,
        component_type: Atom.to_string(type),
        allowed_domains: encoded.allowed_domains,
        allowed_methods: encoded.allowed_methods,
        rate_limit_requests: get_rate_limit_requests(policy_map),
        rate_limit_window_seconds: window_seconds,
        timeout: Map.get(policy_map, :timeout, "30s"),
        max_memory_bytes: Map.get(policy_map, :max_memory_bytes, 64 * 1024 * 1024),
        max_request_size: Map.get(policy_map, :max_request_size, 0),
        max_response_size: Map.get(policy_map, :max_response_size, 0),
        allowed_tools: encoded.allowed_tools,
        allowed_paths: encoded.allowed_paths,
        allowed_actions: encoded.allowed_actions,
        batch_timeout: Map.get(policy_map, :batch_timeout, "5m"),
        max_concurrent_tasks: Map.get(policy_map, :max_concurrent_tasks, 10),
        allowed_private_ips: encoded.allowed_private_ips,
        is_public: Map.get(policy_map, :is_public, false) == true,
        inserted_at: DateTime.to_iso8601(now),
        updated_at: DateTime.to_iso8601(now)
      }

      case Arca.PolicyStorage.put_policy(ctx, attrs) do
        {:ok, _} ->
          Arca.Cache.invalidate({:policy, ref, ctx.org_id, ctx.project_id})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Delete a stored type default, reverting to hardcoded defaults.
  """
  def delete_type_default(%Context{} = ctx, type) when type in [:catalyst, :formula, :reagent, :tincture] do
    ref = type_default_ref(type)

    case Arca.PolicyStorage.delete_policy(ctx, ref) do
      :ok ->
        Arca.Cache.invalidate({:policy, ref, ctx.org_id, ctx.project_id})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all three type defaults with source indicator ("stored" vs "hardcoded").
  """
  def list_type_defaults(%Context{} = ctx) do
    defaults =
      Enum.map([:catalyst, :formula, :reagent, :tincture], fn type ->
        case get_type_default(ctx, type) do
          {:ok, policy} ->
            %{type: Atom.to_string(type), source: "stored", policy: policy}

          {:error, :not_found} ->
            %{type: Atom.to_string(type), source: "hardcoded", policy: Policy.default(type)}
        end
      end)

    {:ok, defaults}
  end

  # ============================================================================
  # Private: Database Operations (via Arca MCP)
  # ============================================================================

  defp row_to_policy(row) when is_map(row) do
    with {:ok, domains} <- decode_json_field(Map.get(row, :allowed_domains), []),
         {:ok, methods} <- decode_json_field(Map.get(row, :allowed_methods), []),
         {:ok, tools} <- decode_json_field(Map.get(row, :allowed_tools), []),
         {:ok, storage_paths} <- decode_json_field(Map.get(row, :allowed_paths), []),
         {:ok, actions} <- decode_json_field(Map.get(row, :allowed_actions), []),
         {:ok, private_ips} <- decode_json_field(Map.get(row, :allowed_private_ips), []) do
      {:ok,
       %Policy{
         allowed_domains: domains,
         allowed_methods: methods,
         rate_limit:
           build_rate_limit(
             Map.get(row, :rate_limit_requests),
             Map.get(row, :rate_limit_window_seconds)
           ),
         timeout: Map.get(row, :timeout) || "30s",
         max_memory_bytes: Map.get(row, :max_memory_bytes) || 64 * 1024 * 1024,
         max_request_size: Map.get(row, :max_request_size) || 1_048_576,
         max_response_size: Map.get(row, :max_response_size) || 5_242_880,
         allowed_tools: tools,
         allowed_paths: storage_paths,
         allowed_actions: actions,
         batch_timeout: Map.get(row, :batch_timeout) || "5m",
         max_concurrent_tasks: Map.get(row, :max_concurrent_tasks) || 10,
         allowed_private_ips: private_ips,
         is_public: Map.get(row, :is_public, false) in [true, 1, "true"]
       }}
    end
  end

  # ============================================================================
  # Private: Helpers
  # ============================================================================

  defp generate_id(component_ref) do
    hash =
      :crypto.hash(:sha256, component_ref) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    "pol_#{hash}"
  end

  defp encode_json_field(nil), do: {:ok, "[]"}

  defp encode_json_field(list) when is_list(list) do
    case Jason.encode(list) do
      {:ok, json} -> {:ok, json}
      {:error, err} -> {:error, {:encode_failed, err}}
    end
  end

  defp encode_json_field(value) do
    case Jason.encode([value]) do
      {:ok, json} -> {:ok, json}
      {:error, err} -> {:error, {:encode_failed, err}}
    end
  end

  @json_policy_fields [
    {:allowed_domains, :allowed_domains},
    {:allowed_methods, :allowed_methods},
    {:allowed_tools, :allowed_tools},
    {:allowed_paths, :allowed_paths},
    {:allowed_actions, :allowed_actions},
    {:allowed_private_ips, :allowed_private_ips}
  ]

  defp encode_policy_json_fields(policy_map) do
    Enum.reduce_while(@json_policy_fields, {:ok, %{}}, fn {map_key, attr_key}, {:ok, acc} ->
      value = Map.get(policy_map, map_key, [])

      case encode_json_field(value) do
        {:ok, json} ->
          {:cont, {:ok, Map.put(acc, attr_key, json)}}

        {:error, {:encode_failed, reason}} ->
          {:halt, {:error, {:encode_failed, attr_key, reason}}}
      end
    end)
  end

  defp decode_json_field(nil, default), do: {:ok, default}

  defp decode_json_field(json, _default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "Invalid JSON field: expected a list, got: #{json}"}
      {:error, _} -> {:error, "Invalid JSON in policy field: #{json}"}
    end
  end

  defp decode_json_field(other, _default),
    do: {:error, "Invalid policy field value: #{inspect(other)}"}

  defp get_rate_limit_requests(%{rate_limit: %{requests: r}}), do: r
  defp get_rate_limit_requests(_), do: nil

  defp get_rate_limit_window_seconds(%{rate_limit: %{window: w}}) when is_binary(w) do
    parse_window_to_seconds(w)
  end

  defp get_rate_limit_window_seconds(_), do: {:ok, nil}

  defp parse_window_to_seconds(window) do
    result =
      cond do
        String.ends_with?(window, "s") ->
          parse_window_int(window, "s", 1)

        String.ends_with?(window, "m") ->
          parse_window_int(window, "m", 60)

        String.ends_with?(window, "h") ->
          parse_window_int(window, "h", 3600)

        true ->
          {:error, "Invalid window '#{window}'. Expected format: 30s, 5m, or 1h"}
      end

    case result do
      {:ok, seconds} -> {:ok, seconds}
      {:error, _} = err -> err
    end
  end

  defp parse_window_int(str, suffix, multiplier) do
    raw = String.trim_trailing(str, suffix)

    case Integer.parse(raw) do
      {n, ""} -> {:ok, n * multiplier}
      _ -> {:error, "Invalid window '#{str}'. Expected format: 30s, 5m, or 1h"}
    end
  end

  defp build_rate_limit(nil, _), do: nil
  defp build_rate_limit(_, nil), do: nil

  defp build_rate_limit(requests, window_seconds) do
    %{
      requests: requests,
      window: format_window(window_seconds)
    }
  end

  defp format_window(seconds) when seconds >= 3600 and rem(seconds, 3600) == 0 do
    "#{div(seconds, 3600)}h"
  end

  defp format_window(seconds) when seconds >= 60 and rem(seconds, 60) == 0 do
    "#{div(seconds, 60)}m"
  end

  defp format_window(seconds), do: "#{seconds}s"

  @doc """
  Convert a Policy struct to a map suitable for `put/3`.

  Preserves all fields so callers can merge targeted updates without
  losing existing values (e.g., toggling `is_public` without resetting
  `rate_limit`).
  """
  def policy_to_update_map(%Policy{} = policy), do: policy_to_map(policy)

  defp policy_to_map(%Policy{} = policy) do
    %{
      allowed_domains: policy.allowed_domains,
      allowed_methods: Map.get(policy, :allowed_methods, []),
      rate_limit: policy.rate_limit,
      timeout: policy.timeout,
      max_memory_bytes: policy.max_memory_bytes,
      max_request_size: policy.max_request_size,
      max_response_size: policy.max_response_size,
      allowed_tools: policy.allowed_tools,
      allowed_paths: policy.allowed_paths,
      allowed_actions: policy.allowed_actions,
      batch_timeout: policy.batch_timeout,
      max_concurrent_tasks: policy.max_concurrent_tasks,
      allowed_private_ips: policy.allowed_private_ips,
      is_public: policy.is_public
    }
  end

  @field_config %{
    "allowed_domains" => {:allowed_domains, :json_list},
    "allowed_methods" => {:allowed_methods, :json_list},
    "rate_limit" => {:rate_limit, :rate_limit},
    "timeout" => {:timeout, :string},
    "max_memory_bytes" => {:max_memory_bytes, {:integer, 64 * 1024 * 1024}},
    "allowed_tools" => {:allowed_tools, :json_list},
    "allowed_paths" => {:allowed_paths, :json_list},
    "allowed_actions" => {:allowed_actions, :json_list},
    "batch_timeout" => {:batch_timeout, :string},
    "max_concurrent_tasks" => {:max_concurrent_tasks, {:integer, 10}},
    "allowed_private_ips" => {:allowed_private_ips, :json_list},
    "is_public" => {:is_public, :boolean}
  }

  defp update_policy_field(policy_map, field, value) do
    case Map.get(@field_config, field) do
      {key, :json_list} ->
        Map.put(policy_map, key, parse_json_value(value, []))

      {key, :string} ->
        Map.put(policy_map, key, value)

      {key, {:integer, default}} ->
        Map.put(policy_map, key, parse_int(value, default))

      {key, :rate_limit} ->
        Map.put(policy_map, key, parse_rate_limit_value(value))

      {key, :boolean} ->
        Map.put(policy_map, key, value == true or value == "true")

      nil ->
        case Sanctum.Atoms.safe_to_atom(field) do
          atom when is_atom(atom) -> Map.put(policy_map, atom, value)
          _string -> policy_map
        end
    end
  end

  defp parse_json_value(value, _default) when is_list(value), do: value

  defp parse_json_value(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> default
    end
  end

  defp parse_json_value(_, default), do: default

  defp parse_rate_limit_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"requests" => r, "window" => w}} -> %{requests: r, window: w}
      _ -> nil
    end
  end

  defp parse_rate_limit_value(_), do: nil

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(value, _) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  @doc """
  Get a name-level policy (stored as type:namespace.name without version).

  Returns `{:ok, policy}` or `{:error, :not_found}`.
  """
  @spec get_name_level(Context.t(), String.t()) ::
          {:ok, Policy.t()} | {:error, :not_found | term()}
  def get_name_level(%Context{} = ctx, name_ref) when is_binary(name_ref) do
    case Arca.PolicyStorage.get_policy(ctx, name_ref) do
      {:ok, row} when is_map(row) ->
        case row_to_policy(row) do
          {:ok, policy} -> {:ok, policy}
          {:error, reason} -> {:error, {:corrupt_policy, reason}}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:store_error, reason}}
    end
  end

  defp normalize_component_ref(ref) do
    Sanctum.ComponentRef.normalize_or_name_ref(ref)
  end

  # Tinctures don't require component registration for policy creation.
  # Their configurable fields (rate_limit, timeout, is_public) are static
  # and don't depend on manifest setup.policy declarations.
  defp fetch_setup_policy_for_type(_ctx, _ref, "tincture"), do: {:ok, %{}}

  defp fetch_setup_policy_for_type(ctx, component_ref, _type),
    do: fetch_manifest_setup_policy(ctx, component_ref)

  defp fetch_manifest_setup_policy(%Context{} = ctx, component_ref) do
    with {:ok, ref} <- Sanctum.ComponentRef.parse(component_ref) do
      name = ref.name
      version = ref.version
      type = ref.type

      # For both name-level and versioned refs, resolve to the appropriate
      # component and validate against its manifest's setup.policy.
      # Name-level refs validate against the latest version's manifest.
      result =
        if version != nil do
          Compendium.Registry.get(ctx, name, version, nil, type)
        else
          Compendium.Registry.get_latest(ctx, name, nil, type)
        end

      case result do
        {:ok, component} ->
          extract_setup_policy(component)

        {:error, :not_found} ->
          {:error,
           "Component not found: #{component_ref}. Component must be registered before policy can be configured."}

        {:error, reason} ->
          {:error, "Failed to fetch component manifest: #{inspect(reason)}"}
      end
    end
  end

  defp extract_setup_policy(component) do
    manifest_raw = component[:manifest] || component["manifest"]
    manifest = Compendium.Manifest.decode(manifest_raw)
    setup = manifest["setup"] || %{}

    {:ok, setup["policy"] || %{}}
  end

  defdelegate decode_manifest(value), to: Compendium.Manifest, as: :decode

  defp validate_restricted_tools("formula", policy_map) do
    tools =
      case Map.get(policy_map, :allowed_tools) || Map.get(policy_map, "allowed_tools") do
        nil -> []
        tools when is_list(tools) -> tools
        tool when is_binary(tool) -> [tool]
      end

    case Sanctum.Policy.RestrictedTools.validate_allowed_tools(:formula, tools) do
      :ok ->
        :ok

      {:error, violations} ->
        tool_list =
          violations
          |> Enum.map(fn {tool, _pattern} -> tool end)
          |> Enum.uniq()
          |> Enum.join(", ")

        {:error, "Formula policies cannot include restricted tools: #{tool_list}"}
    end
  end

  defp validate_restricted_tools(_component_type, _policy_map), do: :ok

  defp validate_component_type(type) when is_atom(type) do
    validate_component_type(Atom.to_string(type))
  end

  defp validate_component_type(type) when type in ["catalyst", "reagent", "formula", "tincture"] do
    {:ok, type}
  end

  defp validate_component_type(invalid) do
    {:error,
     "Invalid component type '#{inspect(invalid)}'. Must be one of: catalyst, reagent, formula, tincture"}
  end
end
