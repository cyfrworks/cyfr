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
  alias Opus.ExecutionRecord

  @type t :: %__MODULE__{
          ctx: Context.t(),
          reference: String.t(),
          component: map() | nil,
          component_ref: String.t() | nil,
          component_type: atom() | nil,
          component_digest: String.t() | nil,
          record: ExecutionRecord.t() | nil,
          exec_opts: keyword(),
          host_policy: map() | nil,
          edge: Sanctum.Authority.Blob.Edge.t() | nil,
          preloaded_secrets: map(),
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
    preloaded_secrets: %{},
    started_written: nil,
    opts: []
  ]
end
