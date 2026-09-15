# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Authority.TransitionAsyncEmitTest do
  use ExUnit.Case, async: true

  alias Cyfr.Authority
  alias Cyfr.Authority.Transition
  alias Cyfr.Test.AuthorityFixtures, as: Fixtures

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"

  # ============================================================================
  # The async five — permitted identically in both cursor states
  # ============================================================================

  describe "async five" do
    test "each is permitted with its own target shape, bound or unbound" do
      bound = Fixtures.root!()
      unbound = Authority.zero()

      cases = [
        {:await, {:task, "task_1"}},
        {:await_all, {:tasks, ["task_1", "task_2"]}},
        {:await_any, {:tasks, ["task_1", "task_2"]}},
        {:poll, {:task, "task_1"}},
        {:cancel, {:task, "task_1"}}
      ]

      for {fun, target} <- cases, auth <- [bound, unbound] do
        assert Transition.step(auth, fun, target) == {:allow_async, fun},
               "expected #{fun} to be permitted for #{inspect(auth.cursor)}"
      end
    end

    test "wrong task shapes are defined invalids, not denials" do
      auth = Fixtures.root!()

      assert {:invalid, {:malformed_target, :await, :tasks}} =
               Transition.step(auth, :await, {:tasks, ["task_1"]})

      assert {:invalid, {:malformed_target, :await_all, :task}} =
               Transition.step(auth, :await_all, {:task, "task_1"})

      assert {:invalid, {:malformed_target, :cancel, :invoke}} =
               Transition.step(auth, :cancel, Fixtures.invoke(@catalyst))

      assert {:invalid, {:malformed_target, :call, :task}} =
               Transition.step(auth, :call, {:task, "task_1"})

      assert {:invalid, {:malformed_target, :spawn, :event}} =
               Transition.step(auth, :spawn, {:event, %{"msg" => "hi"}})
    end
  end

  # ============================================================================
  # Emit — provenance-tagged
  # ============================================================================

  describe "emit" do
    test "a bound emit is attributed to the current node" do
      auth = Fixtures.root!()

      assert {:allow_emit, {:attributed, @formula}} =
               Transition.step(auth, :emit, {:event, %{"progress" => 1}})

      {:child, child} =
        Transition.step(
          auth,
          :call,
          Fixtures.invoke(@catalyst, need: "source", declared_needs: Fixtures.formula_needs())
        )

      assert {:allow_emit, {:attributed, @catalyst}} =
               Transition.step(child, :emit, {:event, %{"progress" => 2}})
    end

    test "an unbound emit is tagged untrusted" do
      assert {:allow_emit, :untrusted} =
               Transition.step(Authority.zero(), :emit, {:event, %{"progress" => 1}})

      auth = Fixtures.root!()
      {:child_zero, child} = Transition.step(auth, :call, Fixtures.invoke("formula:evil.corp.x"))

      assert {:allow_emit, :untrusted} =
               Transition.step(child, :emit, {:event, %{"progress" => 1}})
    end
  end
end
