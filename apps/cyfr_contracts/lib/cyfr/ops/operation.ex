# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Operation do
  @moduledoc """
  One tool action's identity, description, arguments and access/effect
  declaration. Discovery schemas and annotation views derive from these
  values. Contextual authorization belongs to the calling catalog gate.
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
    auth: :required
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
          host: :intercepted | nil
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
    unknown = Keyword.keys(opts) -- @annotation_fields
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

    :ok
  end

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

  @doc "An action-discriminated object schema; each branch owns its required arguments."
  @spec schema([t()]) :: map()
  def schema(operations) do
    Enum.each(operations, &validate!/1)

    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => Enum.map(operations, & &1.action)}
      },
      "required" => ["action"],
      "oneOf" =>
        Enum.map(operations, fn op ->
          schema = Arg.schema(op.args)

          schema
          |> Map.put("description", op.description)
          |> Map.update!(
            "properties",
            &Map.put(&1, "action", %{"type" => "string", "const" => op.action})
          )
          |> Map.update!("required", &["action" | &1])
        end)
    }
  end

  @doc """
  Restrict an action-discriminated wire schema to existing selected actions.

  Preserve metadata and property definitions while filtering the action
  enum and its `oneOf` branches together. Schemas without action branches
  retain their other constraints. An empty selection describes no action.
  """
  @spec restrict_schema(map(), [String.t()]) :: map()
  def restrict_schema(%{"properties" => %{"action" => %{"enum" => existing}}} = schema, actions)
      when is_list(existing) and is_list(actions) do
    kept = Enum.filter(existing, &(&1 in actions))
    schema = put_in(schema, ["properties", "action", "enum"], kept)

    case schema do
      %{"oneOf" => branches} when is_list(branches) ->
        Map.put(
          schema,
          "oneOf",
          Enum.filter(branches, fn branch ->
            get_in(branch, ["properties", "action", "const"]) in kept
          end)
        )

      _ ->
        schema
    end
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
