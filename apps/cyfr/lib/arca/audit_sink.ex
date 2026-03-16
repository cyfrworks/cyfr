defmodule Arca.AuditSink do
  @moduledoc """
  Behaviour for audit event sinks.

  Audit sinks receive security-relevant telemetry events and persist them
  to various backends. Core ships with Console and JSONL sinks. Arx can
  add SIEM, S3, or Postgres sinks by implementing this behaviour and
  adding them to the `:audit_sinks` config.

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
