# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.Prompts do
  @moduledoc """
  The stream `prompt.changes`: the records that wait on one person, for
  the surfaces that draw them. It declares no tool.

  The stream rides the person's own prompts topic (`Cyfr.Bus.prompts/2`,
  `Cyfr.Bus.Prompt`) and is bound to its holder, so a grant reaches that
  person's records alone. Each fact is a record's `kind`, its `ref`, what
  happened to it (`fact`) and its `expires_at`, and nothing the record
  says. A surface opens the stream first, then reads each kind's waiting
  records from that kind's owner, and on each `opened` fact reads that ref
  under its own session, which the owner admits by its own rule; it
  answers at the owner's door. A kind the surface does not know is not
  drawn.

  | kind | its owner's read and doors | facts |
  |---|---|---|
  | `confirmation` | `confirmation.pending`, `request`, `confirm` and `cancel` (`Sanctum.Providers.Confirmation`) | `opened`, `confirmed`, `consumed`, `cancelled`, `voided`, `expired` |

  The bus grants nothing: only Host's bridge (`Cyfr.TelemetryBridge`)
  publishes on the topic, from each kind's owner's telemetry.
  """

  @behaviour Prima.Provider

  # A day: the longest a grant on the stream lives.
  @deadline_bound 86_400

  @impl true
  def service, do: "cyfr"

  @impl true
  def tools, do: []

  @impl true
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "Tool", tool}}

  @doc "The stream `prompt.changes` (the moduledoc's)."
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "prompt.changes",
        topic: :prompts,
        projection: ["kind", "ref", "fact", "expires_at"],
        subject: ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z",
        bind: :holder,
        deadline_bound: @deadline_bound
      }
    ]
  end
end
