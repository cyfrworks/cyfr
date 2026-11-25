# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Operation do
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

  `resource` names the argument that names the resource an action touches
  and that resource's kind, `{"path", :storage_path}`,
  `{"domain", :egress_domain}` or `{"program", :program_row}`, a program
  row's id (`resource_kinds/0`). It is validated at
  declaration: the argument must be one of the action's own string
  arguments. A request's preview names the resource it touches by it
  (`Sanctum.Catalog.action_declaration/1`). Like `resource_schemes`, it
  is metadata for the gate, absent from the annotation view and from
  discovery.

  `reduces_authority` marks an action that only takes authority away:
  signing out, revoking, withdrawing consent, leaving, removing a member,
  denying someone at a door, unlinking a door, archiving. While the home's
  storage reserve is depleted (`Cyfr.StorageReserve`) the gate admits
  these, reads and the confirmations they need, and nothing else. It is
  metadata for the gate too, absent from the annotation view and from
  discovery.

  `threads` is `{module, function}` for an action whose answer may carry
  a thread's posts: `function` reads, from the actor and the answer, the
  ids of the threads whose posts it carries, so that deleting one of
  them finds the run that read it. An action that declares none carries
  no thread's posts. `read_threads/3` is the one rule every caller that
  joins a catalog call's read threads reads. Like `resource`, it is
  metadata for the gate, absent from the annotation view and from
  discovery.

  `follows_setting: true` marks an action that follows the person's own
  browser setting: with the setting off the action is refused, and with
  it on it is decided as any offered call
  (`Aqua.BrowserSetting`). It is admitted for the browser tool's in-chain
  actions alone (`validate!/1`). It is metadata for the gate, absent from
  the annotation view and from discovery.

  `recorded: false` marks a read whose admitted call the gate's decision
  audit leaves out (`Sanctum.Catalog.recorded?/2`): discovery, the audit's
  own reads, and the reads the shell makes of the caller's own state on
  its own initiative. Only a read may be unrecorded; a refusal of any
  action is recorded whatever it declares. It is metadata for the gate,
  absent from the annotation view and from discovery.

  `waits: true` marks a call that waits on something outside itself, a
  run's end or a time, as long as that takes. The gate gives it no
  handler timeout and no holder window, so its charge has no
  `holder_deadline` and its attempt's end reclaims it
  (`Sanctum.Dispatch`), and a turn's loop wakes it when a post arrives
  (`Aqua.Loop`), which the gate answers early once its handler waits. Everything else that bounds a call bounds it
  too: authorization, the grant, the charge and the attempt's end. Only a
  replay-safe read may wait, since the early answer cancels it and a
  restart dispatches it again. It is metadata for the gate and the loop,
  absent from the annotation view and from discovery. A wait is asked for
  at most `longest_wait_ms/0`, the largest time a timer holds; a longer
  one is refused at its arguments in `wait_too_long/1`'s sentence.

  A wake answers such a call early with `woken_answer/0`, the gate's
  doing once the call's handler says it waits
  (`Sanctum.RunningTasks.wake/1`, `Sanctum.RunningTasks.waiting/0`).
  """

  alias Prima.Arg

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
    :recovery,
    :host,
    :resource,
    :threads,
    auth: :required,
    resource_schemes: [],
    reduces_authority: false,
    follows_setting: false,
    recorded: true,
    waits: false
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
          recovery: :replay_safe | nil,
          host: :intercepted | nil,
          resource: {String.t(), resource_kind()} | nil,
          resource_schemes: [String.t()],
          reduces_authority: boolean(),
          follows_setting: boolean(),
          recorded: boolean(),
          waits: boolean(),
          threads: {module(), atom()} | nil
        }

  @typedoc "The kinds of resource an action's argument may name."
  @type resource_kind :: :storage_path | :egress_domain | :program_row

  @valid_planes [:external, :in_chain]
  @resource_kinds [:storage_path, :egress_domain, :program_row]

  # The largest time an Erlang timer holds, in milliseconds.
  @longest_wait_ms 4_294_967_295

  @doc "The longest a call that waits may be asked to wait, in milliseconds."
  @spec longest_wait_ms() :: pos_integer()
  def longest_wait_ms, do: @longest_wait_ms

  @doc """
  The sentence a wait longer than `longest_wait_ms/0` is refused with,
  naming the argument `field` that asked for it.
  """
  @spec wait_too_long(String.t()) :: String.t()
  def wait_too_long(field) when is_binary(field),
    do:
      "#{field} is further off than a wait holds, #{@longest_wait_ms} ms (about 49 days); " <>
        "make a schedule to be woken later instead"

  @woken_answer "A message arrived, so this wait ended early. What it waited for goes on: " <>
                  "answer the message, and wait again if you still need to."

  @doc """
  What a call that waits answers when a wake ended it early: its one
  definition, which the gate answers with (`Sanctum.Dispatch`).
  """
  @spec woken_answer() :: String.t()
  def woken_answer, do: @woken_answer

  @doc "The kinds of resource a `resource:` declaration may name."
  @spec resource_kinds() :: [resource_kind()]
  def resource_kinds, do: @resource_kinds

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
    :recovery,
    :host
  ]

  @doc "Declare an action, refusing invalid or contradictory declarations."
  @spec new(String.t(), String.t(), String.t(), [Arg.t()], keyword()) :: t()
  def new(tool, action, description, args, opts) do
    unknown =
      Keyword.keys(opts) --
        [
          :resource,
          :resource_schemes,
          :reduces_authority,
          :follows_setting,
          :recorded,
          :waits,
          :threads | @annotation_fields
        ]

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
             op.scope in [nil, :platform] and op.recovery in [nil, :replay_safe] and
             is_boolean(op.reduces_authority) and is_boolean(op.follows_setting) and
             is_boolean(op.recorded) and is_boolean(op.waits) and
             (is_nil(op.permission) or is_atom(op.permission)),
           do: raise(ArgumentError, "invalid operation annotation")

    if op.recovery == :replay_safe and op.kind != :read,
      do: raise(ArgumentError, "only explicitly reviewed reads can be replay-safe")

    if op.reduces_authority and op.kind == :read,
      do: raise(ArgumentError, "a read takes no authority away")

    if not op.recorded and op.kind != :read,
      do: raise(ArgumentError, "only a read may go unrecorded")

    if op.waits and op.recovery != :replay_safe,
      do: raise(ArgumentError, "only a replay-safe read may wait")

    if op.follows_setting and (op.tool != "browser" or op.planes != [:in_chain]),
      do: raise(ArgumentError, "only the browser tool's in-chain actions follow the setting")

    if Enum.any?(op.args, &(&1.name == "action")),
      do: raise(ArgumentError, "action is the operation discriminator")

    _ = Arg.schema(op.args)

    if op.host not in [nil, :intercepted] or
         (op.host == :intercepted and :in_chain in op.planes),
       do: raise(ArgumentError, "intercepted actions must be external")

    if op.scope == :platform and op.planes != [:external],
      do: raise(ArgumentError, "platform actions must be external")

    validate_resource_schemes!(op)
    validate_resource!(op)
    validate_threads!(op)
  end

  @doc """
  The ids of the threads whose posts a call of `op` carries into its
  caller, sorted and without duplicates: for a success of an action that
  declares `threads`, what its function reads from `actor` and the
  answer, when that is a list of thread ids; for anything else, none.
  """
  @spec read_threads(t() | nil, Prima.Actor.t() | nil, term()) :: [String.t()]
  def read_threads(%__MODULE__{threads: {module, function}}, actor, {:ok, answer}) do
    case apply(module, function, [actor, answer]) do
      ids when is_list(ids) ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
          do: ids |> Enum.uniq() |> Enum.sort(),
          else: []

      _unreadable ->
        []
    end
  end

  def read_threads(_op, _actor, _result), do: []

  defp validate_threads!(%__MODULE__{threads: nil}), do: :ok

  defp validate_threads!(%__MODULE__{threads: {module, function}})
       when is_atom(module) and is_atom(function),
       do: :ok

  defp validate_threads!(%__MODULE__{}),
    do: raise(ArgumentError, "threads must be {module, function}")

  defp validate_resource!(%__MODULE__{resource: nil}), do: :ok

  defp validate_resource!(%__MODULE__{resource: {name, kind}, args: args})
       when is_binary(name) and kind in @resource_kinds do
    case Enum.find(args, &(&1.name == name)) do
      %Arg{type: :string} -> :ok
      %Arg{} -> raise ArgumentError, "the resource argument #{name} must be a string"
      nil -> raise ArgumentError, "the resource names an argument the action lacks: #{name}"
    end
  end

  defp validate_resource!(%__MODULE__{}),
    do:
      raise(
        ArgumentError,
        "a resource is {argument, :storage_path | :egress_domain | :program_row}"
      )

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

  @doc """
  A call's arguments as a log records them (`Prima.Arg.logged/2`) under
  the declaration of the action it names: bulk content measured, never
  kept. A call naming no declared action is returned as it is.
  """
  @spec logged(map(), term()) :: term()
  def logged(%{operations: operations}, %{} = input) when not is_struct(input) do
    case Enum.find(operations, &(&1.action == Map.get(input, "action"))) do
      nil -> input
      operation -> Arg.logged(operation.args, input)
    end
  end

  def logged(_definition, input), do: input
end
