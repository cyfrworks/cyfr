# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Boot do
  @moduledoc """
  What runs **on** a member: bringing the whole `:cyfr` application up,
  giving it a worker service of its own, and the two cuts a case can make
  from inside it.

  Nothing here is a stand-in for the product's boot. `Application.ensure_all_started/1`
  starts the same supervision tree a release starts, under the same
  refusals: `Cyfr.Cell` reads `Cyfr.Cell.facts/0` and raises if this
  deployment cannot form a cell, and the member claims its
  `cell_leases` slot before anything that admits work.

  A worker service is **not** started with the application. It is the
  suite's scripted one (`Cyfr.Test.ScriptedWorker`), served over HTTP on a
  loopback port of this member's own and holding keys derived from the
  shared worker root, and it is started by the case that needs it, with
  the reference and script that case scripts. One per member is what makes
  the workers **independently reachable**: a member can be cut off from a
  worker its peer can still hear.
  """

  @compile {:no_warn_undefined, [Cyfr.Test.ScriptedWorker, Cyfr.Test.ScriptedWorkerListener]}

  @doc """
  Start the application on this member. Answers `:ok`, or `{:error,
  reason}` naming what stopped the boot — a member that cannot form a
  cell raises here, and its refusal is what the case reads.
  """
  @spec start!(String.t()) :: :ok | {:error, term()}
  def start!(_worker_service) do
    case Application.ensure_all_started(:cyfr) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
  end

  @doc """
  Start this member's scripted worker service for `opts` (`:ref` and
  `:script` at least), and answer the endpoint dispatch reaches it at.
  """
  @spec start_worker!(keyword()) :: map()
  def start_worker!(opts) do
    stop_worker!()
    {:ok, _pid} = Cyfr.Test.ScriptedWorker.start_link(opts)
    Cyfr.Test.ScriptedWorker.endpoint()
  end

  @doc "Stop this member's scripted worker service, if it is running."
  @spec stop_worker!() :: :ok
  def stop_worker! do
    case Process.whereis(Cyfr.Test.ScriptedWorker) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc "Replace what this member's scripted worker will answer next."
  @spec script!([term()]) :: :ok
  def script!(items), do: Cyfr.Test.ScriptedWorker.script(items)

  @doc """
  Point this member's dispatch at `endpoints` for `references` and at
  nothing else, so a case decides which worker each member reaches.
  """
  @spec route!([String.t()], [map()]) :: :ok
  def route!(references, endpoints) do
    Application.put_env(
      :cyfr,
      :workers,
      Enum.map(endpoints, &Map.put(&1, :components, references))
    )

    :ok
  end

  @doc "Whether this member holds its cell slot, and under which generation."
  @spec standing() :: %{held: boolean(), generation: term(), boot: String.t(), node: node()}
  def standing do
    %{
      held: Arca.ControlPlane.held?(),
      generation: Arca.ControlPlane.generation(),
      boot: Cyfr.Boot.id(),
      node: node()
    }
  end

  @doc "This member's copy of the roster, and what it proposes for `subject`."
  @spec proposal(String.t()) :: %{roster: [String.t()], mine: boolean(), owner: term()}
  def proposal(subject) do
    %{
      roster: Cyfr.Cell.roster(),
      mine: Cyfr.Cell.mine?(subject),
      owner: Cyfr.Cell.owner_of(subject)
    }
  end

  @doc "Stop the application cleanly, releasing the slot and every claim."
  @spec stop!() :: :ok
  def stop! do
    Application.stop(:cyfr)
    :ok
  end

  @doc false
  # Kept so `Cyfr.Cluster.Cell.heal!/0` has one call for every cut a case
  # can make from outside a member. The database wire is the control
  # node's (`Cyfr.Cluster.Wire`), so there is nothing to put back here.
  @spec restore_store() :: :ok
  def restore_store, do: :ok
end
