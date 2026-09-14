# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionPipeline do
  @moduledoc """
  Accumulates state through the execution pipeline.

  Replaces the multi-parameter threading in `Opus.Executor.do_run/7`
  and `finalize_execution/12` with a single struct that collects
  all pipeline state as it flows through validation, policy enforcement,
  secret resolution, and execution.
  """

  alias Sanctum.Context
  alias Cyfr.Execution.Record

  @type t :: %__MODULE__{
          ctx: Context.t(),
          reference: String.t(),
          component: map() | nil,
          component_ref: String.t() | nil,
          component_type: atom() | nil,
          component_digest: String.t() | nil,
          record: Record.t() | nil,
          exec_opts: keyword(),
          host_policy: map() | nil,
          edge: Cyfr.Authority.Blob.Edge.t() | nil,
          preloaded_fields: map(),
          started_written: reference() | nil,
          opts: keyword()
        }

  defstruct [
    :ctx,
    :reference,
    :component,
    :component_ref,
    :component_type,
    :component_digest,
    :record,
    :host_policy,
    :edge,
    exec_opts: [],
    preloaded_fields: %{},
    started_written: nil,
    opts: []
  ]

  @doc """
  Every credential value dispensed to this execution's guest: the vault
  fields the executor preloaded plus whatever OAuth tokens were handed out
  during the run. Every egress of guest-influenced text (output, failure
  message, event) masks with this set.

  The OAuth half is collect-and-delete, so take the list once per egress
  decision and reuse it rather than calling again.
  """
  @spec secrets(t()) :: [String.t()]
  def secrets(%__MODULE__{record: nil} = p), do: Map.values(p.preloaded_fields)

  def secrets(%__MODULE__{} = p) do
    Map.values(p.preloaded_fields) ++ Opus.OAuthHandler.collect_dispensed(p.record.id)
  end
end
