# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Host.Children do
  @moduledoc """
  The host calls a formula's runner makes for its guest's children and
  catalog tools: `admit_child` and `tool_call` (`Cyfr.HostAPI`).

  `Cyfr.Execution.Host` verifies the call, decodes its body
  (`operation/2`) and checks its nonce before `call/2` acts. Both act under
  what CYFR holds for the calling attempt (`Cyfr.Execution.Attempt`): the
  authority its run was admitted under, the context its guest's calls run
  in, its root, the declared needs and activation digest the resolver gave
  its component, and the delegation roster its admitted input carries. The
  runner's copy of the authority, of the formula's input and of its
  lineage is never read: nothing in a body stands in for them, and the
  lineage is the verified header's. The calling attempt must be held by
  the calling runner and live, with no cancel asked of it and its execution
  running (`Arca.ExecutionAttempts.live?/4`); otherwise the call is `lost`.

  ## admit_child

  The child's input is checked against the formula's roster
  (`Cyfr.Execution.Delegation.input/4`), then the child is admitted for the
  calling runner (`Cyfr.Execution.admit_child/5`): the formula's authority
  is stepped, a spawn's charge is taken, the child's limits, rates, policy
  and attestation are applied, its row is admitted under the formula
  attempt's barrier, and its attempt is claimed for the calling runner, its
  vault edge unsealed and handed to that runner. The answer carries the
  child's signed assignment, its attempt's keys sealed with the calling
  attempt's seal key (`Cyfr.WorkerAuth.seal_attempt_keys/3`), the JSON of
  the input it was admitted with, which its assignment's `input_digest`
  binds, and its vault fields. The child runs in the calling runner, which
  closes its attempt;
  its execution slot, invoke-budget slot and charge row go back at its
  terminal write.

  ## tool_call

  The tool runs through the catalog's in-chain entry
  (`Cyfr.Ops.Catalog.call_in_chain/5`) under the attempt's authority and
  context, with the header's execution as its parent, the attempt's root
  and the header's attempt as its lineage. A setup refusal is announced on
  the root's event stream. The answer is the tool's result.

  ## Refusals

  A refusal of the child or of the tool is answered as the error a
  formula's invoke functions hand their guest:
  `{:guest_error, type, message}`, and
  `{:guest_error, "setup_required", message, remediation}` for a setup
  refusal (`Cyfr.Remediation`). An internal term never reaches a message.
  """

  require Logger

  alias Cyfr.Execution.{Attempt, Delegation, Events, Keys}
  alias Cyfr.WorkerAuth

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation, :service]
  @guest_fns %{"call" => :call, "spawn" => :spawn}

  @typedoc "A decoded `admit_child` or `tool_call` body."
  @type op ::
          {:admit_child,
           %{reference: String.t(), need: term(), input: map(), guest_fn: :call | :spawn}}
          | {:tool_call, %{name: String.t(), args: map(), guest_fn: :call | :spawn}}

  @doc "The operation a host call body's `op` and `args` name, or `{:error, :lost}`."
  @spec operation(String.t(), map()) :: {:ok, op()} | {:error, :lost}
  def operation("admit_child", %{"reference" => reference, "input" => %{} = input} = args)
      when is_binary(reference) do
    with {:ok, guest_fn} <- guest_fn(args) do
      {:ok,
       {:admit_child,
        %{reference: reference, need: Map.get(args, "need"), input: input, guest_fn: guest_fn}}}
    end
  end

  def operation("tool_call", %{"name" => name, "args" => %{} = tool_args} = args)
      when is_binary(name) do
    with {:ok, guest_fn} <- guest_fn(args) do
      {:ok, {:tool_call, %{name: name, args: tool_args, guest_fn: guest_fn}}}
    end
  end

  def operation(_op, _args), do: {:error, :lost}

  defp guest_fn(%{"guest_fn" => name}) when is_map_key(@guest_fns, name),
    do: {:ok, Map.fetch!(@guest_fns, name)}

  defp guest_fn(_args), do: {:error, :lost}

  @doc """
  Run a decoded operation for `caller`, the verified header of a host call
  from the formula's runner. Answers `{:ok, value}` for the host call's
  answer, a guest error refusal, or `{:error, :lost | :unavailable}`.
  """
  @spec call(Attempt.caller(), op()) :: {:ok, term()} | {:error, term()}
  def call(caller, {:admit_child, child}) do
    with {:ok, chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      case admit(caller, chain, child) do
        {:ok, claimed} -> answer_child(caller, claimed)
        {:error, reason} -> {:error, child_refusal(reason)}
      end
    end
  end

  def call(caller, {:tool_call, tool}) do
    with {:ok, chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      lineage = %{
        parent_execution_id: caller.execution_id,
        root_execution_id: chain.root_execution_id,
        attempt: caller.attempt
      }

      case Cyfr.Ops.Catalog.call_in_chain(tool.name, chain.ctx, tool.args, chain.authority,
             guest_fn: tool.guest_fn,
             lineage: lineage
           ) do
        {:ok, result} -> tool_result(result)
        {:error, reason} -> {:error, tool_refusal(reason, chain)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # admit_child
  # ---------------------------------------------------------------------------

  defp admit(caller, chain, child) do
    with {:ok, input} <-
           Delegation.input(child.reference, child.input, chain.component_ref, chain.roster),
         {:ok, claimed} <-
           Cyfr.Execution.admit_child(chain.authority, child.reference, child.need, input,
             ctx: chain.ctx,
             parent_execution_id: caller.execution_id,
             root_execution_id: chain.root_execution_id,
             attempt: caller.attempt,
             guest_fn: child.guest_fn,
             declared_needs: chain.declared_needs,
             activation_digest: chain.activation_digest,
             runner: caller.runner,
             service_id: caller.service,
             boot_id: caller.boot,
             worker: chain.worker
           ) do
      {:ok, Map.put(claimed, :input, input)}
    end
  end

  # The child's keys cross sealed under the calling attempt's seal key,
  # which only CYFR and the calling runner hold. Its input crosses as the
  # bytes its assignment's digest binds.
  defp answer_child(caller, claimed) do
    with {:ok, keys} <- Keys.attempt_keys(Map.take(caller, @attempt_fields)),
         {:ok, sealed} <- WorkerAuth.seal_attempt_keys(keys.seal, claimed.attempt_keys) do
      {:ok,
       %{
         "assignment" => claimed.assignment,
         "attempt_keys" => sealed,
         "input" => Jason.encode!(claimed.input),
         "secrets" => claimed.secrets
       }}
    else
      {:error, reason} ->
        Logger.error(
          "[Cyfr.Execution.Host.Children] a child of #{caller.execution_id} was admitted but " <>
            "its keys could not be sealed: #{inspect(reason)}"
        )

        {:error, :lost}
    end
  end

  defp child_refusal({:delegation_refused, why}),
    do: guest_error(:tool_denied, "Invocation denied: #{why}")

  defp child_refusal({:invoke_denied, reason})
       when reason in [:depth_cap, :invoke_budget_exhausted],
       do: guest_error(:resource_limit, "Invocation denied: #{reason}")

  defp child_refusal({:invoke_denied, {:need, why}}),
    do: guest_error(:invalid_request, "Invocation denied: need #{guest_reason(why)}")

  defp child_refusal({:invoke_denied, reason}),
    do: guest_error(:tool_denied, "Invocation denied: #{guest_reason(reason)}")

  defp child_refusal({:invoke_invalid, reason}),
    do: guest_error(:invalid_request, "Invalid invocation: #{guest_reason(reason)}")

  defp child_refusal({:invalid_need, need}),
    do: guest_error(:invalid_request, "Invalid need: #{guest_reason(need)}")

  defp child_refusal({:invalid_reference, reason}),
    do: guest_error(:invalid_request, "Invalid reference: #{guest_reason(reason)}")

  defp child_refusal({:setup_required, %{node_ref: node_ref}} = reason) do
    {:setup_required, remediation} = Cyfr.Remediation.analyze(reason)
    {:guest_error, "setup_required", "Dependency cannot be satisfied: #{node_ref}", remediation}
  end

  defp child_refusal(reason), do: guest_error(:dispatch_error, render(reason))

  # ---------------------------------------------------------------------------
  # tool_call
  # ---------------------------------------------------------------------------

  defp tool_result(result) do
    case Jason.encode(result) do
      {:ok, json} -> {:ok, Jason.Fragment.new(json)}
      {:error, _reason} -> {:error, guest_error(:encoding_error, "Failed to encode response")}
    end
  end

  # The typed setup and consent refusals carry their structural cause, so
  # they are analyzed before they are rendered.
  defp tool_refusal(reason, chain) do
    message = render(reason)

    case Cyfr.Remediation.analyze(reason) do
      {:setup_required, remediation} ->
        announce_setup(chain, remediation, message)
        {:guest_error, "setup_required", message, remediation}

      :not_setup_error ->
        guest_error(:dispatch_error, message)
    end
  end

  defp announce_setup(chain, remediation, message) do
    _ =
      Events.push(
        chain.root_execution_id,
        %{
          "kind" => "setup_required",
          "component_ref" => remediation["component_ref"],
          "issues" => remediation["issues"],
          "setup_command" => remediation["setup_command"],
          "message" => message
        },
        chain.ctx,
        origin: "host"
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Guest errors
  # ---------------------------------------------------------------------------

  defp guest_error(type, message), do: {:guest_error, Atom.to_string(type), message}

  # A refusal's one sentence (`Cyfr.Ops.Error.render/1`); an internal term
  # is never rendered.
  defp render(reason), do: Cyfr.Ops.Error.render(reason) || "The call failed."

  # A bare reason atom names itself verbatim: the transition's denial tokens
  # (`edge_only`, `depth_cap`) are what a guest branches on.
  defp guest_reason(reason) when is_binary(reason), do: reason
  defp guest_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp guest_reason(reason) do
    case Cyfr.Ops.Error.render(reason) do
      nil ->
        Logger.warning(
          "[Cyfr.Execution.Host.Children] unrenderable guest reason: #{inspect(reason)}"
        )

        "the call failed"

      message ->
        message
    end
  end
end
