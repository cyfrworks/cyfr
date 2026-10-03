# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.WebhookPayloads do
  @moduledoc """
  Retained payloads of webhook-driven executions (retention class `webhook`) older than N
  days go — the bytes and the rows that reference them.
  """
  @behaviour Arca.Retention.Kind

  alias Arca.Retention.{Kind, Payloads}

  @impl true
  def key, do: "webhook_payload_days"

  @impl true
  def default, do: Kind.configured(:webhook_payload_days, 14)

  @impl true
  def unit, do: :days

  @impl true
  def prune(actor, days, dry_run), do: Payloads.prune_classes(actor, ["webhook"], days, dry_run)
end
