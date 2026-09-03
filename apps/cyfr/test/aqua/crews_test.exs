# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.CrewsTest do
  # Agents belong to the tree they live in. Yours travel with you; an
  # estate may keep its own. These are the rules for addressing them and
  # for reading one back out of the right tree.
  use ExUnit.Case, async: false

  alias Aqua.Turn

  defp entry(name, owner, slug \\ nil, estate? \\ false),
    do: %{
      "name" => name,
      "title" => name,
      "owner" => owner,
      "owner_slug" => slug,
      "estate?" => estate?
    }

  describe "parse_mention/2" do
    test "a qualified mention reaches a shadowed personal agent" do
      # The estate's `aqua` wins a bare mention; the personal one is still
      # addressable by its owner's slug. The qualifier is the SLUG, but the
      # entry carries the owner's ID — so renaming the estate cannot make a
      # stored mention point at a different tree.
      roster = [entry("aqua", "ath_person", "alice"), entry("aqua", "ath_estate", "acme")]

      assert {"hi", %{"owner" => "ath_person"}} = Turn.parse_mention("@alice.aqua hi", roster)
      assert {"hi", %{"owner" => "ath_estate"}} = Turn.parse_mention("@acme.aqua hi", roster)
    end

    test "a bare mention picks the entry, not just its name" do
      roster = [entry("aqua", "ath_estate")]

      assert {"hello", %{"name" => "aqua", "owner" => "ath_estate"}} =
               Turn.parse_mention("@aqua hello", roster)
    end

    test "a bare mention on a collision picks the estate's entry" do
      # The roster lists the personal tree FIRST (that is its build order),
      # so this pins that the estate wins by RULE, not by list position —
      # the deduplicating roster this replaces got the same answer by
      # deleting the personal entry, which killed the qualified spelling.
      roster = [
        entry("aqua", "ath_person", "alice"),
        entry("aqua", "ath_estate", "acme", true)
      ]

      assert {"hi", %{"owner" => "ath_estate"}} = Turn.parse_mention("@aqua hi", roster)
      assert {"hi", %{"owner" => "ath_person"}} = Turn.parse_mention("@alice.aqua hi", roster)
    end

    test "longest handle wins, so a suffixed name is not read as a prefix" do
      roster = [entry("aqua", "ath_e"), entry("aqua_planner", "ath_e")]

      assert {"go", %{"name" => "aqua_planner"}} = Turn.parse_mention("@aqua_planner go", roster)
    end

    test "no mention leaves the message alone" do
      assert {"just talking", nil} = Turn.parse_mention("just talking", [entry("aqua", "ath_e")])
    end

    test "an empty roster matches nothing, even with an @ in the text" do
      assert {"@aqua hello", nil} = Turn.parse_mention("@aqua hello", [])
    end

    test "a mention that is the whole message keeps the text" do
      # Stripping it would leave an empty task.
      assert {"@aqua", %{"name" => "aqua"}} = Turn.parse_mention("@aqua", [entry("aqua", "a")])
    end
  end

  describe "an agent is edited in its own tree" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      test_path = Path.join(System.tmp_dir!(), "crews_#{:rand.uniform(1_000_000)}")
      original = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original,
          do: Application.put_env(:cyfr, :base_path, original),
          else: Application.delete_env(:cyfr, :base_path)
      end)

      n = System.unique_integer([:positive])

      {:ok, mine} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "person",
          name: "Me",
          slug: "me#{n}",
          owner_user_id: "local|idp|me-#{n}",
          created_by: "local|idp|me-#{n}"
        })

      {:ok, theirs} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Acme #{n}",
          slug: "acme#{n}",
          created_by: "local|idp|me-#{n}"
        })

      {:ok, mine: mine, theirs: theirs, base: Sanctum.TestContext.local()}
    end

    test "the production roster keeps a shadowed personal agent addressable", %{
      mine: mine,
      theirs: theirs,
      base: base
    } do
      # Through `orchestrators/1`, not a hand-built list: the roster build
      # itself once deduplicated by name, which made the qualified grammar
      # unreachable in exactly the case it exists for.
      user = mine.owner_user_id
      {:ok, _} = Sanctum.Tenancy.Users.upsert_from_provider(%{id: user, provider: "local"})
      {:ok, u} = Sanctum.Tenancy.Users.get(user)
      {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)
      # The roster reads go through the refocus chokepoint now — the seats
      # (production mints them with the athanors) must exist.
      {:ok, _} = Sanctum.Tenancy.Members.ensure(user, scope: "athanor", athanor_id: mine.id)
      {:ok, _} = Sanctum.Tenancy.Members.ensure(user, scope: "athanor", athanor_id: theirs.id)

      mine_ctx = %{base | user_id: user, athanor_id: mine.id}
      theirs_ctx = %{base | user_id: user, athanor_id: theirs.id}

      for ctx <- [mine_ctx, theirs_ctx] do
        {:ok, _} =
          Aqua.AgentConfig.call_aqua(ctx, %{
            "action" => "create",
            "name" => "tom",
            "title" => "Tom",
            "content" => "# Tom"
          })
      end

      roster = Turn.orchestrators(theirs_ctx)
      toms = Enum.filter(roster, &(&1["name"] == "tom"))

      assert Enum.sort_by(toms, & &1["owner"]) |> Enum.map(&{&1["owner"], &1["estate?"]}) ==
               Enum.sort([{mine.id, false}, {theirs.id, true}])

      # Estate entries sort first, so the solo default and the picker's top
      # row are the estate's.
      assert List.first(roster)["estate?"]

      # Bare mention → the estate's Tom; qualified → yours, still here.
      assert {_, %{"owner" => owner}} = Turn.parse_mention("@tom hi", roster)
      assert owner == theirs.id

      assert {_, %{"owner" => personal_owner}} =
               Turn.parse_mention("@#{mine.slug}.tom hi", roster)

      assert personal_owner == mine.id
    end

    test "a personal crew travels: sub-agents come from the owner's tree", %{
      mine: mine,
      theirs: theirs,
      base: base
    } do
      # The owner-tree reads refocus through membership — seat the user as
      # production does at mint.
      user = mine.owner_user_id
      {:ok, _} = Sanctum.Tenancy.Members.ensure(user, scope: "athanor", athanor_id: mine.id)
      base = %{base | user_id: user}
      mine_ctx = %{base | athanor_id: mine.id}

      # Parent and child live in MY tree only; the estate has neither.
      {:ok, _} =
        Aqua.AgentConfig.call_aqua(mine_ctx, %{
          "action" => "create",
          "name" => "tom",
          "title" => "Tom",
          "content" => "# Tom"
        })

      {:ok, _} =
        Aqua.AgentConfig.call_aqua(mine_ctx, %{
          "action" => "create",
          "parent" => "tom",
          "name" => "scout",
          "title" => "Scout",
          "description" => "scouts",
          "content" => "# Scout"
        })

      theirs_ctx = %{base | athanor_id: theirs.id}
      orchestrator = Turn.orchestrator(theirs_ctx, "tom", mine.id)
      assert orchestrator["owner"] == mine.id

      # Tom runs in the OTHER estate and still brings his crew — the guides
      # are read from the owner's tree, where reading focus instead found
      # the estate's (nonexistent) children and quietly ran Tom alone.
      assert {:ok, %{input: input}} = Turn.build_input(theirs_ctx, orchestrator, "hi")
      assert [%{"name" => "scout"}] = input["sub_agents"]
    end

    test "a named catalyst the working estate lacks refuses the turn", %{
      mine: mine,
      theirs: theirs,
      base: base
    } do
      orchestrator = %{
        "name" => "tom",
        "owner" => mine.id,
        "catalyst_ref" => "catalyst:nobody.model",
        "tool_policy" => %{}
      }

      # Fail closed, with the ref named: the old path shipped the
      # unresolved ref to the engine and surfaced as a confusing runtime
      # error instead of "this estate has no such model".
      assert {:error, {:catalyst_not_in_estate, "catalyst:nobody.model"}} =
               Turn.build_input(%{base | athanor_id: theirs.id}, orchestrator, "hi")

      # No pinned catalyst is a different, pre-existing path: nil rides
      # through to the engine's default.
      unpinned = Map.put(orchestrator, "catalyst_ref", nil)
      assert {:ok, _} = Turn.build_input(%{base | athanor_id: theirs.id}, unpinned, "hi")
    end

    test "a write under the owner's ctx materializes there, and nowhere else", %{
      mine: mine,
      theirs: theirs,
      base: base
    } do
      # The bug this pins is a LiveView one as much as a harness one: the
      # agents page called through the FOCUSED ctx, so editing your Tom
      # while working in a group wrote `tom.md` into the group's overlay —
      # forking your agent into an estate that does not own it.
      # `owner_ctx/2` is what makes the write follow the agent.
      mine_ctx = %{base | athanor_id: mine.id}
      theirs_ctx = %{base | athanor_id: theirs.id}

      assert {:ok, %{files: 0}} = Arca.usage(mine_ctx, ["aqua"])
      assert {:ok, %{files: 0}} = Arca.usage(theirs_ctx, ["aqua"])

      {:ok, _} =
        Aqua.AgentConfig.call_aqua(mine_ctx, %{
          "action" => "update",
          "name" => "aqua",
          "title" => "My Tom"
        })

      # The edit materialized one agent file into MY tree…
      assert {:ok, %{files: files}} = Arca.usage(mine_ctx, ["aqua"])
      assert files > 0

      # …and left the estate reading the shipped template through the
      # overlay, exactly as it did before.
      assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(theirs_ctx, ["aqua"])
    end
  end
end
