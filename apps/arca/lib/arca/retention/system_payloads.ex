# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.SystemPayloads do
  @moduledoc """
  Retained payloads of the server's own executions (retention class `system`) older than N
  days go — the bytes and the rows that reference them.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.{Kind, Payloads}

  @impl true
  def key, do: "system_payload_days"

  @impl true
  def default, do: Kind.configured(:system_payload_days, 7)

  @impl true
  def unit, do: :days

  @impl true
  def prune(actor, days, dry_run), do: Payloads.prune_classes(actor, ["system"], days, dry_run)
end
