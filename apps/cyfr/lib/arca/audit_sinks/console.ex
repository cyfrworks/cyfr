# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSinks.Console do
  @moduledoc """
  Audit sink that logs events via Logger.

  Default sink for default-mode deployments. Emits structured log lines
  with audit metadata that can be picked up by log aggregators. Renders
  what the emitter actually sent (already sanitized by the handler) —
  a fixed key set would print a sign-in with every field blank and drop
  the door-refusal's reason.

  `user_id` and `athanor_id` are Logger metadata fields. With
  `CYFR_LOG_FORMAT=json`, `Cyfr.JsonFormatter` emits them as structured
  fields for filtering by caller and athanor.

  This sink logs at `:info`, so it is subject to the node's log level: a
  deployment that raises the level to `:warning` keeps its operational
  logging and silently loses its audit trail. That is a property of having
  one shipped sink, and the reason a real deployment ships a second
  (`config :cyfr, :audit_sinks`).
  """

  @behaviour Arca.AuditSink

  require Logger

  @impl true
  def handle_audit_event(%Arca.Audit.Event{} = event) do
    detail =
      event.metadata
      |> Map.drop([:user_id, :athanor_id])
      |> inspect(limit: 50, printable_limit: 500)

    Logger.info(
      "[Audit] #{Arca.Audit.Event.name_string(event)} " <>
        "measurements=#{inspect(event.measurements)} metadata=#{detail}",
      user_id: event.user_id,
      athanor_id: event.athanor_id
    )

    :ok
  end
end
