# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Delta do
  @moduledoc """
  One event a guest emitted, as its runner forwards it to CYFR through
  `c:Cyfr.HostAPI.push_deltas/2`.

  `event` is the JSON text the guest emitted, exactly as the guest passed
  it, unchecked and unmasked: CYFR checks its size, charges the root's emit
  budget, decodes it (an event must be a JSON object), runs the emit
  transition, masks it and numbers it. A delta names the attempt that
  emitted it; one whose attempt is no longer current is dropped by its
  fence.
  """

  @enforce_keys [:execution_id, :attempt, :fence, :event]
  defstruct [:execution_id, :attempt, :fence, :event]

  @type t :: %__MODULE__{
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          event: String.t()
        }
end
