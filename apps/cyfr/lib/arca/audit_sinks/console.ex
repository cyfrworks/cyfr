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
        "user_id=#{event.user_id} athanor_id=#{event.athanor_id} " <>
        "measurements=#{inspect(event.measurements)} metadata=#{detail}"
    )

    :ok
  end
end
