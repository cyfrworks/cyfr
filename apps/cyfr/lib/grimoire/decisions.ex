# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Decisions do
  @moduledoc """
  The telemetry of the gate's admission decisions: one event per decision,
  read off the same `Prima.Decision` the decision log records
  (`Arca.DecisionLog`), and one per decision or completion the log could
  not write.

  The loss event is the audit's alarm. The operation's result stands and
  nothing is retried, so a gap in the trail is visible only here: it is
  catalogued with a metric an operator alerts on
  (`cyfr_grimoire_decision_lost_total`, by stage and kind), not a log
  line alone. Audit is not a reaction, so none of these reaches the bus.
  """

  alias Arca.DecisionLog.AuditFailure
  alias Prima.Decision

  @doc false
  # The decision's own event, after the gate has decided it.
  @spec emit(Decision.t()) :: :ok
  def emit(%Decision{admission: :admitted} = decision) do
    :telemetry.execute([:cyfr, :grimoire, :decision, :admitted], %{count: 1}, metadata(decision))
  end

  def emit(%Decision{admission: :refused} = decision) do
    :telemetry.execute(
      [:cyfr, :grimoire, :decision, :refused],
      %{count: 1},
      Map.put(metadata(decision), :refusal_class, decision.refusal_class)
    )
  end

  @doc false
  # A decision (`stage: :append`) or its completion (`stage: :finish`) the
  # log could not write, and why.
  @spec lost(AuditFailure.t()) :: :ok
  def lost(%AuditFailure{stage: stage, kind: kind}) do
    :telemetry.execute([:cyfr, :grimoire, :decision, :lost], %{count: 1}, %{
      stage: stage,
      kind: kind
    })
  end

  # Metric tags need a value: an operation not yet named reads as "".
  defp metadata(%Decision{} = decision) do
    %{plane: decision.plane, tool: decision.tool || "", action: decision.action || ""}
  end
end
