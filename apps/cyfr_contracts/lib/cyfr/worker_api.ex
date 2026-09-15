# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerAPI do
  @moduledoc """
  What CYFR asks of a worker service. A worker service implements this
  behaviour; CYFR is its client.

  A worker service runs no guest code: it starts runners, kills them and
  reports on them. Every request is addressed to one worker service and
  signed with the dispatch key (`Cyfr.WorkerAuth.request_header/3`); the
  worker service verifies it (`Cyfr.WorkerAuth.verify_request/4`), refuses
  a request addressed to another worker service and refuses a nonce it
  has already seen. It reports each runner's exit to CYFR itself
  (`c:Cyfr.HostAPI.runner_exited/2`).
  """

  @typedoc """
  A worker service's state: its boot id, which changes on every start; its
  runners, by whether they are fresh, idle or busy; and the attempts its
  runners have claimed.
  """
  @type status :: %{
          boot: String.t(),
          runners: %{
            fresh: non_neg_integer(),
            idle: non_neg_integer(),
            busy: non_neg_integer()
          },
          attempts: [String.t()]
        }

  @doc """
  Start an assignment on a runner. `input` is the execution's input bytes,
  bound by the assignment's `input_digest`, and `sealed_keys` is the
  attempt key sealed with the dispatch seal key
  (`Cyfr.WorkerAuth.seal_attempt_key/2`). The runner attaches
  (`c:Cyfr.HostAPI.attach/2`) before it runs anything. `:malformed` means
  the assignment cannot be read or is addressed to another worker service,
  the input does not match its digest or the keys do not open as its
  attempt.
  """
  @callback start(Cyfr.Assignment.token(), input :: binary(), sealed_keys :: String.t()) ::
              :ok | {:error, :malformed}

  @doc """
  Stop an execution. For a subtree root, the worker service releases the
  runner; for a child, it sends the runner a cancel and taints it. The
  execution's durable cancel request remains the fence. `:not_found` means
  no runner of this worker service runs it.
  """
  @callback kill(execution_id :: String.t()) :: :ok | {:error, :not_found}

  @doc "The worker service's state."
  @callback status() :: {:ok, status()}
end
