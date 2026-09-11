# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Binding do
  @moduledoc """
  The one host-side table from a model-visible call to what runs it.

  A model names a tool as `"<tool>.<action>"`; the binding answers what
  that is — a hand (`Aqua.Hands`, run as a child of the pinned authority
  on a local catalyst), a catalog action (dispatched in-chain through the
  one gate), an external server's tool (`server__tool` on the wire,
  `server:tool` in the catalog), a role to clone into, the `ui` event, or
  an application launch — with the canonical operation every policy
  decision is made on: a `files` call inside the storage boundary is the
  storage operation of the same effect, an `execution.run` of a wrapped
  catalyst is the hand it aliases, an `execution.run` of an agent is
  refused (a role is cloned, never launched), and any other
  `execution.run` is a launch the loop hands to `Aqua.Launch` after a
  card.

  `dispatch/2` runs a hand, a catalog call or an external call under the
  turn's authority from a worker of the loop's, with the turn root as
  lineage and the step's charge identity; a launch, a clone and the `ui`
  event are the loop's to handle. `render/2` turns a result into the text
  the model reads.
  """

  alias Aqua.Hands
  alias Sanctum.Context

  defmodule Call do
    @moduledoc "One model-visible call, resolved to what runs it."

    @type kind :: :hand | :catalog | :external | :clone | :ui | :launch

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

  @doc "The wire spelling of a catalog tool name: `server:tool` becomes `server__tool`."
  @spec model_name(String.t()) :: String.t()
  def model_name(tool) when is_binary(tool), do: String.replace(tool, ":", "__")

  @doc "The catalog spelling of a model-visible tool name."
  @spec host_name(String.t()) :: String.t()
  def host_name(name) when is_binary(name), do: String.replace(name, "__", ":")

  @doc """
  Resolve one model call. `opts`: `:roles` (the role names the soul may
  clone into), `:tool_call_id`. Answers the call with its canonical
  operation, or a refusal the loop records as the call's result.
  """
  @spec resolve(String.t(), map(), keyword()) :: {:ok, Call.t()} | {:error, String.t()}
  def resolve(name, args, opts \\ []) when is_binary(name) and is_map(args) do
    roles = Keyword.get(opts, :roles, [])
    tool_call_id = Keyword.get(opts, :tool_call_id)

    result =
      cond do
        name in roles ->
          {:ok, %Call{kind: :clone, tool: name, action: "clone", args: args, target: name}}

        name == @ui_tool ->
          {:ok, %Call{kind: :ui, tool: @ui_tool, action: str(args, "action"), args: args}}

        String.contains?(name, "__") ->
          {:ok,
           %Call{
             kind: :external,
             tool: host_name(name),
             action: nil,
             args: args,
             target: host_name(name)
           }}

        true ->
          case String.split(name, ".", parts: 2) do
            [tool, action] ->
              resolve_action(tool, action, args)

            [tool] ->
              # The model names the tool and carries the action in its
              # arguments, as every catalog tool's schema declares.
              case Map.pop(args, "action") do
                {action, rest} when is_binary(action) -> resolve_action(tool, action, rest)
                _ -> {:error, "unknown tool: #{name}"}
              end
          end
      end

    case result do
      {:ok, call} -> {:ok, %{call | model_name: name, tool_call_id: tool_call_id}}
      error -> error
    end
  end

  defp resolve_action("execution", action, args) when action in ["run", "run_stream"] do
    reference = str(args, "reference")
    input = Map.get(args, "input") || %{}

    cond do
      Compendium.AgentSource.agent_ref?(reference) ->
        {:error, "an agent is cloned as a role, never run: name the role instead"}

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
  `:conversation_id`, `:agent_ref`, `:charge` (the step's charge map),
  `:execution_id` (a hand's pre-minted child id), `:step_id`. A hand runs
  as a child of the root on its catalyst; a catalog or external call goes
  in-chain through the one gate. A launch, a clone and the `ui` event are
  not dispatched here.
  """
  @spec dispatch(Call.t(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(%Call{kind: :hand} = call, dispatch) do
    with {:ok, %{catalyst: catalyst, input: input}} <- child_input(call) do
      Cyfr.Execution.run_child(
        Map.fetch!(dispatch, :authority),
        catalyst,
        nil,
        input,
        ctx: Map.fetch!(dispatch, :ctx),
        execution_id: Map.get(dispatch, :execution_id),
        step_id: Map.get(dispatch, :step_id),
        parent_execution_id: Map.fetch!(dispatch, :root_execution_id),
        root_execution_id: Map.fetch!(dispatch, :root_execution_id),
        parent_reference: Map.get(dispatch, :agent_ref),
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
        conversation_id: Map.get(dispatch, :conversation_id)
      },
      charge: Map.get(dispatch, :charge),
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

  @doc false
  def guest?(%Context{plane: :guest}), do: true
  def guest?(_), do: false
end
