defmodule Arca.AuditSinks.Console do
  @moduledoc """
  Audit sink that logs events via Logger.

  Default sink for Core mode. Emits structured log lines with audit
  metadata that can be picked up by log aggregators.
  """

  @behaviour Arca.AuditSink

  require Logger

  @impl true
  def handle_audit_event(event_name, measurements, metadata) do
    event_str = Enum.join(event_name, ".")

    Logger.info("[Audit] #{event_str}",
      audit_event: event_str,
      audit_measurements: inspect(measurements),
      execution_id: metadata[:execution_id],
      user_id: metadata[:user_id],
      org_id: metadata[:org_id],
      component: metadata[:component] || metadata[:reference]
    )

    :ok
  end
end
