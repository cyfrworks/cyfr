# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AloudTest do
  # Saying part of a private exchange out loud: the one deliberate copy in
  # the system, from a thread of the person's own athanor into a shared
  # thread they sit in, and the checks that keep it from being a way out
  # of an athanor or into a thread the person is not in.
  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Aloud
  alias Sanctum.SharedThreads

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "aloud_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    alice = Cyfr.Test.ShareFixtures.person!("Alice")
    bob = Cyfr.Test.ShareFixtures.person!("Bob")

    {:ok, private} = Threads.create(Sanctum.Context.actor(alice.ctx))
    {:ok, trip} = SharedThreads.create(alice.user.id, "Trip")
    {:ok, :added} = SharedThreads.add(alice.user.id, trip.id, user_id: bob.user.id)
    {:ok, theirs} = SharedThreads.create(bob.user.id, "Theirs")

    {:ok, ctx: alice.ctx, alice: alice, bob: bob, private: private, trip: trip, theirs: theirs}
  end

  defp said(ctx, thread, text) do
    {:ok, msg} =
      Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: ctx.user_id,
        kind: "text",
        content: text
      })

    msg
  end

  # What the thread holds, as its people read it.
  defp contents(user_id, thread) do
    {:ok, messages} = SharedThreads.messages(user_id, thread.id)
    Enum.map(messages, & &1.content)
  end

  # The stored payload of a message the thread holds.
  defp payload(thread, message_id) do
    {:ok, row} = Arca.SharedMessages.get(Prima.Actor.system(), thread.id, message_id)
    row.payload
  end

  test "a private line reaches the shared thread only when it is said aloud", %{
    ctx: ctx,
    bob: bob,
    private: private,
    trip: trip
  } do
    a = said(ctx, private, "tom, what's the flight number?")
    b = said(ctx, private, "BA117, apparently")

    # Nothing crosses on its own.
    assert contents(ctx.user_id, trip) == []

    assert {:ok, [posted]} = Aloud.post(ctx, private.id, [b.id], trip.id)
    assert posted.content == "BA117, apparently"
    assert posted.author == ctx.user_id

    # Only what was chosen — the question stayed private — and the other
    # person in the thread reads it.
    assert contents(bob.user.id, trip) == ["BA117, apparently"]

    # And the original is untouched: saying something aloud is a copy, not
    # a move out of your own thread.
    assert length(Threads.messages(Sanctum.Context.actor(ctx), private.id)) == 2
    assert a.id != posted.id
  end

  test "it records where the line came from", %{ctx: ctx, private: private, trip: trip} do
    m = said(ctx, private, "here it is")
    {:ok, [posted]} = Aloud.post(ctx, private.id, [m.id], trip.id)

    assert payload(trip, posted.id) == %{
             "aloud_from" => %{"thread_id" => private.id, "message_id" => m.id}
           }
  end

  test "several lines keep the order they were said in", %{
    ctx: ctx,
    private: private,
    trip: trip
  } do
    one = said(ctx, private, "first")
    two = said(ctx, private, "second")

    # Listed backwards on purpose.
    {:ok, posted} = Aloud.post(ctx, private.id, [two.id, one.id], trip.id)
    assert Enum.map(posted, & &1.content) == ["first", "second"]
    assert contents(ctx.user_id, trip) == ["first", "second"]
  end

  test "a shared thread you do not sit in answers as a missing one", %{
    ctx: ctx,
    bob: bob,
    private: private,
    theirs: theirs
  } do
    mine = said(ctx, private, "mine")
    theirs_id = theirs.id

    assert {:error, {:not_found, "Thread", ^theirs_id}} =
             Aloud.post(ctx, private.id, [mine.id], theirs.id)

    assert contents(bob.user.id, theirs) == []
  end

  test "a thread of an athanor you are not in is not a source", %{
    ctx: ctx,
    bob: bob,
    trip: trip
  } do
    {:ok, bobs} = Threads.create(Sanctum.Context.actor(bob.ctx))
    line = said(bob.ctx, bobs, "bob's own")

    assert {:error, :not_a_member} =
             Aloud.post(%{ctx | athanor_id: bob.athanor.id}, bobs.id, [line.id], trip.id)

    assert contents(ctx.user_id, trip) == []
  end

  test "your own assistant's line, from your own athanor, is yours to share — attributed to you",
       %{ctx: ctx, private: private, trip: trip} do
    {:ok, answer} =
      Threads.append(Sanctum.Context.actor(ctx), private.id, %{
        author: "aqua",
        kind: "text",
        content: "Try BA117."
      })

    assert {:ok, [copy]} = Aloud.post(ctx, private.id, [answer.id], trip.id)

    # Attributed to the person, marked as the assistant's words.
    assert copy.author == ctx.user_id
    assert copy.content == "Try BA117."

    assert payload(trip, copy.id) == %{
             "aloud_from" => %{"thread_id" => private.id, "message_id" => answer.id},
             "shared_agent" => true
           }

    # A system line is nobody's to say aloud.
    {:ok, note} =
      Threads.append(Sanctum.Context.actor(ctx), private.id, %{
        author: "system",
        kind: "system",
        content: "📝"
      })

    assert {:error, :not_the_author} = Aloud.post(ctx, private.id, [note.id], trip.id)
  end

  test "another athanor's assistant's line is not the caller's to say", %{
    alice: alice,
    trip: trip
  } do
    # An athanor Alice sits in that is not her own: its assistant spoke to
    # everyone there, not to her.
    group = Arca.Test.Shares.group!([alice.user.id])
    in_group = %{alice.ctx | athanor_id: group.id}
    {:ok, thread} = Threads.create(Sanctum.Context.actor(in_group))

    {:ok, answer} =
      Threads.append(Sanctum.Context.actor(in_group), thread.id, %{
        author: "aqua",
        kind: "text",
        content: "Sure."
      })

    assert {:error, :not_the_author} = Aloud.post(in_group, thread.id, [answer.id], trip.id)
  end

  test "only your own lines can be said aloud", %{ctx: ctx, private: private, trip: trip} do
    mine = said(ctx, private, "my line")

    {:ok, other} =
      Threads.append(Sanctum.Context.actor(ctx), private.id, %{
        author: "local|idp|somebody-else",
        kind: "text",
        content: "their line"
      })

    # Refused whole, not filtered: publishing less than the person picked
    # would quietly say less than they chose to say — and publishing the
    # other line would speak someone else's words under their name.
    assert {:error, :not_the_author} = Aloud.post(ctx, private.id, [mine.id, other.id], trip.id)
    assert contents(ctx.user_id, trip) == []
  end

  test "an operator who sits in no thread is refused like anyone else", %{
    ctx: ctx,
    private: private,
    trip: trip,
    theirs: theirs
  } do
    row = said(ctx, private, "for the thread")
    admin = %{ctx | platform_admin: true}

    # The capability is no seat: the thread they sit in takes the copy, the
    # one they do not answers as missing.
    theirs_id = theirs.id

    assert {:error, {:not_found, "Thread", ^theirs_id}} =
             Aloud.post(admin, private.id, [row.id], theirs.id)

    assert {:ok, [_]} = Aloud.post(admin, private.id, [row.id], trip.id)
  end

  test "an archived shared thread refuses the copy", %{
    ctx: ctx,
    private: private,
    trip: trip
  } do
    m = said(ctx, private, "too late")
    {:ok, _} = SharedThreads.archive(ctx.user_id, trip.id)

    assert {:error, {:shared_thread, :archived}} = Aloud.post(ctx, private.id, [m.id], trip.id)
    assert contents(ctx.user_id, trip) == []
  end

  test "attachments are copied as bytes into the shared thread's own root", %{
    ctx: ctx,
    bob: bob,
    private: private,
    trip: trip
  } do
    message_id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, private.id, message_id, [
        %{"filename" => "flight.txt", "media_type" => "text/plain", "bytes" => "BA117"}
      ])

    {:ok, m} =
      Threads.append(Sanctum.Context.actor(ctx), private.id, %{
        id: message_id,
        author: ctx.user_id,
        kind: "text",
        content: "see attached",
        payload: %{"attachments" => refs}
      })

    {:ok, [posted]} = Aloud.post(ctx, private.id, [m.id], trip.id)
    assert [%{"filename" => "flight.txt", "stored_name" => stored} = ref] = posted.attachments
    assert ref["media_type"] == "text/plain"
    assert ref["size"] == 5

    # The thread's other person reads the bytes from the thread itself.
    assert {:ok, %{filename: "flight.txt", media_type: "text/plain", bytes: "BA117"}} =
             SharedThreads.attachment(bob.user.id, trip.id, posted.id, stored)

    # And they are the thread's own copy: removing the private original
    # leaves them where they were said.
    :ok = Aqua.Attachments.discard(ctx, private.id, message_id, refs)

    assert {:ok, %{bytes: "BA117"}} =
             SharedThreads.attachment(bob.user.id, trip.id, posted.id, stored)
  end

  test "a missing blob refuses the copy rather than saying less than was chosen", %{
    ctx: ctx,
    private: private,
    trip: trip
  } do
    message_id = Prima.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, private.id, message_id, [
        %{"filename" => "gone.txt", "media_type" => "text/plain", "bytes" => "poof"}
      ])

    {:ok, m} =
      Threads.append(Sanctum.Context.actor(ctx), private.id, %{
        id: message_id,
        author: ctx.user_id,
        kind: "text",
        content: "see attached",
        payload: %{"attachments" => refs}
      })

    :ok = Aqua.Attachments.discard(ctx, private.id, message_id, refs)

    assert {:error, :attachment_missing} = Aloud.post(ctx, private.id, [m.id], trip.id)
    assert contents(ctx.user_id, trip) == []
  end

  test "refuses a copy into the same thread, an empty selection and an unknown line", %{
    ctx: ctx,
    private: private,
    trip: trip
  } do
    m = said(ctx, private, "x")

    assert {:error, :same_thread} = Aloud.post(ctx, private.id, [m.id], private.id)
    assert {:error, :nothing_to_say} = Aloud.post(ctx, private.id, [], trip.id)
    assert {:error, :not_found} = Aloud.post(ctx, private.id, ["msg_nope"], trip.id)
    assert contents(ctx.user_id, trip) == []
  end
end
