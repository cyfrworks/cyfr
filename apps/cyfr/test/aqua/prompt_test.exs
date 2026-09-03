# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.PromptTest do
  # The whole system prompt, composed in one place — so what the model is
  # told it can do can be checked against what the turn may actually do.
  use ExUnit.Case, async: false

  alias Aqua.Prompt

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp agent(policy \\ %{}), do: %{"name" => "aqua", "tool_policy" => policy}

  defp authority_granting(paths),
    do: %{resources: %{storage: %{paths: paths, actions: ["read"]}}}

  describe "file paths follow the authority, not the layout" do
    test "a turn granted no storage is told so", %{ctx: ctx} do
      prompt = Prompt.compose(ctx, agent: agent(), authority: nil)

      assert prompt =~ "File paths: none"

      # The regression: this section used to name every guest scope from
      # `Arca.Storage.guest_scopes/0` on every turn, whatever the edge
      # granted. A model told it has files will try to read them.
      for scope <- Map.keys(Arca.Storage.guest_scopes()) do
        refute prompt =~ scope <> "/ for",
               "the prompt still advertises #{scope}/ with no grant behind it"
      end
    end

    test "a granted scope is named, an ungranted one is not", %{ctx: ctx} do
      prompt =
        Prompt.compose(ctx, agent: agent(), authority: authority_granting(["data/notes"]))

      assert prompt =~ "data/ for user storage"
      refute prompt =~ "components/ for"
    end

    test "a whole-tree grant names every scope", %{ctx: ctx} do
      prompt = Prompt.compose(ctx, agent: agent(), authority: authority_granting(["**"]))

      for scope <- Map.keys(Arca.Storage.guest_scopes()) do
        assert prompt =~ scope <> "/"
      end
    end

    test "the scope vocabulary is still the layout's", %{ctx: ctx} do
      # A renamed scope must move the prompt with it — the grant decides
      # WHETHER a scope is named, the layout decides what it is called.
      prompt = Prompt.compose(ctx, agent: agent(), authority: authority_granting(["**"]))
      named = Map.keys(Arca.Storage.guest_scopes())

      assert Enum.all?(named, &(prompt =~ &1))
    end
  end

  describe "whose estate" do
    test "says nothing when the agent is working in its own", %{ctx: ctx} do
      prompt =
        Prompt.compose(ctx, agent: agent(), owner: "ath_1", focus: "ath_1", authority: nil)

      refute prompt =~ "another estate"
    end

    test "says so when it is not", %{ctx: ctx} do
      prompt =
        Prompt.compose(ctx, agent: agent(), owner: "ath_1", focus: "ath_2", authority: nil)

      assert prompt =~ "another estate than your own"
      assert prompt =~ "your own are not"
    end
  end

  describe "several people" do
    test "explains the Name: prefix only when there is one", %{ctx: ctx} do
      alone = Prompt.compose(ctx, agent: agent(), authority: nil)
      refute alone =~ "Several people are talking"

      together = Prompt.compose(ctx, agent: agent(), authority: nil, several_people?: true)
      assert together =~ "Several people are talking"
      assert together =~ "`Name: text`"
    end
  end

  test "the approval prelude is part of the one composition", %{ctx: ctx} do
    prompt = Prompt.compose(ctx, agent: agent(%{"component.pull" => "ask"}), authority: nil)

    assert prompt =~ "component.pull"
    assert prompt =~ "need approval"
  end

  describe "the estate's notes" do
    setup do
      test_path = Path.join(System.tmp_dir!(), "prompt_notes_#{:rand.uniform(1_000_000)}")
      original = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original,
          do: Application.put_env(:cyfr, :base_path, original),
          else: Application.delete_env(:cyfr, :base_path)
      end)

      n = System.unique_integer([:positive])
      user = "local|idp|prompt-#{n}"

      {:ok, mine} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "person",
          name: "Me",
          slug: "me#{n}",
          owner_user_id: user,
          created_by: user
        })

      {:ok, _} = Sanctum.Tenancy.Users.upsert_from_provider(%{id: user, provider: "local"})
      {:ok, u} = Sanctum.Tenancy.Users.get(user)
      {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)
      {:ok, _} = Sanctum.Tenancy.Members.create(%{user_id: user, athanor_id: mine.id})
      {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Trip #{n}")

      room = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}
      {:ok, home} = Sanctum.Context.focus(room, mine.id)
      {:ok, room: room, home: home}
    end

    test "the pinned page and the filed index come last, and a room is told its bounds", %{
      room: room
    } do
      {:ok, _} = Aqua.Notes.pin(room, "about-us", "We are planning a trip.")
      {:ok, _} = Aqua.Notes.keep(room, "flight", "BA117 on the 3rd\nseat 4A")
      {:ok, _} = Aqua.Notes.keep(room, "decided", "Lisbon")

      prompt = Prompt.compose(room, agent: agent(%{"notes.keep" => "ask"}), authority: nil)

      [before, notes] = String.split(prompt, "## Notes", parts: 2)
      assert before =~ "## Runtime Context"
      assert before =~ "need approval"

      assert notes =~ "### Pinned: about-us\n\nWe are planning a trip."
      # Sorted by name, first line only, no timestamps.
      assert notes =~ "- decided — Lisbon\n- flight — BA117 on the 3rd\n"
      refute notes =~ "seat 4A"
      refute notes =~ ~r/\d{4}-\d{2}-\d{2}T/

      assert notes =~ "not readable from here"
      refute notes =~ "scope `everywhere`"
    end

    test "a person's own athanor carries about-you and may look everywhere", %{home: home} do
      {:ok, _} = Aqua.Notes.pin(home, "about-you", "Prefers mornings.")

      prompt = Prompt.compose(home, agent: agent(), authority: nil)

      assert prompt =~ "### Pinned: about-you\n\nPrefers mornings."
      assert prompt =~ "scope `everywhere`"
      refute prompt =~ "not readable from here"
      assert prompt =~ "No notes filed yet."
    end

    test "the same pile renders the same bytes", %{room: room} do
      {:ok, _} = Aqua.Notes.keep(room, "decided", "Lisbon")

      [_, first] = String.split(Prompt.compose(room, agent: agent(), authority: nil), "## Notes")
      [_, again] = String.split(Prompt.compose(room, agent: agent(), authority: nil), "## Notes")

      assert first == again
    end
  end
end
