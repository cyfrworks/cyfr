# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSink do
  @moduledoc """
  Behaviour for audit event sinks.

  Audit sinks receive security-relevant events as `Arca.Audit.Event`
  structs — metadata already sanitized by `Arca.AuditHandler` — and
  persist them to various backends. Only the Console sink
  (`Arca.AuditSinks.Console`) ships. Additional sinks (e.g. JSONL, SIEM,
  object store, or Postgres) can be added by implementing this behaviour
  and adding them to the `:audit_sinks` config.

  ## Implementing a sink

      defmodule MyApp.AuditSinks.Splunk do
        @behaviour Arca.AuditSink

        @impl true
        def handle_audit_event(%Arca.Audit.Event{} = event) do
          # Forward to Splunk HEC endpoint
          :ok
        end
      end

  Then configure:

      config :arca, :audit_sinks, [Arca.AuditSinks.Console, MyApp.AuditSinks.Splunk]
  """

  @callback handle_audit_event(event :: Arca.Audit.Event.t()) :: :ok
end
