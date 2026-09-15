# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Assignments do
  @moduledoc """
  The signed assignment of an admitted execution attempt, and the keys its
  runner signs and seals host calls with.

  `issue/1` builds a `Cyfr.Assignment` from what admission settled and
  signs it with the assign key (`Cyfr.Execution.Keys`). The runner presents
  the token at attach (`Cyfr.Execution.Host`), which verifies it, checks
  it names the attempt its header does and claims the attempt.

  An assignment is issued under the current generation
  (`Cyfr.Execution.Keys.generation/0`), to the worker service it is
  dispatched to as its audience, and may be claimed for 30 seconds after
  it is issued. Its deadline is its timeout from issue, and its lease runs
  one lease period from issue. Its attempt's keys are bound to that worker
  service as well as to the attempt, its fence and its generation.
  """

  alias Cyfr.{Actor, Assignment, Authority}
  alias Cyfr.Execution.{Keys, Record}
  alias Sanctum.Context

  @claim_window_ms 30_000

  @typedoc """
  What an assignment is built from: the admission context, the admitted
  row, the run's authority, its component (`ref`, `type`, `digest`,
  `declared_needs`, `activation_digest`), its input, its consented timeout,
  the boot id of the worker service it is dispatched to and the turn step
  that dispatched it (nil when none did).
  """
  @type admitted :: %{
          required(:ctx) => Context.t(),
          required(:record) => Record.t(),
          required(:authority) => Authority.t(),
          required(:component) => Assignment.component(),
          required(:input) => map(),
          required(:timeout_ms) => pos_integer(),
          required(:audience) => String.t(),
          optional(:step) => Assignment.step() | nil
        }

  @typedoc """
  An issued assignment: its token and its attempt's keys, naming the
  attempt as a host call header carries it.
  """
  @type issued :: %{assignment: Assignment.token(), attempt_keys: Cyfr.WorkerAuth.attempt_keys()}

  @doc """
  Sign the assignment of the admitted attempt at fence 1. Answers
  `{:error, :unavailable}` when the control-plane generation is not known
  (`Cyfr.Execution.Keys.generation/0`), and `{:error, reason}` when what
  admission settled is not a valid assignment (`Cyfr.Assignment.sign/2`).
  """
  @spec issue(admitted()) :: {:ok, issued()} | {:error, term()}
  def issue(%{record: %Record{} = record} = admitted) do
    with {:ok, generation} <- Keys.generation() do
      sign(admitted, record, generation)
    end
  end

  defp sign(admitted, record, generation) do
    now = System.system_time(:millisecond)

    attempt = %{
      athanor_id: record.athanor_id,
      execution_id: record.id,
      attempt: record.attempt,
      fence: 1,
      generation: generation,
      worker: admitted.audience
    }

    assignment = %Assignment{
      generation: attempt.generation,
      audience: admitted.audience,
      issued_at: now,
      claim_by: now + @claim_window_ms,
      execution_id: record.id,
      attempt: record.attempt,
      fence: attempt.fence,
      parent_execution_id: record.parent_execution_id,
      root_execution_id: record.root_execution_id || record.id,
      step: Map.get(admitted, :step),
      athanor_id: record.athanor_id,
      actor: actor(admitted.ctx),
      authority: Authority.to_wire(admitted.authority),
      component: admitted.component,
      input_digest: Cyfr.Digest.sha256(Jason.encode!(admitted.input)),
      timeout_ms: admitted.timeout_ms,
      deadline: now + admitted.timeout_ms,
      lease_until: now + Arca.ExecutionAttempts.lease_seconds() * 1000,
      intercepted: Cyfr.Ops.Catalog.host_intercepted_actions()
    }

    with {:ok, token} <- Assignment.sign(assignment, Keys.assign_key()),
         {:ok, keys} <- Keys.attempt_keys(attempt) do
      {:ok, %{assignment: token, attempt_keys: keys}}
    end
  end

  defp actor(%Context{} = ctx) do
    %Actor{
      user_id: present(ctx.user_id),
      request_id: present(ctx.request_id),
      authenticated: ctx.authenticated == true,
      client_ip: present(ctx.client_ip)
    }
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
