# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.WaitingCallTest do
  @moduledoc """
  A call of an action declared `waits: true` (`Prima.Operation`) is given
  no handler timeout and no holder window: its charge has no
  `holder_deadline`, so the sweep leaves it to its attempt's end, and its
  handler answers past the window a call that does work is held to. A
  call without the flag keeps both: its charge has a deadline, and past
  its window it answers that its outcome is unknown. Both are charged,
  admitted and released alike. A short window (`:holder_window_ms`)
  stands in for the five minutes.
  """

  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Catalog
  alias Sanctum.Context

  @tool "waiting_probe"
  @node "formula:local.waiting-probe"
  @athanor "ath_test"
  @user "waiting_user"
  @window_ms 2_000

  defmodule Probe do
    @moduledoc false
    # Tells the process registered as `:waiting_probe_observer` it started,
    # then holds until it is told to answer.
    @behaviour Prima.Provider

    alias Prima.Operation

    @impl true
    def service, do: "probe"

    @impl true
    def tools do
      [
        Operation.tool([
          Operation.new("waiting_probe", "hold", "Wait for an answer", [],
            kind: :read,
            planes: [:in_chain],
            recovery: :replay_safe,
            waits: true
          ),
          Operation.new("waiting_probe", "work", "Work until told", [],
            kind: :write,
            planes: [:in_chain]
          )
        ])
      ]
    end

    @impl true
    def handle("waiting_probe", _ctx, %{"action" => action}) do
      send(:waiting_probe_observer, {:holding, action, self()})

      receive do
        :answer -> {:ok, %{"answered" => action}}
      end
    end
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    Process.register(self(), :waiting_probe_observer)

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{
            "@ingress" => %{"tools" => ["waiting_probe.hold", "waiting_probe.work"]}
          }
        }
      }
    }

    {:ok, blob} = Blob.parse(graph)

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-waiting",
          consent_id: "consent-waiting",
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => "sha256:waiting"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    {:ok, %{execution: root, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_waiting_#{System.unique_integer([:positive])}",
          reference: "#{@node}:1.0.0",
          user_id: @user,
          athanor_id: @athanor,
          component_type: "formula",
          origin: :programmatic
        },
        reservation: %{budget_id: auth.budget.id, cap: 1},
        grant: Cyfr.Test.AttemptFixtures.grant(@athanor),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    ctx =
      Context.enter_guest(%Context{
        user_id: @user,
        athanor_id: @athanor,
        scope: :athanor,
        permissions: MapSet.new([:*]),
        authenticated: true,
        request_id: "req_waiting"
      })

    charge = %{id: "call:w:1:c1:g0", attempt: attempt.attempt, generation: 0}
    lineage = %{parent_execution_id: root.id, attempt: attempt.attempt}

    {:ok,
     auth: auth, ctx: ctx, charge: Map.put(charge, :holder_execution_id, nil), lineage: lineage}
  end

  defp call(%{auth: auth, ctx: ctx, charge: charge, lineage: lineage}, action) do
    Task.async(fn ->
      Catalog.with_providers([Probe], fn ->
        Sanctum.Gate.call_in_chain(@tool, ctx, %{"action" => action}, auth,
          guest_fn: :spawn,
          charge: charge,
          lineage: lineage,
          holder_window_ms: @window_ms
        )
      end)
    end)
  end

  defp actor, do: Prima.Actor.in_athanor(@athanor)

  # The window has passed on this member's clock since `since`.
  defp window_passed(since) do
    Prima.Test.Wait.wait_until(
      fn -> System.monotonic_time(:millisecond) - since > 2 * @window_ms end,
      10_000
    )
  end

  test "the flag is read from the operation's one definition, and nowhere else" do
    Catalog.with_providers([Probe], fn ->
      assert Catalog.waits?(@tool, "hold")
      refute Catalog.waits?(@tool, "work")
      refute Catalog.waits?(@tool, "nope")
    end)

    assert Catalog.waits?("program", "wait")
    assert Catalog.waits?("aqua", "wait")
    refute Catalog.waits?("program", "start")
    refute Catalog.waits?("notes", "read")
  end

  test "a call that waits holds a charge with no deadline and answers past its window",
       %{auth: auth} = setup do
    since = System.monotonic_time(:millisecond)
    task = call(setup, "hold")
    assert_receive {:holding, "hold", handler}, 10_000

    # Charged as every call is, but with no deadline: the sweep leaves it.
    assert {:ok, [%{holder_deadline: nil}]} =
             Arca.BudgetReservations.charges(actor(), auth.budget.id)

    window_passed(since)
    assert {:ok, 0} = Arca.BudgetReservations.sweep(actor())
    assert Process.alive?(handler)

    send(handler, :answer)
    assert {:ok, %{"answered" => "hold"}} = Task.await(task, 10_000)

    # Released at its end, as every call's charge is.
    assert {:ok, []} = Arca.BudgetReservations.charges(actor(), auth.budget.id)
    assert Sanctum.TestContext.invoke_budget(auth).in_flight == 0
  end

  test "a call that does work keeps its deadline and answers uncertain past its window",
       %{auth: auth} = setup do
    task = call(setup, "work")
    assert_receive {:holding, "work", handler}, 10_000

    assert {:ok, [%{holder_deadline: %DateTime{}}]} =
             Arca.BudgetReservations.charges(actor(), auth.budget.id)

    {result, _log} = ExUnit.CaptureLog.with_log(fn -> Task.await(task, 10_000) end)

    assert {:error, {:uncertain, "Tool #{@tool} timed out; its outcome is unknown"}} == result
    refute Process.alive?(handler)
    assert {:ok, []} = Arca.BudgetReservations.charges(actor(), auth.budget.id)
    assert Sanctum.TestContext.invoke_budget(auth).in_flight == 0
  end
end
