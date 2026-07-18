# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSinks.Console do
  @moduledoc """
  Audit sink that logs events via Logger.

  Default sink for default-mode deployments. Emits structured log lines with audit
  metadata that can be picked up by log aggregators.
  """

  @behaviour Arca.AuditSink

  require Logger

  @impl true
  def handle_audit_event(event_name, measurements, metadata) do
    event_str = Enum.join(event_name, ".")

    component = metadata[:component] || metadata[:reference]

    Logger.info(
      "[Audit] #{event_str} " <>
        "execution_id=#{metadata[:execution_id]} user_id=#{metadata[:user_id]} " <>
        "org_id=#{metadata[:org_id]} component=#{component} " <>
        "measurements=#{inspect(measurements)}"
    )

    :ok
  end
end
