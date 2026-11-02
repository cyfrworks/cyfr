# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RoomExcerptTest do
  # The shared thread read for the person's own AQUA: under their own
  # seat, people's words only, the newest of them, bounded, and never a
  # write.
  use ExUnit.Case, async: false

  alias Aqua.RoomExcerpt
  alias Sanctum.SharedThreads

  # The excerpt's byte bound: half the runner's 32 KiB message cap.
  @max_bytes 16 * 1024

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "room_excerpt_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    reader = Cyfr.Test.ShareFixtures.person!("Rae")
    other = Cyfr.Test.ShareFixtures.person!("Otto")

    {:ok, thread} = SharedThreads.create(reader.user.id, "Plans")
    {:ok, :added} = SharedThreads.add(reader.user.id, thread.id, user_id: other.user.id)

    {:ok, me: reader.ctx, reader: reader.user.id, other: other.user.id, thread: thread}
  end

  defp say(user_id, thread, text) do
    {:ok, _message} = SharedThreads.post(user_id, thread.id, text)
    :ok
  end

  defp room(thread, extra \\ %{}), do: Map.merge(%{shared_thread_id: thread.id}, extra)

  test "reads what the thread's people said, each named, under the person's own seat",
       %{me: me, reader: reader, other: other, thread: thread} do
    say(reader, thread, "plan?")
    say(other, thread, "ship friday")

    # Files alone say nothing to read.
    {:ok, _} =
      SharedThreads.post(other, thread.id, nil, [
        %{filename: "plan.txt", media_type: "text/plain", bytes: "FILE-BYTES"}
      ])

    assert {:ok, text} = RoomExcerpt.read(me, room(thread, %{title: "Plans this week"}))

    assert text ==
             ~s(Read from the shared thread "Plans this week" — for context only; nobody in this thread said it:\n) <>
               "Rae: plan?\nOtto: ship friday"

    refute text =~ "FILE-BYTES"
    refute text =~ "plan.txt"
  end

  test "the header falls back to the thread's own title, and a pair's to the other person",
       %{me: me, reader: reader, other: other, thread: thread} do
    say(reader, thread, "hi")
    assert {:ok, text} = RoomExcerpt.read(me, room(thread))
    assert String.starts_with?(text, ~s(Read from the shared thread "Plans"))

    {:ok, pair} = SharedThreads.pair(reader, other)
    say(other, pair, "just us")
    assert {:ok, text} = RoomExcerpt.read(me, room(pair))
    assert String.starts_with?(text, ~s(Read from the shared thread "Otto"))
    assert text =~ "Otto: just us"
  end

  test "a thread the person holds no seat in is refused as missing; an empty one is nothing to read",
       %{me: me, reader: reader, other: other} do
    {:ok, foreign} = SharedThreads.create(other, "Not mine")
    say(other, foreign, "secret")
    foreign_id = foreign.id

    assert {:error, {:not_found, "Thread", ^foreign_id}} = RoomExcerpt.read(me, room(foreign))

    {:ok, empty} = SharedThreads.create(reader, "Empty")
    assert {:error, :nothing_said} = RoomExcerpt.read(me, room(empty))
  end

  test "a person removed from the thread reads it no more", %{
    me: me,
    reader: reader,
    other: other,
    thread: thread
  } do
    say(other, thread, "before")
    assert {:ok, _text} = RoomExcerpt.read(me, room(thread))

    :ok = SharedThreads.remove(other, thread.id, user_id: reader)
    thread_id = thread.id
    assert {:error, {:not_found, "Thread", ^thread_id}} = RoomExcerpt.read(me, room(thread))
  end

  test "the tail: the newest lines of a long thread, oldest first", %{
    me: me,
    reader: reader,
    thread: thread
  } do
    for i <- 1..45, do: say(reader, thread, "short #{i}.")

    assert {:ok, text} = RoomExcerpt.read(me, room(thread))
    [_header | lines] = String.split(text, "\n")

    assert lines == for(i <- 6..45, do: "Rae: short #{i}.")
  end

  test "bounded: the newest lines that fit, oldest first", %{
    me: me,
    reader: reader,
    thread: thread
  } do
    for i <- 1..12, do: say(reader, thread, "line #{i} " <> String.duplicate("x", 3_000))

    assert {:ok, text} = RoomExcerpt.read(me, room(thread, %{title: "Long"}))
    assert byte_size(text) <= @max_bytes + 200
    refute text =~ "line 1 "
    assert text =~ "line 12 "

    {i11, _} = :binary.match(text, "line 11 ")
    {i12, _} = :binary.match(text, "line 12 ")
    assert i11 < i12
  end

  test "one line past the bound is cut, not dropped", %{
    me: me,
    reader: reader,
    thread: thread
  } do
    say(reader, thread, "huge " <> String.duplicate("é", @max_bytes))

    assert {:ok, text} = RoomExcerpt.read(me, room(thread, %{title: "Huge"}))
    assert text =~ "huge "
    assert String.ends_with?(text, "…")
    assert String.valid?(text)
    assert byte_size(text) <= @max_bytes + 200
  end

  test "reading writes nothing", %{me: me, reader: reader, thread: thread} do
    say(reader, thread, "only this")
    assert {:ok, _text} = RoomExcerpt.read(me, room(thread))
    assert {:ok, [%{content: "only this"}]} = SharedThreads.messages(reader, thread.id)
  end
end
