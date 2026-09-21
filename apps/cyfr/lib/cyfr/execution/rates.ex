# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Rates do
  @moduledoc """
  The consented invocation rate, as the execution plane asks for it.

  This module reads a cap and a window out of the caller's consent and
  answers the plane's refusal vocabulary. The allowance itself is claimed
  in the row every member of the cell shares
  (`Arca.RateWindows`): there is no table here, no owner process and no
  count in this boot's memory, which is the whole of what this module is.
  Two members admit an athanor's consented rate once between them, and a
  member that restarts forgets nothing — a counter that died with its
  node used to hand every bucket a fresh window on every restart.

  ## Buckets

  A bucket is one `{athanor, bucket}` pair, and members of an athanor
  share it. The name is the caller's: a pinned component reference for an
  invocation, `http:`/`oauth:` for a running guest's egress and token
  dispense, `emit:` for a root's event budget, `pub:` for a public
  profile's runs. Its cap and window come from the consent the caller
  passes on every claim and are never stored as policy, so a consent
  revised downward takes effect on the next claim.

  Rate allowance is distinct from the execution slots
  `Cyfr.Execution.Slots` holds (`Cyfr.Slots`): nothing here holds,
  charges or releases a slot. An allowance is spent at admission and
  comes back with the clock, whether or not the work it admitted still
  runs.

  ## The window

  Two adjacent fixed windows on database time, weighted at the boundary —
  the arithmetic, its guarantee and what a boundary refuses are
  `Arca.RateWindows`'. What matters here: at most the consented `requests`
  are admitted in a window of `window`, across the whole cell, and a claim
  at a boundary is refused rather than admitted when the window before it
  was full.

  ## Refusals

  Every refusal denies, and they stay apart in the result:

    * `{:error, :rate_limited, retry_after_ms}` — the consented ceiling.
    * `{:error, :missing_tenant}` — no athanor was resolved. A bucket
      without a tenant would collide across tenants, so it is refused
      before any claim.
    * `{:error, :unavailable}` — the store could not answer, or the row
      would not settle under contention. A consented ceiling that cannot
      be read is not a ceiling that passes: callers deny, and say the
      limiter could not answer rather than that the caller was over its
      rate.

  A limit source with no `:rate_limit` is unlimited and claims nothing. A
  `:rate_limit` that cannot be read as a positive window and a
  non-negative count of requests is denied rather than defaulted:
  substituting a window would silently rescale a value the caller
  consented to.

  ## Usage

      case Cyfr.Execution.Rates.check(actor, "stripe-catalyst", %{
             rate_limit: %{requests: 50, window: "1m"}
           }) do
        {:ok, _remaining} -> proceed_with_execution()
        {:error, :rate_limited, _retry_after_ms} -> return_rate_limit_error()
        {:error, _reason} -> deny()
      end
  """

  require Logger

  @type verdict ::
          {:ok, non_neg_integer() | :unlimited}
          | {:error, :rate_limited, non_neg_integer()}
          | {:error, :missing_tenant}
          | {:error, :unavailable}

  @doc """
  Claim one of the actor's athanor's allowance for `bucket`, under the
  cap and window `limit_source` consents to.

  `{:ok, remaining}` admits and counts the claim; `{:ok, :unlimited}`
  means no limit is configured and nothing was counted.

  ## Examples

      iex> Cyfr.Execution.Rates.check(actor, "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:ok, 9}

      # After 10 requests...
      iex> Cyfr.Execution.Rates.check(actor, "component", %{rate_limit: %{requests: 10, window: "1m"}})
      {:error, :rate_limited, 45000}
  """
  @spec check(Cyfr.Actor.t(), String.t(), map() | nil) :: verdict()
  def check(%Cyfr.Actor{athanor_id: athanor_id} = actor, bucket, limit_source)
      when is_binary(athanor_id) and athanor_id != "" do
    case consented(limit_source) do
      :unlimited -> {:ok, :unlimited}
      :invalid -> {:error, :rate_limited, 0}
      {cap, window_ms} -> verdict(Arca.RateWindows.claim(actor, bucket, cap, window_ms))
    end
  end

  def check(%Cyfr.Actor{}, _bucket, _limit_source), do: missing_tenant("check")

  # `check/3` at an explicit instant, for tests that pin a claim to a
  # window's edge; a running cell takes the instant from its own clock.
  @doc false
  @spec claim_at(Cyfr.Actor.t(), String.t(), map() | nil, DateTime.t()) :: verdict()
  def claim_at(
        %Cyfr.Actor{athanor_id: athanor_id} = actor,
        bucket,
        limit_source,
        %DateTime{} = now
      )
      when is_binary(athanor_id) and athanor_id != "" do
    case consented(limit_source) do
      :unlimited ->
        {:ok, :unlimited}

      :invalid ->
        {:error, :rate_limited, 0}

      {cap, window_ms} ->
        verdict(Arca.RateWindows.claim_at(actor, bucket, cap, window_ms, now))
    end
  end

  def claim_at(%Cyfr.Actor{}, _bucket, _limit_source, _now), do: missing_tenant("check")

  @doc """
  Forget the bucket's window: the next claim opens a fresh one.
  Administrative, and what a test uses to start a bucket from nothing.
  """
  @spec reset(Cyfr.Actor.t(), String.t()) ::
          :ok | {:error, :missing_tenant} | {:error, :unavailable}
  def reset(%Cyfr.Actor{athanor_id: athanor_id} = actor, bucket)
      when is_binary(athanor_id) and athanor_id != "" do
    case Arca.RateWindows.clear(actor, bucket) do
      :ok -> :ok
      {:error, reason} -> unavailable(reason, "reset")
    end
  end

  def reset(%Cyfr.Actor{}, _bucket), do: missing_tenant("reset")

  @doc """
  What the bucket reads now, counting nothing: `{:ok, used, remaining,
  window_ms}`, or `{:ok, :unlimited}` when no limit is configured.
  """
  @spec status(Cyfr.Actor.t(), String.t(), map() | nil) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:ok, :unlimited}
          | {:error, :missing_tenant}
          | {:error, :unavailable}
  def status(%Cyfr.Actor{athanor_id: athanor_id} = actor, bucket, limit_source)
      when is_binary(athanor_id) and athanor_id != "" do
    case consented(limit_source) do
      :unlimited ->
        {:ok, :unlimited}

      :invalid ->
        # `check/3` denies on a consented limit it cannot read; status is
        # the diagnostics path and reports that state rather than crashing
        # on it.
        {:ok, 0, 0, 0}

      {cap, window_ms} ->
        case Arca.RateWindows.estimate(actor, bucket, cap, window_ms) do
          {:ok, used, remaining, width} -> {:ok, used, remaining, width}
          {:error, reason} -> unavailable(reason, "status")
        end
    end
  end

  def status(%Cyfr.Actor{}, _bucket, _limit_source), do: missing_tenant("status")

  # ---- internal --------------------------------------------------------------

  defp verdict({:ok, remaining}), do: {:ok, remaining}
  defp verdict({:refused, retry_after_ms}), do: {:error, :rate_limited, retry_after_ms}
  defp verdict({:error, reason}), do: unavailable(reason, "check")

  # A store that could not answer and a row that would not settle are one
  # thing to the caller — the rate could not be decided — and both deny.
  # `:no_athanor` cannot reach here: every entry guards the athanor first.
  defp unavailable(reason, operation) do
    Logger.warning(
      "[Cyfr.Execution.Rates] the rate authority could not answer #{operation} " <>
        "(#{inspect(reason)}) — denying"
    )

    {:error, :unavailable}
  end

  defp missing_tenant(operation) do
    Logger.warning(
      "[Cyfr.Execution.Rates] no athanor resolved during #{operation} — rejecting to prevent " <>
        "cross-tenant rate limit collision"
    )

    {:error, :missing_tenant}
  end

  # The cap and the window a limit source consents to. Any map carrying a
  # `:rate_limit` key of `%{requests: n, window: "1m"}` — callers pass the
  # node's consented `Cyfr.Limits.rate_limit`, or a platform-config bucket
  # like the emit cap. A nil map or a nil `:rate_limit` is unlimited.
  defp consented(nil), do: :unlimited
  defp consented(%{rate_limit: nil}), do: :unlimited

  defp consented(%{rate_limit: %{requests: requests, window: window}}) do
    case parse_window(window) do
      # A window of zero milliseconds or less holds nothing and a negative
      # count of requests admits nothing: both read as configured and
      # enforce nothing, so both are refused rather than run.
      {:ok, window_ms} when window_ms > 0 and is_integer(requests) and requests >= 0 ->
        {requests, window_ms}

      _ ->
        :invalid
    end
  end

  defp consented(_), do: :unlimited

  # Duration grammar is Cyfr.Limits' — one parser for every enforcement
  # window, so "1h" cannot mean an hour in one limiter and a fallback minute
  # in another. Unparseable is unparseable, never a default.
  defp parse_window(window) when is_integer(window), do: {:ok, window}

  defp parse_window(window) do
    case Cyfr.Limits.parse_duration(window) do
      {:ok, ms} ->
        {:ok, ms}

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Execution.Rates] invalid rate-limit window #{inspect(window)}: #{reason}"
        )

        :error
    end
  end
end
