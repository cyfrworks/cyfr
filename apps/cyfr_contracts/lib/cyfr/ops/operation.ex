# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Operation do
  @moduledoc """
  One tool action's identity, description, arguments and access/effect
  declaration. Discovery schemas and annotation views derive from these
  values. Contextual authorization belongs to the calling catalog gate.

  `resource_schemes` names the MCP resource URI schemes this operation
  reads (`compendium`, `arca`, …): an MCP `resources/read` of such a URI
  is admitted as a call of this operation, through the same gate. It is
  metadata for the resource adapter, not an access annotation, so it is
  absent from the annotation view and from discovery. A resource read is
  an external, consent-free, replay-safe read taking exactly one required
  string argument, `uri`.
  """

  alias Cyfr.Ops.Arg

  @enforce_keys [:tool, :action, :description, :args, :kind, :planes]
  defstruct [
    :tool,
    :action,
    :description,
    :args,
    :kind,
    :planes,
    :permission,
    :consent,
    :scope,
    :standing,
    :recovery,
    :host,
    auth: :required,
    resource_schemes: []
  ]

  @type t :: %__MODULE__{
          tool: String.t(),
          action: String.t(),
          description: String.t(),
          args: [Arg.t()],
          kind: :read | :write | :execute | :destructive | :external,
          planes: [:external | :in_chain],
          auth: :anonymous | :signed_in | :required,
          permission: atom() | nil,
          consent: :interactive | :staging | nil,
          scope: :platform | nil,
          standing: :thread | false | nil,
          recovery: :replay_safe | nil,
          host: :intercepted | nil,
          resource_schemes: [String.t()]
        }

  @valid_planes [:external, :in_chain]

  @doc "The supported authorization planes."
  @spec valid_planes() :: [atom()]
  def valid_planes, do: @valid_planes

  @annotation_fields [
    :kind,
    :planes,
    :auth,
    :permission,
    :consent,
    :scope,
    :standing,
    :recovery,
    :host
  ]

  @doc "Declare an action, refusing invalid or contradictory declarations."
  @spec new(String.t(), String.t(), String.t(), [Arg.t()], keyword()) :: t()
  def new(tool, action, description, args, opts) do
    unknown = Keyword.keys(opts) -- [:resource_schemes | @annotation_fields]
    if unknown != [], do: raise(ArgumentError, "unknown operation annotations")

    op =
      struct!(
        __MODULE__,
        Keyword.merge(opts, tool: tool, action: action, description: description, args: args)
      )

    validate!(op)
    op
  end

  @doc "Validate a declaration, including structs updated after construction."
  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = op) do
    unless Enum.all?([op.tool, op.action, op.description], &(is_binary(&1) and &1 != "")),
      do: raise(ArgumentError, "operation identity and description must be non-empty strings")

    unless op.kind in [:read, :write, :execute, :destructive, :external] and
             is_list(op.planes) and op.planes != [] and
             Enum.all?(op.planes, &(&1 in @valid_planes)) and
             op.auth in [:anonymous, :signed_in, :required] and
             op.consent in [nil, :interactive, :staging] and
             op.scope in [nil, :platform] and op.standing in [nil, false, :thread] and
             op.recovery in [nil, :replay_safe] and
             (is_nil(op.permission) or is_atom(op.permission)),
           do: raise(ArgumentError, "invalid operation annotation")

    if op.recovery == :replay_safe and op.kind != :read,
      do: raise(ArgumentError, "only explicitly reviewed reads can be replay-safe")

    if Enum.any?(op.args, &(&1.name == "action")),
      do: raise(ArgumentError, "action is the operation discriminator")

    _ = Arg.schema(op.args)

    if op.host not in [nil, :intercepted] or
         (op.host == :intercepted and :in_chain in op.planes),
       do: raise(ArgumentError, "intercepted actions must be external")

    if op.scope == :platform and op.planes != [:external],
      do: raise(ArgumentError, "platform actions must be external")

    validate_resource_schemes!(op)
  end

  # A URI scheme as RFC 3986 spells it, lowercase only, so one scheme has
  # one spelling in the index the resource adapter derives.
  @scheme ~r/\A[a-z][a-z0-9+.\-]*\z/

  defp validate_resource_schemes!(%__MODULE__{resource_schemes: []}), do: :ok

  defp validate_resource_schemes!(%__MODULE__{resource_schemes: [_ | _] = schemes} = op) do
    unless Enum.all?(schemes, &(is_binary(&1) and Regex.match?(@scheme, &1))) and
             length(Enum.uniq(schemes)) == length(schemes),
           do: raise(ArgumentError, "resource schemes must be unique lowercase URI schemes")

    unless op.kind == :read and op.planes == [:external] and is_nil(op.consent) and
             op.recovery == :replay_safe and uri_argument?(op.args),
           do:
             raise(
               ArgumentError,
               "a resource read is an external, consent-free, replay-safe read of one required uri"
             )

    :ok
  end

  defp validate_resource_schemes!(%__MODULE__{}),
    do: raise(ArgumentError, "resource schemes must be a list")

  defp uri_argument?([%Arg{name: "uri", type: :string, required: true, nullable: false}]),
    do: true

  defp uri_argument?(_args), do: false

  @doc "Materialize a tool's discovery and annotation views from its operations."
  @spec tool([t()], keyword()) :: map()
  def tool([%__MODULE__{} = first | _] = operations, opts \\ []) do
    Enum.each(operations, &validate!/1)

    unless Enum.all?(operations, &(&1.tool == first.tool)) and
             length(operations) == length(Enum.uniq_by(operations, & &1.action)),
           do: raise(ArgumentError, "a tool must have unique actions sharing its identity")

    unknown = Keyword.keys(opts) -- [:description, :title, :icons, :output_schema]
    if unknown != [], do: raise(ArgumentError, "unknown tool metadata")

    %{
      name: first.tool,
      description: Keyword.get(opts, :description, first.description),
      operations: operations,
      input_schema: schema(operations),
      annotations: %{
        readOnlyHint: Enum.all?(operations, &(&1.kind == :read)),
        destructiveHint: Enum.any?(operations, &(&1.kind == :destructive)),
        actions: Map.new(operations, &{&1.action, annotations(&1)})
      }
    }
    |> Map.merge(Map.new(Keyword.take(opts, [:title, :icons, :output_schema])))
  end

  @doc "An action's access/effect annotations, with absent optional fields omitted."
  @spec annotations(t()) :: map()
  def annotations(%__MODULE__{} = op),
    do: op |> Map.take(@annotation_fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)

  # Per-declaration constraints that a merged property may loosen or drop.
  # Everything else in a value schema is its shape, which every action
  # declaring the name must share.
  @bounds [
    {"minimum", "maximum"},
    {"minLength", "maxLength"},
    {"minItems", "maxItems"},
    {"minProperties", "maxProperties"}
  ]
  @agreed ["pattern", "default"]
  @loose ["description", "enum" | @agreed] ++ Enum.flat_map(@bounds, &Tuple.to_list/1)

  @doc """
  One flat object schema for a tool: the action discriminator plus one
  property per argument name, merged across the actions that declare it.

  Model APIs refuse `oneOf`, `anyOf` and `allOf` at the top level of a tool
  schema, so discovery is a single object and `cast/2` remains the place
  where each call meets its own action's declaration. A merged property is
  the loosest of its declarations: nullable when any action accepts null,
  the union of their enums, the widest of their bounds, and a pattern or
  default only when every declaration agrees. An argument declared by a
  subset of the actions names them in its description. `required` lists
  the arguments every action requires. One name declared with different
  shapes across a tool's actions is a declaration error.
  """
  @spec schema([t()]) :: map()
  def schema(operations) do
    Enum.each(operations, &validate!/1)
    actions = Enum.map(operations, & &1.action)

    declared =
      operations
      |> Enum.flat_map(fn op -> Enum.map(op.args, &{&1.name, {op.action, &1}}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    properties =
      Map.new(declared, fn {name, entries} -> {name, merge_property(name, entries, actions)} end)

    required =
      for {name, entries} <- declared,
          length(entries) == length(actions),
          Enum.all?(entries, fn {_action, arg} -> arg.required end),
          do: name

    %{
      "type" => "object",
      "properties" => Map.put(properties, "action", %{"type" => "string", "enum" => actions}),
      "required" => ["action" | Enum.sort(required)],
      "additionalProperties" => false
    }
  end

  defp merge_property(name, entries, actions) do
    schemas = Enum.map(entries, fn {_action, arg} -> Arg.value_schema(arg) end)

    case schemas |> Enum.map(&shape/1) |> Enum.uniq() do
      [shape] ->
        shape
        |> merge_nullable(schemas)
        |> merge_enum(schemas)
        |> merge_bounds(schemas)
        |> merge_agreed(schemas)
        |> merge_description(schemas, Enum.map(entries, &elem(&1, 0)), actions)

      _ ->
        raise ArgumentError, "argument #{name} declares different types across actions"
    end
  end

  defp shape(schema) do
    case Map.drop(schema, @loose) do
      %{"type" => [type, "null"]} = shape -> Map.put(shape, "type", type)
      shape -> shape
    end
  end

  defp merge_nullable(shape, schemas) do
    if Enum.any?(schemas, &match?(%{"type" => [_, "null"]}, &1)),
      do: Map.update!(shape, "type", &[&1, "null"]),
      else: shape
  end

  defp merge_enum(shape, schemas) do
    if Enum.all?(schemas, &Map.has_key?(&1, "enum")),
      do: Map.put(shape, "enum", schemas |> Enum.flat_map(& &1["enum"]) |> Enum.uniq()),
      else: shape
  end

  defp merge_bounds(shape, schemas) do
    Enum.reduce(@bounds, shape, fn {low, high}, shape ->
      shape
      |> merge_bound(schemas, low, &Enum.min/1)
      |> merge_bound(schemas, high, &Enum.max/1)
    end)
  end

  defp merge_bound(shape, schemas, key, pick) do
    if Enum.all?(schemas, &Map.has_key?(&1, key)),
      do: Map.put(shape, key, pick.(Enum.map(schemas, & &1[key]))),
      else: shape
  end

  defp merge_agreed(shape, schemas) do
    Enum.reduce(@agreed, shape, fn key, shape ->
      case schemas |> Enum.map(&Map.fetch(&1, key)) |> Enum.uniq() do
        [{:ok, value}] -> Map.put(shape, key, value)
        _ -> shape
      end
    end)
  end

  defp merge_description(shape, schemas, declared_by, actions) do
    description = Enum.find_value(schemas, & &1["description"])

    scope =
      if length(declared_by) < length(actions),
        do: "Actions: #{Enum.join(declared_by, ", ")}.",
        else: nil

    case Enum.reject([description, scope], &is_nil/1) do
      [] -> shape
      parts -> Map.put(shape, "description", Enum.join(parts, " "))
    end
  end

  @doc """
  Restrict a wire schema's action enum to existing selected actions.

  A bare schema carries no record of which action declared which property,
  so only the enum narrows here; `restrict/2` rebuilds the whole view from
  the declarations. Schemas without an action enum retain their other
  constraints. An empty selection describes no action.
  """
  @spec restrict_schema(map(), [String.t()]) :: map()
  def restrict_schema(%{"properties" => %{"action" => %{"enum" => existing}}} = schema, actions)
      when is_list(existing) and is_list(actions) do
    put_in(schema, ["properties", "action", "enum"], Enum.filter(existing, &(&1 in actions)))
  end

  def restrict_schema(schema, actions) when is_map(schema) and is_list(actions), do: schema

  @doc "Keep only selected actions, rebuilding every derived view together."
  @spec restrict(map(), [String.t()]) :: map() | nil
  def restrict(%{operations: operations} = definition, actions) do
    case Enum.filter(operations, &(&1.action in actions)) do
      [] ->
        nil

      selected ->
        tool(
          selected,
          Map.to_list(Map.take(definition, [:description, :title, :icons, :output_schema]))
        )
    end
  end

  @doc "Validate action arguments, using Arg integer normalization without inserting defaults."
  @spec cast(map(), term()) :: {:ok, map()} | {:error, term()}
  def cast(%{name: name, operations: operations}, input) when is_map(input) do
    case Map.fetch(input, "action") do
      :error ->
        {:error, :action_missing}

      {:ok, action} when is_binary(action) ->
        case Enum.find(operations, &(&1.action == action)) do
          nil ->
            {:error, {:unknown_action, name <> "." <> action}}

          operation ->
            case Arg.cast(operation.args, Map.delete(input, "action")) do
              {:ok, args} -> {:ok, Map.put(args, "action", action)}
              {:error, message} -> {:error, {:invalid_argument, message}}
            end
        end

      {:ok, _} ->
        {:error, {:invalid_argument, "Field 'action' must be a string"}}
    end
  end

  def cast(_definition, _input), do: {:error, {:invalid_argument, "Arguments must be an object"}}
end
