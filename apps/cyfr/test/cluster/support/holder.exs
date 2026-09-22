# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Holder do
  @moduledoc """
  The process on a member that holds a case's attempts open.

  An execution attempt is a process, and `Cyfr.Test.AttemptFixtures`
  registers **the calling process** as its waiter. A fixture built inside
  a `:peer` call would be built inside a process that exits when the call
  returns, so the attempt would go with it and the case would be watching
  a hole rather than a run. This process outlives the call, so what the
  member holds is what a member holds: an open attempt with a lease on
  its row and a runner attached to it.

  One holder per member, started on demand. It keeps fixtures by label and
  answers three things about one:

    * `fixture/1` — the identifiers a case reads rows by;
    * `sign/4` — a signed host-call header and its body, which a case may
      then deliver to **either** member's host surface. That is what makes
      the host-routing case possible: the same call, verified against two
      different members' standing;
    * `call/4` — sign and deliver on this member, the ordinary path.
  """

  use GenServer

  @compile {:no_warn_undefined, [Cyfr.Test.AttemptFixtures, Sanctum.TestContext]}

  @name __MODULE__

  @doc "Open an attempt on this member under `label`, and answer what a case reads it by."
  @spec attach!(atom(), keyword()) :: map()
  def attach!(label, opts \\ []), do: GenServer.call(ensure(), {:attach, label, opts}, 60_000)

  @doc "The identifiers of the attempt held under `label`."
  @spec fixture(atom()) :: map()
  def fixture(label), do: GenServer.call(ensure(), {:fixture, label}, 30_000)

  @doc """
  A signed host call for `label`'s attempt: `{header, body}`, ready to be
  answered by `Cyfr.Execution.Host.call/2` on any member.
  """
  @spec sign(atom(), String.t(), map(), keyword()) :: {String.t(), String.t()}
  def sign(label, op, args, opts \\ []),
    do: GenServer.call(ensure(), {:sign, label, op, args, opts}, 30_000)

  @doc "Sign and answer a host call for `label` on this member."
  @spec call(atom(), String.t(), map(), keyword()) :: map()
  def call(label, op, args, opts \\ []),
    do: GenServer.call(ensure(), {:call, label, op, args, opts}, 60_000)

  @doc "Forget everything this holder holds, ending the attempts with it."
  @spec release!() :: :ok
  def release! do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp ensure do
    case Process.whereis(@name) do
      nil ->
        {:ok, pid} = GenServer.start(__MODULE__, [], name: @name)
        pid

      pid ->
        pid
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:attach, label, opts}, _from, held) do
    fixture = Cyfr.Test.AttemptFixtures.attached!(opts)
    {:reply, identifiers(fixture), Map.put(held, label, fixture)}
  end

  def handle_call({:fixture, label}, _from, held),
    do: {:reply, identifiers(Map.fetch!(held, label)), held}

  def handle_call({:sign, label, op, args, opts}, _from, held) do
    fixture = Map.fetch!(held, label)
    body = Cyfr.Test.AttemptFixtures.body(op, args)
    {:reply, {Cyfr.Test.AttemptFixtures.header(fixture, body, opts), body}, held}
  end

  def handle_call({:call, label, op, args, opts}, _from, held) do
    fixture = Map.fetch!(held, label)
    {:reply, Cyfr.Test.AttemptFixtures.call(fixture, op, args, opts), held}
  end

  # Only what crosses the control channel: identifiers and the assignment,
  # never the pid or the structs, which mean nothing off the member that
  # made them.
  defp identifiers(fixture) do
    Map.take(fixture, [
      :athanor_id,
      :execution_id,
      :attempt,
      :fence,
      :generation,
      :service,
      :boot,
      :runner
    ])
  end
end
