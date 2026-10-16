# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.FlowTest do
  @moduledoc """
  `Prima.Flow`: the flow grammar a manifest and a stored edge are held to,
  and the one decision every send is held to.
  """

  use ExUnit.Case, async: true

  alias Prima.{Flow, Source}

  @declared %{domains: ["api.example.test", "*.x.test", "frame.example.test"], needs: ["api_key"]}

  describe "parse/2" do
    test "reads declared exits of every kind as a set, ordered by class then exit" do
      raw = [
        %{"from" => "outside", "to" => "api.example.test"},
        %{"from" => "pinned", "to" => "server:search"},
        %{"from" => "filed", "to" => "need:api_key"},
        %{"from" => "outside", "to" => "api.example.test"},
        %{"from" => "vault_disclosed", "to" => "*.x.test"}
      ]

      assert {:ok, flows} = Flow.parse(raw, @declared)

      assert flows == [
               %{from: :pinned, to: "server:search"},
               %{from: :filed, to: "need:api_key"},
               %{from: :vault_disclosed, to: "*.x.test"},
               %{from: :outside, to: "api.example.test"}
             ]

      assert Flow.to_json(flows) |> Flow.parse(:any) == {:ok, flows}
      assert Flow.parse(nil, @declared) == {:ok, []}
    end

    test "refuses an undeclared exit, an unknown class, unsettled, unknown keys and a malformed entry" do
      for {raw, reason} <- [
            {[%{"from" => "filed", "to" => "evil.test"}], {:undeclared_flow_exit, "evil.test"}},
            {[%{"from" => "filed", "to" => "need:other"}], {:undeclared_flow_exit, "need:other"}},
            {[%{"from" => "secret", "to" => "api.example.test"}],
             {:unknown_flow_class, "secret"}},
            {[%{"from" => "unsettled", "to" => "api.example.test"}],
             {:unknown_flow_class, "unsettled"}},
            {[%{"from" => "filed", "to" => "api.example.test", "via" => "x"}],
             {:unknown_flow_keys, ["via"]}},
            {[%{"from" => "filed", "to" => "server:"}], {:malformed_flow_exit, "server:"}},
            {["filed"], {:flow_not_an_object, "filed"}},
            {%{}, {:flows_not_a_list, %{}}}
          ] do
        assert Flow.parse(raw, @declared) == {:error, reason}
      end
    end
  end

  describe "bound/2" do
    test "keeps a domain flow while an edge domain is its pattern or lies under it, and need and server flows while bound" do
      flows = [
        %{from: :filed, to: "*.x.test"},
        %{from: :filed, to: "api.example.test"},
        %{from: :pinned, to: "need:api_key"},
        %{from: :pinned, to: "server:search"},
        %{from: :pinned, to: "server:other"}
      ]

      assert Flow.bound(flows, %{domains: ["api.x.test"], needs: ["api_key"], servers: ["search"]}) ==
               [
                 %{from: :pinned, to: "need:api_key"},
                 %{from: :pinned, to: "server:search"},
                 %{from: :filed, to: "*.x.test"}
               ]
    end
  end

  describe "uncovered/3" do
    test "an empty ledger is covered whatever the flows" do
      assert Flow.uncovered([], {:domain, "api.example.test"}, flows: []) == []
    end

    test "a class reaches a host only through a flow whose pattern matches it" do
      ledger = [Source.new(:filed), Source.new(:pinned)]
      flows = [%{from: :filed, to: "*.x.test"}, %{from: :pinned, to: "api.example.test"}]

      assert Flow.uncovered(ledger, {:domain, "api.x.test"}, flows: flows) == [
               Source.new(:pinned)
             ]

      assert Flow.uncovered(ledger, {:domain, "api.example.test"}, flows: flows) == [
               Source.new(:filed)
             ]

      assert Flow.uncovered([Source.new(:filed)], {:domain, "x.test"}, flows: flows) == [
               Source.new(:filed)
             ]
    end

    test "an outside source is covered by name only for its own exact host, never by a pattern" do
      ledger = [Source.outside("api.x.test")]

      assert Flow.uncovered(ledger, {:domain, "api.x.test"}, flows: []) == []
      assert Flow.uncovered(ledger, {:domain, "other.x.test"}, flows: []) == ledger

      assert Flow.uncovered([Source.outside("*.x.test")], {:domain, "api.x.test"}, flows: []) ==
               [Source.outside("*.x.test")]

      assert Flow.uncovered([Source.outside(nil)], {:domain, "api.x.test"}, flows: []) ==
               [Source.outside(nil)]
    end

    test "a server flow reaches only its server, a need flow reaches no send, and launch classes reach every exit" do
      ledger = [Source.new(:vault_disclosed)]

      assert Flow.uncovered(ledger, {:server, "search"},
               flows: [%{from: :vault_disclosed, to: "server:search"}]
             ) == []

      assert Flow.uncovered(ledger, {:server, "other"},
               flows: [%{from: :vault_disclosed, to: "server:search"}]
             ) == ledger

      assert Flow.uncovered(ledger, {:domain, "api.example.test"},
               flows: [%{from: :vault_disclosed, to: "need:api_key"}]
             ) == ledger

      assert Flow.uncovered(ledger, {:domain, "api.example.test"},
               launch_classes: [:vault_disclosed]
             ) == []
    end
  end

  test "a refusal names the uncovered classes and the exit, and reads as its Prima.Refusal row" do
    refusal = Flow.refusal([Source.outside("a.test"), Source.new(:filed)], {:domain, "b.test"})
    assert refusal == {:flow_not_declared, %{classes: [:filed, :outside], exit: "b.test"}}

    assert %Prima.Refusal{class: :forbidden, message: message} = Prima.Refusal.classify(refusal)

    assert message ==
             "This run read filed, outside material, and its grant declares no flow of it to b.test"

    assert Flow.refusal([Source.new(:pinned)], {:server, "search"}) ==
             {:flow_not_declared, %{classes: [:pinned], exit: "server:search"}}
  end
end
