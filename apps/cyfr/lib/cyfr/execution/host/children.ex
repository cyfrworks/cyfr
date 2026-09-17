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

  The body names the child's `child_key`, the key the runner minted for
  it (`t:Cyfr.HostAPI.child_key/0`); a body without one, or with a
  malformed one, is refused as a guest error before anything is read. The
  child's input is checked against the formula's roster
  (`Cyfr.Execution.Delegation.input/4`), then the child is admitted for the
  calling runner under that key (`Cyfr.Execution.admit_child/5`): the
  formula's authority is stepped, a spawn's charge is taken, the child's
  limits, rates, policy and attestation are applied, its row is admitted
  under the formula attempt's barrier carrying the key, and its attempt is
  claimed for the calling runner, its vault edge unsealed and handed to
  that runner. The answer carries the child's signed assignment, its
  attempt's keys sealed with the calling attempt's seal key
  (`Cyfr.WorkerAuth.seal_attempt_keys/3`), the JSON of the input it was
  admitted with, which its assignment's `input_digest` binds, and its
  vault fields. The child runs in the calling runner, which closes its
  attempt; its execution slot, invoke-budget slot and charge row go back
  at its terminal write.

  A repeat with the same key — a runner retrying a lost answer
  (`Cyfr.HostAPI.retry/1`, `:keyed`) — admits nothing and answers the child
  already admitted under it, decided by its row: the same child, its
  assignment signed afresh, its keys and the input it was admitted with. A
  key whose child has ended is `lost`; a different key admits another
  child.

  ## tool_call

  The tool runs through the catalog's in-chain entry
  (`Cyfr.Ops.Catalog.call_in_chain/5`) under the attempt's authority and
  context, with the header's execution as its parent, the attempt's root
  and the header's attempt as its lineage. A setup refusal is announced on
  the root's event stream. The answer is the tool's result.

  ## release_child

  A child the runner was handed but could not start (its keys did not open,
  its assignment did not read) is given back by its parent: for a child of
  the calling execution that the calling runner claims on its boot and that
  still runs, CYFR closes it failed and releases what it held, once. A
  child that already ended answers `:ok` too, so a repeat is harmless; any
  other execution is `lost`. A child whose keys CYFR itself could not seal
  is closed the same way before the refusal is answered, so no admitted
  child waits for its lease.

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
  @not_started "Execution refused: its runner could not start"
  @not_sealed "Execution refused: its keys could not be sealed for its runner"

  @typedoc "A decoded `admit_child`, `tool_call` or `release_child` body."
  @type op ::
          {:admit_child,
           %{
             reference: String.t(),
             need: term(),
             input: map(),
             guest_fn: :call | :spawn,
             child_key: Cyfr.HostAPI.child_key()
           }}
          | {:tool_call, %{name: String.t(), args: map(), guest_fn: :call | :spawn}}
          | {:release_child, String.t()}

  @doc """
  The operation a host call body's `op` and `args` name, `{:error, :lost}`
  for one that is not an operation, or the guest error an `admit_child`
  without a well-formed `child_key` is refused with.
  """
  @spec operation(String.t(), map()) :: {:ok, op()} | {:error, :lost | Cyfr.HostAPI.guest_error()}
  def operation("admit_child", %{"reference" => reference, "input" => %{} = input} = args)
      when is_binary(reference) do
    with {:ok, guest_fn} <- guest_fn(args),
         {:ok, child_key} <- child_key(args) do
      {:ok,
       {:admit_child,
        %{
          reference: reference,
          need: Map.get(args, "need"),
          input: input,
          guest_fn: guest_fn,
          child_key: child_key
        }}}
    end
  end

  def operation("tool_call", %{"name" => name, "args" => %{} = tool_args} = args)
      when is_binary(name) do
    with {:ok, guest_fn} <- guest_fn(args) do
      {:ok, {:tool_call, %{name: name, args: tool_args, guest_fn: guest_fn}}}
    end
  end

  def operation("release_child", %{"execution_id" => id}) when is_binary(id) and id != "",
    do: {:ok, {:release_child, id}}

  def operation(_op, _args), do: {:error, :lost}

  defp guest_fn(%{"guest_fn" => name}) when is_map_key(@guest_fns, name),
    do: {:ok, Map.fetch!(@guest_fns, name)}

  defp guest_fn(_args), do: {:error, :lost}

  # The key is the runner's, so a runner that sends none, or one outside
  # the contract's shape, is told so rather than losing its attempt.
  defp child_key(%{"child_key" => key}) do
    if Cyfr.HostAPI.valid_child_key?(key),
      do: {:ok, key},
      else: {:error, guest_error(:invalid_request, "Invalid child_key: not a child key")}
  end

  defp child_key(_args),
    do: {:error, guest_error(:invalid_request, "Invalid child_key: a child needs one")}

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
        {:error, reason} when reason in [:lost, :unavailable] -> {:error, reason}
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

  def call(caller, {:release_child, child_id}) do
    with {:ok, chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      release(caller, chain, child_id)
    end
  end

  # ---------------------------------------------------------------------------
  # release_child
  # ---------------------------------------------------------------------------

  # The child is the caller's to give back only while it is the caller's:
  # admitted under this execution, claimed by this runner on this service
  # and boot, and still running. Its attempt closes it failed, releasing
  # its slot, invoke slot and charge, and the waiter hears the refusal.
  defp release(caller, chain, child_id) do
    with %Arca.Execution{parent_execution_id: parent} <-
           Arca.Execution.get_tenant(chain.ctx, child_id),
         true <- parent == caller.execution_id do
      case Arca.ExecutionAttempts.current(chain.ctx.athanor_id, child_id) do
        %{state: "running", claimed_by: runner, service_id: service, boot_id: boot}
        when runner == caller.runner and service == caller.service and boot == caller.boot ->
          refuse_child(child_id, @not_started)

        %{state: state} when state in ["completed", "failed", "cancelled", "lapsed"] ->
          {:ok, true}

        _ ->
          {:error, :lost}
      end
    else
      _ -> {:error, :lost}
    end
  end

  defp refuse_child(child_id, sentence) do
    case Attempt.whereis(child_id) do
      nil ->
        {:error, :lost}

      pid ->
        :closed = Attempt.release(pid, sentence)
        {:ok, true}
    end
  end

  # ---------------------------------------------------------------------------
  # admit_child
  # ---------------------------------------------------------------------------

  # The answer's input is the one CYFR admitted the child with: on a
  # repeat under the key, the one recorded, not what the retry carries.
  defp admit(caller, chain, child) do
    with {:ok, input} <-
           Delegation.input(child.reference, child.input, chain.component_ref, chain.roster) do
      Cyfr.Execution.admit_child(chain.authority, child.reference, child.need, input,
        ctx: chain.ctx,
        parent_execution_id: caller.execution_id,
        root_execution_id: chain.root_execution_id,
        attempt: caller.attempt,
        guest_fn: child.guest_fn,
        child_key: child.child_key,
        declared_needs: chain.declared_needs,
        activation_digest: chain.activation_digest,
        runner: caller.runner,
        service_id: caller.service,
        boot_id: caller.boot,
        worker: chain.worker,
        parent_deadline: chain.deadline
      )
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

        # The child never reaches its runner: close it now rather than
        # leaving its slot, invoke slot and charge to the lease.
        _ = refuse_child(claimed.attempt_keys.attempt.execution_id, @not_sealed)
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
