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
  answers two things about one:

    * `fixture/1` — the identifiers a case reads rows by, and the signed
      assignment. Both cross the control channel, and between them a case
      on the control node can make that attempt's host calls itself: its
      keys derive from the shared worker root and those identifiers, and
      the assignment names the member they belong to and the address they
      are posted at (`host_routing_test.exs`);
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

  @doc "Sign and answer a host call for `label` on this member."
  @spec call(atom(), String.t(), map(), keyword()) :: map()
  def call(label, op, args, opts \\ []),
    do: GenServer.call(ensure(), {:call, label, op, args, opts}, 60_000)

  @doc """
  Complete `label`'s run as its runner would: the outcome is written and
  the attempt closed, all through a signed host call.
  """
  @spec complete(atom(), map()) :: map()
  def complete(label, data \\ %{"ok" => true}),
    do: GenServer.call(ensure(), {:complete, label, data}, 60_000)

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

  def handle_call({:call, label, op, args, opts}, _from, held) do
    fixture = Map.fetch!(held, label)
    {:reply, Cyfr.Test.AttemptFixtures.call(fixture, op, args, opts), held}
  end

  def handle_call({:complete, label, data}, _from, held) do
    fixture = Map.fetch!(held, label)
    args = %{"outcome" => completion(fixture, data)}
    {:reply, Cyfr.Test.AttemptFixtures.call(fixture, "complete", args), held}
  end

  defp completion(fixture, data) do
    Cyfr.Test.AttemptFixtures.outcome(fixture, "completed", %{
      "output" => Jason.encode!(data),
      "duration_ms" => 1
    })
  end

  # An attempt answers its waiter — this process — when its run ends.
  # Nothing here reads that: the case reads the rows.
  @impl true
  def handle_info(_message, held), do: {:noreply, held}

  # Only what crosses the control channel: identifiers and the signed
  # assignment, never the pid or the structs, which mean nothing off the
  # member that made them. `member` and the address inside the assignment
  # are what a case reads to post this attempt's host calls where they
  # belong; its keys are not carried, since they derive from the shared
  # root and the identifiers above.
  defp identifiers(fixture) do
    Map.take(fixture, [
      :athanor_id,
      :execution_id,
      :attempt,
      :fence,
      :generation,
      :service,
      :boot,
      :runner,
      :member,
      :assignment
    ])
  end
end
