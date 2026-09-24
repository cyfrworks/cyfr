# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Close do
  @moduledoc """
  How an admitted execution ends: its terminal row, its lifecycle
  telemetry and the answer its caller receives.

  `complete/4` closes a run with its output: the output is masked, checked
  for an application error (unless the run's answer is its catalyst
  envelope) and against the node's response size, and written with its
  result payload. `fail/3` closes a run with a reason and
  fails the children a failed formula leaves running. Every text that
  leaves here — the output, the failure message on the row, the terminal
  event and the answer handed to the caller (an MCP client, a parent
  formula's guest, a tincture response, a webhook log) — is masked with the
  `secrets` passed in: the masking set of the run's
  `Cyfr.Execution.Attempt`, which calls these functions from its own
  process. A refusal before the attempt opens (`Cyfr.Execution.Admission`)
  or at attach passes an empty set: nothing has been unsealed or dispensed
  yet.

  A close struct is data only: the row's record, the context the run was
  admitted in, the node's limits and whether the row has been admitted.

  A run whose row was never admitted is admitted on failure, so a refusal
  is on record like any other run. When one of the admission barriers
  refuses that row (`Arca.Execution.barrier_refusal?/1`), nothing is
  recorded: no row, no lifecycle telemetry and no error log, and the
  refusal is answered (`barred/1`).
  """

  require Logger

  alias Cyfr.Execution.{Cascade, Events, Record, StepSpans, Telemetry}
  alias Prima.SecretMasker
  alias Sanctum.Context

  @enforce_keys [:ctx, :record]
  defstruct [
    :ctx,
    :record,
    :limits,
    :step_spans,
    :setup_stream,
    signature_verified: false,
    started: false,
    envelope: false,
    admission: []
  ]

  @typedoc """
  What closing a run needs. `record` is the row as admitted; `limits` the
  node's, set once policy was enforced; `step_spans` the caller's clock;
  `setup_stream` the stream a setup refusal is announced on (the run's root,
  else its parent); `signature_verified` the registry's attestation flag;
  `started` whether the row was admitted; `envelope` whether the output is
  the component's catalyst envelope (`Prima.Model.decode_envelope/1`),
  whose error is a refusal the component answers rather than a failure of
  the run; `admission` the barriers (`:charge`, `:step`, `:occurrence_id`)
  a row admitted only on failure passes through.
  """
  @type t :: %__MODULE__{
          ctx: Context.t(),
          record: Record.t(),
          limits: Prima.Limits.t() | nil,
          step_spans: StepSpans.t() | nil,
          setup_stream: String.t() | nil,
          signature_verified: boolean(),
          started: boolean(),
          envelope: boolean(),
          admission: keyword()
        }

  @doc """
  Close a run that returned `output`, masked with `secrets`.

  An output that carries an application error (`"error"`) closes the run
  failed instead, unless the close's `envelope` says the output is the
  component's catalyst envelope, whose error is its refusal: that run
  completes with the refusal as its output. An output that exceeds the
  node's `max_response_size` or cannot be encoded closes the run failed. Answers the result — `%{status: :completed, output: masked,
  metadata: map}` — or `{:error, message}`. A cancel that closed the row
  first leaves the cancelled row standing; the result is still answered.
  A run whose estate was archived while it ran is never answered as a
  success: its completion is refused (`Cyfr.Execution.Record.write_completed/1`),
  the row closes failed and the answer is `{:error, message}`.
  """
  @spec complete(t(), [String.t()], term(), map()) :: {:ok, map()} | {:error, String.t()}
  def complete(%__MODULE__{} = close, secrets, output, exec_metadata) do
    masked_output = SecretMasker.mask(output, secrets)

    with :ok <- check_application_error(close, secrets, masked_output),
         :ok <- check_response_size(close, secrets, masked_output),
         completed_record = Record.complete(close.record, masked_output),
         {:written, write_result} <- completed_write(close, completed_record) do
      if write_result == :ok, do: StepSpans.completed(close.step_spans)

      # The lifecycle telemetry follows the row: a completion is announced
      # only when its write committed. A cancel that closed the row first
      # announces nothing here; any other failed write is an audit error.
      audit_error = audit_error(completed_record, write_result)
      if write_result == :ok, do: Telemetry.execute_stop(completed_record, exec_metadata)

      # The terminal event is the row's, published by the record's write.
      if write_result == {:error, :not_running} do
        Logger.info(
          "[Cyfr.Execution.Close] execution #{completed_record.id} finished after cancel; " <>
            "the cancelled row stands"
        )
      end

      result = %{
        status: :completed,
        output: masked_output,
        metadata: metadata(close, completed_record)
      }

      result =
        if audit_error, do: put_in(result, [:metadata, :audit_error], audit_error), else: result

      # A completed parent leaves its asynchronous children running; failure
      # and cancellation cascade, and lease expiry reaps abandoned children.
      {:ok, result}
    end
  end

  # A completion refused because the run's grant no longer stands was
  # closed failed by the record's write: its output is neither answered
  # nor announced as a success.
  defp completed_write(close, completed_record) do
    case Record.write_completed(completed_record) do
      {:error, :not_standing} ->
        message = "Execution refused: its athanor is no longer active"
        Telemetry.execute_exception(Record.fail(close.record, message), message)
        {:error, message}

      write_result ->
        {:written, write_result}
    end
  end

  @doc """
  Close a run failed with `reason`, masked with `secrets`.

  `reason` is a crafted sentence, a typed `{:setup_required, payload}` or
  `{:consent_required, payload}` refusal, or an internal term. A sentence
  is recorded as it is. A typed refusal records its readable message,
  announces a `setup_required` event on the run's root or parent stream,
  and answers `{:error, typed}` whole. An internal term is recorded as the
  sentence `Cyfr.Ops.Error.render/1` gives it, or `"internal error"`
  (logged). Answers `{:error, masked_message}` otherwise.
  """
  @spec fail(t(), [String.t()], term()) :: {:error, term()}
  def fail(%__MODULE__{} = close, secrets, reason) when is_binary(reason) do
    close_failed(close, secrets, reason)
  end

  def fail(%__MODULE__{} = close, secrets, {tag, payload} = typed)
      when tag in [:setup_required, :consent_required] and is_map(payload) do
    announce_setup(close, typed)
    _ = close_failed(close, secrets, failure_message(typed))
    {:error, typed}
  end

  def fail(%__MODULE__{} = close, secrets, reason) do
    close_failed(close, secrets, "Execution failed: #{client_reason(reason)}")
  end

  @doc """
  Close a run whose attempt ended before it closed the run itself. The
  message is fixed and carries nothing the guest produced, so it needs no
  masking set.

  The write is fenced on the run's attempt. When the row is no longer
  running under it (the attempt wrote its terminal row before it ended, a
  cancel closed the row, or another attempt took it over), nothing is
  written, no failure telemetry fires and no child is failed, and the
  answer is the row's: its result when it completed, its error when it
  failed or was cancelled, and the fixed message otherwise. A boot that
  does not hold the control plane (`Arca.ControlPlane.held?/0`) writes
  nothing and answers the same way.
  """
  @spec lost(t()) :: {:ok, map()} | {:error, String.t()}
  def lost(%__MODULE__{record: record} = close) do
    message = "Execution attempt ended before it closed"

    if Arca.ControlPlane.held?() do
      failed_record = Record.fail(record, message)

      case Record.write_failed(failed_record) do
        {:error, :not_running} -> closed_answer(close, message)
        written -> ended_failed(failed_record, written, message)
      end
    else
      closed_answer(close, message)
    end
  end

  # The row is read with the host-side context of its own terminal writes:
  # a child admitted on the guest plane cannot read it with its own.
  defp closed_answer(%__MODULE__{record: record} = close, message) do
    case Record.reread(record) do
      {:ok, %Record{status: :completed} = row} ->
        {:ok, %{status: :completed, output: row.output, metadata: metadata(close, row)}}

      {:ok, %Record{status: status, error: error}} when status in [:failed, :cancelled] ->
        {:error, error || "Execution #{status}"}

      _ ->
        {:error, message}
    end
  end

  @doc """
  The failure message for an exception raised while admitting, running or
  closing a run. A `RuntimeError` or `ArgumentError` carries a sentence
  authored where it was raised; any other exception is logged with its
  stacktrace and reported as an internal error.
  """
  @spec exception_message(Exception.t(), Exception.stacktrace()) :: String.t()
  def exception_message(%RuntimeError{message: message}, _stacktrace),
    do: "Execution error: #{message}"

  def exception_message(%ArgumentError{message: message}, _stacktrace),
    do: "Execution error: #{message}"

  def exception_message(exception, stacktrace) do
    Logger.error(
      "[Cyfr.Execution.Close] execution raised: " <>
        Exception.format(:error, exception, stacktrace)
    )

    "Execution error: the engine raised an internal error"
  end

  @doc """
  The sentence a vault setup refusal's reason is recorded as: a
  JSON-encodable value, since the typed payload crosses the error envelope.
  A reason carrying detail is recorded by its shape alone — the vault
  reader's details can quote the material that failed
  (`{:invalid_payload, payload}`), and a row's message outlives the call.
  """
  @spec setup_reason(term()) :: atom() | String.t()
  def setup_reason({:entry_unavailable, status}), do: "vault_entry_#{status}"
  def setup_reason({:selection_unbound, _label}), do: "vault_selection_unbound"
  def setup_reason(:consent_moved), do: "consent_moved"
  def setup_reason(reason) when is_atom(reason), do: reason
  def setup_reason(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  def setup_reason(_reason), do: :vault_refused

  defp check_application_error(%__MODULE__{envelope: true}, _secrets, _masked_output), do: :ok

  defp check_application_error(close, secrets, masked_output) do
    case application_error(masked_output) do
      nil -> :ok
      error -> close_failed(close, secrets, error)
    end
  end

  # The limits are set when policy is enforced; a close without them was
  # never admitted, and matching raises rather than substituting a ceiling.
  defp check_response_size(close, secrets, masked_output) do
    %Prima.Limits{max_response_size: max_response} = close.limits

    case Jason.encode(masked_output) do
      {:ok, output_json} when byte_size(output_json) > max_response ->
        close_failed(
          close,
          secrets,
          "Output size (#{byte_size(output_json)} bytes) exceeds maximum (#{max_response} bytes)"
        )

      {:ok, _output_json} ->
        :ok

      {:error, _} ->
        close_failed(close, secrets, "Output could not be serialized to JSON")
    end
  end

  # An application-level error a component reports in its output.
  defp application_error(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp application_error(%{"error" => %{"message" => msg}}), do: inspect(msg)
  defp application_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp application_error(%{"error" => err}) when is_map(err), do: inspect(err)
  defp application_error(_output), do: nil

  defp audit_error(_record, :ok), do: nil

  # A cancel won the race for the row: not an audit fault.
  defp audit_error(_record, {:error, :not_running}), do: nil

  # The result was answered and not retained: the record's write closed
  # the row failed and said so in its own log line.
  defp audit_error(record, {:error, {:result_lost, reason}} = lost) do
    emit_audit_error(record, :completed, elem(lost, 1))
    inspect(reason)
  end

  defp audit_error(record, {:error, reason}) do
    Logger.error(
      "[Cyfr.Execution.Close] Failed to write completed record #{record.id}: #{inspect(reason)}. " <>
        "Audit trail is incomplete — this execution will appear as 'running' in logs."
    )

    emit_audit_error(record, :completed, reason)
    inspect(reason)
  end

  # The reason travels as data: `Arca.AuditHandler` redacts this metadata
  # by key on its way to the sinks, and key-based redaction cannot see
  # inside a string.
  defp emit_audit_error(record, phase, reason) do
    :telemetry.execute(
      [:cyfr, :opus, :audit_error],
      %{system_time: System.system_time()},
      %{execution_id: record.id, phase: phase, reason: reason}
    )
  end

  defp metadata(close, record) do
    %{
      execution_id: record.id,
      duration_ms: record.duration_ms,
      component_type: record.component_type,
      component_digest: record.component_digest,
      user_id: close.ctx.user_id,
      reference: record.reference,
      policy_applied: record.host_policy,
      signature_verified: close.signature_verified
    }
    |> put_present(:resolved_from, record.resolved_from)
    |> put_present(:resolver_digest, record.resolver_digest)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The answer to a run an admission barrier refused before its row existed
  (`Arca.Execution.barrier_refusal?/1`): a child whose parent ended is
  refused with the sentence its caller is shown, and every other barrier's
  refusal is answered as itself.
  """
  @spec barred(atom()) :: {:error, atom() | String.t()}
  def barred(:parent_ended),
    do: {:error, "Execution refused: its parent execution is no longer running"}

  def barred(reason) when is_atom(reason), do: {:error, reason}

  # The terminal failure write. A row not yet admitted is admitted first,
  # so a refusal is on record like any other run, unless a barrier refuses
  # it.
  defp close_failed(%__MODULE__{started: false, record: record} = close, secrets, message) do
    case Record.write_started(record, close.admission) do
      :ok ->
        Telemetry.execute_start(record)
        close_failed(%{close | started: true}, secrets, message)

      {:error, reason} ->
        if Arca.Execution.barrier_refusal?(reason) do
          barred(reason)
        else
          Logger.error(
            "[Cyfr.Execution.Close] Failed to write started record #{record.id}: " <>
              "#{inspect(reason)}. Audit trail is incomplete — this execution will not " <>
              "appear in logs."
          )

          emit_audit_error(record, :started, reason)
          write_failed(%{close | started: true}, secrets, message, :unadmitted)
        end
    end
  end

  defp close_failed(close, secrets, message),
    do: write_failed(close, secrets, message, :admitted)

  defp write_failed(close, secrets, message, admitted) do
    message = SecretMasker.mask(message, secrets)
    failed_record = Record.fail(close.record, message)
    ended_failed(failed_record, Record.write_failed(failed_record), message, admitted)
  end

  # What follows a failure's terminal write, whatever it answered: the
  # failure telemetry when the write committed (nothing when there was no
  # running row to close, an audit error when it failed), and the cascade
  # to a formula's running children. `admitted` says whether the row was
  # written at all: one whose admission failed has no row for the write
  # to close, which is not a cancel winning the race.
  defp ended_failed(failed_record, written, message, admitted \\ :admitted) do
    case written do
      :ok ->
        Telemetry.execute_exception(failed_record, message)

      {:error, :not_running} when admitted == :unadmitted ->
        Logger.error(
          "[Cyfr.Execution.Close] execution #{failed_record.id} was never admitted; " <>
            "its failure has no row to close"
        )

      {:error, :not_running} ->
        Logger.info(
          "[Cyfr.Execution.Close] execution #{failed_record.id} failed after cancel; " <>
            "the cancelled row stands"
        )

      {:error, reason} ->
        Logger.error(
          "[Cyfr.Execution.Close] Failed to write failed record #{failed_record.id}: " <>
            "#{inspect(reason)}. Audit trail is incomplete — this execution will appear " <>
            "as 'running' in logs."
        )

        emit_audit_error(failed_record, :failed, reason)
    end

    Cascade.fail_children(failed_record)

    {:error, message}
  end

  # A setup refusal is announced on the stream the caller watching the
  # whole run subscribes to, so it is seen even where the parent's own
  # dispatch does not surface it.
  defp announce_setup(%__MODULE__{setup_stream: nil}, _typed), do: :ok

  defp announce_setup(%__MODULE__{setup_stream: stream_id} = close, typed) do
    case Prima.Remediation.analyze(typed) do
      {:setup_required, remediation} ->
        _ =
          Events.push(
            stream_id,
            %{
              "kind" => "setup_required",
              "component_ref" => remediation["component_ref"],
              "issues" => remediation["issues"],
              "setup_command" => remediation["setup_command"],
              "message" => failure_message(typed)
            },
            close.ctx,
            origin: "host"
          )

        :ok

      :not_setup_error ->
        :ok
    end
  end

  # The payload's reason is already the sentence `setup_reason/1` gave it.
  defp failure_message({:setup_required, %{node_ref: node_ref, reason: reason}}),
    do: "Setup required for #{node_ref}: #{reason}"

  defp failure_message(reason), do: "Execution failed: #{client_reason(reason)}"

  # A typed refusal gets its one sentence (`Cyfr.Ops.Error.render/1`); an
  # internal term goes to the log and never into a message that outlives
  # this call.
  defp client_reason(reason) do
    case Cyfr.Ops.Error.render(reason) do
      nil ->
        Logger.warning("[Cyfr.Execution.Close] unrenderable failure reason: #{inspect(reason)}")
        "internal error"

      msg ->
        msg
    end
  end
end
