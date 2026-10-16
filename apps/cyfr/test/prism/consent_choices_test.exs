# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.ConsentChoicesTest do
  @moduledoc """
  The consent sheet's choices, read as the pure functions they are: what a
  walk's decisions reconstruct to serializes to those decisions again,
  whole; a re-grant reopens on what the plan places, at the `now` it is
  given; a lifetime is computed from that `now`; a lowered limit is at
  most its ask, with the sheet's own sentences; a flow to an exit is only
  ever removed or kept again, never added.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Prism.ConsentChoices

  @ref "tincture:local.choices"
  @dep "catalyst:local.choices-db"
  @now ~U[2026-10-16 12:00:00Z]

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp need(name, ids),
    do: %{
      need: name,
      kind: "api_key",
      required: true,
      candidates: for(id <- ids, do: %{entry_id: id, source: "own"})
    }

  # A plan of one app need or two, and a dependency edge declaring one
  # need or two, each need with its own candidates.
  defp plan do
    gen all(
          app_needs <- integer(1..2),
          dep_needs <- integer(1..2)
        ) do
      %{
        source_ref: @ref,
        candidates: [],
        needs: for(i <- 1..app_needs, do: need("key_#{i}", ["vlt_a#{i}", "vlt_b#{i}"])),
        dependency_needs: [
          %{
            from: @ref,
            dep: @dep,
            needs: for(i <- 1..dep_needs, do: need("db_#{i}", ["vlt_d#{i}", "vlt_e#{i}"])),
            candidates: [%{label: "work", entry_id: "vlt_lent", source: "own"}]
          }
        ],
        head_bindings: []
      }
    end
  end

  defp lifetime do
    one_of([
      constant(%{"kind" => "standing"}),
      constant(%{"kind" => "once"}),
      map(integer(60..86_400), fn s ->
        %{"kind" => "until", "until" => @now |> DateTime.add(s) |> DateTime.to_iso8601()}
      end)
    ])
  end

  defp choice(source, id, need) do
    gen all(lifetime <- lifetime(), renew <- boolean()) do
      %{
        source: source,
        id: id,
        need: need,
        lifetime: lifetime,
        choice: if(lifetime["kind"] == "until", do: nil, else: lifetime["kind"]),
        renew: renew
      }
    end
  end

  # Account names distinct by Unicode's full lowercase mapping on one edge.
  defp names do
    map(list_of(boolean(), length: 4), fn picks ->
      for({name, true} <- Enum.zip(~w(Work Home Ops Lab), picks), do: name) |> Enum.take(3)
    end)
  end

  # The choices of a walk over `plan`: the app's default for one of its
  # needs, the edge's default (an entry, or the profile that lends one),
  # and named accounts beside each default.
  defp choices(plan) do
    [app_need | _] = plan.needs
    [row] = plan.dependency_needs
    several? = length(row.needs) > 1
    dep_need = hd(row.needs)
    dep_need_name = if several?, do: dep_need.need

    gen all(
          app <- choice("own", hd(app_need.candidates).entry_id, nil),
          default_kind <- member_of([:own, :label]),
          default <-
            if(default_kind == :own,
              do: choice("own", hd(dep_need.candidates).entry_id, dep_need_name),
              else: choice("label", "work", nil)
            ),
          app_names <- names(),
          dep_names <- if(default_kind == :own, do: names(), else: constant([])),
          app_accounts <- fixed_list(for(_ <- app_names, do: choice("own", "vlt_b1", nil))),
          dep_accounts <-
            fixed_list(for(_ <- dep_names, do: choice("own", "vlt_e1", dep_need_name)))
        ) do
      edge = {:need, app_need.need}

      accounts =
        for {name, choice} <- Enum.zip(app_names, app_accounts),
            into: %{},
            do:
              {{:account, edge, "name:" <> name},
               Map.merge(choice, %{name: name, fixed: true, seq: 0})}

      dep_accounts =
        for {name, choice} <- Enum.zip(dep_names, dep_accounts),
            into: %{},
            do:
              {{:account, {:dep, @ref, @dep}, "name:" <> name},
               Map.merge(choice, %{name: name, fixed: true, seq: 0})}

      %{
        {:need, app_need.need, nil} => app,
        {:dep, @ref, @dep} => default
      }
      |> Map.merge(accounts)
      |> Map.merge(dep_accounts)
    end
  end

  defp walk do
    gen all(
          plan <- plan(),
          choices <- choices(plan),
          label <- one_of([constant(nil), constant("work")]),
          origins <- member_of([["interactive"], ["interactive", "schedule"]]),
          subset <- member_of([%{}, %{@ref => %{"egress" => %{"methods" => ["GET"]}}}])
        ) do
      {plan, choices, label, origins, subset}
    end
  end

  # ---------------------------------------------------------------------------
  # Reconstruct, then serialize
  # ---------------------------------------------------------------------------

  property "the choices a walk's decisions reconstruct to serialize to those decisions" do
    check all({plan, choices, label, origins, subset} <- walk()) do
      decisions = ConsentChoices.decisions(@ref, label, origins, subset, choices)
      reconstructed = ConsentChoices.choices_of(decisions, plan)

      assert ConsentChoices.decisions(@ref, label, origins, subset, reconstructed) == decisions
    end
  end

  property "a walk drawn again from the choices the sheet held serializes as it did" do
    check all({plan, choices, label, origins, subset} <- walk()) do
      decisions = ConsentChoices.decisions(@ref, label, origins, subset, choices)

      again =
        decisions
        |> ConsentChoices.choices_of(plan)
        |> ConsentChoices.held_choices(choices, plan, @now)

      assert ConsentChoices.decisions(@ref, label, origins, subset, again) == decisions

      # Every choice the sheet held is held again: the decided ones as
      # decided, an until-lifetime by the button that made it.
      assert again == choices
    end
  end

  property "every decision names exactly one binding's entry and its lifetime" do
    check all({_plan, choices, label, origins, subset} <- walk()) do
      decisions = ConsentChoices.decisions(@ref, label, origins, subset, choices)

      assert decisions["ref"] == @ref
      assert decisions["origins"] == origins
      assert Map.get(decisions, "subset", %{}) == subset
      assert Map.get(decisions, "label") == label

      for item <- decisions["bindings"] ++ Map.get(decisions, "selections", []) do
        assert Enum.count(~w(entry_id instance_entry_id label), &Map.has_key?(item, &1)) == 1
        assert %{"kind" => kind} = item["lifetime"]
        assert kind in ~w(standing once until)
        assert Map.get(item, "renew", true) == true
      end
    end
  end

  test "a walk serializes exactly: defaults first, then each edge's accounts by name" do
    choices = %{
      {:need, "key_1", nil} => %{
        source: "own",
        id: "vlt_a1",
        need: nil,
        lifetime: %{"kind" => "standing"},
        choice: "standing",
        renew: false
      },
      {:account, {:need, "key_1"}, "row:2"} => %{
        source: "own",
        id: "vlt_b1",
        need: nil,
        lifetime: %{"kind" => "once"},
        choice: "once",
        renew: true,
        name: "Work",
        fixed: false,
        seq: 2
      },
      # No name yet: no decision.
      {:account, {:need, "key_1"}, "row:3"} => %{
        source: "own",
        id: "vlt_b1",
        need: nil,
        lifetime: %{"kind" => "standing"},
        choice: "standing",
        renew: false,
        name: "",
        fixed: false,
        seq: 3
      },
      # No lifetime chosen yet: no decision.
      {:dep, @ref, @dep} => %{
        source: "own",
        id: "vlt_d1",
        need: "db_1",
        lifetime: nil,
        choice: nil,
        renew: false
      }
    }

    assert ConsentChoices.decisions(@ref, nil, ["interactive"], %{}, choices) == %{
             "ref" => @ref,
             "origins" => ["interactive"],
             "bindings" => [
               %{
                 "need" => "key_1",
                 "entry_id" => "vlt_a1",
                 "lifetime" => %{"kind" => "standing"}
               },
               %{
                 "need" => "key_1",
                 "entry_id" => "vlt_b1",
                 "name" => "Work",
                 "lifetime" => %{"kind" => "once"},
                 "renew" => true
               }
             ]
           }
  end

  test "an entry made through a prompt for a need is bound there standing" do
    decisions = %{
      "ref" => @ref,
      "bindings" => [
        %{"need" => "key_1", "entry_id" => "vlt_old", "lifetime" => %{"kind" => "once"}},
        %{"need" => "key_1", "entry_id" => "vlt_w", "name" => "Work", "lifetime" => %{}},
        %{"need" => "key_2", "entry_id" => "vlt_x", "lifetime" => %{"kind" => "standing"}}
      ],
      "selections" => [
        %{"dep" => @dep, "from" => @ref, "label" => "work", "lifetime" => %{"kind" => "standing"}}
      ]
    }

    assert ConsentChoices.bind_entered(decisions, %{need: "key_1"}, "vlt_new")["bindings"] == [
             %{"need" => "key_1", "entry_id" => "vlt_new", "lifetime" => %{"kind" => "standing"}},
             %{"need" => "key_1", "entry_id" => "vlt_w", "name" => "Work", "lifetime" => %{}}
           ]

    assert ConsentChoices.bind_entered(decisions, %{from: @ref, dep: @dep, need: "db_2"}, "vlt_n")[
             "selections"
           ] == [
             %{
               "dep" => @dep,
               "from" => @ref,
               "entry_id" => "vlt_n",
               "need" => "db_2",
               "lifetime" => %{"kind" => "standing"}
             }
           ]
  end

  # ---------------------------------------------------------------------------
  # A re-grant reopens on what the plan places
  # ---------------------------------------------------------------------------

  defp head(key, binds, place, lifetime \\ %{kind: "standing", until: nil}) do
    %{binding_key: key, lifetime: lifetime, consumed: false}
    |> Map.merge(binds)
    |> Map.merge(place)
  end

  defp regrant(head_bindings, dep_needs \\ 1) do
    %{
      source_ref: @ref,
      candidates: [],
      needs: [need("key_1", ["vlt_a1", "vlt_b1"]) |> Map.put(:suggested, %{entry_id: "vlt_a1"})],
      dependency_needs: [
        %{
          from: @ref,
          dep: @dep,
          needs: for(i <- 1..dep_needs, do: need("db_#{i}", ["vlt_d#{i}"])),
          candidates: []
        }
      ],
      head_bindings: head_bindings
    }
  end

  test "a head binding reopens on its slot for the need the plan places it on, never wider" do
    ingress = %{source: "own", node: @ref, edge: "@ingress", need: "key_1"}

    plan =
      regrant([
        head("#{@ref}|@ingress|default", %{entry_id: "vlt_b1"}, ingress),
        head(
          "#{@ref}|@ingress|name:Work",
          %{entry_id: "vlt_a1"},
          Map.put(ingress, :connection, "Work"),
          %{kind: "once", until: nil}
        ),
        head("#{@ref}|#{@dep}|db_2", %{entry_id: "vlt_d2"}, %{
          source: "own",
          node: @ref,
          edge: "#{@dep}|db_2",
          dep: @dep,
          need: "db_2"
        })
      ])
      |> Map.put(:dependency_needs, regrant([], 2).dependency_needs)

    assert ConsentChoices.initial_choices(plan, @now) == %{
             {:need, "key_1", nil} => %{
               source: "own",
               id: "vlt_b1",
               need: nil,
               lifetime: %{"kind" => "standing"},
               choice: "standing",
               renew: false
             },
             {:account, {:need, "key_1"}, "name:Work"} => %{
               source: "own",
               id: "vlt_a1",
               need: nil,
               lifetime: %{"kind" => "once"},
               choice: "once",
               renew: false,
               name: "Work",
               fixed: true,
               seq: 0
             },
             {:dep, @ref, @dep} => %{
               source: "own",
               id: "vlt_d2",
               need: "db_2",
               lifetime: %{"kind" => "standing"},
               choice: "standing",
               renew: false
             }
           }
  end

  test "a head binding the plan places on no need, or not at all, leaves its edge unbound" do
    untold = %{source: "own", node: @ref, edge: "@ingress"}
    lent_on_ingress = %{source: "label", node: @ref, edge: "@ingress", need: "key_1"}

    for {binds, place} <- [
          {%{entry_id: "vlt_b1"}, untold},
          {%{label: "work"}, lent_on_ingress},
          {%{entry_id: "vlt_b1"}, %{}}
        ] do
      plan = regrant([head("#{@ref}|@ingress|default", binds, place)])

      # The edge the head binds takes no suggestion either, except where
      # the plan could not place the binding at all.
      expected =
        if place == %{},
          do: %{
            {:need, "key_1", nil} => %{
              source: "own",
              id: "vlt_a1",
              need: nil,
              lifetime: %{"kind" => "standing"},
              choice: "standing",
              renew: false
            }
          },
          else: %{}

      assert ConsentChoices.initial_choices(plan, @now) == expected
    end

    # A dependency's need the edge no longer declares.
    plan =
      regrant(
        [
          head("#{@ref}|#{@dep}|default", %{entry_id: "vlt_d1"}, %{
            source: "own",
            node: @ref,
            edge: @dep,
            dep: @dep,
            need: "db_9"
          })
        ],
        2
      )

    refute Map.has_key?(ConsentChoices.initial_choices(plan, @now), {:dep, @ref, @dep})
  end

  test "an until reopens while it is ahead of the now it is given, and is undecided after" do
    until = DateTime.add(@now, 60)
    lifetime = %{kind: "until", until: DateTime.to_iso8601(until)}
    place = %{source: "own", node: @ref, edge: "@ingress", need: "key_1"}
    plan = regrant([head("#{@ref}|@ingress|default", %{entry_id: "vlt_b1"}, place, lifetime)])

    assert %{lifetime: %{"kind" => "until", "until" => "2026-10-16T12:01:00Z"}, choice: nil} =
             ConsentChoices.initial_choices(plan, @now)[{:need, "key_1", nil}]

    for now <- [until, DateTime.add(until, 1)] do
      assert %{lifetime: nil, choice: nil} =
               ConsentChoices.initial_choices(plan, now)[{:need, "key_1", nil}]

      assert ConsentChoices.decisions(
               @ref,
               nil,
               ["interactive"],
               %{},
               ConsentChoices.initial_choices(plan, now)
             )["bindings"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # Lifetimes
  # ---------------------------------------------------------------------------

  property "a lifetime is computed from the now it is given, a session's held to 24 hours" do
    check all(
            offset <- integer(-3600..(3 * 86_400)),
            micro <- integer(0..999_999)
          ) do
      now = DateTime.add(@now, micro, :microsecond)
      session_end = DateTime.add(@now, offset)

      at = fn s ->
        now |> DateTime.add(s) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end

      assert ConsentChoices.lifetime_of("standing", session_end, now) ==
               {:ok, %{"kind" => "standing"}}

      assert ConsentChoices.lifetime_of("once", session_end, now) == {:ok, %{"kind" => "once"}}

      assert ConsentChoices.lifetime_of("5m", session_end, now) ==
               {:ok, %{"kind" => "until", "until" => at.(300)}}

      assert ConsentChoices.lifetime_of("1h", session_end, now) ==
               {:ok, %{"kind" => "until", "until" => at.(3600)}}

      session = ConsentChoices.lifetime_of("session", session_end, now)

      cond do
        DateTime.compare(session_end, now) != :gt ->
          assert session == :error

        DateTime.diff(session_end, now, :microsecond) < 86_400_000_000 ->
          assert session ==
                   {:ok,
                    %{
                      "kind" => "until",
                      "until" =>
                        session_end |> DateTime.truncate(:second) |> DateTime.to_iso8601()
                    }}

        true ->
          assert session == {:ok, %{"kind" => "until", "until" => at.(86_400)}}
      end

      assert ConsentChoices.lifetime_of("forever", session_end, now) == :error
    end
  end

  # ---------------------------------------------------------------------------
  # Limits
  # ---------------------------------------------------------------------------

  property "a whole-number limit is lowered to at most its ask, in the sheet's sentence" do
    check all(
            ask <- integer(1..10_000),
            value <- integer(-5..10_005),
            held <- member_of([%{}, %{"timeout" => "5s"}])
          ) do
      answer =
        ConsentChoices.lowered(
          %{"max_concurrent_tasks" => " #{value} "},
          %{
            "max_concurrent_tasks" => ask
          },
          held
        )

      cond do
        value == ask ->
          assert answer == {:ok, held}

        value > ask or value < 0 ->
          assert answer == {:error, "Concurrent tasks can be at most #{ask}."}

        true ->
          assert answer == {:ok, Map.put(held, "max_concurrent_tasks", value)}
      end
    end
  end

  test "a limit left blank keeps what it held, one malformed is refused in its own words" do
    asked = %{
      "timeout" => "30s",
      "max_memory_bytes" => 100,
      "rate_limit" => %{"requests" => 10, "window" => "1m"}
    }

    held = %{"rate_limit" => %{"requests" => 5, "window" => "5m"}}

    assert ConsentChoices.lowered(%{"timeout" => "", "rate_requests" => ""}, asked, held) ==
             {:ok, held}

    # The count is lowered in the window the node holds now.
    assert ConsentChoices.lowered(%{"rate_requests" => "3"}, asked, held) ==
             {:ok, %{"rate_limit" => %{"requests" => 3, "window" => "5m"}}}

    assert ConsentChoices.lowered(%{"rate_requests" => "10"}, asked, %{}) == {:ok, %{}}

    assert ConsentChoices.lowered(%{"timeout" => "10s"}, asked, %{}) ==
             {:ok, %{"timeout" => "10s"}}

    assert ConsentChoices.lowered(%{"timeout" => "30s"}, asked, held) == {:ok, held}

    assert ConsentChoices.lowered(%{"timeout" => "1h"}, asked, %{}) ==
             {:error, "Timeout can be at most 30s."}

    assert ConsentChoices.lowered(%{"timeout" => "soon"}, asked, %{}) ==
             {:error, "Timeout must be a duration, like 30s or 5m."}

    assert ConsentChoices.lowered(%{"max_memory_bytes" => "1.5"}, asked, %{}) ==
             {:error, "Memory (bytes) must be a whole number."}

    assert ConsentChoices.lowered(%{"rate_requests" => "11"}, asked, %{}) ==
             {:error, "The rate can be at most 10 requests."}

    assert ConsentChoices.lowered(%{"rate_requests" => "x"}, asked, %{}) ==
             {:error, "The rate must be a whole number of requests."}
  end

  describe "an exit's flows" do
    @exits [
      %{
        "kind" => "exits",
        "node" => @ref,
        "narrowed" => false,
        "values" => %{"exit" => "api.example.com", "flows" => ["pinned", "filed"]}
      },
      %{
        "kind" => "exits",
        "node" => @ref,
        "narrowed" => false,
        "values" => %{"exit" => "need:api_key", "flows" => []}
      },
      %{
        "kind" => "exits",
        "node" => @dep,
        "narrowed" => false,
        "values" => %{"exit" => "api.db.example", "flows" => ["outside"]}
      },
      %{"kind" => "egress", "node" => @ref, "narrowed" => false, "values" => %{}}
    ]

    defp flow(from, to), do: %{"from" => from, "to" => to}

    test "the flows asked are each class of each of the node's exits" do
      assert ConsentChoices.asked_flows(@exits, @ref) ==
               [flow("pinned", "api.example.com"), flow("filed", "api.example.com")]

      assert ConsentChoices.asked_flows(@exits, @dep) == [flow("outside", "api.db.example")]
      assert ConsentChoices.asked_flows(@exits, "reagent:local.none") == []
    end

    test "a flow is removed and kept again; at the ask the narrowing names nothing" do
      asked = ConsentChoices.asked_flows(@exits, @ref)
      pinned = flow("pinned", "api.example.com")
      filed = flow("filed", "api.example.com")
      held = %{@dep => %{"tools" => []}}

      removed = ConsentChoices.toggle_flow(held, @ref, asked, pinned)
      assert removed == Map.put(held, @ref, %{"exits" => [filed]})

      # Removing the last keeps none, which is an empty list, not the ask.
      none = ConsentChoices.toggle_flow(removed, @ref, asked, filed)
      assert none == Map.put(held, @ref, %{"exits" => []})

      # Kept again, the flows come back in the ask's order, and at the
      # whole ask the node names nothing, as if never narrowed.
      back = ConsentChoices.toggle_flow(none, @ref, asked, filed)
      assert back[@ref] == %{"exits" => [filed]}
      assert ConsentChoices.toggle_flow(back, @ref, asked, pinned) == held

      # The decisions carry the narrowing exactly as held.
      assert ConsentChoices.decisions(@ref, nil, ["interactive"], removed, %{})["subset"] ==
               removed
    end

    test "a flow the ask does not name is never added" do
      asked = ConsentChoices.asked_flows(@exits, @ref)

      for flow <- [
            flow("vault_disclosed", "api.example.com"),
            flow("pinned", "need:api_key"),
            flow("outside", "api.db.example")
          ] do
        assert ConsentChoices.toggle_flow(%{}, @ref, asked, flow) == %{}, inspect(flow)
      end
    end
  end
end
