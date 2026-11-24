# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ThreadListTest do
  @moduledoc """
  One person's list of threads as a view reads it (`Aqua.threads/2`): their
  athanor's daily and workspace threads, an archived one marked, and the
  active shared threads they sit in, each with a workspace thread's state;
  and a title found as `thread.search` folds text, over every thread of
  theirs before any limit, never another athanor's.
  """

  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ShareFixtures
  alias Sanctum.SharedThreads

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "thread_list_#{System.unique_integer([:positive])}")
    # The restore is registered before the change.
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf!(test_path) end)

    {:ok, ada: ShareFixtures.person!("Ada"), bob: ShareFixtures.person!("Bob")}
  end

  # Workspace threads of `actor`'s athanor as the store writes them, the
  # first `minutes_back` minutes before now and each next one a minute
  # older, in `state`, archived when `archived`.
  defp workspaces!(actor, titles, minutes_back, state \\ "done", archived \\ false) do
    now = DateTime.utc_now()

    rows =
      for {title, i} <- Enum.with_index(titles) do
        at = DateTime.add(now, -(minutes_back + i) * 60, :second)

        %{
          id: Prima.UUID7.generate_id("thread"),
          athanor_id: actor.athanor_id,
          kind: "workspace",
          workspace_state: state,
          title: title,
          created_by: Prima.Author.system(),
          last_message_at: at,
          archived_at: if(archived, do: now),
          inserted_at: at,
          updated_at: at
        }
      end

    {_count, _} = Arca.Repo.insert_all(Arca.Schemas.Thread, rows)
    rows
  end

  defp ids(threads), do: Enum.map(threads, & &1.id)

  test "lists the athanor's daily and workspace threads, archived ones marked, and the shared " <>
         "threads the person sits in, each a workspace thread's state",
       %{ada: ada, bob: bob} do
    {:ok, daily} = Arca.Test.Days.thread(ada.actor)
    [going] = workspaces!(ada.actor, ["Going"], 3, "open")
    [waiting] = workspaces!(ada.actor, ["Waiting"], 4, "needs_you")
    [shelved] = workspaces!(ada.actor, ["Shelved"], 5, "done", true)
    {:ok, child} = Threads.crew_thread(ada.actor, daily.id, "planner")

    {:ok, trip} = SharedThreads.create(ada.user.id, "Trip")
    {:ok, :added} = SharedThreads.add(ada.user.id, trip.id, user_id: bob.user.id)
    {:ok, old} = SharedThreads.create(ada.user.id, "Old")
    {:ok, _} = SharedThreads.archive(ada.user.id, old.id)
    {:ok, bobs} = Arca.Test.Days.thread(bob.actor)

    assert {:ok, listed} = Aqua.threads(ada.ctx, title: nil)
    by_id = Map.new(listed, &{&1.id, &1})

    assert Enum.sort(Map.keys(by_id)) ==
             Enum.sort([daily.id, going.id, waiting.id, shelved.id, trip.id])

    refute child.id in Map.keys(by_id)
    refute old.id in Map.keys(by_id)
    refute bobs.id in Map.keys(by_id)

    title = Date.to_iso8601(daily.day)

    assert %{kind: :daily, title: ^title, state: nil, archived: false, unread: 0} =
             by_id[daily.id]

    assert by_id[going.id] == %{
             id: going.id,
             kind: :workspace,
             title: "Going",
             state: "open",
             last_activity: going.last_message_at,
             waits_on_you: false,
             unread: 0,
             archived: false
           }

    assert %{state: "needs_you", waits_on_you: true, archived: false} = by_id[waiting.id]
    assert %{state: "done", archived: true} = by_id[shelved.id]
    assert %{kind: :shared, title: "Trip", state: nil, waits_on_you: false} = by_id[trip.id]

    for entry <- listed do
      assert Enum.sort(Map.keys(entry)) ==
               Enum.sort(~w(id kind title state last_activity waits_on_you unread archived)a)
    end

    times = Enum.map(listed, & &1.last_activity)
    assert times == Enum.sort(times, {:desc, DateTime})

    # The stream's refresh is the same list.
    assert {:ok, refreshed} = Aqua.ThreadList.listed(ada.ctx, ada.user.id)
    assert ids(refreshed) == ids(listed)
  end

  test "a title asked for is read to its first 100 characters, the rest dropped",
       %{ada: ada} do
    long = String.duplicate("a", 100)
    [thread] = workspaces!(ada.actor, [long], 1)

    assert {:ok, [%{id: id}]} = Aqua.threads(ada.ctx, title: long <> String.duplicate("z", 900))
    assert id == thread.id
  end

  test "the unarchived workspace threads are asked for as such, before the window",
       %{ada: ada} do
    [older] = workspaces!(ada.actor, ["Older work"], 10_000)
    # 200 daily threads, each newer than it.
    _newer = for _n <- 1..200, do: {:ok, _} = Arca.Test.Days.thread(ada.actor)

    assert {:ok, [%{id: id, kind: :workspace, archived: false}]} =
             Aqua.threads(ada.ctx, kind: :workspace, archived: false)

    assert id == older.id
  end

  test "a title is found as a search folds text, in no post's body, past the list's window, " <>
         "a shared thread's too, and another athanor's never",
       %{ada: ada, bob: bob} do
    [moon] = workspaces!(ada.actor, ["Moon Report"], 1_000)
    [shelved] = workspaces!(ada.actor, ["Old moon notes"], 2_000, "done", true)
    _newer = workspaces!(ada.actor, for(n <- 1..200, do: "Newer #{n}"), 0)
    {:ok, daily} = Arca.Test.Days.thread(ada.actor)

    {:ok, _} =
      Threads.append(ada.actor, moon.id, %{
        author: "aqua",
        sent_by: "aqua",
        content: "nothing about it"
      })

    # The post moved its activity; it is put back, older than the window.
    Arca.Schemas.Thread
    |> Arca.Repo.get!(moon.id)
    |> Ecto.Changeset.change(last_message_at: moon.last_message_at)
    |> Arca.Repo.update!()

    {:ok, sky} = SharedThreads.create(ada.user.id, "Sky and MOON")
    {:ok, _bobs_sky} = SharedThreads.create(bob.user.id, "Moon for Bob")
    [_bobs] = workspaces!(bob.actor, ["Moon Report"], 0)

    # No post's body holds the title, and the moon is past the window.
    assert {:ok, %{posts: []}} = Threads.search(ada.actor, "moon")
    {:ok, everything} = Aqua.threads(ada.ctx, title: nil)
    refute moon.id in ids(everything)

    assert {:ok, found} = Aqua.threads(ada.ctx, title: "mOOn")
    assert Enum.sort(ids(found)) == Enum.sort([moon.id, shelved.id, sky.id])
    assert %{archived: true} = Enum.find(found, &(&1.id == shelved.id))

    assert {:ok, [%{id: daily_id, kind: :daily}]} =
             Aqua.threads(ada.ctx, title: Date.to_iso8601(daily.day))

    assert daily_id == daily.id

    # No character of the text is a pattern.
    assert {:ok, []} = Aqua.threads(ada.ctx, title: "m%n")
  end
end
