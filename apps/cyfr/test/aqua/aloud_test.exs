# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AloudTest do
  # Saying part of a private exchange out loud: the one deliberate copy in
  # the system, and the checks that keep it from being a way into an estate
  # you are not in.
  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Aloud

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "aloud_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    n = System.unique_integer([:positive])
    alice = "local|idp|alice-#{n}"
    bob = "local|idp|bob-#{n}"

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Alice",
        slug: "alice#{n}",
        owner_user_id: alice,
        created_by: alice
      })

    {:ok, _} = Sanctum.Tenancy.Members.create(%{user_id: alice, athanor_id: mine.id})
    {:ok, room} = Sanctum.Tenancy.Athanors.create_group(alice, "Room #{n}")
    {:ok, elsewhere} = Sanctum.Tenancy.Athanors.create_group(bob, "Theirs #{n}")

    base = Sanctum.TestContext.local()
    alice_ctx = %{base | user_id: alice}

    {:ok, private} = Threads.create(%{alice_ctx | athanor_id: mine.id})
    {:ok, shared} = Threads.create(%{alice_ctx | athanor_id: room.id})
    {:ok, theirs} = Threads.create(%{base | user_id: bob, athanor_id: elsewhere.id})

    {:ok,
     ctx: %{alice_ctx | athanor_id: mine.id}, private: private, shared: shared, theirs: theirs}
  end

  defp said(ctx, thread, text) do
    {:ok, msg} =
      Threads.append(%{ctx | athanor_id: thread.athanor_id}, thread.id, %{
        author: ctx.user_id,
        kind: "text",
        content: text
      })

    msg
  end

  test "a private line reaches the room only when it is said aloud", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    a = said(ctx, private, "tom, what's the flight number?")
    b = said(ctx, private, "BA117, apparently")

    # Nothing crosses on its own.
    assert [] = Threads.messages(%{ctx | athanor_id: shared.athanor_id}, shared.id)

    assert {:ok, [posted]} = Aloud.post(ctx, private.id, [b.id], shared.athanor_id, shared.id)
    assert posted.content == "BA117, apparently"

    # Only what was chosen — the question stayed private.
    contents =
      %{ctx | athanor_id: shared.athanor_id}
      |> Threads.messages(shared.id)
      |> Enum.map(& &1.content)

    assert contents == ["BA117, apparently"]

    # And the original is untouched: saying something aloud is a copy, not
    # a move out of your own thread.
    assert length(Threads.messages(%{ctx | athanor_id: private.athanor_id}, private.id)) ==
             2

    assert a.id != posted.id
  end

  test "it records where the line came from", %{ctx: ctx, private: private, shared: shared} do
    m = said(ctx, private, "here it is")
    {:ok, [posted]} = Aloud.post(ctx, private.id, [m.id], shared.athanor_id, shared.id)

    from = Threads.payload(posted)["aloud_from"]
    assert from["thread_id"] == private.id
    assert from["message_id"] == m.id
  end

  test "several lines keep the order they were said in", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    one = said(ctx, private, "first")
    two = said(ctx, private, "second")

    # Listed backwards on purpose.
    {:ok, posted} = Aloud.post(ctx, private.id, [two.id, one.id], shared.athanor_id, shared.id)
    assert Enum.map(posted, & &1.content) == ["first", "second"]
  end

  test "an estate you are not in is neither readable nor writable", %{
    ctx: ctx,
    private: private,
    shared: shared,
    theirs: theirs
  } do
    mine = said(ctx, private, "mine")

    # Not a way to push into somebody else's room…
    assert {:error, :not_a_member} =
             Aloud.post(ctx, private.id, [mine.id], theirs.athanor_id, theirs.id)

    # …nor to pull out of one.
    assert {:error, :not_a_member} =
             Aloud.post(
               %{ctx | athanor_id: theirs.athanor_id},
               theirs.id,
               [mine.id],
               shared.athanor_id,
               shared.id
             )
  end

  test "your own assistant's line, from your own athanor, is yours to share — a room's is not", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    # The user's row must name the personal athanor for "own" to hold, and
    # the person — now named by their own id — must be seated in both rooms.
    {ctx, u} = Sanctum.TestContext.person!(ctx)
    {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, ctx.athanor_id)

    for athanor_id <- [ctx.athanor_id, shared.athanor_id] do
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: athanor_id)
    end

    {:ok, answer} =
      Threads.append(ctx, private.id, %{author: "aqua", kind: "text", content: "Try BA117."})

    assert {:ok, [copy]} = Aloud.post(ctx, private.id, [answer.id], shared.athanor_id, shared.id)

    # Attributed to the person, marked as the assistant's words.
    assert copy.author == ctx.user_id
    assert copy.content == "Try BA117."
    assert Threads.payload(copy)["shared_agent"] == true

    # The room's own assistant spoke to the room; nobody carries that out.
    room_ctx = %{ctx | athanor_id: shared.athanor_id}

    {:ok, room_answer} =
      Threads.append(room_ctx, shared.id, %{author: "aqua", kind: "text", content: "Sure."})

    assert {:error, :not_the_author} =
             Aloud.post(room_ctx, shared.id, [room_answer.id], private.athanor_id, private.id)

    # A system line is nobody's to say aloud, at home or not.
    {:ok, note} =
      Threads.append(ctx, private.id, %{author: "system", kind: "system", content: "📝"})

    assert {:error, :not_the_author} =
             Aloud.post(ctx, private.id, [note.id], shared.athanor_id, shared.id)
  end

  test "only your own lines can be said aloud", %{ctx: ctx, private: private, shared: shared} do
    mine = said(ctx, private, "my line")

    {:ok, other} =
      Threads.append(%{ctx | athanor_id: private.athanor_id}, private.id, %{
        author: "local|idp|somebody-else",
        kind: "text",
        content: "their line"
      })

    # Refused whole, not filtered: publishing less than the person picked
    # would quietly say less than they chose to say — and publishing the
    # other line would speak someone else's words under their name.
    assert {:error, :not_the_author} =
             Aloud.post(ctx, private.id, [mine.id, other.id], shared.athanor_id, shared.id)

    target_ctx = %{ctx | athanor_id: shared.athanor_id}
    assert Threads.messages(target_ctx, shared.id) == []
  end

  test "an operator who is not a member is refused like anyone else", %{
    ctx: ctx,
    private: private,
    shared: shared,
    theirs: theirs
  } do
    row = said(ctx, private, "for the room")
    admin = %{ctx | platform_admin: true}

    # Focus is the audited open; the copy is a second act and takes no
    # capability. The admin is a member of the source and the shared room —
    # those still work — but not of the third estate.
    assert {:error, :not_a_member} =
             Aloud.post(admin, private.id, [row.id], theirs.athanor_id, theirs.id)

    assert {:ok, [_]} = Aloud.post(admin, private.id, [row.id], shared.athanor_id, shared.id)
  end

  test "an archived target estate refuses the copy", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    m = said(ctx, private, "too late")

    {:ok, room} = Sanctum.Tenancy.Athanors.get(shared.athanor_id)
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(room)

    # Membership survives an archive; the `Context.focus/2` step is what
    # carries the refusal — the reason aloud narrows through it rather
    # than swapping the struct by hand.
    assert {:error, :archived} =
             Aloud.post(ctx, private.id, [m.id], shared.athanor_id, shared.id)
  end

  test "attachments are byte-copied into the target's own tree", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    message_id = Cyfr.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, private.id, message_id, [
        %{"filename" => "flight.txt", "media_type" => "text/plain", "bytes" => "BA117"}
      ])

    {:ok, m} =
      Threads.append(ctx, private.id, %{
        id: message_id,
        author: ctx.user_id,
        kind: "text",
        content: "see attached",
        payload: %{"attachments" => refs}
      })

    {:ok, [posted]} = Aloud.post(ctx, private.id, [m.id], shared.athanor_id, shared.id)

    # The posted ref resolves in the TARGET estate — the bytes crossed,
    # not a pointer back into the private tree.
    target_ctx = %{ctx | athanor_id: shared.athanor_id}
    assert [ref] = Aqua.Attachments.refs_of(posted)
    assert ref["filename"] == "flight.txt"

    assert [%{"data" => data}] =
             Aqua.Attachments.load(target_ctx, shared.id, [%{message_id: posted.id, ref: ref}])

    assert Base.decode64!(data) == "BA117"
  end

  test "a missing blob refuses the copy rather than saying less than was chosen", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    message_id = Cyfr.UUID7.generate_id("msg")

    {:ok, refs} =
      Aqua.Attachments.store(ctx, private.id, message_id, [
        %{"filename" => "gone.txt", "media_type" => "text/plain", "bytes" => "poof"}
      ])

    {:ok, m} =
      Threads.append(ctx, private.id, %{
        id: message_id,
        author: ctx.user_id,
        kind: "text",
        content: "see attached",
        payload: %{"attachments" => refs}
      })

    :ok = Aqua.Attachments.discard(ctx, private.id, message_id, refs)

    assert {:error, :attachment_missing} =
             Aloud.post(ctx, private.id, [m.id], shared.athanor_id, shared.id)

    assert Threads.messages(%{ctx | athanor_id: shared.athanor_id}, shared.id) == []
  end

  test "refuses a copy into the same thread and an empty selection", %{
    ctx: ctx,
    private: private,
    shared: shared
  } do
    m = said(ctx, private, "x")

    assert {:error, :same_thread} =
             Aloud.post(ctx, private.id, [m.id], private.athanor_id, private.id)

    assert {:error, :nothing_to_say} =
             Aloud.post(ctx, private.id, [], shared.athanor_id, shared.id)

    assert {:error, :not_found} =
             Aloud.post(ctx, private.id, ["msg_nope"], shared.athanor_id, shared.id)
  end
end
