# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Feed.Read do
  @moduledoc false
  # The readers `Prima.Feed`, `Prima.Feed.Binding` and `Prima.Feed.Action`
  # share, each answering a refusal as `%{path, reason}` that names no
  # value it was handed. `Prima.Feed` comes last in this file because it
  # matches the two structs, which must be compiled before it.

  alias Prima.Canvas.Shape

  @control ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u

  def known_keys(map, known, path) do
    case map |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse(child(path, key), "unknown_key")
    end
  end

  # A key that is not a string, a binary that is not UTF-8 text among them,
  # has no spelling in a pointer, so the refusal stays at its object and
  # never names the key.
  defp child(path, key) do
    if is_binary(key) and String.valid?(key), do: path <> "/" <> Shape.escape(key), else: path
  end

  def fetch(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> refuse(path <> "/" <> key, "required")
    end
  end

  def name(value, path) do
    cond do
      Prima.Feed.name?(value) -> {:ok, value}
      is_binary(value) -> refuse(path, "name")
      true -> refuse(path, "type")
    end
  end

  def label(value, max, path) do
    cond do
      not (is_binary(value) and String.valid?(value)) ->
        refuse(path, "type")

      length(String.codepoints(value)) in 1..max and not Regex.match?(@control, value) ->
        {:ok, value}

      true ->
        refuse(path, "text")
    end
  end

  def operation(value, path) do
    cond do
      Prima.Manifest.Results.operation?(value) -> {:ok, value}
      is_binary(value) -> refuse(path, "name")
      true -> refuse(path, "type")
    end
  end

  def args(%{} = args, path) when not is_struct(args) do
    with :ok <- json_text(args, Prima.Feed.args_max_bytes(), path), do: {:ok, args}
  end

  def args(_args, path), do: refuse(path, "type")

  def json_text(value, max, path) do
    with true <- Shape.json?(value),
         {:ok, text} <- Prima.Json.encode(value) do
      if byte_size(text) <= max, do: :ok, else: refuse(path, "size")
    else
      _unwritable -> refuse(path, "json")
    end
  end

  def refuse(path, reason) when is_binary(path) and is_binary(reason) do
    unless Map.has_key?(Prima.Feed.reasons(), reason),
      do: raise(ArgumentError, "a feed refusal names one of Prima.Feed.reasons/0")

    {:error, %{path: path, reason: reason}}
  end

  # A proper list's length, or nil for an improper one, which `length/1`
  # would raise on, its report printing the list.
  def proper_length(list), do: proper_length(list, 0)
  defp proper_length([], count), do: count
  defp proper_length([_head | tail], count), do: proper_length(tail, count + 1)
  defp proper_length(_improper_tail, _count), do: nil
end

defmodule Prima.Feed.Action do
  @moduledoc """
  One labelled action of a feed binding, which a canvas may show as a
  control:

    * `name` — the feed-name grammar (`Prima.Feed.name?/1`), distinct
      within its binding;
    * `label` — 1 to 40 code points with no control character, the
      control's label;
    * `kind` — `:refresh` reruns the feed and publishes its result, and
      carries no `operation` or `args`; `:run` runs `operation` (1 to 64
      code points with no control character) with `args` (a JSON object,
      `{}` allowed, at most 4096 bytes of JSON text) and publishes nothing.

  In JSON the kind is the string `refresh` or `run`.
  """

  alias Prima.Feed.Read

  @label_max 40
  @kinds %{"refresh" => :refresh, "run" => :run}

  @type kind :: :refresh | :run

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          kind: kind(),
          operation: String.t() | nil,
          args: map() | nil
        }

  @enforce_keys [:name, :label, :kind]
  defstruct [:name, :label, :kind, operation: nil, args: nil]

  @doc "The most code points an action's label takes."
  @spec label_max() :: pos_integer()
  def label_max, do: @label_max

  @doc """
  A decoded JSON action, or `{:error, %{path, reason}}` with the path a
  pointer into the action.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, Prima.Feed.refusal()}
  def validate(%{} = json) when not is_struct(json) do
    with :ok <- Read.known_keys(json, ~w(name label kind operation args), ""),
         {:ok, name} <- Read.fetch(json, "name", ""),
         {:ok, name} <- Read.name(name, "/name"),
         {:ok, label} <- Read.fetch(json, "label", ""),
         {:ok, label} <- Read.label(label, @label_max, "/label"),
         {:ok, kind} <- Read.fetch(json, "kind", ""),
         {:ok, kind} <- kind(kind),
         {:ok, fields} <- kind_fields(kind, json) do
      {:ok, struct!(__MODULE__, Map.merge(fields, %{name: name, label: label, kind: kind}))}
    end
  end

  def validate(_json), do: Read.refuse("", "type")

  @doc """
  The JSON form: string keys, `operation` and `args` only for `run`. Any
  other term raises an `ArgumentError` naming no value.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{kind: :refresh} = action),
    do: %{"name" => action.name, "label" => action.label, "kind" => "refresh"}

  def to_json(%__MODULE__{kind: :run} = action) do
    %{
      "name" => action.name,
      "label" => action.label,
      "kind" => "run",
      "operation" => action.operation,
      "args" => action.args
    }
  end

  # Never a clause error: its report would print the term.
  def to_json(_action), do: raise(ArgumentError, "to_json/1 takes a Prima.Feed.Action")

  defp kind(kind) when is_map_key(@kinds, kind), do: {:ok, Map.fetch!(@kinds, kind)}
  defp kind(kind) when is_binary(kind), do: Read.refuse("/kind", "enum")
  defp kind(_kind), do: Read.refuse("/kind", "type")

  defp kind_fields(:refresh, json) do
    case Enum.find(~w(operation args), &Map.has_key?(json, &1)) do
      nil -> {:ok, %{}}
      key -> Read.refuse("/" <> key, "unknown_key")
    end
  end

  defp kind_fields(:run, json) do
    with {:ok, operation} <- Read.fetch(json, "operation", ""),
         {:ok, operation} <- Read.operation(operation, "/operation"),
         {:ok, args} <- Read.fetch(json, "args", ""),
         {:ok, args} <- Read.args(args, "/args") do
      {:ok, %{operation: operation, args: args}}
    end
  end
end

defmodule Prima.Feed.Binding do
  @moduledoc """
  A feed's binding, every field required:

    * `name` — the feed-name grammar (`Prima.Feed.name?/1`);
    * `label` — 1 to 80 code points with no control character;
    * `reference` — a versionless `catalyst` or `formula` reference in its
      canonical spelling (`Prima.ComponentRef.to_string/1` of what
      `Prima.ComponentRef.parse/1` reads);
    * `operation` — 1 to 64 code points with no control character, the
      rule a `results` key follows (`Prima.Manifest.Results`);
    * `args` — a JSON object, `{}` allowed, at most 4096 bytes of JSON text;
    * `interval_minutes` — one of `Prima.Feed.intervals/0`;
    * `result_shape` — a `Prima.Canvas.Shape`, held normalized; the
      component manifest's `results[operation]` when bound;
    * `actions` — at most 8 `Prima.Feed.Action`s with distinct names.

  `validate/1` of `to_json/1` answers the binding it was written from.
  """

  alias Prima.Canvas.Shape
  alias Prima.Feed
  alias Prima.Feed.{Action, Read}

  @label_max 80
  @max_actions 8
  @keys ~w(name label reference operation args interval_minutes result_shape actions)
  @reference_types ~w(catalyst formula)

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          reference: String.t(),
          operation: String.t(),
          args: map(),
          interval_minutes: pos_integer(),
          result_shape: Shape.t(),
          actions: [Action.t()]
        }

  @enforce_keys [
    :name,
    :label,
    :reference,
    :operation,
    :args,
    :interval_minutes,
    :result_shape,
    :actions
  ]
  defstruct @enforce_keys

  @doc "The most code points a binding's label takes."
  @spec label_max() :: pos_integer()
  def label_max, do: @label_max

  @doc "The most actions a binding carries."
  @spec max_actions() :: pos_integer()
  def max_actions, do: @max_actions

  @doc """
  A decoded JSON binding, or `{:error, %{path, reason}}` with the path a
  pointer into the binding. Fields are read in the order the moduledoc
  lists them.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, Feed.refusal()}
  def validate(%{} = json) when not is_struct(json) do
    with :ok <- Read.known_keys(json, @keys, ""),
         {:ok, name} <- read(json, "name", &Read.name/2),
         {:ok, label} <- read(json, "label", &Read.label(&1, @label_max, &2)),
         {:ok, reference} <- read(json, "reference", &reference/2),
         {:ok, operation} <- read(json, "operation", &Read.operation/2),
         {:ok, args} <- read(json, "args", &Read.args/2),
         {:ok, interval} <- read(json, "interval_minutes", &interval/2),
         {:ok, shape} <- read(json, "result_shape", &result_shape/2),
         {:ok, actions} <- read(json, "actions", &actions/2) do
      {:ok,
       %__MODULE__{
         name: name,
         label: label,
         reference: reference,
         operation: operation,
         args: args,
         interval_minutes: interval,
         result_shape: shape,
         actions: actions
       }}
    end
  end

  def validate(_json), do: Read.refuse("", "type")

  @doc """
  The JSON form: string keys, every field written. Any other term, or a
  binding whose actions are not a list of `Prima.Feed.Action`s, raises an
  `ArgumentError` naming no value.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{actions: actions} = binding) do
    unless Read.proper_length(actions),
      do: raise(ArgumentError, "a binding's actions are a list of Prima.Feed.Action")

    %{
      "name" => binding.name,
      "label" => binding.label,
      "reference" => binding.reference,
      "operation" => binding.operation,
      "args" => binding.args,
      "interval_minutes" => binding.interval_minutes,
      "result_shape" => binding.result_shape,
      "actions" => Enum.map(actions, &Action.to_json/1)
    }
  end

  # Never a clause error: its report would print the term.
  def to_json(_binding), do: raise(ArgumentError, "to_json/1 takes a Prima.Feed.Binding")

  defp read(json, key, reader) do
    with {:ok, value} <- Read.fetch(json, key, ""), do: reader.(value, "/" <> key)
  end

  defp reference(ref, path) when is_binary(ref) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %Prima.ComponentRef{type: type, version: nil} = parsed}
      when type in @reference_types ->
        if Prima.ComponentRef.to_string(parsed) == ref,
          do: {:ok, ref},
          else: Read.refuse(path, "reference")

      _other ->
        Read.refuse(path, "reference")
    end
  end

  defp reference(_ref, path), do: Read.refuse(path, "type")

  defp interval(minutes, path) when is_integer(minutes) do
    if minutes in Feed.intervals(), do: {:ok, minutes}, else: Read.refuse(path, "enum")
  end

  defp interval(_minutes, path), do: Read.refuse(path, "type")

  defp result_shape(shape, path) do
    case Shape.validate(shape) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, %{path: at, reason: reason}} -> Read.refuse(path <> at, reason)
    end
  end

  defp actions(actions, path) when is_list(actions) do
    case Read.proper_length(actions) do
      nil -> Read.refuse(path, "type")
      count when count <= @max_actions -> distinct_actions(actions, path)
      _count -> Read.refuse(path, "range")
    end
  end

  defp actions(_actions, path), do: Read.refuse(path, "type")

  defp distinct_actions(actions, path) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {json, index}, {:ok, acc, names} ->
      at = path <> "/" <> Integer.to_string(index)

      case Action.validate(json) do
        {:ok, %Action{name: name} = action} ->
          if MapSet.member?(names, name),
            do: {:halt, Read.refuse(at <> "/name", "duplicate")},
            else: {:cont, {:ok, [action | acc], MapSet.put(names, name)}}

        {:error, %{path: inner, reason: reason}} ->
          {:halt, Read.refuse(at <> inner, reason)}
      end
    end)
    |> case do
      {:ok, acc, _names} -> {:ok, Enum.reverse(acc)}
      refusal -> refusal
    end
  end
end

defmodule Prima.Feed do
  @moduledoc """
  A feed: one component operation with fixed arguments, run on an interval,
  whose result a canvas reads by the feed's name, with labelled actions a
  canvas may show as controls.

  `Prima.Feed.Binding` is the binding and `Prima.Feed.Action` one of its
  actions, each read from string-keyed JSON by `validate/1` and written
  back by `to_json/1`. A binding carries no id: its id is its row's
  (`binding_id?/1`), so rebinding a name is a new id.

  A feed's arguments and results are never digested, so their bounds are
  byte lengths of their `Prima.Json.encode/1` text, which key order does
  not change: arguments at most 4096 bytes, a result at most 65536.
  A value that text cannot be written for is refused as `"json"`.

  Every refusal is `%{path, reason}`, the path an RFC 6901 pointer into
  the binding's JSON (or the result's, for `check_result/2`) and the
  reason one of `reasons/0`. A refusal names no value it was handed: a
  term outside the grammar (an improper list, a key that is not a string,
  a struct) is refused like any other value of the wrong type, and a key
  that is not a string, a binary that is not UTF-8 text among them, leaves
  the path at its object, so a path is always text. A function handed
  an argument outside its type raises an `ArgumentError` naming no value.

  `tests/fixtures/feed.json` holds bindings, inputs, crons, results,
  envelopes, and results and arguments at their byte bounds.
  """

  alias Prima.Canvas.Shape
  alias Prima.Feed.{Action, Binding, Read}

  @name ~r/\A[a-z0-9][a-z0-9-]{0,47}\z/
  @binding_id ~r/\Afeed_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @intervals [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60]
  @args_max_bytes 4096
  @result_max_bytes 65_536

  @actions_sentence "a binding's actions are a list of Prima.Feed.Action"
  @time_sentence "an envelope's time is a DateTime"

  # The reasons a feed adds to the shape's vocabulary (`Shape.reasons/0`).
  @feed_reasons %{
    "text" => "a label outside its code-point range or with a control character",
    "reference" => "not a canonically spelt, versionless catalyst or formula reference",
    "size" => "JSON text longer than its bound",
    "json" => "a value Prima.Json.encode/1 cannot write as JSON text"
  }

  @typedoc "A refusal: where and why."
  @type refusal :: Shape.refusal()

  @doc "Whether `name` is a feed's or an action's name: `#{Regex.source(@name)}`."
  @spec name?(term()) :: boolean()
  def name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc """
  Whether `id` is a binding id: `feed_` and a lowercase UUID v7, the form
  `Prima.UUID7.generate_id("feed")` mints.
  """
  @spec binding_id?(term()) :: boolean()
  def binding_id?(id), do: is_binary(id) and Regex.match?(@binding_id, id)

  @doc "The intervals a feed may run at, in minutes: the whole divisors of 60."
  @spec intervals() :: [pos_integer()]
  def intervals, do: @intervals

  @doc "The most bytes a binding's or a `run` action's arguments take as JSON text."
  @spec args_max_bytes() :: pos_integer()
  def args_max_bytes, do: @args_max_bytes

  @doc "The most bytes a result takes as JSON text."
  @spec result_max_bytes() :: pos_integer()
  def result_max_bytes, do: @result_max_bytes

  @doc "Every refusal reason a feed answers: the shape's and the feed's own."
  @spec reasons() :: %{String.t() => String.t()}
  def reasons, do: Map.merge(Shape.reasons(), @feed_reasons)

  @doc """
  The component input a binding or a `run` action runs with, the catalyst
  input convention: `%{"operation" => operation, "params" => args}`.
  """
  @spec input(Binding.t() | Action.t()) :: %{String.t() => term()}
  def input(%Binding{operation: operation, args: args}),
    do: %{"operation" => operation, "params" => args}

  def input(%Action{kind: :run, operation: operation, args: args}),
    do: %{"operation" => operation, "params" => args}

  # Never a clause error: its report would print the term.
  def input(_source), do: raise(ArgumentError, "input/1 takes a binding or a run action")

  @doc "The binding's cron expression: `*/N * * * *`, or `0 * * * *` for 60."
  @spec cron(Binding.t()) :: String.t()
  def cron(%Binding{interval_minutes: 60}), do: "0 * * * *"

  def cron(%Binding{interval_minutes: minutes}) when minutes in @intervals,
    do: "*/#{minutes} * * * *"

  def cron(_binding),
    do: raise(ArgumentError, "cron/1 takes a binding whose interval is one of intervals/0")

  @doc """
  Whether a decoded `result` may be accepted for `binding`: its JSON text
  at most #{@result_max_bytes} bytes (`"json"` when there is none, `"size"`
  past the bound, both at the root), then the binding's result shape
  (`Prima.Canvas.Shape.check/2`).
  """
  @spec check_result(Binding.t(), term()) :: :ok | {:error, refusal()}
  def check_result(%Binding{result_shape: shape}, result) do
    with :ok <- Read.json_text(result, @result_max_bytes, ""), do: Shape.check(shape, result)
  end

  def check_result(_binding, _result),
    do: raise(ArgumentError, "check_result/2 takes a binding and a decoded result")

  @doc """
  The payload a feed's stream carries for one accepted result: exactly
  `binding` (its id), `feed` (its name), `revision` (the accepted seq),
  `at` (ISO 8601 in UTC), `result`, and the binding's display part,
  `label` and `actions` (`[{name, label}]` in the binding's order). It
  never carries the operation, the arguments, the reference or the
  interval. A binding id outside its grammar, or any other argument
  outside its type, raises an `ArgumentError` naming no value.
  """
  @spec envelope(String.t(), Binding.t(), non_neg_integer(), DateTime.t(), term()) :: map()
  def envelope(binding_id, %Binding{} = binding, revision, %DateTime{} = at, result)
      when is_integer(revision) and revision >= 0 do
    unless binding_id?(binding_id),
      do: raise(ArgumentError, "an envelope names its binding by a binding id")

    %{
      "binding" => binding_id,
      "feed" => binding.name,
      "revision" => revision,
      "at" => utc_iso8601(at),
      "result" => result,
      "label" => binding.label,
      "actions" => display(binding.actions)
    }
  end

  # Never a clause error: its report would print the binding and result.
  def envelope(_binding_id, _binding, _revision, _at, _result) do
    raise ArgumentError,
          "envelope/5 takes a binding id, a binding, a revision, a DateTime and a result"
  end

  # A DateTime struct whose fields are not a time's either raises in the
  # calendar functions, whose reports print the fields, or is written as a
  # time that is none; both raise here instead, carrying neither.
  defp utc_iso8601(at) do
    case utc_iso8601_text(at) do
      {:ok, iso} -> iso
      :error -> raise ArgumentError, @time_sentence
    end
  end

  # The raise above stays outside this rescue: re-raising the calendar's own
  # error would carry the fields it prints.
  defp utc_iso8601_text(at) do
    iso = at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
    if match?({:ok, _at, 0}, DateTime.from_iso8601(iso)), do: {:ok, iso}, else: :error
  rescue
    _not_a_time -> :error
  end

  defp display(actions) do
    unless Read.proper_length(actions), do: raise(ArgumentError, @actions_sentence)

    Enum.map(actions, fn
      %Action{name: name, label: label} -> %{"name" => name, "label" => label}
      _other -> raise ArgumentError, @actions_sentence
    end)
  end
end
