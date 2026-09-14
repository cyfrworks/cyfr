# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Outcome do
  @moduledoc """
  How an execution attempt ended, as its runner reports it to CYFR: a
  `:completed` outcome through `c:Cyfr.HostAPI.complete/2`, a `:failed`
  one through `c:Cyfr.HostAPI.fail/2`.

  A completed outcome carries the guest's `output` exactly as the runner
  received it. CYFR masks it, checks it against the node's response size,
  stages it and closes the row. A failed outcome carries the `error`
  message the row records. An outcome names the attempt it closes, and CYFR
  refuses one whose attempt is not the calling attempt.
  """

  @enforce_keys [:execution_id, :attempt, :fence, :status]
  defstruct [:execution_id, :attempt, :fence, :status, :output, :error]

  @type t :: %__MODULE__{
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          status: :completed | :failed,
          output: term(),
          error: String.t() | nil
        }
end
