# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Barrier do
  @moduledoc """
  Where two members act at one instant, the instant is **made** here.

  Four tests in this slice asserted more than their mechanism could
  guarantee, each passing alone and failing in a full run. A case that
  starts two members a millisecond apart and hopes they collide is the
  same mistake: it passes on a quiet machine and says nothing on a busy
  one. So a case that needs an interleaving takes it — both parties do
  their reads, both arrive at the barrier, and neither is released until
  the other has arrived. What is left between the release and the two
  writes is one message send, not a scheduler's opinion.

  The barrier lives on a member rather than on the control node, because
  the control node is not distributed (`Cyfr.Cluster.Cell`) and cannot be
  reached from inside a member. It is addressed by `{name, node}`, so
  either member can host it and the other reaches it over distribution —
  which is also why no case that cuts distribution may use one.
  """

  @compile {:no_warn_undefined, Cyfr.Cluster.Cell}

  @doc """
  Run `funs` — a keyword list of `member id => {module, function, args}` —
  one on each member, released from a barrier so that every one of them
  has finished whatever it did before the barrier when the first one
  passes it.

  What each member runs is named rather than closed over: a function term
  is decoded only where its module exists at the same version, and a case
  file is loaded by ExUnit on the control node alone. The module must
  therefore be one this suite pushed to the members
  (`Cyfr.Cluster.Support`), which in practice means `Cyfr.Cluster.Fixtures`.

  Answers `[{member_id, result}]` in the order given. A call that raises
  answers `{:error, kind, reason}` rather than taking the case down with
  it, so a race whose loser refuses is readable.
  """
  @spec race(keyword({module(), atom(), [term()]})) :: keyword()
  def race(funs) when is_list(funs) do
    [{host_id, _} | _] = funs
    host = Cyfr.Cluster.Cell.member(host_id).node
    name = :"barrier_#{System.unique_integer([:positive])}"
    count = length(funs)

    :ok = Cyfr.Cluster.Cell.call(host_id, __MODULE__, :open, [name, count])

    tasks =
      for {id, fun} <- funs do
        {id,
         Task.async(fn ->
           Cyfr.Cluster.Cell.call(id, __MODULE__, :run, [{name, host}, fun], 60_000)
         end)}
      end

    results = for {id, task} <- tasks, do: {id, Task.await(task, 60_000)}
    :ok = Cyfr.Cluster.Cell.call(host_id, __MODULE__, :close, [name])
    results
  end

  @doc false
  # Opened on the host member. A plain process rather than a GenServer:
  # it has one job and it must not outlive the race that opened it.
  @spec open(atom(), pos_integer()) :: :ok
  def open(name, count) do
    pid = spawn(fn -> gather(count, []) end)
    Process.register(pid, name)
    :ok
  end

  @doc false
  @spec close(atom()) :: :ok
  def close(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  @doc false
  # Called on each member: arrive, wait for the last party, then act.
  @spec run({atom(), node()}, {module(), atom(), [term()]}) :: term()
  def run(barrier, {module, function, args}) do
    arrive(barrier)
    apply(module, function, args)
  catch
    kind, reason -> {:error, kind, reason}
  end

  @doc """
  Arrive at `barrier` and block until every party has. Raises at 30 s: a
  barrier that never releases is a case whose other party never ran, and
  a hanging suite says less than a failing one.
  """
  @spec arrive({atom(), node()}) :: :ok
  def arrive(barrier) do
    send(barrier, {:arrived, self()})

    receive do
      :go -> :ok
    after
      30_000 -> raise "barrier #{inspect(barrier)} never released"
    end
  end

  defp gather(count, waiting) when length(waiting) + 1 == count do
    receive do
      {:arrived, pid} -> for party <- [pid | waiting], do: send(party, :go)
    end

    idle()
  end

  defp gather(count, waiting) do
    receive do
      {:arrived, pid} -> gather(count, [pid | waiting])
    end
  end

  # The barrier stays put once released so a late `arrive/1` — a party
  # whose call was slower than the race — is answered rather than hung.
  defp idle do
    receive do
      {:arrived, pid} -> send(pid, :go)
    end

    idle()
  end
end
