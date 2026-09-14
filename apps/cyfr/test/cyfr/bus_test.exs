# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BusTest do
  use ExUnit.Case, async: true

  alias Cyfr.Bus
  alias Sanctum.Context

  @scoped_1 [
    :executions,
    :requests,
    :components,
    :builds,
    :schedule_runs,
    :tinctures,
    :enforcement,
    :webhooks,
    :api_keys,
    :mcp_servers,
    :schedules,
    :vault_changed
  ]

  @scoped_2 [:build, :register, :progress, :execution_events, :thread]

  defp ctx(athanor_id), do: %Context{user_id: "u1", athanor_id: athanor_id}

  describe "athanor-scoped topics" do
    test "every one carries the tenant prefix and the bus: vocabulary" do
      for fun <- @scoped_1 do
        topic = apply(Bus, fun, [ctx("ath_1")])

        assert String.starts_with?(topic, "tenant:ath_1:"),
               "#{fun}/1 is not tenant-prefixed"

        # One vocabulary: every tenant topic is spelled under `bus:`.
        assert String.starts_with?(topic, "tenant:ath_1:bus:"),
               "#{fun}/1 does not use the bus: vocabulary"
      end

      for fun <- @scoped_2 do
        assert String.starts_with?(apply(Bus, fun, ["id_1", ctx("ath_1")]), "tenant:ath_1:"),
               "#{fun}/2 is not tenant-prefixed"
      end
    end

    test "a Context and a bare athanor id name the same topic" do
      for fun <- @scoped_1 do
        assert apply(Bus, fun, [ctx("ath_1")]) == apply(Bus, fun, ["ath_1"])
      end

      for fun <- @scoped_2 do
        assert apply(Bus, fun, ["id_1", ctx("ath_1")]) ==
                 apply(Bus, fun, ["id_1", "ath_1"])
      end
    end

    test "two athanors never share a topic" do
      for fun <- @scoped_1 do
        refute apply(Bus, fun, [ctx("ath_1")]) == apply(Bus, fun, [ctx("ath_2")])
      end
    end

    test "an unresolved athanor raises rather than routing somewhere" do
      for fun <- @scoped_1 do
        assert_raise ArgumentError, fn -> apply(Bus, fun, [ctx(nil)]) end
      end
    end

    test "every name is distinct" do
      names = Enum.map(@scoped_1, &apply(Bus, &1, [ctx("ath_1")]))
      assert length(Enum.uniq(names)) == length(names)
    end

    test "schedule rows and schedule firings are different topics" do
      # One word apart in the vocabulary, two different message shapes:
      # `:schedules_updated` vs `{:schedule_fired, meta, meas}`.
      refute Bus.schedules(ctx("ath_1")) == Bus.schedule_runs(ctx("ath_1"))
    end
  end

  describe "global topics" do
    test "carry no tenant prefix" do
      for topic <- [
            Bus.vault_changed_global(),
            Bus.sessions(),
            Bus.memberships("user_1"),
            Bus.platform_notify(),
            Bus.health_check(7)
          ] do
        refute String.starts_with?(topic, "tenant:"), "#{topic} should be global"
      end
    end

    test "global/0 lists exactly the unscoped topics" do
      listed = Enum.map(Bus.global(), &elem(&1, 0))

      assert listed == [
               "sanctum:vault_changed",
               "sanctum:sessions",
               "sanctum:memberships:<user_id>",
               "platform:notify",
               "health_check:<nonce>"
             ]

      for {_topic, reason} <- Bus.global() do
        assert is_binary(reason) and reason != ""
      end
    end

    test "the tray topic is tenant-prefixed and agrees with Sanctum.Notify" do
      # Notify.topic/1 uses the shared tenant-topic builder.
      assert Bus.notify("ath_1") == Sanctum.Notify.topic("ath_1")
      assert String.starts_with?(Bus.notify("ath_1"), "tenant:ath_1:")
    end
  end
end
