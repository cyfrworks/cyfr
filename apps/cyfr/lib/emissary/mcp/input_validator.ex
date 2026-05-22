# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.InputValidator do
  @moduledoc """
  Validates MCP tool call arguments against the tool's declared JSON Schema.

  Performs server-side validation of required fields, enum constraints,
  and basic type checks before arguments reach tool handlers. This prevents
  malformed or malicious inputs from reaching business logic.

  Only validates constraints that are cheap to check and security-relevant:
  - Required fields
  - Enum values (prevents injection of unexpected actions)
  - Basic type conformance (string, integer, number, boolean, object, array)
  """

  @doc """
  Validate arguments against a tool's input_schema.

  Returns `:ok` if valid, or `{:error, message}` with a human-readable
  description of the first validation failure.
  """
  @spec validate(map(), map()) :: :ok | {:error, String.t()}
  def validate(arguments, input_schema) when is_map(arguments) and is_map(input_schema) do
    with :ok <- validate_required(arguments, input_schema),
         :ok <- validate_properties(arguments, input_schema) do
      :ok
    end
  end

  def validate(_arguments, _input_schema), do: :ok

  # Check that all required fields are present
  defp validate_required(arguments, schema) do
    required = Map.get(schema, "required", [])

    case Enum.find(required, fn field -> not Map.has_key?(arguments, field) end) do
      nil -> :ok
      field -> {:error, "Missing required field: #{field}"}
    end
  end

  # Validate each provided argument against its property schema
  defp validate_properties(arguments, schema) do
    properties = Map.get(schema, "properties", %{})

    Enum.reduce_while(arguments, :ok, fn {key, value}, :ok ->
      case Map.get(properties, key) do
        nil ->
          # Unknown property — allow (tools may accept extra args)
          {:cont, :ok}

        prop_schema ->
          case validate_value(key, value, prop_schema) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  # Validate a single value against its property schema
  defp validate_value(key, value, prop_schema) do
    with :ok <- validate_type(key, value, prop_schema),
         :ok <- validate_enum(key, value, prop_schema) do
      :ok
    end
  end

  # Type validation
  defp validate_type(_key, _value, %{"type" => nil}), do: :ok

  defp validate_type(key, value, %{"type" => "string"}) do
    if is_binary(value), do: :ok, else: {:error, "Field '#{key}' must be a string"}
  end

  defp validate_type(key, value, %{"type" => "integer"}) do
    if is_integer(value), do: :ok, else: {:error, "Field '#{key}' must be an integer"}
  end

  defp validate_type(key, value, %{"type" => "number"}) do
    if is_number(value), do: :ok, else: {:error, "Field '#{key}' must be a number"}
  end

  defp validate_type(key, value, %{"type" => "boolean"}) do
    if is_boolean(value), do: :ok, else: {:error, "Field '#{key}' must be a boolean"}
  end

  defp validate_type(key, value, %{"type" => "object"}) do
    if is_map(value), do: :ok, else: {:error, "Field '#{key}' must be an object"}
  end

  defp validate_type(key, value, %{"type" => "array"}) do
    if is_list(value), do: :ok, else: {:error, "Field '#{key}' must be an array"}
  end

  defp validate_type(_key, _value, _schema), do: :ok

  # Enum validation — critical for preventing injection of unexpected actions
  defp validate_enum(key, value, %{"enum" => allowed}) when is_list(allowed) do
    if value in allowed do
      :ok
    else
      {:error, "Field '#{key}' must be one of: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp validate_enum(_key, _value, _schema), do: :ok
end