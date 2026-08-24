# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TopicsTest do
  use ExUnit.Case, async: true

  alias Prism.Topics
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

  @scoped_2 [:build, :register, :progress, :execution_events]

  defp ctx(athanor_id), do: %Context{user_id: "u1", athanor_id: athanor_id}

  describe "athanor-scoped topics" do
    test "every one carries the tenant prefix" do
      for fun <- @scoped_1 do
        assert String.starts_with?(apply(Topics, fun, [ctx("ath_1")]), "tenant:ath_1:"),
               "#{fun}/1 is not tenant-prefixed"
      end

      for fun <- @scoped_2 do
        assert String.starts_with?(apply(Topics, fun, ["id_1", ctx("ath_1")]), "tenant:ath_1:"),
               "#{fun}/2 is not tenant-prefixed"
      end
    end

    test "a Context and a bare athanor id name the same topic" do
      for fun <- @scoped_1 do
        assert apply(Topics, fun, [ctx("ath_1")]) == apply(Topics, fun, ["ath_1"])
      end

      for fun <- @scoped_2 do
        assert apply(Topics, fun, ["id_1", ctx("ath_1")]) ==
                 apply(Topics, fun, ["id_1", "ath_1"])
      end
    end

    test "two athanors never share a topic" do
      for fun <- @scoped_1 do
        refute apply(Topics, fun, [ctx("ath_1")]) == apply(Topics, fun, [ctx("ath_2")])
      end
    end

    test "an unresolved athanor raises rather than routing somewhere" do
      for fun <- @scoped_1 do
        assert_raise ArgumentError, fn -> apply(Topics, fun, [ctx(nil)]) end
      end
    end

    test "every name is distinct" do
      names = Enum.map(@scoped_1, &apply(Topics, &1, [ctx("ath_1")]))
      assert length(Enum.uniq(names)) == length(names)
    end

    test "schedule rows and schedule firings are different topics" do
      # One word apart in the vocabulary, two different message shapes:
      # `:schedules_updated` vs `{:schedule_fired, meta, meas}`.
      refute Topics.schedules(ctx("ath_1")) == Topics.schedule_runs(ctx("ath_1"))
    end
  end

  describe "global topics" do
    test "carry no tenant prefix" do
      for topic <- [
            Topics.vault_changed_global(),
            Topics.sessions(),
            Topics.memberships("user_1"),
            Topics.platform_notify(),
            Topics.health_check(7)
          ] do
        refute String.starts_with?(topic, "tenant:"), "#{topic} should be global"
      end
    end

    test "global/0 lists exactly the unscoped topics" do
      listed = Enum.map(Topics.global(), &elem(&1, 0))

      assert listed == [
               "sanctum:vault_changed",
               "sanctum:sessions",
               "sanctum:memberships:<user_id>",
               "platform:notify",
               "health_check:<nonce>"
             ]

      for {_topic, reason} <- Topics.global() do
        assert is_binary(reason) and reason != ""
      end
    end

    test "the tray topic is tenant-prefixed and agrees with Sanctum.Notify" do
      # `Notify.topic/1` used to spell the `tenant:` prefix itself; it now
      # goes through the same builder as everything else.
      assert Topics.notify("ath_1") == Sanctum.Notify.topic("ath_1")
      assert String.starts_with?(Topics.notify("ath_1"), "tenant:ath_1:")
    end
  end
end
