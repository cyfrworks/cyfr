# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Host do
  @moduledoc """
  Where a runner's host calls reach CYFR: `attach`, `renew`, `complete`,
  `fail`, `push_deltas`, `oauth_token`, `take_rate`, `storage`,
  `fetch_artifact`, `record_denial`, `admit_child` and `tool_call`, as
  `Cyfr.HostAPI` describes them.

  `call/2` is the one entry point. It takes a host call's header
  (`Cyfr.WorkerAuth.host_call_header/3`) and its JSON body,
  `{"op": name, "args": {...}}`, and answers JSON. The operation is named
  inside the body, so the header's MAC covers it. The tenant, execution,
  attempt and runner a call acts for come from the verified header, never
  from the body. Over HTTP, `Cyfr.Execution.HostListener` carries the
  header and body here and the answer back; `call/2` verifies the whole
  call itself either way.

  ## Checks, in order

    0. This boot holds the control plane (`Cyfr.ControlPlane.owner?/0`). A
       boot that does not has no attempt to answer for: its open attempts
       stop without closing their runs (`Cyfr.Execution.Attempt`), and the
       rows are the holder's to write.
    1. The header verifies (`Cyfr.WorkerAuth.verify_host_call/5`) under the
       call key of the attempt it names, derived from the worker root, and
       the current generation (`Cyfr.Execution.Keys.generation/0`; one the
       control plane cannot answer refuses every call), and the body is a
       known operation with well-formed arguments.
    2. `attach`: the assignment verifies (`Cyfr.Assignment.verify/3`), it
       names the header's athanor, execution, attempt, fence and
       generation, it is addressed to the header's worker service and
       boot, and the attempt row is claimed for the header's runner
       (`Arca.ExecutionAttempts.claim/4`). The attempt then unseals the
       run's vault edge and audits each field it hands over, once, at the
       attach that claims it (`Cyfr.Execution.Attempt.attach/2`).
    3. `renew`: each named attempt's lease is renewed by one update
       predicated on the header's runner holding it on the header's
       service and boot (`Arca.ExecutionAttempts.renew_held/3`), the
       runner's own attempt and the children it runs alike; one it does
       not hold renews as `lost`.
    4. Every other operation: the header's nonce has not been presented to
       the attempt before, and the attempt row is held by the header's
       runner, before the attempt runs it (`Cyfr.Execution.Attempt.call/3`).
       `admit_child` and `tool_call` act under what the attempt holds
       (`Cyfr.Execution.Host.Children`), and need the row live as well: no
       cancel asked of it and its execution running.

  ## Answers

  `{"ok": value}` on success. A refusal is `{"error": name}`:

    * `lost` — this boot does not hold the control plane, the header does
      not verify, the body is not an operation, the nonce was presented
      before, or the attempt is not open, current, running, at the header's
      fence and claimed by its runner;
    * `unavailable` — the store could not answer;
    * at attach, `malformed`, `bad_mac`, `unknown_version` or
      `claim_expired` for an assignment that does not verify, `replayed`
      when another runner holds the claim, and `setup_required` with its
      `payload` when the run's vault edge cannot be unsealed;
    * `failed` with its `message`, when `complete` closed the run failed;
    * `not_found`, when `fetch_artifact` names no artifact of the attempt's;
    * `guest_error` with its `type` and `message`, and a `remediation` for
      a `setup_required` one, a refusal the runner hands its guest.

  | Operation | `args` | `ok` |
  |---|---|---|
  | `attach` | `assignment` (token) | the run's vault fields, name to value |
  | `renew` | `attempts` (ids) | attempt id to `{"lease_until": ms}` or `"lost"` |
  | `complete` | `outcome` (`status` `completed`, `output`) | `output`, masked |
  | `fail` | `outcome` (`status` `failed`, `error`, optional `abandoned`) | the failure as recorded, masked |
  | `push_deltas` | `deltas` (each `execution_id`, `attempt`, `fence`, `event` text) | one emit reply per delta |
  | `oauth_token` | `provider` | the token |
  | `take_rate` | `bucket` | `true` |
  | `storage` | `action`, `path`, optional `content` | the answer's members |
  | `fetch_artifact` | `digest` | the artifact's bytes, base64 |
  | `record_denial` | `type`, `message` | `true` |
  | `admit_child` | `reference`, optional `need`, `input` (object), `guest_fn` (`call` or `spawn`), `child_key` | `assignment`, `attempt_keys` (sealed), `input` (JSON text), `secrets` |
  | `tool_call` | `name`, `args` (object), `guest_fn` (`call` or `spawn`) | the tool's result |

  An outcome names its `execution_id`, `attempt` and `fence`. `storage`,
  `fetch_artifact` and `record_denial` are `Cyfr.Execution.Host.Storage`'s;
  `admit_child`, `tool_call` and `release_child` are
  `Cyfr.Execution.Host.Children`'s. `admit_child` is keyed: a repeat with
  the same `child_key` answers the child already admitted under it.

  ## A worker service's report

  `runner_exited/2` takes a report's header (`Cyfr.WorkerAuth.report_header/3`)
  and its JSON body,
  `{"op": "runner_exited", "args": {"runner": id, "attempts": [ids]}}`, and
  answers JSON. The header must verify under the dispatch key of the
  worker service it names (`Cyfr.WorkerAuth.verify_report/4`), which only
  that worker service holds; a report is idempotent, so its nonce is not
  checked. Each named attempt dispatched to the reporting service on the
  reporting boot, claimed by the named runner, that still owns its running
  execution is lapsed (`Cyfr.Execution.Lapse`), and the attempt process
  open for each is stopped without closing its run
  (`Cyfr.Execution.Attempt.stop_unclosed/2`). A report from another boot
  of the same service lapses nothing.
  It answers `{"ok": true}`, `{"error": "lost"}` for a report that does not
  verify, and `{"error": "unavailable"}` when this boot does not hold the
  control plane (nothing is lapsed) or the store cannot list the attempts.
  """

  require Logger

  alias Cyfr.{Assignment, Delta, WorkerAuth}
  alias Cyfr.Execution.{Attempt, Keys, Lapse, Outcome}
  alias Cyfr.Execution.Host.Children

  @assignment_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]
  @refusals [
    :lost,
    :unavailable,
    :replayed,
    :malformed,
    :bad_mac,
    :unknown_version,
    :claim_expired,
    :not_found
  ]

  @doc "Answer one host call: `header` and the JSON `body` it signs, answered as JSON."
  @spec call(String.t(), String.t()) :: String.t()
  def call(header, body) when is_binary(header) and is_binary(body) do
    now = System.system_time(:millisecond)

    answer =
      with :ok <- owner(:lost),
           {:ok, caller} <- verify(header, body, now),
           {:ok, op} <- decode(body) do
        dispatch(caller, op, now)
      end

    encode(answer)
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Host] host call raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode({:error, :lost})
  end

  @doc "Answer one worker service report of a runner's exit: `header` and the JSON `body` it signs."
  @spec runner_exited(String.t(), String.t()) :: String.t()
  def runner_exited(header, body) when is_binary(header) and is_binary(body) do
    now = System.system_time(:millisecond)

    answer =
      with :ok <- owner(:unavailable),
           {:ok, report} <- verify_report(header, body, now),
           {:ok, runner, attempts} <- reported_attempts(body),
           :ok <- Lapse.dispatched(report.service, report.boot, runner, attempts) do
        holder = %{service_id: report.service, boot_id: report.boot, runner: runner}
        Enum.each(attempts, &Attempt.stop_unclosed(&1, holder))
      end

    encode(answer)
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.Host] runner exit report raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode({:error, :unavailable})
  end

  defp owner(refusal) do
    if Cyfr.ControlPlane.owner?() do
      :ok
    else
      Logger.warning("[Cyfr.Execution.Host] refused: this boot does not hold the control plane")
      {:error, refusal}
    end
  end

  defp verify_report(header, body, now) do
    case WorkerAuth.verify_report(Keys.root(), header, body, now) do
      {:ok, report} ->
        {:ok, report}

      {:error, reason} ->
        Logger.warning("[Cyfr.Execution.Host] runner exit report refused: #{reason}")
        {:error, :lost}
    end
  end

  defp reported_attempts(body) do
    with {:ok,
          %{"op" => "runner_exited", "args" => %{"runner" => runner, "attempts" => attempts}}}
         when is_binary(runner) and runner != "" and is_list(attempts) <- Jason.decode(body),
         true <- Enum.all?(attempts, &(is_binary(&1) and &1 != "")) do
      {:ok, runner, Enum.uniq(attempts)}
    else
      _ -> {:error, :lost}
    end
  end

  # A generation the control plane cannot answer verifies nothing.
  defp verify(header, body, now) do
    with {:ok, generation} <- Keys.generation(),
         {:ok, caller} <- WorkerAuth.verify_host_call(Keys.root(), header, body, now, generation) do
      {:ok, caller}
    else
      {:error, reason} ->
        Logger.warning("[Cyfr.Execution.Host] host call refused: #{reason}")
        {:error, :lost}
    end
  end

  # ---------------------------------------------------------------------------
  # Operations
  # ---------------------------------------------------------------------------

  defp dispatch(caller, {:attach, token}, now) do
    with {:ok, assignment} <- Assignment.verify(token, Keys.assign_key(), now),
         :ok <- names_caller(assignment, caller),
         :ok <- claim(caller) do
      Attempt.attach(caller.execution_id, caller)
    end
  end

  defp dispatch(caller, {:renew, attempts}, _now) do
    Enum.reduce_while(attempts, {:ok, %{}}, fn attempt, {:ok, renewals} ->
      case renew(caller, attempt) do
        {:ok, renewal} -> {:cont, {:ok, Map.put(renewals, attempt, renewal_wire(renewal))}}
        :unavailable -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp dispatch(caller, {Children, op}, _now), do: Children.call(caller, op)

  defp dispatch(caller, op, _now), do: Attempt.call(caller.execution_id, caller, op)

  defp names_caller(%Assignment{} = assignment, caller) do
    cond do
      not Enum.all?(@assignment_fields, &(Map.fetch!(assignment, &1) == Map.fetch!(caller, &1))) ->
        {:error, :lost}

      assignment.service != caller.service or assignment.boot != caller.boot ->
        Logger.warning(
          "[Cyfr.Execution.Host] attach of #{caller.execution_id} refused: the assignment " <>
            "is addressed to another worker service or another boot of it"
        )

        {:error, :lost}

      true ->
        :ok
    end
  end

  defp claim(caller) do
    case Arca.ExecutionAttempts.claim(
           Cyfr.Actor.in_athanor(caller.athanor_id),
           caller.attempt,
           caller.fence,
           caller.runner
         ) do
      :ok -> :ok
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # A runner renews every attempt it holds on its worker service and boot:
  # its own and the children it runs. Each renewal is one update predicated
  # on that hold, so a stale runner, boot or service renews nothing.
  defp renew(caller, attempt) do
    holder = %{service_id: caller.service, boot_id: caller.boot, runner: caller.runner}

    case Arca.ExecutionAttempts.renew_held(
           Cyfr.Actor.in_athanor(caller.athanor_id),
           attempt,
           holder
         ) do
      {:ok, until} -> {:ok, {:ok, DateTime.to_unix(until, :millisecond)}}
      :lost -> {:ok, :lost}
      {:error, _reason} -> :unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # Wire
  # ---------------------------------------------------------------------------

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"op" => op, "args" => %{} = args}} -> operation(op, args)
      _ -> {:error, :lost}
    end
  end

  defp operation("attach", %{"assignment" => token}) when is_binary(token),
    do: {:ok, {:attach, token}}

  defp operation("renew", %{"attempts" => attempts}) when is_list(attempts) do
    if Enum.all?(attempts, &is_binary/1),
      do: {:ok, {:renew, Enum.uniq(attempts)}},
      else: {:error, :lost}
  end

  defp operation("complete", %{"outcome" => %{"status" => "completed"} = outcome}),
    do: with({:ok, outcome} <- outcome(outcome, :completed), do: {:ok, {:complete, outcome}})

  defp operation("fail", %{"outcome" => %{"status" => "failed"} = outcome}),
    do: with({:ok, outcome} <- outcome(outcome, :failed), do: {:ok, {:fail, outcome}})

  defp operation("push_deltas", %{"deltas" => deltas}) when is_list(deltas) do
    deltas
    |> Enum.reduce_while({:ok, []}, fn delta, {:ok, acc} ->
      case delta(delta) do
        {:ok, delta} -> {:cont, {:ok, [delta | acc]}}
        :error -> {:halt, {:error, :lost}}
      end
    end)
    |> case do
      {:ok, deltas} -> {:ok, {:push_deltas, Enum.reverse(deltas)}}
      refused -> refused
    end
  end

  defp operation("oauth_token", %{"provider" => provider}) when is_binary(provider),
    do: {:ok, {:oauth_token, provider}}

  defp operation("take_rate", %{"bucket" => bucket}) when is_binary(bucket),
    do: {:ok, {:take_rate, bucket}}

  defp operation(op, args) when op in ["storage", "fetch_artifact", "record_denial"],
    do: Cyfr.Execution.Host.Storage.operation(op, args)

  defp operation(op, args) when op in ["admit_child", "tool_call", "release_child"] do
    with {:ok, call} <- Children.operation(op, args), do: {:ok, {Children, call}}
  end

  defp operation(_op, _args), do: {:error, :lost}

  defp outcome(%{"execution_id" => id, "attempt" => attempt, "fence" => fence} = wire, status)
       when is_binary(id) and is_binary(attempt) and is_integer(fence) and fence > 0 do
    error = Map.get(wire, "error")
    abandoned = Map.get(wire, "abandoned", false)

    if (is_nil(error) or is_binary(error)) and is_boolean(abandoned) do
      {:ok,
       %Outcome{
         execution_id: id,
         attempt: attempt,
         fence: fence,
         status: status,
         output: Map.get(wire, "output"),
         error: error,
         abandoned: abandoned and status == :failed
       }}
    else
      {:error, :lost}
    end
  end

  defp outcome(_wire, _status), do: {:error, :lost}

  defp delta(%{"execution_id" => id, "attempt" => attempt, "fence" => fence, "event" => event})
       when is_binary(id) and is_binary(attempt) and is_integer(fence) and fence > 0 and
              is_binary(event),
       do: {:ok, %Delta{execution_id: id, attempt: attempt, fence: fence, event: event}}

  defp delta(_wire), do: :error

  defp renewal_wire({:ok, until}), do: %{"lease_until" => until}
  defp renewal_wire(:lost), do: "lost"

  defp encode(:ok), do: Jason.encode!(%{"ok" => true})
  defp encode({:ok, value}), do: Jason.encode!(%{"ok" => value})

  defp encode({:error, {:setup_required, payload}}),
    do: Jason.encode!(%{"error" => "setup_required", "payload" => payload})

  defp encode({:error, {:guest_error, type, message}}),
    do: Jason.encode!(%{"error" => "guest_error", "type" => type, "message" => message})

  defp encode({:error, {:guest_error, type, message, remediation}}) do
    Jason.encode!(%{
      "error" => "guest_error",
      "type" => type,
      "message" => message,
      "remediation" => remediation
    })
  end

  defp encode({:error, {:failed, message}}),
    do: Jason.encode!(%{"error" => "failed", "message" => message})

  defp encode({:error, reason}) when reason in @refusals,
    do: Jason.encode!(%{"error" => Atom.to_string(reason)})

  defp encode(_other), do: Jason.encode!(%{"error" => "lost"})
end
