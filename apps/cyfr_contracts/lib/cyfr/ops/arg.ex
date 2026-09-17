# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Arg do
  @moduledoc """
  An operation argument's type, presence and value constraints.

  Records reject unknown keys. Maps explicitly permit arbitrary string
  keys and validate every value; JSON explicitly permits any JSON value.
  Casting normalizes mathematically integral floats to integers only for
  integer declarations, including nested fields. It performs no string or
  boolean coercion and inserts no defaults: omission, null, false, zero and
  empty values remain distinct. Defaults are discovery hints for
  domain-owned behavior.

  Bounds measure numeric value, Unicode code points for strings, array
  items or object properties, matching the generated JSON Schema.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :description,
    :enum,
    :min,
    :max,
    :pattern,
    required: false,
    nullable: false,
    default: :unset
  ]

  @type value_type ::
          :string
          | :integer
          | :number
          | :boolean
          | :json
          | {:array, t()}
          | {:record, [t()]}
          | {:map, t()}
  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: value_type(),
          description: String.t() | nil,
          required: boolean(),
          nullable: boolean(),
          enum: [term()] | nil,
          min: number() | nil,
          max: number() | nil,
          pattern: String.t() | nil,
          default: term()
        }

  @doc "Declare an argument; nil names an array item or map value. Invalid declarations raise."
  @spec new(String.t() | nil, value_type(), keyword()) :: t()
  def new(name, type, opts \\ []) do
    arg = struct!(__MODULE__, Keyword.merge(opts, name: name, type: type))
    validate_declaration!(arg)
    arg
  end

  @doc "Change whether an existing field must be present, preserving its value contract."
  @spec required(t(), boolean()) :: t()
  def required(%__MODULE__{} = arg, required \\ true) when is_boolean(required),
    do: %{arg | required: required}

  @doc "Validate a closed object and normalize declared integers, or return a safe error."
  @spec cast([t()], term()) :: {:ok, map()} | {:error, String.t()}
  def cast(args, input) do
    case cast_record(args, input, "") do
      {:ok, values} -> {:ok, normalize_record(args, values)}
      error -> error
    end
  end

  defp normalize_record(args, values) do
    Enum.reduce(args, values, fn arg, values ->
      case Map.fetch(values, arg.name) do
        {:ok, value} -> Map.put(values, arg.name, normalize_value(arg, value))
        :error -> values
      end
    end)
  end

  defp normalize_value(_arg, nil), do: nil
  defp normalize_value(%{type: :integer}, value) when is_float(value), do: trunc(value)
  defp normalize_value(%{type: {:record, fields}}, value), do: normalize_record(fields, value)

  defp normalize_value(%{type: {:array, item}}, value),
    do: Enum.map(value, &normalize_value(item, &1))

  defp normalize_value(%{type: {:map, item}}, value),
    do: Map.new(value, fn {key, value} -> {key, normalize_value(item, value)} end)

  defp normalize_value(_arg, value), do: value

  @doc "The closed object schema derived from these declarations."
  @spec schema([t()]) :: map()
  def schema(args) do
    validate_fields!(args)

    %{
      "type" => "object",
      "properties" => Map.new(args, &{&1.name, value_schema(&1)}),
      "required" => for(arg <- args, arg.required, do: arg.name),
      "additionalProperties" => false
    }
  end

  @doc "The schema of one value, including its recursive constraints."
  @spec value_schema(t()) :: map()
  def value_schema(%__MODULE__{} = arg) do
    schema = type_schema(arg.type)

    schema =
      if arg.nullable and Map.has_key?(schema, "type"),
        do: Map.update!(schema, "type", &[&1, "null"]),
        else: schema

    schema
    |> present("description", arg.description)
    |> present("enum", enum_values(arg))
    |> present("pattern", arg.pattern)
    |> put_bounds(arg)
    |> then(fn schema ->
      if arg.default == :unset, do: schema, else: Map.put(schema, "default", arg.default)
    end)
  end

  defp type_schema(type) when type in [:string, :integer, :number, :boolean],
    do: %{"type" => Atom.to_string(type)}

  defp type_schema(:json), do: %{}
  defp type_schema({:array, item}), do: %{"type" => "array", "items" => value_schema(item)}
  defp type_schema({:record, fields}), do: schema(fields)

  defp type_schema({:map, item}),
    do: %{"type" => "object", "additionalProperties" => value_schema(item)}

  defp enum_values(%{enum: nil}), do: nil
  defp enum_values(%{enum: values, nullable: true}), do: Enum.uniq(values ++ [nil])
  defp enum_values(%{enum: values}), do: values

  defp put_bounds(schema, %{type: type, min: min, max: max}) do
    {low, high} =
      case type do
        :string -> {"minLength", "maxLength"}
        {:array, _} -> {"minItems", "maxItems"}
        {object, _} when object in [:record, :map] -> {"minProperties", "maxProperties"}
        _ -> {"minimum", "maximum"}
      end

    schema |> present(low, min) |> present(high, max)
  end

  defp present(map, _key, nil), do: map
  defp present(map, key, value), do: Map.put(map, key, value)

  defp cast_record(args, input, parent) when is_map(input) do
    names = Enum.map(args, & &1.name)
    unknown = Map.keys(input) -- names

    if unknown != [] do
      {:error, "Unknown field: " <> field(parent, bounded_key(hd(unknown)))}
    else
      Enum.reduce_while(args, {:ok, input}, fn arg, result ->
        path = field(parent, arg.name)

        error =
          case Map.fetch(input, arg.name) do
            :error -> if arg.required, do: "Missing required field: #{path}"
            {:ok, value} -> value_error(arg, value, path)
          end

        if error, do: {:halt, {:error, error}}, else: {:cont, result}
      end)
    end
  end

  defp cast_record(_args, _input, path),
    do: {:error, "Field '#{path_name(path)}' must be an object"}

  defp value_error(arg, value, path) do
    type_error(arg, value, path) || enum_error(arg, value, path) || bounds_error(arg, value, path) ||
      pattern_error(arg, value, path)
  end

  defp type_error(%{nullable: true}, nil, _path), do: nil

  defp type_error(%{type: :string}, value, path),
    do: unless(is_binary(value) and String.valid?(value), do: "Field '#{path}' must be a string")

  defp type_error(%{type: :integer}, value, path),
    do: unless(integer_value?(value), do: "Field '#{path}' must be an integer")

  defp type_error(%{type: :number}, value, path),
    do: unless(is_number(value), do: "Field '#{path}' must be a number")

  defp type_error(%{type: :boolean}, value, path),
    do: unless(is_boolean(value), do: "Field '#{path}' must be a boolean")

  defp type_error(%{type: :json}, value, path),
    do: unless(json?(value), do: "Field '#{path}' must contain JSON values")

  defp type_error(%{type: {:array, item}}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} -> value_error(item, value, "#{path}[#{index}]") end)
  end

  defp type_error(%{type: {:array, _}}, _value, path), do: "Field '#{path}' must be an array"

  defp type_error(%{type: {:record, fields}}, value, path) do
    case cast_record(fields, value, path) do
      {:ok, _} -> nil
      {:error, error} -> error
    end
  end

  defp type_error(%{type: {:map, item}}, value, path) when is_map(value) do
    if Enum.all?(Map.keys(value), &(is_binary(&1) and String.valid?(&1))) do
      Enum.find_value(value, fn {key, value} ->
        value_error(item, value, field(path, bounded_key(key)))
      end)
    else
      "Field '#{path}' must have string keys"
    end
  end

  defp type_error(%{type: {:map, _}}, _value, path), do: "Field '#{path}' must be an object"

  defp enum_error(%{nullable: true}, nil, _path), do: nil
  defp enum_error(%{enum: nil}, _value, _path), do: nil

  defp enum_error(%{enum: values}, value, path),
    do: unless(Enum.any?(values, &(&1 == value)), do: "Field '#{path}' is not an allowed value")

  defp bounds_error(_arg, nil, _path), do: nil

  defp bounds_error(%{min: min, max: max}, value, path) do
    size =
      cond do
        is_number(value) -> value
        is_binary(value) -> length(String.codepoints(value))
        is_list(value) -> length(value)
        is_map(value) -> map_size(value)
        true -> nil
      end

    cond do
      min != nil and size < min -> "Field '#{path}' must be at least #{min}"
      max != nil and size > max -> "Field '#{path}' must be at most #{max}"
      true -> nil
    end
  end

  defp pattern_error(%{pattern: nil}, _value, _path), do: nil

  defp pattern_error(%{pattern: pattern}, value, path) when is_binary(value),
    do:
      unless(Regex.match?(Regex.compile!(pattern), value),
        do: "Field '#{path}' does not match the required pattern"
      )

  defp pattern_error(_arg, _value, _path), do: nil

  defp integer_value?(value) when is_integer(value), do: true
  defp integer_value?(value) when is_float(value), do: value == trunc(value)
  defp integer_value?(_value), do: false

  defp json?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, value} ->
        is_binary(key) and String.valid?(key) and json?(value)
      end)

  defp json?(_), do: false

  defp field("", name), do: name
  defp field(parent, name), do: parent <> "." <> name
  defp path_name(""), do: "arguments"
  defp path_name(path), do: path
  defp bounded_key(key) when is_binary(key), do: String.slice(key, 0, 128)
  defp bounded_key(_key), do: "<non-string key>"

  defp validate_fields!(fields) when is_list(fields) do
    names =
      Enum.map(fields, fn %__MODULE__{} = arg ->
        validate_declaration!(arg)
        arg.name
      end)

    unless Enum.all?(names, &(is_binary(&1) and &1 != "")) and
             length(names) == length(Enum.uniq(names)),
           do: raise(ArgumentError, "record fields must have unique non-empty names")

    :ok
  end

  defp validate_declaration!(%__MODULE__{} = arg) do
    unless (is_nil(arg.name) or (is_binary(arg.name) and arg.name != "")) and
             is_boolean(arg.required) and is_boolean(arg.nullable),
           do: raise(ArgumentError, "invalid argument declaration")

    unless is_nil(arg.description) or is_binary(arg.description),
      do: raise(ArgumentError, "description must be a string")

    validate_type!(arg.type)

    if arg.enum != nil and (not is_list(arg.enum) or arg.enum == []),
      do: raise(ArgumentError, "enum must be non-empty")

    if arg.enum != nil and not Enum.all?(arg.enum, &json?/1),
      do: raise(ArgumentError, "enum values must be JSON")

    if arg.default != :unset and not json?(arg.default),
      do: raise(ArgumentError, "default must be JSON")

    for bound <- [arg.min, arg.max], bound != nil do
      unless is_number(bound), do: raise(ArgumentError, "bounds must be numeric")

      if arg.type not in [:integer, :number] and (not is_integer(bound) or bound < 0),
        do: raise(ArgumentError, "size bounds must be non-negative integers")

      if arg.type in [:boolean, :json], do: raise(ArgumentError, "this type has no bounds")
    end

    if arg.min != nil and arg.max != nil and arg.min > arg.max,
      do: raise(ArgumentError, "minimum exceeds maximum")

    if arg.pattern != nil do
      unless arg.type == :string and is_binary(arg.pattern),
        do: raise(ArgumentError, "patterns require a string argument")

      case Regex.compile(arg.pattern) do
        {:ok, _} -> :ok
        {:error, _} -> raise ArgumentError, "invalid argument pattern"
      end
    end

    if arg.enum != nil do
      for value <- arg.enum do
        if value_error(%{arg | enum: nil}, value, arg.name || "value"),
          do: raise(ArgumentError, "enum value violates its argument declaration")
      end
    end

    if arg.default != :unset and value_error(arg, arg.default, arg.name || "value"),
      do: raise(ArgumentError, "default violates its argument declaration")

    if arg.default != :unset and normalize_value(arg, arg.default) !== arg.default,
      do: raise(ArgumentError, "integer defaults must use integer representation")

    :ok
  end

  defp validate_type!(type) when type in [:string, :integer, :number, :boolean, :json], do: :ok

  defp validate_type!({kind, %__MODULE__{} = item}) when kind in [:array, :map],
    do: validate_declaration!(item)

  defp validate_type!({:record, fields}), do: validate_fields!(fields)
  defp validate_type!(_), do: raise(ArgumentError, "unknown argument type")
end
