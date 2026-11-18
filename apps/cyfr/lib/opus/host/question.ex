# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.Question do
  @moduledoc """
  The host's side of a catalyst's ask (`cyfr:question/ask`):
  `question_ask` and `question_wait` (`Prima.HostAPI`), decided by
  `Sanctum.Questions`.

  `Opus.Host` verifies each call and reads its args before it reaches
  here. Every step runs under the calling runner's live attempt
  (`Opus.Attempt.call/3` with `{:question, texts}`): an attempt with a
  cancel asked of it, or whose run has ended, is `lost` and is asked
  nothing.

  ## An ask

  The ask is keyed by the signed attempt and its number, `ask_no`, which
  the runner takes once for each call of the guest's `ask`. Its request's
  digest (`request_digest/3`) is taken before masking. In order:

    1. Two admissions of one key are serialized on this member, the one
       that issued the attempt and so receives all of its calls.
    2. `Sanctum.Questions.find/4` by the key: an ask already admitted, a
       retry's or the first of two at once, answers what its row holds,
       its decision or the same wait, and spends nothing; the same number
       with another request is `none(invalid)`.
    3. The attempt masks the summary and the operation with its masking
       set and takes one ask from the root's allowance. With no room the
       ask is answered `{retry_after_ms}`, and the runner sends it again.
    4. `Sanctum.Questions.ask/4` decides it, with the run's identity: the
       component's reference, the release that runs, the caller read
       from the root's row (`Opus.Record.caller/1`) and the run's
       deadline.

  An answer is `{answer}`, or `{pending: true}` while its question is
  open.

  ## A wait

  `Sanctum.Questions.wait/4` by the same key, at most
  `Prima.HostAPI.max_question_wait_ms/0`. The attempt is checked live
  before the wait and again after it, under a nonce of this step's own
  derived from the header's: an attempt stopped while it waited is `lost`,
  and is handed no allow.

  Nothing a request carries is logged.
  """

  alias Opus.Attempt
  alias Prima.Question.Caller

  @doc """
  The digest of an ask's request, as `Sanctum.Questions` keys a retry by
  it: SHA-256, as lowercase hexadecimal, over its `action`, `summary` and
  `operation`, each prefixed with its UTF-8 byte length as an unsigned
  32-bit big-endian integer, taken before masking.
  """
  @spec request_digest(String.t(), String.t(), String.t()) :: String.t()
  def request_digest(action, summary, operation)
      when is_binary(action) and is_binary(summary) and is_binary(operation) do
    :sha256
    |> :crypto.hash([field(action), field(summary), field(operation)])
    |> Base.encode16(case: :lower)
  end

  defp field(text), do: [<<byte_size(text)::unsigned-big-32>>, text]

  @doc "Ask `request` (`action`, `summary`, `operation`) as the caller's ask `ask_no`."
  @spec ask(Attempt.caller(), pos_integer(), map()) ::
          {:ok, Prima.HostAPI.question_asked()} | {:error, term()}
  def ask(caller, ask_no, %{action: action, summary: summary, operation: operation}) do
    digest = request_digest(action, summary, operation)

    with {:ok, run} <- Attempt.call(caller.execution_id, caller, {:question, nil}) do
      serialized(run.attempt, ask_no, fn ->
        case found(run, ask_no, digest) do
          :none -> admit(step(caller, "ask"), ask_no, action, summary, operation, digest)
          held -> {:ok, held}
        end
      end)
    end
  end

  @doc "Wait up to `max_wait_ms` for the caller's ask `ask_no` to be decided."
  @spec wait(Attempt.caller(), pos_integer(), non_neg_integer()) ::
          {:ok, {:answer, Prima.HostAPI.question_answer()} | :pending} | {:error, term()}
  def wait(caller, ask_no, max_wait_ms) do
    with {:ok, run} <- Attempt.call(caller.execution_id, caller, {:question, nil}) do
      waited = Sanctum.Questions.wait(run.ctx, run.attempt, ask_no, max_wait_ms)

      with {:ok, _still_live} <-
             Attempt.call(caller.execution_id, step(caller, "wait"), {:question, nil}) do
        {:ok, waited}
      end
    end
  end

  defp found(run, ask_no, digest) do
    case Sanctum.Questions.find(run.ctx, run.attempt, ask_no, digest) do
      {:answer, answer} -> {:answer, answer}
      {:pending, _ref} -> :pending
      {:error, :changed} -> {:answer, {:none, :invalid}}
      :none -> :none
    end
  end

  defp admit(caller, ask_no, action, summary, operation, digest) do
    texts = %{summary: summary, operation: operation}

    with {:ok, run} <- Attempt.call(caller.execution_id, caller, {:question, texts}) do
      case run.allowance do
        {:retry_after_ms, ms} -> {:ok, {:retry_after_ms, ms}}
        :ok -> decided(run, ask_no, action, digest)
      end
    end
  end

  defp decided(run, ask_no, action, digest) do
    case caller_text(run) do
      {:ok, caller} ->
        identity = %{
          execution_id: run.execution_id,
          attempt_id: run.attempt,
          root_execution_id: run.root_execution_id,
          component_ref: run.component_ref,
          release_digest: run.release_digest,
          caller: caller,
          deadline: run.deadline
        }

        request = %{
          action: action,
          summary: run.summary,
          operation: run.operation,
          masked: run.masked,
          request_digest: digest
        }

        case Sanctum.Questions.ask(run.ctx, identity, ask_no, request) do
          {:answer, answer} -> {:ok, {:answer, answer}}
          {:pending, _ref} -> {:ok, :pending}
        end

      :error ->
        {:ok, {:answer, {:none, :unavailable}}}
    end
  end

  # The caller is the root's: a root's own record carries it, and a child,
  # which records none, reads its root's row (`Opus.Record.caller/1`).
  defp caller_text(run) do
    case Opus.Record.caller(run.record) do
      {:ok, caller} -> {:ok, Caller.encode(caller)}
      {:error, _unreadable} -> :error
    end
  end

  # One admission of a key at a time on this member: the attempt's calls
  # all reach the member that issued it.
  defp serialized(attempt, ask_no, admit) do
    :global.trans({{__MODULE__, attempt, ask_no}, self()}, admit, [node()])
  end

  defp step(caller, name), do: %{caller | nonce: caller.nonce <> "/question-" <> name}
end
