defmodule Sanctum.Policy.FieldSchema do
  @moduledoc """
  Manifest-driven policy field validation.

  Derives which policy fields are configurable from a component's manifest
  `setup.policy` section. Universal runtime fields (timeout, memory limits, etc.)
  are always configurable. Capability-specific fields (allowed_domains, allowed_paths,
  etc.) are only configurable when declared in the manifest's `setup.policy` keys.
  """

  @universal_fields ~w(timeout max_memory_bytes max_request_size max_response_size rate_limit)

  @all_capability_fields ~w(allowed_domains allowed_methods allowed_private_ips
                            allowed_paths allowed_actions
                            allowed_tools batch_timeout max_concurrent_tasks)

  @doc """
  Returns the list of universal fields (always configurable).
  """
  def universal_fields, do: @universal_fields

  @doc """
  Returns the list of all known capability fields.
  """
  def all_capability_fields, do: @all_capability_fields

  @doc """
  Derives configurable fields from manifest `setup.policy` keys.

  Universal fields are always included. Capability fields are included only
  when their key appears in the `setup_policy` map.

  Returns `{:error, reason}` when `setup_policy` is nil (manifest required).
  """
  @spec configurable_fields(map() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def configurable_fields(nil) do
    {:error, "Component manifest with setup.policy is required before policy can be configured"}
  end

  def configurable_fields(setup_policy) when is_map(setup_policy) do
    policy_keys = Map.keys(setup_policy) |> Enum.map(&to_string/1)

    capability =
      @all_capability_fields
      |> Enum.filter(fn field -> field in policy_keys end)

    {:ok, @universal_fields ++ capability}
  end

  @doc """
  Validates that a policy map only sets applicable fields.

  Returns `:ok` or `{:error, reason}` describing which fields are not configurable.
  """
  @spec validate_fields(map(), map() | nil) :: :ok | {:error, String.t()}
  def validate_fields(_policy_map, nil) do
    {:error, "Component manifest with setup.policy is required before policy can be configured"}
  end

  def validate_fields(policy_map, setup_policy) when is_map(setup_policy) do
    {:ok, allowed} = configurable_fields(setup_policy)

    # Only check capability fields that were explicitly set to non-default values.
    # Default struct values (empty lists, default scalars) are ignored.
    invalid =
      policy_map
      |> Enum.filter(fn {k, v} -> explicitly_set?(k, v) end)
      |> Enum.map(fn {k, _v} -> to_string(k) end)
      |> Enum.filter(fn key -> key in @all_capability_fields and key not in allowed end)

    case invalid do
      [] -> :ok
      fields ->
        field_list = Enum.join(fields, ", ")
        declared = Map.keys(setup_policy) |> Enum.map(&to_string/1) |> Enum.join(", ")
        {:error, "Field(s) #{field_list} not configurable for this component. Manifest setup.policy declares: #{declared}"}
    end
  end

  # Default values from the Policy struct that should not trigger validation
  @capability_defaults %{
    allowed_domains: [],
    allowed_methods: [],
    allowed_tools: [],
    allowed_paths: [],
    allowed_actions: [],
    allowed_private_ips: [],
    batch_timeout: "5m",
    max_concurrent_tasks: 10
  }

  defp explicitly_set?(_key, nil), do: false

  defp explicitly_set?(key, value) do
    atom_key = if is_atom(key), do: key, else: String.to_existing_atom(key)
    default = Map.get(@capability_defaults, atom_key)
    value != default
  rescue
    ArgumentError -> value not in [nil, [], 0]
  end

  @doc """
  Validates a single field name against the manifest's `setup.policy`.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_field(String.t(), map() | nil) :: :ok | {:error, String.t()}
  def validate_field(_field_name, nil) do
    {:error, "Component manifest with setup.policy is required before policy can be configured"}
  end

  def validate_field(field_name, setup_policy) when is_map(setup_policy) do
    field = to_string(field_name)

    cond do
      field in @universal_fields ->
        :ok

      field not in @all_capability_fields ->
        # Unknown field — let it through (might be a custom/future field)
        :ok

      true ->
        # It's a known capability field — check if declared in setup.policy
        policy_keys = Map.keys(setup_policy) |> Enum.map(&to_string/1)

        if field in policy_keys do
          :ok
        else
          declared = Enum.join(policy_keys, ", ")
          {:error, "Field '#{field}' is not configurable for this component. Manifest setup.policy declares: #{declared}"}
        end
    end
  end
end
