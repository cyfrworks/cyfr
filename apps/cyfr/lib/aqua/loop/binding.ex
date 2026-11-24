# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Binding do
  @moduledoc """
  The one host-side table from a model-visible call to what runs it.

  A model names a tool as `"<tool>.<action>"`; the binding answers what
  that is — a hand (`Aqua.Hands`, run as a child of the pinned authority
  on a local catalyst), a catalog action (dispatched in-chain through the
  one gate), an outside server's tool (`server__tool` to a model, a
  name of `outside_name/1`'s grammar alone, `server:tool` in the soul's
  list), the `ui` event, or an application
  launch — with the canonical operation every policy decision is made
  on: a `files` call inside the storage boundary is the storage
  operation of the same effect, an `execution.run` of a wrapped catalyst
  is the hand it aliases, an `execution.run` of an agent is refused (a
  crew member is asked with `crew.ask`, never launched), and any other
  `execution.run` is a launch the loop hands to `Aqua.Launch` once the
  policy runs it, its arguments as the model wrote them, the
  account it names (`connection`) among them.

  `dispatch/2` runs a hand, a catalog call or an external call under the
  turn's authority from a worker of the loop's, with the turn root as
  lineage and the step's charge identity; a launch and the `ui` event are
  the loop's to handle. `render/2` turns a result into the text
  the model reads.
  """

  alias Aqua.Hands

  defmodule Call do
    @moduledoc "One model-visible call, resolved to what runs it."

    @type kind :: :hand | :catalog | :external | :ui | :launch

    @type t :: %__MODULE__{
            kind: kind(),
            tool: String.t(),
            action: String.t() | nil,
            args: map(),
            target: String.t() | nil,
            model_name: String.t(),
            tool_call_id: String.t() | nil
          }

    @enforce_keys [:kind, :tool, :args]
    defstruct [:kind, :tool, :action, :args, :target, :model_name, :tool_call_id]
  end

  @ui_tool "ui"
  @max_result_bytes 256_000

  # An outside tool's name to a model, `<server>__<tool>`: each part
  # letters, digits, `_` and `-`, neither holding `__`, the server's not
  # ending in `_` and the tool's not beginning with one, so the name holds
  # exactly one `__` and splits there into one key. The server is not
  # `mcp`, whose names Codex keeps for its own, and the tool is neither
  # `resources` nor `prompts`, the spellings of a server's resources and
  # prompts. The whole name is at most 64 characters, the least an API
  # provider CYFR runs documents.
  @server ~r/\A(?!mcp\z)[A-Za-z0-9_-]*[A-Za-z0-9-]\z/
  @tool ~r/\A(?!(?:resources|prompts)\z)[A-Za-z0-9-][A-Za-z0-9_-]*\z/
  @max_outside_name 64

  @doc """
  The name a model is handed an outside server's tool by, for its key
  `server:tool`: `server__tool`, when both names are of that grammar and
  the whole is at most 64 characters, so that one name spells one key on
  every turn and thread; `:error` for any other key.
  """
  @spec outside_name(String.t()) :: {:ok, String.t()} | :error
  def outside_name(key) when is_binary(key) do
    with [server, tool] <- String.split(key, ":", parts: 2),
         name = server <> "__" <> tool,
         true <- outside?(server, tool, name) do
      {:ok, name}
    else
      _ -> :error
    end
  end

  @doc """
  The key `server:tool` a handed outside name (`outside_name/1`) spells;
  `:error` for a name of no other grammar, which is never an outside
  tool's.
  """
  @spec host_name(String.t()) :: {:ok, String.t()} | :error
  def host_name(name) when is_binary(name) do
    with [server, tool] <- String.split(name, "__", parts: 2),
         true <- outside?(server, tool, name) do
      {:ok, server <> ":" <> tool}
    else
      _ -> :error
    end
  end

  defp outside?(server, tool, name),
    do:
      String.length(name) <= @max_outside_name and not String.contains?(server, "__") and
        not String.contains?(tool, "__") and Regex.match?(@server, server) and
        Regex.match?(@tool, tool)

  @doc """
  Resolve one model call. `opts`: `:tool_call_id`. Answers the call with
  its canonical operation, or a refusal the loop records as the call's
  result. A call with an argument the canonical form (`Prima.JCS`) has
  no form for, at any depth, is refused `invalid_argument` before
  anything runs: a null, since an explicit null and an omitted argument
  can be two operations, a decimal number, or an integer past 2^53 - 1.
  """
  @spec resolve(String.t(), map(), keyword()) ::
          {:ok, Call.t()} | {:error, String.t() | {:invalid_argument, String.t()}}
  def resolve(name, args, opts \\ []) when is_binary(name) and is_map(args) do
    tool_call_id = Keyword.get(opts, :tool_call_id)

    result =
      cond do
        refusal = unencodable(name, args) ->
          {:error, refusal}

        name == @ui_tool ->
          {:ok, %Call{kind: :ui, tool: @ui_tool, action: str(args, "action"), args: args}}

        true ->
          resolve_named(name, args)
      end

    case result do
      {:ok, call} -> {:ok, %{call | model_name: name, tool_call_id: tool_call_id}}
      error -> error
    end
  end

  # An outside server's tool by the one name that spells its key
  # (`host_name/1`); any other name is CYFR's own tool, its action named
  # after a dot or carried in its arguments, as every catalog tool's
  # schema declares.
  defp resolve_named(name, args) do
    case host_name(name) do
      {:ok, key} -> {:ok, %Call{kind: :external, tool: key, action: nil, args: args, target: key}}
      :error -> resolve_own(name, String.split(name, ".", parts: 2), args)
    end
  end

  defp resolve_own(_name, [tool, action], args), do: resolve_action(tool, action, args)

  defp resolve_own(name, [tool], args) do
    case Map.pop(args, "action") do
      {action, rest} when is_binary(action) -> resolve_action(tool, action, rest)
      _ -> {:error, "unknown tool: #{name}"}
    end
  end

  # The refusal of the first argument the canonical form refuses, in a
  # sentence the caller can act on, or nil when it takes them all.
  defp unencodable(name, args) do
    case Prima.JCS.encode(args) do
      {:ok, _canonical} ->
        nil

      {:error, {:invalid_value, path, reason}} ->
        argument = Enum.map_join(path, ".", &to_string/1)
        {:invalid_argument, "#{name}: the argument #{argument} #{unencodable(reason)}"}
    end
  end

  defp unencodable(:nil_not_permitted), do: "is null; leave it out or give it a value"

  defp unencodable(:float_not_permitted),
    do: "is a decimal number; give a whole number, or the number as text"

  defp unencodable(:integer_out_of_range), do: "is too large a number; give it as text"
  defp unencodable(_reason), do: "is a value no call carries"

  defp resolve_action("execution", action, args) when action in ["run", "run_stream"] do
    reference = str(args, "reference")
    input = Map.get(args, "input") || %{}

    cond do
      Prima.AgentRef.agent_ref?(reference) ->
        {:error, "an agent is never run: ask a crew member with crew.ask instead"}

      true ->
        case Hands.canonical(reference, if(is_map(input), do: input, else: %{})) do
          {:ok, [%{tool: tool, action: canonical_action, args: canonical_args} | _]} ->
            {:ok,
             %Call{
               kind: :hand,
               tool: tool,
               action: canonical_action,
               args: canonical_args,
               target: Hands.catalyst_for(tool)
             }}

          {:error, :not_virtual} ->
            {:ok,
             %Call{
               kind: :launch,
               tool: "execution",
               action: action,
               args: args,
               target: reference
             }}

          {:error, :unknown_operation} ->
            {:error, "#{reference} does not know that operation"}
        end
    end
  end

  defp resolve_action("request_setup", "open", args),
    do: {:ok, %Call{kind: :ui, tool: "request_setup", action: "open", args: args}}

  defp resolve_action("files", action, args) do
    case Hands.canonical_files(action, args) do
      # A component's source is host-side: the files catalyst's grant is
      # `data/`, so the path never belonged to a hand.
      {:ok, %{tool: "source", action: canonical_action, args: canonical_args}} ->
        {:ok,
         %Call{kind: :catalog, tool: "source", action: canonical_action, args: canonical_args}}

      {:ok, %{tool: tool, action: canonical_action, args: canonical_args}} ->
        {:ok,
         %Call{
           kind: :hand,
           tool: tool,
           action: canonical_action,
           args: canonical_args,
           target: Hands.catalyst_for(tool)
         }}

      {:error, :not_a_storage_operation} ->
        {:error, "files.#{action} has no storage equivalent inside data/storage/"}

      {:error, :unknown_operation} ->
        {:error, "unknown files action: #{action}"}
    end
  end

  defp resolve_action(tool, action, args) do
    cond do
      Hands.hand?(tool) ->
        if Map.has_key?(Hands.catalog()[tool].actions, action),
          do:
            {:ok,
             %Call{
               kind: :hand,
               tool: tool,
               action: action,
               args: args,
               target: Hands.catalyst_for(tool)
             }},
          else: {:error, "unknown #{tool} action: #{action}"}

      Aqua.Ops.action_kind(tool, action) ->
        {:ok, %Call{kind: :catalog, tool: tool, action: action, args: args}}

      true ->
        {:error, "unknown tool: #{tool}.#{action}"}
    end
  end

  @doc """
  The catalyst and the input a hand call becomes (`Aqua.Hands.child_call/3`).
  """
  @spec child_input(Call.t()) ::
          {:ok, %{catalyst: String.t(), input: map()}} | {:error, String.t()}
  def child_input(%Call{kind: :hand, tool: tool, action: action, args: args}),
    do: Hands.child_call(tool, action, args)

  def child_input(%Call{kind: kind}), do: {:error, "a #{kind} call builds no catalyst input"}

  @doc """
  Run a resolved call under the turn's authority. `dispatch`:
  `:ctx` (guest-planed), `:authority`, `:root_execution_id`,
  `:thread_id`, `:charge` (the step's charge map),
  `:execution_id` (a hand's pre-minted child id), `:step_id`, `:call_id`
  (the admission the root's row was started under, the parent call of a
  catalog or external call; nil when none was recorded). A hand runs
  as a child of the root on its catalyst; a catalog or external call goes
  in-chain through the one gate. A launch and the `ui` event are not
  dispatched here.
  """
  @spec dispatch(Call.t(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(%Call{kind: :hand} = call, dispatch) do
    with {:ok, %{catalyst: catalyst, input: input}} <- child_input(call) do
      Opus.run_child(
        Map.fetch!(dispatch, :authority),
        catalyst,
        nil,
        input,
        ctx: Map.fetch!(dispatch, :ctx),
        execution_id: Map.get(dispatch, :execution_id),
        step_id: Map.get(dispatch, :step_id),
        parent_execution_id: Map.fetch!(dispatch, :root_execution_id),
        root_execution_id: Map.fetch!(dispatch, :root_execution_id),
        declared_needs: [],
        retention_class: "chat_step",
        charge: Map.get(dispatch, :charge),
        guest_fn: :spawn
      )
    end
  end

  def dispatch(%Call{kind: kind} = call, dispatch) when kind in [:catalog, :external] do
    args =
      case call.action do
        nil -> call.args
        action -> Map.put(call.args, "action", action)
      end

    Aqua.Ops.call_in_chain(
      call.tool,
      Map.fetch!(dispatch, :ctx),
      args,
      Map.fetch!(dispatch, :authority),
      lineage: %{
        parent_execution_id: Map.fetch!(dispatch, :root_execution_id),
        root_execution_id: Map.fetch!(dispatch, :root_execution_id),
        attempt: Map.get(dispatch, :attempt),
        thread_id: Map.get(dispatch, :thread_id),
        # The admission the turn's root execution was started under, read
        # off its row: the parent call of every call the turn makes.
        call_id: Map.get(dispatch, :call_id)
      },
      charge: Map.get(dispatch, :charge),
      cancel_handle: Map.get(dispatch, :cancel_handle),
      execution_id: Map.get(dispatch, :execution_id),
      step: Map.get(dispatch, :step),
      retention_class: "chat_step",
      runner: :supervised,
      guest_fn: :spawn
    )
  end

  def dispatch(%Call{kind: kind}, _dispatch), do: {:error, {:not_dispatchable, kind}}

  @doc """
  The text a result becomes for the model. A catalyst's answer is its
  `data`; a catalog or external answer is pretty JSON; an error names its
  source. The projection copy is bounded (`max_result_bytes/0`); the
  canonical row keeps the digest and size of the whole.
  """
  @spec render(Call.t(), {:ok, term()} | {:error, term()}) :: %{
          text: String.t(),
          is_error: boolean()
        }
  def render(%Call{kind: :hand}, {:ok, %{output: output}}),
    do: %{text: bounded(unwrap_data(output)), is_error: false}

  def render(%Call{kind: :hand}, {:ok, output}),
    do: %{text: bounded(unwrap_data(output)), is_error: false}

  def render(%Call{kind: :external, target: server}, {:error, reason}),
    do: %{
      text: bounded("Error from external server '#{server}': #{Aqua.Ops.render_refusal(reason)}"),
      is_error: true
    }

  def render(%Call{}, {:error, reason}),
    do: %{text: bounded("Error: " <> Aqua.Ops.render_refusal(reason)), is_error: true}

  def render(%Call{}, {:ok, result}), do: %{text: bounded(to_text(result)), is_error: false}

  @doc "The bound on a rendered result's bytes in the projection."
  def max_result_bytes, do: @max_result_bytes

  @doc "The charge identity of a step's dispatch, bound to the turn's attempt."
  @spec charge(map(), map()) :: map()
  def charge(step, turn) do
    %{
      id: "#{step.idempotency_key}:g#{step.generation}",
      attempt: turn.attempt,
      generation: step.generation,
      holder_execution_id: step.child_execution_id
    }
  end

  defp unwrap_data(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> unwrap_data(decoded)
      _ -> output
    end
  end

  defp unwrap_data(%{"data" => data}), do: to_text(data)
  defp unwrap_data(%{"error" => error}), do: "Error: " <> to_text(error)
  defp unwrap_data(other), do: to_text(other)

  defp to_text(text) when is_binary(text), do: text
  defp to_text(nil), do: ""
  defp to_text(value), do: Jason.encode!(value, pretty: true)

  defp bounded(text) when byte_size(text) <= @max_result_bytes, do: text

  defp bounded(text) do
    kept = binary_part(text, 0, @max_result_bytes)
    kept <> "\n…[truncated: #{byte_size(text) - @max_result_bytes} more bytes]"
  end

  defp str(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end
end
