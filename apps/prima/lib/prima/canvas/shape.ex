# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Canvas.Shape do
  @moduledoc """
  The type of a value a canvas reads: a stream's payload, a feed's result.
  A shape is a JSON object with `type` and that type's keys, plus
  `nullable` on any type, and no other key.

    * `string` — `max` code points, 1 to 4096, default 256;
    * `number` — any JSON number;
    * `integer` — a JSON integer; a float, `1.0` included, is refused;
    * `boolean`;
    * `time` — a string `DateTime.from_iso8601/1` accepts, offset included;
    * `enum` — `values`, 1 to 64 distinct strings of 1 to 256 code points;
    * `list` — `of` (a shape) and `max` elements, 1 to 1000, default 100;
    * `object` — `fields`, 0 to 64 names (`name?/1`) each mapped to a
      shape, and `required`, distinct names of `fields`, default `[]`. A
      key `fields` does not name is refused, a required field absent is
      refused, and an optional field may be absent;
    * `json` — any JSON value, bounded only by its container's bound.

  `nullable` (default false) admits `null` at that node and nowhere else:
  a present `null` in an object's field is refused unless that field's
  shape is nullable. The top shape is depth 1, each `of` and each `fields`
  value one deeper, and a shape deeper than 8 is refused.

  `validate/1` answers the normalized shape, every default written and
  `required` sorted, and `encode/1` and `digest/1` are its `Prima.JCS`
  bytes and their digest, so two spellings of one shape hash alike. `check/2` holds a value to a
  validated shape and `fixture/1` answers a value it passes. A refusal of
  either is `%{path, reason}`: `path` an RFC 6901 pointer (`""` the root,
  then `/field` or `/3`, with `~` and `/` escaped) into the shape for
  `validate/1` and into the value for `check/2`, and `reason` one of
  `reasons/0`. A node is checked before its children, an object's keys in
  sorted order and a list's elements in order, so the refusal is the first
  failing path.

  `tests/fixtures/canvas_shape.json` holds valid and refused shapes, values
  and `results` blocks.
  """

  @types ~w(string number integer boolean time enum list object json)

  # The keys each type takes beside `type` and `nullable`.
  @type_keys %{
    "string" => ~w(max),
    "number" => [],
    "integer" => [],
    "boolean" => [],
    "time" => [],
    "enum" => ~w(values),
    "list" => ~w(of max),
    "object" => ~w(fields required),
    "json" => []
  }

  @max_depth 8
  @string_max 4096
  @string_default 256
  @list_max 1000
  @list_default 100
  @enum_max 64
  @enum_value_max 256
  @fields_max 64
  @name_max 64

  @control ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u

  # The one vocabulary of refusal reasons, for shapes and values alike.
  @reasons %{
    "type" => "a value of another JSON type than its position takes",
    "null" => "null where the shape is not nullable",
    "max" => "a string or list longer than its max",
    "enum" => "a value none of the values its position admits",
    "time" => "a string DateTime.from_iso8601/1 refuses",
    "unknown_field" => "an object key its fields do not name",
    "required" => "a required field or key absent",
    "unknown_type" => "a shape whose type is none of the types",
    "unknown_key" => "a key its object does not take",
    "range" => "a bound or count outside its range",
    "name" => "a name outside its grammar",
    "duplicate" => "a value repeated where values are distinct",
    "depth" => "a shape deeper than its limit"
  }

  @fixture_time "1970-01-01T00:00:00Z"

  @typedoc "A normalized shape: string-keyed JSON, every default written."
  @type t :: %{required(String.t()) => term()}

  @typedoc "An RFC 6901 pointer."
  @type path :: String.t()

  @typedoc "A refusal: where and why."
  @type refusal :: %{path: path(), reason: String.t()}

  @doc "The types a shape may name."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The refusal reasons `validate/1` and `check/2` answer, each with what it means."
  @spec reasons() :: %{String.t() => String.t()}
  def reasons, do: @reasons

  @doc "The deepest a shape may nest."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Whether `name` is an object field's name: 1 to #{@name_max} code points
  with no control character. A `results` key and a feed's operation
  follow the same rule.
  """
  @spec name?(term()) :: boolean()
  def name?(name) do
    is_binary(name) and String.valid?(name) and code_points(name) in 1..@name_max and
      not Regex.match?(@control, name)
  end

  @doc "`segment` escaped for an RFC 6901 pointer: `~` as `~0`, `/` as `~1`."
  @spec escape(String.t() | non_neg_integer()) :: String.t()
  def escape(index) when is_integer(index), do: Integer.to_string(index)

  def escape(segment) when is_binary(segment),
    do: segment |> String.replace("~", "~0") |> String.replace("/", "~1")

  @doc "Whether `value` is a decoded JSON value: string-keyed objects, lists and scalars."
  @spec json?(term()) :: boolean()
  def json?(value) when is_binary(value), do: String.valid?(value)
  def json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  def json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  def json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, member} -> is_binary(key) and json?(key) and json?(member) end)

  def json?(_value), do: false

  # ---- the shape -------------------------------------------------------------

  @doc """
  A decoded JSON shape held to the grammar, answered normalized: `nullable`
  on every node, `max` on `string` and `list`, `required` on `object`,
  sorted.
  `{:error, %{path, reason}}` names the first invalid node.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, refusal()}
  def validate(shape), do: node(shape, "", 1)

  defp node(_shape, path, depth) when depth > @max_depth, do: refuse(path, "depth")

  defp node(%{} = shape, path, depth) when not is_struct(shape) do
    type = Map.get(shape, "type")

    with :ok <- known_type(type, path),
         :ok <- known_keys(shape, ["type", "nullable" | Map.fetch!(@type_keys, type)], path),
         {:ok, nullable} <- nullable(Map.get(shape, "nullable", false), path),
         {:ok, keys} <- type_keys(type, shape, path, depth) do
      {:ok, Map.merge(keys, %{"type" => type, "nullable" => nullable})}
    end
  end

  defp node(_shape, path, _depth), do: refuse(path, "type")

  defp known_type(type, _path) when type in @types, do: :ok
  defp known_type(_type, path), do: refuse(path <> "/type", "unknown_type")

  defp known_keys(map, known, path) do
    case map |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse(path <> "/" <> escape(to_string(key)), "unknown_key")
    end
  end

  defp nullable(value, _path) when is_boolean(value), do: {:ok, value}
  defp nullable(_value, path), do: refuse(path <> "/nullable", "type")

  defp type_keys("string", shape, path, _depth) do
    with {:ok, max} <- bound(shape, "max", @string_default, @string_max, path),
         do: {:ok, %{"max" => max}}
  end

  defp type_keys("enum", shape, path, _depth) do
    with {:ok, values} <- enum_values(Map.fetch(shape, "values"), path <> "/values"),
         do: {:ok, %{"values" => values}}
  end

  defp type_keys("list", shape, path, depth) do
    with {:ok, max} <- bound(shape, "max", @list_default, @list_max, path),
         {:ok, of} <- required_key(shape, "of", path),
         {:ok, of} <- node(of, path <> "/of", depth + 1) do
      {:ok, %{"of" => of, "max" => max}}
    end
  end

  defp type_keys("object", shape, path, depth) do
    with {:ok, fields} <- required_key(shape, "fields", path),
         :ok <- field_names(fields, path <> "/fields"),
         {:ok, required} <- required(Map.get(shape, "required", []), fields, path <> "/required"),
         {:ok, fields} <- field_shapes(fields, path <> "/fields", depth) do
      {:ok, %{"fields" => fields, "required" => required}}
    end
  end

  defp type_keys(_scalar, _shape, _path, _depth), do: {:ok, %{}}

  defp bound(shape, key, default, ceiling, path) do
    case Map.get(shape, key, default) do
      n when is_integer(n) and n >= 1 and n <= ceiling -> {:ok, n}
      n when is_integer(n) -> refuse(path <> "/" <> key, "range")
      _other -> refuse(path <> "/" <> key, "type")
    end
  end

  defp required_key(shape, key, path) do
    case Map.fetch(shape, key) do
      {:ok, value} -> {:ok, value}
      :error -> refuse(path <> "/" <> key, "required")
    end
  end

  defp enum_values(:error, path), do: refuse(path, "required")

  defp enum_values({:ok, values}, path) when is_list(values) and length(values) in 1..@enum_max do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {value, index}, {:ok, seen} ->
      at = path <> "/" <> escape(index)

      cond do
        not (is_binary(value) and String.valid?(value)) -> {:halt, refuse(at, "type")}
        code_points(value) not in 1..@enum_value_max -> {:halt, refuse(at, "range")}
        MapSet.member?(seen, value) -> {:halt, refuse(at, "duplicate")}
        true -> {:cont, {:ok, MapSet.put(seen, value)}}
      end
    end)
    |> case do
      {:ok, _seen} -> {:ok, values}
      refusal -> refusal
    end
  end

  defp enum_values({:ok, values}, path) when is_list(values), do: refuse(path, "range")

  defp enum_values({:ok, _values}, path), do: refuse(path, "type")

  defp field_names(fields, path) when is_map(fields) and not is_struct(fields) do
    if map_size(fields) > @fields_max do
      refuse(path, "range")
    else
      case fields |> Map.keys() |> Enum.sort() |> Enum.reject(&name?/1) do
        [] -> :ok
        [name | _] -> refuse(path <> "/" <> escape(to_string(name)), "name")
      end
    end
  end

  defp field_names(_fields, path), do: refuse(path, "type")

  defp required(names, fields, path) when is_list(names) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {name, index}, {:ok, seen} ->
      at = path <> "/" <> escape(index)

      cond do
        not is_binary(name) -> {:halt, refuse(at, "type")}
        not Map.has_key?(fields, name) -> {:halt, refuse(at, "unknown_field")}
        MapSet.member?(seen, name) -> {:halt, refuse(at, "duplicate")}
        true -> {:cont, {:ok, MapSet.put(seen, name)}}
      end
    end)
    |> case do
      # Sorted, so the order a spelling lists them in changes no digest.
      {:ok, _seen} -> {:ok, Enum.sort(names)}
      refusal -> refusal
    end
  end

  defp required(_names, _fields, path), do: refuse(path, "type")

  defp field_shapes(fields, path, depth) do
    fields
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, shape}, {:ok, acc} ->
      case node(shape, path <> "/" <> escape(name), depth + 1) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, name, normalized)}}
        refusal -> {:halt, refusal}
      end
    end)
  end

  @doc "The canonical JSON bytes (`Prima.JCS`) of a validated shape."
  @spec encode(t()) :: binary()
  def encode(shape) when is_map(shape) do
    {:ok, bytes} = Prima.JCS.encode(shape)
    bytes
  end

  @doc "A validated shape's digest: `sha256:` over `encode/1`."
  @spec digest(t()) :: String.t()
  def digest(shape) when is_map(shape), do: Prima.JCS.hash_binary(encode(shape))

  # ---- values ----------------------------------------------------------------

  @doc """
  Whether a decoded JSON `value` has the validated `shape`: `:ok`, or
  `{:error, %{path, reason}}` for the first failing path.
  """
  @spec check(t(), term()) :: :ok | {:error, refusal()}
  def check(shape, value), do: value(shape, value, "")

  defp value(%{"nullable" => true}, nil, _path), do: :ok
  defp value(%{}, nil, path), do: refuse(path, "null")

  defp value(%{"type" => "string", "max" => max}, value, path) do
    cond do
      not (is_binary(value) and String.valid?(value)) -> refuse(path, "type")
      code_points(value) > max -> refuse(path, "max")
      true -> :ok
    end
  end

  defp value(%{"type" => "number"}, value, path),
    do: if(is_number(value), do: :ok, else: refuse(path, "type"))

  defp value(%{"type" => "integer"}, value, path),
    do: if(is_integer(value), do: :ok, else: refuse(path, "type"))

  defp value(%{"type" => "boolean"}, value, path),
    do: if(is_boolean(value), do: :ok, else: refuse(path, "type"))

  defp value(%{"type" => "time"}, value, path) do
    cond do
      not (is_binary(value) and String.valid?(value)) -> refuse(path, "type")
      match?({:ok, _at, _offset}, DateTime.from_iso8601(value)) -> :ok
      true -> refuse(path, "time")
    end
  end

  defp value(%{"type" => "enum", "values" => values}, value, path) do
    cond do
      not is_binary(value) -> refuse(path, "type")
      value in values -> :ok
      true -> refuse(path, "enum")
    end
  end

  defp value(%{"type" => "list", "of" => of, "max" => max}, value, path) do
    cond do
      not is_list(value) ->
        refuse(path, "type")

      length(value) > max ->
        refuse(path, "max")

      true ->
        value
        |> Enum.with_index()
        |> first_refusal(fn {element, index} ->
          value(of, element, path <> "/" <> escape(index))
        end)
    end
  end

  defp value(%{"type" => "object", "fields" => fields, "required" => required}, value, path) do
    if is_map(value) and not is_struct(value) do
      value
      |> Map.keys()
      |> Enum.concat(Map.keys(fields))
      |> Enum.uniq()
      |> Enum.sort()
      |> first_refusal(&field(fields, required, value, &1, path))
    else
      refuse(path, "type")
    end
  end

  defp value(%{"type" => "json"}, value, path),
    do: if(json?(value), do: :ok, else: refuse(path, "type"))

  defp field(fields, required, value, key, path) do
    at = path <> "/" <> escape(to_string(key))

    case {Map.fetch(fields, key), Map.fetch(value, key)} do
      {:error, _present} -> refuse(at, "unknown_field")
      {{:ok, shape}, {:ok, member}} -> value(shape, member, at)
      {{:ok, _shape}, :error} -> if key in required, do: refuse(at, "required"), else: :ok
    end
  end

  defp first_refusal(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  # ---- fixtures --------------------------------------------------------------

  @doc """
  A value a validated shape passes, deterministic and never `null`: `""`,
  `0`, `false`, `#{@fixture_time}`, an enum's first value, a list of one
  fixture, an object with every field's fixture, and `{}` for `json`.
  """
  @spec fixture(t()) :: term()
  def fixture(%{"type" => "string"}), do: ""
  def fixture(%{"type" => type}) when type in ["number", "integer"], do: 0
  def fixture(%{"type" => "boolean"}), do: false
  def fixture(%{"type" => "time"}), do: @fixture_time
  def fixture(%{"type" => "enum", "values" => [first | _]}), do: first
  def fixture(%{"type" => "list", "of" => of}), do: [fixture(of)]

  def fixture(%{"type" => "object", "fields" => fields}),
    do: Map.new(fields, fn {name, shape} -> {name, fixture(shape)} end)

  def fixture(%{"type" => "json"}), do: %{}

  # ---- helpers ---------------------------------------------------------------

  defp code_points(string), do: string |> String.codepoints() |> length()

  defp refuse(path, reason) when is_map_key(@reasons, reason),
    do: {:error, %{path: path, reason: reason}}
end
