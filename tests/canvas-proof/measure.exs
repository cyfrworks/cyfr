# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The vault page's operations measured inside a running server, evaluated
# by `bin/cyfr rpc` (tests/canvas-proof/run.sh): `vault.list` and
# `vault.status`, each called CALLS times at CONCURRENCY at once, as the
# console calls a tool for the session's person (`PrismWeb.Ops.call_tool/3`,
# through the gate). Evaluates to a function of [token, calls, concurrency]
# that answers one line, `MEASURE=` and a JSON object: per operation the
# count, the refusals and p50, p95 and p99 in milliseconds, and what the
# burst did to the member's lease and to the audit:
#
#   renewals   every renewal the member's claimant (`Cyfr.Cell`) asked
#              while the operation ran, each as the time from its call to
#              its answer and whether it renewed, read by tracing the
#              claimant's calls to `Arca.ControlPlane.renew/1`; each burst
#              is started just before the member's next renewal, so one
#              falls inside it;
#   held       whether the member held its slot at every sample, and its
#              generation before and after (a new one is a lost slot);
#   writers    the most audit writers running at once, of the node's cap;
#   queue      the most audit and control-plane requests waiting for a
#              turn at the write lock at once;
#   lost       the audit writes the log could not make, by stage and kind.
#
# `slot_kept` and `renewals_ok` sum the operations up, and run.sh fails the
# proof on either: the member lost its slot or its generation, or a renewal
# asked during a burst failed or none was asked.

fn [token, calls, concurrency] ->
  {:ok, ctx} = Sanctum.Caller.establish({:session, token})
  calls = String.to_integer(calls)
  concurrency = String.to_integer(concurrency)
  cell = Process.whereis(Cyfr.Cell)
  %{renew_ms: renew_ms, lease_ms: lease_ms} = :sys.get_state(cell)
  standing_key = {Arca.ControlPlane, :standing}
  renew = {Arca.ControlPlane, :renew, 1}
  now = fn -> System.monotonic_time(:millisecond) end

  percentile = fn sorted, p ->
    rank = max(0, min(length(sorted) - 1, ceil(p / 100 * length(sorted)) - 1))
    sorted |> Enum.at(rank) |> Kernel./(1000) |> Float.round(2)
  end

  # What the member last published of its standing: it changes with each
  # renewal.
  published = fn -> :persistent_term.get(standing_key, nil) end

  # The claimant's renewals while it is traced, each as the time from its
  # call to its answer and whether it renewed. Asked to stop, it waits for
  # a renewal still in flight to answer first.
  collector = fn ->
    loop = fn loop, calls, done ->
      receive do
        {:trace, ^cell, :call, {Arca.ControlPlane, :renew, _args}} ->
          loop.(loop, [now.() | calls], done)

        {:trace, ^cell, :return_from, ^renew, answer} ->
          [called | rest] = calls
          loop.(loop, rest, [%{ms: now.() - called, ok: match?({:ok, _}, answer)} | done])

        {:stop, from} when calls == [] ->
          send(from, {:renewals, Enum.reverse(done)})
      end
    end

    loop.(loop, [], [])
  end

  # Samples until told to stop: every millisecond whether the member held
  # its slot, a term read; every tenth, the audit writers and the turn
  # queue, which are asked of processes the burst itself uses.
  sampler = fn ->
    loop = fn loop, seen ->
      seen = %{
        seen
        | samples: seen.samples + 1,
          unheld: seen.unheld + if(Arca.ControlPlane.held?(), do: 0, else: 1)
      }

      seen =
        if rem(seen.samples, 10) == 0 do
          turn = Arca.WriteTurn.status()

          %{
            seen
            | writers: max(seen.writers, Arca.DecisionLog.writers()),
              audit_waiting: max(seen.audit_waiting, turn.waiting.audit),
              control_plane_waiting: max(seen.control_plane_waiting, turn.waiting.control_plane)
          }
        else
          seen
        end

      receive do
        {:stop, from} -> send(from, {:sampled, seen})
      after
        1 -> loop.(loop, seen)
      end
    end

    loop.(loop, %{samples: 0, unheld: 0, writers: 0, audit_waiting: 0, control_plane_waiting: 0})
  end

  # Starts the burst a little before the member's next renewal, so that
  # renewal is asked while the burst runs: waits for a renewal to publish,
  # then for most of the claimant's interval.
  align = fn ->
    first = published.()
    until = now.() + renew_ms + 1_000

    wait = fn wait ->
      if published.() == first and now.() < until do
        Process.sleep(1)
        wait.(wait)
      end
    end

    wait.(wait)
    Process.sleep(max(renew_ms - 200, 0))
  end

  lost = :ets.new(:canvas_measure_lost, [:public, :bag])
  handler = {:canvas_measure, make_ref()}

  :ok =
    :telemetry.attach(
      handler,
      [:cyfr, :grimoire, :decision, :lost],
      fn _event, _measurements, %{stage: stage, kind: kind}, table ->
        :ets.insert(table, {"#{stage}:#{kind}"})
      end,
      lost
    )

  1 = :erlang.trace_pattern(renew, [{:_, [], [{:return_trace}]}], [:global])

  measure = fn tool ->
    align.()
    :ets.delete_all_objects(lost)
    generation = Arca.ControlPlane.generation()
    test = self()
    renewals = spawn(fn -> collector.() end)
    1 = :erlang.trace(cell, true, [:call, {:tracer, renewals}])
    watcher = spawn(fn -> sampler.() end)

    results =
      1..calls
      |> Task.async_stream(
        fn _ ->
          {micros, answer} = :timer.tc(fn -> PrismWeb.Ops.call_tool(ctx, tool, %{}) end)
          {micros, match?({:ok, _}, answer)}
        end,
        max_concurrency: concurrency,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    send(watcher, {:stop, test})
    seen = receive do: ({:sampled, seen} -> seen)
    send(renewals, {:stop, test})

    # A renewal that never answers is a failed one.
    renewed =
      receive do
        {:renewals, renewed} -> renewed
      after
        lease_ms -> [%{ms: lease_ms, ok: false}]
      end

    :erlang.trace(cell, false, [:call])
    sorted = results |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    %{
      n: length(results),
      refused: Enum.count(results, &(not elem(&1, 1))),
      p50: percentile.(sorted, 50),
      p95: percentile.(sorted, 95),
      p99: percentile.(sorted, 99),
      renewals: renewed,
      held: %{
        throughout: seen.unheld == 0,
        samples: seen.samples,
        unheld_samples: seen.unheld,
        generation_before: inspect(generation),
        generation_after: inspect(Arca.ControlPlane.generation())
      },
      writers: %{most: seen.writers, cap: Arca.DecisionLog.max_writers()},
      queue: %{audit: seen.audit_waiting, control_plane: seen.control_plane_waiting},
      lost: lost |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
    }
  end

  measured = %{"vault.list": measure.("vault/list"), "vault.status": measure.("vault/status")}
  :erlang.trace_pattern(renew, false, [:global])
  :telemetry.detach(handler)

  "MEASURE=" <>
    Jason.encode!(
      Map.merge(measured, %{
        adapter: Application.get_env(:arca, :database_adapter) |> inspect(),
        concurrency: concurrency,
        calls: calls,
        lease_ms: lease_ms,
        renew_ms: renew_ms,
        slot_kept:
          Enum.all?(Map.values(measured), fn m ->
            m.held.throughout and m.held.generation_before == m.held.generation_after
          end),
        renewals_ok:
          Enum.all?(Map.values(measured), fn m ->
            m.renewals != [] and Enum.all?(m.renewals, & &1.ok)
          end)
      })
    )
end
