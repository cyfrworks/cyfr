# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host do
  @moduledoc """
  Where a runner's host calls reach CYFR: `attach`, `renew`, `complete`,
  `fail`, `push_deltas`, `oauth_token`, `take_rate`, `storage`,
  `fetch_artifact`, `record_denial`, `admit_child`, `tool_call`,
  `release_child` and `egress_pin`, as `Prima.HostAPI` describes them.

  `call/2` is the one entry point. It takes a host call's header
  (`Prima.WorkerAuth.host_call_header/3`) and its JSON body,
  `{"v": 1, "op": name, "args": {...}}` (`Prima.WorkerWire.request_body/2`),
  and answers JSON. The operation is named inside the body, so the
  header's MAC covers it; the body's version is read before its operation
  (`Prima.WorkerWire.read_request_body/2`). The tenant, execution,
  attempt and runner a call acts for come from the verified header, never
  from the body. Over HTTP, `Crucible.HostListener` carries the
  header and body here and the answer back; `call/2` verifies the whole
  call itself either way.

  ## Checks, in order

    0. This boot holds the control plane (`Arca.ControlPlane.held?/0`). A
       boot that does not has no attempt to answer for: its open attempts
       stop without closing their runs (`Crucible.Attempt`), and the
       rows are the holder's to write.
    1. The header verifies (`Prima.WorkerAuth.verify_host_call/5`) under the
       call key of the attempt it names, derived from the worker root, and
       names this member's standing (`Crucible.Keys.standing/0`: its
       current generation, which the control plane must be able to answer,
       and its own boot), and the body is at this wire's version and is a
       known operation with well-formed arguments. A call addressed to
       another member is `lost` here, whether or not this member could
       have answered it from the rows: the attempt's process is the
       member's that issued it.
    2. `attach`: the assignment verifies (`Prima.Assignment.verify/3`), it
       names the header's athanor, execution, attempt, fence, generation
       and member, it is addressed to the header's worker service and
       boot, its attempt is open on this member, and the attempt row is
       claimed for the header's runner (`Arca.ExecutionAttempts.claim/5`)
       under the grant the row stores.
       The attempt then unseals the run's vault edge and audits each field
       it hands over, once, at the attach that claims it
       (`Crucible.Attempt.attach/2`).
    3. `renew`: each named attempt's lease is renewed by one update
       predicated on the header's runner holding it on the header's
       service and boot, under the grant that attempt itself stores
       (`Arca.ExecutionAttempts.renew_held/4`), the runner's own attempt
       and the children it runs alike; one it does not hold, or whose
       grant no longer stands, renews as `lost`.
    4. Every other operation: the header's nonce has not been presented to
       the attempt before, and the attempt row is held by the header's
       runner under a grant that stands, before the attempt runs it
       (`Crucible.Attempt.call/3`); `fail` needs the hold alone.
       `admit_child`, `tool_call` and `egress_pin` act under what the
       attempt holds (`Crucible.Host.Children`, `Crucible.Host.Egress`),
       and need the row live as well: no cancel asked of it and its
       execution running.

  A grant stands while its athanor is active at the generation the run was
  admitted under (`Sanctum.ExecutionStanding.verify/1`). An archive
  retires it for good, whether or not the archive was heard: a call under
  it is `lost`, and one whose standing cannot be read is `unavailable`,
  with no effect.

  ## Answers

  Every answer carries the wire's version first
  (`Prima.WorkerWire.ok/1` and `error/2`): `{"v": 1, "ok": value}` on
  success, and a refusal is `{"v": 1, "error": name}`:

    * `lost` — this boot does not hold the control plane, the header does
      not verify, the header names another member, the body is not an
      operation, the nonce was presented before, or the attempt is not
      open, current, running, at the header's fence and claimed by its
      runner;
    * `unknown_version` — the body has no `v`, or another one;
    * `unavailable` — the store could not answer;
    * at attach, `malformed`, `bad_mac`, `unknown_version` or
      `claim_expired` for an assignment that does not verify, `replayed`
      when another runner holds the claim, and `setup_required` with its
      `payload` when the run's vault edge cannot be unsealed;
    * `failed` with its `message`, when `complete` closed the run failed;
    * `not_found`, when `fetch_artifact` names no artifact of the attempt's;
    * for `egress_pin`, `malformed` for args that do not read
      (`Prima.PinnedTarget.read_request/1`), and `denied`, `metadata`,
      `resolution` or `redirect_credentials` for a pin CYFR does not grant
      (`Crucible.Host.Egress`);
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
  | `egress_pin` | `url`, `purpose` (`fetch`, `stream` or `redirect`), `from` for a redirect | the pin (`Prima.PinnedTarget`) |

  An outcome names its `execution_id`, `attempt` and `fence`. `storage`,
  `fetch_artifact` and `record_denial` are `Crucible.Host.Storage`'s;
  `admit_child`, `tool_call` and `release_child` are
  `Crucible.Host.Children`'s. `admit_child` is keyed: a repeat with
  the same `child_key` answers the child already admitted under it.

  ## A worker service's report

  `runner_exited/2` takes a report's header (`Prima.WorkerAuth.report_header/3`)
  and its JSON body, `{"v": 1, "op": "runner_exited", "args": {"member":
  boot, "runner": id, "attempts": [ids]}}`, and answers JSON. The header must
  verify under the dispatch key of the worker service it names
  (`Prima.WorkerAuth.verify_report/4`), which only that worker service
  holds, and its `member` must be this member's boot, since every attempt
  one runner holds was issued here; a report is idempotent, so its nonce
  is not checked. A report naming another member lapses nothing: the
  attempts are that member's to lapse and the processes open for them are
  its to stop. Each named attempt dispatched to the reporting service on the
  reporting boot, claimed by the named runner, that still owns its running
  execution is lapsed (`Crucible.Lapse`), and the attempt process
  open for each is stopped without closing its run
  (`Crucible.Attempt.stop_unclosed/2`). A report from another boot
  of the same service lapses nothing.
  It answers `{"v": 1, "ok": true}`, `{"v": 1, "error": "lost"}` for a
  report that does not verify, is not a report at this version or names
  another member, and `{"v": 1, "error": "unavailable"}` when this boot
  does not hold the control plane (nothing is lapsed) or the store cannot
  list the attempts.
  """

  require Logger

  alias Prima.{Assignment, Delta, HostAPI, PinnedTarget, WorkerAuth, WorkerWire}
  alias Crucible.{Attempt, Keys, Lapse}
  alias Prima.Outcome
  alias Crucible.Host.{Children, Egress}

  @assignment_fields [:athanor_id, :execution_id, :attempt, :fence, :generation, :member]
  @refusals [
    :lost,
    :unavailable,
    :replayed,
    :malformed,
    :bad_mac,
    :unknown_version,
    :claim_expired,
    :not_found,
    :denied,
    :metadata,
    :resolution,
    :redirect_credentials
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
        "[Crucible.Host] host call raised: " <>
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
           {:ok, reporter, attempts} <- reported_attempts(body),
           :ok <- reported_here(reporter),
           :ok <- Lapse.dispatched(report.service, report.boot, reporter.runner, attempts) do
        holder = %{service_id: report.service, boot_id: report.boot, runner: reporter.runner}
        Enum.each(attempts, &Attempt.stop_unclosed(&1, holder))
      end

    encode(answer)
  rescue
    exception ->
      Logger.error(
        "[Crucible.Host] runner exit report raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode({:error, :unavailable})
  end

  defp owner(refusal) do
    if Arca.ControlPlane.held?() do
      :ok
    else
      Logger.warning("[Crucible.Host] refused: this boot does not hold the control plane")
      {:error, refusal}
    end
  end

  defp verify_report(header, body, now) do
    case WorkerAuth.verify_report(Keys.root(), header, body, now) do
      {:ok, report} ->
        {:ok, report}

      {:error, reason} ->
        Logger.warning("[Crucible.Host] runner exit report refused: #{reason}")
        {:error, :lost}
    end
  end

  defp reported_attempts(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, :runner_exited, args} <- WorkerWire.read_request_body(HostAPI, decoded),
         %{"member" => member, "runner" => runner, "attempts" => attempts} <- args,
         true <- is_binary(member) and member != "",
         true <- is_binary(runner) and runner != "" and is_list(attempts),
         true <- Enum.all?(attempts, &(is_binary(&1) and &1 != "")) do
      {:ok, %{member: member, runner: runner}, Enum.uniq(attempts)}
    else
      _ -> {:error, :lost}
    end
  end

  # Every attempt one runner holds was issued by one member, so the report
  # of its exit belongs to that member: the rows are its to lapse and the
  # attempt processes open for them are its to stop.
  defp reported_here(%{member: member}) do
    if member == Keys.member() do
      :ok
    else
      Logger.warning("[Crucible.Host] runner exit report refused: it names another member")
      {:error, :lost}
    end
  end

  # A generation the control plane cannot answer verifies nothing, and a
  # call addressed to another member is refused here rather than answered
  # from rows whose work this member does not hold.
  defp verify(header, body, now) do
    with {:ok, standing} <- Keys.standing(),
         {:ok, caller} <- WorkerAuth.verify_host_call(Keys.root(), header, body, now, standing) do
      {:ok, caller}
    else
      {:error, reason} ->
        Logger.warning("[Crucible.Host] host call refused: #{reason}")
        {:error, :lost}
    end
  end

  # ---------------------------------------------------------------------------
  # Operations
  # ---------------------------------------------------------------------------

  defp dispatch(caller, {:attach, token}, now) do
    with {:ok, assignment} <- Assignment.verify(token, Keys.assign_key(), now),
         :ok <- names_caller(assignment, caller),
         :ok <- open_here(caller),
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

  defp dispatch(caller, {:egress_pin, request}, now), do: Egress.pin(caller, request, now: now)

  defp dispatch(caller, op, _now), do: Attempt.call(caller.execution_id, caller, op)

  defp names_caller(%Assignment{} = assignment, caller) do
    cond do
      not Enum.all?(@assignment_fields, &(Map.fetch!(assignment, &1) == Map.fetch!(caller, &1))) ->
        {:error, :lost}

      assignment.service != caller.service or assignment.boot != caller.boot ->
        Logger.warning(
          "[Crucible.Host] attach of #{caller.execution_id} refused: the assignment " <>
            "is addressed to another worker service or another boot of it"
        )

        {:error, :lost}

      true ->
        :ok
    end
  end

  # An attempt with no process open on this member has nothing to attach
  # to: its row is not claimed for a runner that could never be answered.
  defp open_here(caller) do
    if Attempt.whereis(caller.execution_id), do: :ok, else: {:error, :lost}
  end

  defp claim(caller) do
    case Arca.ExecutionAttempts.claim(
           Prima.Actor.in_athanor(caller.athanor_id),
           caller.attempt,
           caller.fence,
           caller.runner,
           grant: :stored,
           verify: &Sanctum.ExecutionStanding.verify/1
         ) do
      :ok -> :ok
      {:error, reason} when reason in [:database_error, :unavailable] -> {:error, :unavailable}
      {:error, :replayed} -> {:error, :replayed}
      {:error, _lost} -> {:error, :lost}
    end
  end

  # A runner renews every attempt it holds on its worker service and boot:
  # its own and the children it runs. Each renewal is one update predicated
  # on that hold and on the grant that attempt stores, so a stale runner,
  # boot or service renews nothing, and neither does one whose athanor was
  # archived.
  defp renew(caller, attempt) do
    holder = %{service_id: caller.service, boot_id: caller.boot, runner: caller.runner}

    case Arca.ExecutionAttempts.renew_held(
           Prima.Actor.in_athanor(caller.athanor_id),
           attempt,
           holder,
           grant: :stored,
           verify: &Sanctum.ExecutionStanding.verify/1
         ) do
      {:ok, until} -> {:ok, {:ok, DateTime.to_unix(until, :millisecond)}}
      :lost -> {:ok, :lost}
      {:error, _reason} -> :unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # Wire
  # ---------------------------------------------------------------------------

  # The version is read before the operation: a body at another version
  # is told so, and one that is no operation at this version is lost.
  defp decode(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, callback, args} <- WorkerWire.read_request_body(HostAPI, decoded) do
      operation(Atom.to_string(callback), args)
    else
      {:error, :unknown_version} -> {:error, :unknown_version}
      _not_an_operation -> {:error, :lost}
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
    do: Crucible.Host.Storage.operation(op, args)

  defp operation(op, args) when op in ["admit_child", "tool_call", "release_child"] do
    with {:ok, call} <- Children.operation(op, args), do: {:ok, {Children, call}}
  end

  defp operation("egress_pin", args) do
    case PinnedTarget.read_request(args) do
      {:ok, request} -> {:ok, {:egress_pin, request}}
      {:error, :malformed} -> {:error, :malformed}
    end
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

  defp encode(answer), do: answer |> wire() |> Jason.encode!()

  defp wire(:ok), do: WorkerWire.ok(true)
  defp wire({:ok, %PinnedTarget{} = pin}), do: WorkerWire.ok(PinnedTarget.to_wire(pin))
  defp wire({:ok, value}), do: WorkerWire.ok(value)

  defp wire({:error, {:setup_required, payload}}),
    do: WorkerWire.error(:setup_required, %{"payload" => payload})

  defp wire({:error, {:guest_error, type, message}}),
    do: WorkerWire.error(:guest_error, %{"type" => type, "message" => message})

  defp wire({:error, {:guest_error, type, message, remediation}}) do
    WorkerWire.error(:guest_error, %{
      "type" => type,
      "message" => message,
      "remediation" => remediation
    })
  end

  defp wire({:error, {:failed, message}}), do: WorkerWire.error(:failed, %{"message" => message})
  defp wire({:error, reason}) when reason in @refusals, do: WorkerWire.error(reason)
  defp wire(_other), do: WorkerWire.error(:lost)
end
