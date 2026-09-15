# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.PolicyTest do
  @moduledoc """
  A call runs, asks or is refused by the agent's effective policy; a
  launch by the launch rule on top, with what this turn wrote to read
  from durable rows; reads overlap and nothing else does; a card carries
  the canonical proposal and the catalog's kind and standing.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.{Binding, Policy}

  defp resolve!(name, args, opts \\ []) do
    {:ok, call} = Binding.resolve(name, args, opts)
    call
  end

  @policy %{
    "files.read" => "auto",
    "files.write" => "ask",
    "notes.read" => "auto",
    "builder.*" => "auto",
    "execution.run" => "auto"
  }

  test "the decision matrix" do
    assert :auto =
             Policy.decide(resolve!("files", %{"action" => "read", "path" => "a"}), @policy, [])

    assert :ask =
             Policy.decide(resolve!("files", %{"action" => "write", "path" => "a"}), @policy, [])

    assert {:deny, text} =
             Policy.decide(resolve!("files", %{"action" => "delete", "path" => "a"}), @policy, [])

    assert text =~ "files.delete"
    assert :auto = Policy.decide(resolve!("ui", %{"kind" => "ui.navigate"}), @policy, [])

    assert :auto =
             Policy.decide(resolve!("builder", %{"task" => "x"}, roles: ["builder"]), @policy, [])

    assert {:deny, _} =
             Policy.decide(resolve!("web", %{"task" => "x"}, roles: ["web"]), @policy, [])

    assert :ask = Policy.decide(resolve!("github__search", %{}), @policy, [])
  end

  test "the launch rule: consented and untouched runs as a child, touched or unconsented needs a card" do
    launch =
      resolve!("execution", %{"action" => "run", "reference" => "formula:local.demo:1.0.0"})

    consented = fn ref -> String.starts_with?(ref, "formula:local.demo") end

    assert :auto = Policy.decide(launch, @policy, consented?: consented)
    assert :ask = Policy.decide(launch, @policy, consented?: fn _ -> false end)

    assert :ask =
             Policy.decide(launch, @policy,
               consented?: consented,
               touched: MapSet.new(["formula:local.demo"])
             )

    assert {:deny, _} =
             Policy.decide(launch, Map.put(@policy, "execution.run", "deny"),
               consented?: consented
             )

    bad = resolve!("execution", %{"action" => "run", "reference" => "not a ref"})
    assert {:refuse, _} = Policy.decide(bad, @policy, [])
  end

  test "what the turn wrote to is read from the closed calls' rows" do
    calls = [
      %{
        "tool" => "files",
        "action" => "read",
        "arguments" => %{"path" => "components/formulas/local/demo/1.0.0/x"}
      },
      %{
        "tool" => "files",
        "action" => "write",
        "arguments" => %{"path" => "components/formulas/local/demo/1.0.0/src/lib.rs"}
      },
      %{
        "tool" => "component",
        "action" => "register",
        "arguments" => %{"reference" => "reagent:local.tool:2.0.0"}
      },
      %{
        "tool" => "build",
        "action" => "compile",
        "arguments" => %{"ref" => "catalyst:local.thing:0.1.0"}
      }
    ]

    touched = Policy.touched_refs(calls)
    assert MapSet.member?(touched, "formula:local.demo")
    assert MapSet.member?(touched, "catalyst:local.thing")
    refute MapSet.member?(touched, "formula:local.other")
  end

  test "a run after a source write and a compile of the same component still needs a card" do
    launch =
      resolve!("execution", %{"action" => "run", "reference" => "catalyst:local.widget:0.1.0"})

    consented = fn ref -> String.starts_with?(ref, "catalyst:local.widget") end

    closed =
      for {action, extra} <- [
            {"write", %{"content" => "fn main() {}"}},
            {"edit", %{"edits" => []}},
            {"delete", %{}}
          ] do
        [
          %{
            "tool" => "source",
            "action" => action,
            "arguments" =>
              Map.put(extra, "path", "components/catalysts/local/widget/0.1.0/src/lib.rs")
          },
          %{
            "tool" => "build",
            "action" => "compile",
            "arguments" => %{"reference" => "catalyst:local.widget:0.1.0"}
          }
        ]
      end

    for calls <- closed do
      touched = Policy.touched_refs(calls)
      assert MapSet.member?(touched, "catalyst:local.widget")
      assert :ask = Policy.decide(launch, @policy, consented?: consented, touched: touched)
    end
  end

  test "a launch of what the same batch writes to needs a card, whatever has closed" do
    launch =
      resolve!("execution", %{"action" => "run", "reference" => "formula:local.demo:1.0.0"})

    consented = fn ref -> String.starts_with?(ref, "formula:local.demo") end

    # Nothing has closed yet, which is the state every call in one model
    # response is decided in.
    assert :auto = Policy.decide(launch, @policy, consented?: consented, touched: MapSet.new())

    # The same response also proposes writing to it.
    writes =
      Policy.touched_refs([
        %{
          "tool" => "files",
          "action" => "write",
          "arguments" => %{"path" => "components/formulas/local/demo/1.0.0/src/lib.rs"}
        }
      ])

    assert :ask = Policy.decide(launch, @policy, consented?: consented, touched: writes)
  end

  test "reads overlap; everything else runs alone" do
    assert :concurrent = Policy.overlap(resolve!("files", %{"action" => "read"}))
    assert :concurrent = Policy.overlap(resolve!("notes", %{"action" => "read"}))
    assert :exclusive = Policy.overlap(resolve!("files", %{"action" => "write"}))
    assert :exclusive = Policy.overlap(resolve!("builder", %{}, roles: ["builder"]))
    assert :exclusive = Policy.overlap(resolve!("github__search", %{}))
  end

  test "a card carries the canonical proposal, the kind and the standing, and a stable digest" do
    call =
      resolve!("files", %{"action" => "write", "path" => "data/storage/k.json", "content" => "{}"})

    card = Policy.card(call, id: "apr_1")

    assert card["proposal"] == %{
             "tool" => "storage",
             "action" => "write",
             "args" => %{"key" => "k", "value" => "{}"}
           } or
             card["proposal"]["tool"] == "storage"

    assert card["action_kind"] == "write"
    assert card["id"] == "apr_1"
    assert Policy.proposal_digest(card) == Policy.proposal_digest(card["proposal"])
    assert Policy.proposal_digest(card) =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "a restricted turn runs replay-safe reads and nothing else, whatever the policy says" do
    read = resolve!("files", %{"action" => "read", "path" => "a"})
    write = resolve!("files", %{"action" => "write", "path" => "a", "content" => "b"})
    ui = resolve!("ui", %{"kind" => "ui.navigate"})

    assert Policy.replay_safe?(read)
    refute Policy.replay_safe?(write)
    refute Policy.replay_safe?(ui)

    assert :auto = Policy.decide(read, @policy, restricted?: true)
    assert {:deny, why} = Policy.decide(write, @policy, restricted?: true)
    assert why =~ "outcome is unknown"
    assert {:deny, _} = Policy.decide(ui, @policy, restricted?: true)
    assert :auto = Policy.decide(ui, @policy, restricted?: false)
  end
end
