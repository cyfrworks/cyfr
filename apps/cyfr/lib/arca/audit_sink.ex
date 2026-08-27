# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSink do
  @moduledoc """
  Behaviour for audit event sinks.

  Audit sinks receive security-relevant telemetry events and persist them
  to various backends. Only the Console sink (`Arca.AuditSinks.Console`)
  ships. Additional sinks (e.g. JSONL, SIEM, object store, or Postgres)
  can be added by implementing this behaviour and adding them to the
  `:audit_sinks` config.

  ## Implementing a sink

      defmodule MyApp.AuditSinks.Splunk do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(event_name, measurements, metadata) do
          # Forward to Splunk HEC endpoint
          :ok
        end
      end

  Then configure:

      config :cyfr, :audit_sinks, [Arca.AuditSinks.Console, MyApp.AuditSinks.Splunk]
  """

  @callback handle_audit_event(
              event_name :: [atom()],
              measurements :: map(),
              metadata :: map()
            ) :: :ok
end
