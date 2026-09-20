# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RoomExcerptTest do
  # The room read for the person's own AQUA: under their own membership,
  # people's lines only, bounded, and never a write.
  use ExUnit.Case, async: false

  alias Aqua.RoomExcerpt
  alias Arca.ThreadStorage, as: Threads
  alias Arca.Schemas.Message

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    n = System.unique_integer([:positive])
    user = "local|idp|reader-#{n}"
    other = "local|idp|other-#{n}"

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me-x#{n}",
        owner_user_id: user,
        created_by: user
      })

    {:ok, _} = Sanctum.Tenancy.Members.create(%{user_id: user, athanor_id: mine.id})
    {:ok, room} = Sanctum.Tenancy.Athanors.create_group(user, "Team #{n}")
    {:ok, _} = Sanctum.Tenancy.Members.ensure(other, scope: "athanor", athanor_id: room.id)
    {:ok, elsewhere} = Sanctum.Tenancy.Athanors.create_group(other, "Not mine #{n}")

    me = %{Sanctum.TestContext.local() | user_id: user, athanor_id: mine.id}
    in_room = Sanctum.Context.actor(%{me | athanor_id: room.id})
    them = %{in_room | user_id: other}
    {:ok, thread} = Threads.create(in_room)

    {:ok, me: me, them: them, in_room: in_room, room: room, elsewhere: elsewhere, thread: thread}
  end

  defp say(actor, thread, attrs) do
    {:ok, row} =
      Threads.append(
        actor,
        thread.id,
        Map.merge(%{kind: "text", author: actor.user_id}, attrs)
      )

    row
  end

  defp room(room, thread, extra \\ %{}) do
    Map.merge(%{athanor_id: room.id, thread_id: thread.id}, extra)
  end

  test "reads the room's people and its AQUA, named, under the person's own seat",
       %{me: me, them: them, in_room: in_room, room: room, thread: thread} do
    say(in_room, thread, %{content: "plan?"})
    say(them, thread, %{content: "ship friday"})
    say(in_room, thread, %{author: Message.agent_author(), content: "Friday it is."})
    say(in_room, thread, %{kind: "approval", content: "", payload: %{"intent" => %{"x" => 1}}})

    say(in_room, thread, %{
      author: Message.system_author(),
      kind: "system",
      content: "📝 kept a note"
    })

    assert {:ok, text} =
             RoomExcerpt.read(me, room(room, thread, %{title: "Plans", estate: "Team"}))

    assert String.starts_with?(text, ~s(Read from the room "Team · Plans"))
    assert text =~ ": plan?"
    assert text =~ ": ship friday"
    assert text =~ "AQUA: Friday it is."
    refute text =~ "kept a note"
    refute text =~ "intent"
    assert byte_size(text) <= RoomExcerpt.max_bytes() + 200
  end

  test "the header falls back to the thread's own title", %{
    me: me,
    in_room: in_room,
    room: room,
    thread: thread
  } do
    say(in_room, thread, %{content: "hi"})
    # The first line names the thread; the header follows the row as it is now.
    {:ok, thread} = Threads.get(in_room, thread.id)
    assert {:ok, text} = RoomExcerpt.read(me, room(room, thread))
    assert text =~ ~s("#{thread.title}")
  end

  test "a room the person holds no seat in is refused; an empty one is nothing to read",
       %{me: me, in_room: in_room, room: room, thread: thread, elsewhere: elsewhere, them: them} do
    {:ok, foreign} = Threads.create(%{them | athanor_id: elsewhere.id})
    assert {:error, _} = RoomExcerpt.read(me, room(elsewhere, foreign))

    assert {:error, :nothing_said} = RoomExcerpt.read(me, room(room, thread))
    say(in_room, thread, %{content: ""})
    assert {:error, :nothing_said} = RoomExcerpt.read(me, room(room, thread))
  end

  test "bounded: the newest lines that fit, oldest first", %{
    me: me,
    in_room: in_room,
    room: room,
    thread: thread
  } do
    for i <- 1..12,
        do: say(in_room, thread, %{content: "line #{i} " <> String.duplicate("x", 3_000)})

    assert {:ok, text} = RoomExcerpt.read(me, room(room, thread, %{title: "Long"}))
    assert byte_size(text) <= RoomExcerpt.max_bytes() + 200
    refute text =~ "line 1 "
    assert text =~ "line 12 "

    {:ok, i11} = :binary.match(text, "line 11 ") |> then(&{:ok, elem(&1, 0)})
    {:ok, i12} = :binary.match(text, "line 12 ") |> then(&{:ok, elem(&1, 0)})
    assert i11 < i12
  end

  test "one line past the bound is cut, not dropped", %{
    me: me,
    in_room: in_room,
    room: room,
    thread: thread
  } do
    say(in_room, thread, %{content: "huge " <> String.duplicate("é", RoomExcerpt.max_bytes())})

    assert {:ok, text} = RoomExcerpt.read(me, room(room, thread, %{title: "Huge"}))
    assert text =~ "huge "
    assert String.ends_with?(text, "…")
    assert String.valid?(text)
    assert byte_size(text) <= RoomExcerpt.max_bytes() + 200
  end
end
