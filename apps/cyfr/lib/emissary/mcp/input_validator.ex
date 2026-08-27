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
  - String length bounds and `pattern` where the schema declares them
  - Nested objects, recursively — a `"type": "object"` property with its
    own `required`/`properties` is held to them

  Not a full JSON Schema implementation by design: `oneOf`/`allOf`,
  array `items`, numeric ranges and format keywords are not enforced —
  no tool schema in the tree relies on them for safety.
  """

  @doc """
  Validate arguments against a tool's input_schema.

  Returns `:ok` if valid, or `{:error, message}` with a human-readable
  description of the first validation failure.
  """
  @spec validate(term(), term()) :: :ok | {:error, String.t()}
  def validate(arguments, input_schema) when is_map(arguments) and is_map(input_schema) do
    with :ok <- validate_required(arguments, input_schema),
         :ok <- validate_properties(arguments, input_schema) do
      :ok
    end
  end

  # `arguments` must be a JSON object. Letting a list or scalar through here is
  # not harmless: the dispatcher immediately reads `arguments["action"]`, and
  # Access raises on a list, killing the request with a 500 instead of returning
  # a JSON-RPC error.
  def validate(arguments, _input_schema) when not is_map(arguments) do
    {:error, "Invalid params: arguments must be an object, got #{type_name(arguments)}"}
  end

  # A tool with no usable schema still gets its arguments shape-checked above.
  def validate(_arguments, _input_schema), do: :ok

  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "value"

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
      validate_string_constraints(key, value, prop_schema)
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

  defp validate_type(key, value, %{"type" => "object"} = prop_schema) do
    if is_map(value) do
      # Recurse: a nested object's own required/properties bind too.
      validate(value, prop_schema)
    else
      {:error, "Field '#{key}' must be an object"}
    end
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

  # Declared string bounds and pattern. An invalid pattern is the schema
  # author's bug — it is skipped rather than failing every request.
  defp validate_string_constraints(key, value, prop_schema) when is_binary(value) do
    min = prop_schema["minLength"]
    max = prop_schema["maxLength"]
    length = String.length(value)

    cond do
      is_integer(min) and length < min ->
        {:error, "Field '#{key}' must be at least #{min} characters"}

      is_integer(max) and length > max ->
        {:error, "Field '#{key}' must be at most #{max} characters"}

      is_binary(prop_schema["pattern"]) ->
        case Regex.compile(prop_schema["pattern"]) do
          {:ok, regex} ->
            if Regex.match?(regex, value),
              do: :ok,
              else: {:error, "Field '#{key}' does not match the required pattern"}

          _ ->
            :ok
        end

      true ->
        :ok
    end
  end

  defp validate_string_constraints(_key, _value, _prop_schema), do: :ok
end
