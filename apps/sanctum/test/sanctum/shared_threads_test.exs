# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SharedThreadsTest do
  @moduledoc """
  The rules of shared threads (`Sanctum.SharedThreads`): who makes a
  thread or a pair, who reads one, who adds, removes, withdraws and
  leaves, what a declared restore's freeze holds back, what a message and
  its files are, and whom each change is told to. A thread answers anyone
  not seated in it as a missing one, the platform administrator too.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.SharedThreads
  alias Sanctum.Tenancy.Users
  alias Sanctum.Test.Settings

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])
    [alice, bob, carol, dave] = for name <- ~w(alice bob carol dave), do: person!("#{name}-#{n}")
    {:ok, alice: alice, bob: bob, carol: carol, dave: dave}
  end

  defp person!(name) do
    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|st-#{name}",
        provider: "github",
        email: "#{name}@example.com",
        verified: true,
        name: name
      })

    user.id
  end

  # A person whose keys another CYFR holds, admitted here under `identifier`.
  defp remote!(identifier) do
    {:ok, user} =
      Sanctum.Test.People.remote(
        %{
          id: "cyfr|https://dir.example|" <> identifier,
          provider: "cyfr"
        },
        %{
          identifier: identifier,
          directory_url: "https://dir.example",
          head_hash: Prima.Digest.sha256("head-" <> identifier)
        }
      )

    user
  end

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("st-#{System.unique_integer()}")

  defp thread!(by, title \\ "Plans") do
    {:ok, thread} = SharedThreads.create(by, title)
    thread
  end

  defp seated!(thread, by, people) do
    for who <- people, do: {:ok, :added} = SharedThreads.add(by, thread.id, user_id: who)
    thread
  end

  defp people!(by, thread) do
    {:ok, people} = SharedThreads.people(by, thread.id)
    people
  end

  defp seated_ids(by, thread),
    do: for(%{status: "active", user_id: id} <- people!(by, thread), do: id)

  defp status!(thread_id) do
    {:ok, %{status: status}} = Arca.SharedThreads.get(Prima.Actor.system(), thread_id)
    status
  end

  defp stored(thread_id) do
    {:ok, paths} = Arca.list_recursive(Prima.Actor.system(), ["shared", thread_id])
    paths
  end

  defp open_restore!(user_id) do
    restore_id = Prima.UUID7.generate_id("rst")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.RestorePerson, [
        %{restore_id: restore_id, user_id: user_id, open: true}
      ])

    restore_id
  end

  defp close_restore!(restore_id) do
    {1, _} =
      Arca.Repo.update_all(
        from(r in Arca.Schemas.RestorePerson, where: r.restore_id == ^restore_id),
        set: [open: false, closed_at: DateTime.utc_now()]
      )

    :ok
  end

  # The people the next announcement of `kind` for the thread names.
  defp told(kind, thread_id) do
    assert_receive {^kind, %{thread_id: ^thread_id, user_ids: user_ids}}
    Enum.sort(user_ids)
  end

  describe "create/2" do
    test "makes a thread whose first member is its creator", %{alice: alice, bob: bob} do
      assert {:ok, thread} = SharedThreads.create(alice, "  Trip  ")
      assert %{kind: "shared", title: "Trip", status: "active", created_by: ^alice} = thread
      assert "sth_" <> _ = thread.id
      assert seated_ids(alice, thread) == [alice]
      assert {:error, {:not_found, "Thread", _}} = SharedThreads.get(bob, thread.id)
    end

    test "a blank title is refused", %{alice: alice} do
      for title <- ["", "   ", nil] do
        assert {:error, {:invalid_argument, "A thread needs a title"}} =
                 SharedThreads.create(alice, title)
      end

      assert {:ok, []} = SharedThreads.list(alice)
    end

    test "max_shared_threads_per_person refuses past its cap, and an archived thread frees its place",
         %{alice: alice, bob: bob} do
      Settings.put("max_shared_threads_per_person", 2)
      first = thread!(alice, "One")
      _second = thread!(alice, "Two")

      assert {:error, {:limit_reached, :max_shared_threads_per_person, 2}} =
               SharedThreads.create(alice, "Three")

      # The cap is the creator's: someone else still makes one.
      assert {:ok, _} = SharedThreads.create(bob, "Bob's")

      {:ok, _} = SharedThreads.archive(alice, first.id)
      assert {:ok, %{title: "Three"}} = SharedThreads.create(alice, "Three")
    end

    test "with the cap absent, a person makes as many as they like", %{alice: alice} do
      for n <- 1..5, do: assert({:ok, _} = SharedThreads.create(alice, "T#{n}"))
      assert {:ok, threads} = SharedThreads.list(alice)
      assert length(threads) == 5
    end
  end

  describe "pair/2" do
    test "is made for two who share an active thread, and found again from either side",
         %{alice: alice, bob: bob} do
      thread!(alice) |> seated!(alice, [bob])

      assert {:ok, pair} = SharedThreads.pair(alice, bob)
      assert %{kind: "pair", title: nil, status: "active", with: %{user_id: ^bob}} = pair
      assert Enum.sort(seated_ids(alice, pair)) == Enum.sort([alice, bob])

      assert {:ok, %{id: same, with: %{user_id: ^alice}}} = SharedThreads.pair(bob, alice)
      assert same == pair.id
      assert {:ok, %{id: ^same}} = SharedThreads.pair(alice, bob)
    end

    test "is refused for oneself and for two who share no active thread",
         %{alice: alice, bob: bob, carol: carol} do
      thread = thread!(alice) |> seated!(alice, [bob])

      assert {:error, {:shared_thread, :self}} = SharedThreads.pair(alice, alice)
      assert {:error, {:shared_thread, :not_together}} = SharedThreads.pair(alice, carol)

      # An id no one holds answers as a stranger does.
      assert {:error, {:shared_thread, :not_together}} =
               SharedThreads.pair(alice, Prima.UUID7.generate_id(Prima.PersonId.prefix()))

      # An archived thread brings no one together.
      {:ok, _} = SharedThreads.archive(alice, thread.id)
      assert {:error, {:shared_thread, :not_together}} = SharedThreads.pair(alice, bob)
    end

    test "max_pairs_per_person refuses a new pair when either person is at the cap",
         %{alice: alice, bob: bob, carol: carol} do
      Settings.put("max_pairs_per_person", 1)
      thread!(alice) |> seated!(alice, [bob, carol])
      {:ok, pair} = SharedThreads.pair(alice, bob)

      # Alice is at the cap, whoever asks.
      assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
               SharedThreads.pair(alice, carol)

      assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
               SharedThreads.pair(carol, alice)

      # A pair found is not counted.
      assert {:ok, %{id: same}} = SharedThreads.pair(bob, alice)
      assert same == pair.id

      # An ended pair frees its place.
      {:ok, %{ended: true}} = SharedThreads.leave(alice, pair.id)
      assert {:ok, %{kind: "pair"}} = SharedThreads.pair(alice, carol)
    end

    test "takes no add or remove, no rename, and never reopens",
         %{alice: alice, bob: bob, carol: carol} do
      thread!(alice) |> seated!(alice, [bob, carol])
      {:ok, pair} = SharedThreads.pair(alice, bob)

      assert {:error, {:shared_thread, :pair}} =
               SharedThreads.add(alice, pair.id, user_id: carol)

      assert {:error, {:shared_thread, :pair}} =
               SharedThreads.add(alice, pair.id, identifier: identifier())

      assert {:error, {:shared_thread, :pair}} =
               SharedThreads.remove(alice, pair.id, user_id: bob)

      assert {:error, {:shared_thread, :pair}} = SharedThreads.rename(alice, pair.id, "Us")
      assert {:ok, %{title: nil}} = SharedThreads.get(alice, pair.id)
      assert Enum.sort(seated_ids(alice, pair)) == Enum.sort([alice, bob])

      {:ok, %{status: "archived"}} = SharedThreads.archive(bob, pair.id)
      assert {:error, {:shared_thread, :pair}} = SharedThreads.unarchive(alice, pair.id)
      assert status!(pair.id) == "archived"
    end

    test "leaving a pair ends it, and the next pair call makes a new one",
         %{alice: alice, bob: bob} do
      thread!(alice) |> seated!(alice, [bob])
      {:ok, pair} = SharedThreads.pair(alice, bob)

      assert {:ok, %{ended: true}} = SharedThreads.leave(alice, pair.id)
      assert {:ok, %{status: "archived"}} = SharedThreads.get(bob, pair.id)
      assert {:error, {:shared_thread, :pair}} = SharedThreads.unarchive(bob, pair.id)

      assert {:ok, again} = SharedThreads.pair(bob, alice)
      refute again.id == pair.id
      assert again.status == "active"
    end
  end

  describe "reading" do
    test "get, people and messages answer only a seated person; to anyone else, the administrator too, the thread is missing",
         %{alice: alice, bob: bob, carol: carol} do
      {:ok, _} = Sanctum.TestContext.ensure_platform(carol)
      thread = thread!(alice) |> seated!(alice, [bob])
      {:ok, _} = SharedThreads.post(alice, thread.id, "hello")
      id = thread.id

      assert {:ok, %{id: ^id, title: "Plans"}} = SharedThreads.get(bob, id)
      assert [%{user_id: ^alice}, %{user_id: ^bob}] = people!(bob, thread)
      assert {:ok, [%{content: "hello", author: ^alice}]} = SharedThreads.messages(bob, id)

      stranger = person!("stranger-#{System.unique_integer([:positive])}")

      for who <- [carol, stranger] do
        assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.get(who, id)
        assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.people(who, id)
        assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.messages(who, id)
        assert {:ok, []} = SharedThreads.list(who)
      end

      # Archived, it answers the same to them, and its members still read it.
      {:ok, _} = SharedThreads.archive(alice, id)
      assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.get(carol, id)
      assert {:ok, %{status: "archived"}} = SharedThreads.get(bob, id)

      missing = "sth_" <> Ecto.UUID.generate()
      assert {:error, {:not_found, "Thread", ^missing}} = SharedThreads.get(alice, missing)
    end

    test "list answers the person's threads, active and archived, and a pair names the other person",
         %{alice: alice, bob: bob} do
      plans = thread!(alice, "Plans") |> seated!(alice, [bob])
      old = thread!(alice, "Old")
      {:ok, _} = SharedThreads.archive(alice, old.id)
      {:ok, pair} = SharedThreads.pair(alice, bob)

      assert {:ok, threads} = SharedThreads.list(alice)
      assert Enum.sort(Enum.map(threads, & &1.id)) == Enum.sort([plans.id, old.id, pair.id])

      assert %{kind: "pair", with: %{user_id: ^bob, name: bob_name}} =
               Enum.find(threads, &(&1.id == pair.id))

      assert bob_name == Users.display_name(bob)
      refute Map.has_key?(Enum.find(threads, &(&1.id == plans.id)), :with)

      assert {:ok, bobs} = SharedThreads.list(bob)
      assert Enum.sort(Enum.map(bobs, & &1.id)) == Enum.sort([plans.id, pair.id])
      assert %{with: %{user_id: ^alice}} = Enum.find(bobs, &(&1.id == pair.id))
    end
  end

  describe "tail/3 and people_in_threads_with/1" do
    test "tail reads the newest messages, oldest first, for a seated person alone",
         %{alice: alice, bob: bob, carol: carol} do
      thread = thread!(alice) |> seated!(alice, [bob])
      id = thread.id
      for n <- 1..4, do: {:ok, _} = SharedThreads.post(alice, id, "line #{n}")

      assert {:ok, tail} = SharedThreads.tail(bob, id, 2)
      assert Enum.map(tail, & &1.content) == ["line 3", "line 4"]
      assert [%{seq: 3, author: ^alice}, %{seq: 4}] = tail

      assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.tail(carol, id, 2)
    end

    test "people_in_threads_with names everyone seated with the person in an active thread, by name",
         %{alice: alice, bob: bob, carol: carol, dave: dave} do
      # Made last, named first: the order is the name's, not the row's.
      aaron = person!("aaron-#{System.unique_integer([:positive])}")
      one = thread!(alice) |> seated!(alice, [dave, aaron])
      thread!(alice, "Again") |> seated!(alice, [dave])
      # An invitation is no seat, and an archived thread no place to share.
      {:ok, :added} = SharedThreads.add(alice, one.id, identifier: identifier())
      closed = thread!(alice, "Closed") |> seated!(alice, [carol])
      {:ok, _} = SharedThreads.archive(alice, closed.id)
      thread!(bob, "Theirs") |> seated!(bob, [carol])

      assert {:ok, people} = SharedThreads.people_in_threads_with(alice)
      assert Enum.map(people, & &1.user_id) == [aaron, dave]

      assert [%{display_name: "aaron-" <> _, email: "aaron-" <> _} | _] = people
      assert {:ok, [%{user_id: ^carol}]} = SharedThreads.people_in_threads_with(bob)
    end
  end

  describe "add/3" do
    test "by user id seats the person, and again answers added with one seat",
         %{alice: alice, bob: bob} do
      thread = thread!(alice)

      assert {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: bob)
      assert {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: bob)
      assert seated_ids(bob, thread) == [alice, bob]

      nobody = Prima.UUID7.generate_id(Prima.PersonId.prefix())

      assert {:error, {:not_found, "Person", ^nobody}} =
               SharedThreads.add(alice, thread.id, user_id: nobody)
    end

    test "a person not seated adds no one", %{alice: alice, bob: bob, carol: carol} do
      thread = thread!(alice)
      id = thread.id

      assert {:error, {:not_found, "Thread", ^id}} =
               SharedThreads.add(bob, id, user_id: carol)

      assert seated_ids(alice, thread) == [alice]
    end

    test "by the identifier a person here holds seats them", %{alice: alice} do
      thread = thread!(alice)
      held = identifier()
      user = remote!(held)

      assert {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: held)
      assert seated_ids(alice, thread) == [alice, user.id]
      refute Enum.any?(people!(alice, thread), &(&1.status == "invited"))
      refute Enum.any?(Sanctum.Door.Store.requests(), &(&1.value == held))
    end

    test "by an identifier no one here holds leaves an invitation and the door's request",
         %{alice: alice} do
      thread = thread!(alice)
      unknown = identifier()

      assert {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: unknown)
      assert {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: unknown)

      assert [%{identifier: ^unknown, status: "invited"}] =
               Enum.filter(people!(alice, thread), &(&1.status == "invited"))

      assert [%{kind: "identifier", status: "requested"}] =
               Enum.filter(Sanctum.Door.Store.requests(), &(&1.value == unknown))

      # An identifier the door admits already queues nothing.
      admitted = identifier()
      {:ok, _} = Sanctum.Door.Store.allow("identifier", admitted, "ops")
      assert {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: admitted)
      refute Enum.any?(Sanctum.Door.Store.requests(), &(&1.value == admitted))
      assert Enum.any?(people!(alice, thread), &(&1[:identifier] == admitted))
    end

    test "a malformed identifier is refused and writes nothing", %{alice: alice} do
      thread = thread!(alice)

      for bad <- ["per_not-an-identifier", "someone", "per_" <> String.duplicate("a", 63)] do
        assert {:error, {:invalid_argument, _}} =
                 SharedThreads.add(alice, thread.id, identifier: bad)
      end

      assert people!(alice, thread) |> length() == 1
      assert Sanctum.Door.Store.requests() == []
    end

    test "max_people_per_thread counts invitations and refuses past its cap",
         %{alice: alice, bob: bob, carol: carol} do
      Settings.put("max_people_per_thread", 3)
      thread = thread!(alice) |> seated!(alice, [bob])
      invited = identifier()
      {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: invited)

      assert {:error, {:limit_reached, :max_people_per_thread, 3}} =
               SharedThreads.add(alice, thread.id, user_id: carol)

      assert {:error, {:limit_reached, :max_people_per_thread, 3}} =
               SharedThreads.add(bob, thread.id, identifier: identifier())

      assert length(people!(alice, thread)) == 3

      # A withdrawn invitation frees its place.
      :ok = SharedThreads.withdraw(alice, thread.id, invited)
      assert {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: carol)
    end

    # Lib defect: `Arca.SharedThreadMembers.add/5` counts the cap before
    # the insert's conflict, so at the cap a seat or an invitation already
    # held is refused instead of answered `:added`, as `add/3` promises.
    test "at max_people_per_thread, a seat or an invitation already held is answered added",
         %{alice: alice, bob: bob} do
      Settings.put("max_people_per_thread", 3)
      thread = thread!(alice) |> seated!(alice, [bob])
      invited = identifier()
      {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: invited)

      assert {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: bob)
      assert {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: invited)
      assert length(people!(alice, thread)) == 3
    end

    test "an archived thread takes no one", %{alice: alice, bob: bob} do
      thread = thread!(alice)
      {:ok, _} = SharedThreads.archive(alice, thread.id)

      assert {:error, {:shared_thread, :archived}} =
               SharedThreads.add(alice, thread.id, user_id: bob)

      assert {:error, {:shared_thread, :archived}} =
               SharedThreads.add(alice, thread.id, identifier: identifier())
    end
  end

  describe "remove, withdraw, leave and unarchive" do
    test "a member removes another member", %{alice: alice, bob: bob, carol: carol} do
      thread = thread!(alice) |> seated!(alice, [bob, carol])
      id = thread.id

      assert :ok = SharedThreads.remove(bob, id, user_id: carol)
      assert seated_ids(alice, thread) == [alice, bob]
      assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.get(carol, id)

      assert {:error, {:not_found, "Member", ^carol}} =
               SharedThreads.remove(bob, id, user_id: carol)
    end

    test "withdraw removes an invitation, and finds none once its sign-in seated it",
         %{alice: alice} do
      thread = thread!(alice)
      pending = identifier()
      {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: pending)

      assert :ok = SharedThreads.withdraw(alice, thread.id, pending)
      assert people!(alice, thread) |> Enum.all?(&(&1.status == "active"))

      assert {:error, {:not_found, "Invitation", ^pending}} =
               SharedThreads.withdraw(alice, thread.id, pending)

      claimed = identifier()
      {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: claimed)
      user = remote!(claimed)
      assert {:ok, 1} = SharedThreads.activate_invited(user)

      assert {:error, {:not_found, "Invitation", ^claimed}} =
               SharedThreads.withdraw(alice, thread.id, claimed)

      assert user.id in seated_ids(alice, thread)
    end

    test "removing oneself is a leave, and the last leave archives the thread",
         %{alice: alice, bob: bob} do
      thread = thread!(alice) |> seated!(alice, [bob])

      assert :ok = SharedThreads.remove(alice, thread.id, user_id: alice)
      assert seated_ids(bob, thread) == [bob]
      assert status!(thread.id) == "active"

      assert {:ok, %{ended: true}} = SharedThreads.leave(bob, thread.id)
      assert status!(thread.id) == "archived"

      assert {:error, {:not_found, "Thread", _}} = SharedThreads.leave(bob, thread.id)
    end

    test "a member who still sits there reopens an archived thread", %{alice: alice, bob: bob} do
      thread = thread!(alice) |> seated!(alice, [bob])
      {:ok, %{status: "archived"}} = SharedThreads.archive(alice, thread.id)

      assert {:ok, %{status: "active"}} = SharedThreads.unarchive(bob, thread.id)
      assert status!(thread.id) == "active"
      assert {:ok, %{title: "Again"}} = SharedThreads.rename(bob, thread.id, "Again")
    end
  end

  describe "a declared restore's freeze" do
    test "while a member recovers, adding and inviting are refused; removing and leaving stay admitted",
         %{alice: alice, bob: bob, carol: carol, dave: dave} do
      thread = thread!(alice) |> seated!(alice, [bob, dave])
      _restore = open_restore!(bob)

      assert {:error, {:shared_thread, :recovering_from_restore}} =
               SharedThreads.add(alice, thread.id, user_id: carol)

      assert {:error, {:shared_thread, :recovering_from_restore}} =
               SharedThreads.add(alice, thread.id, identifier: identifier())

      assert Enum.all?(people!(alice, thread), &(&1.status == "active"))

      assert :ok = SharedThreads.remove(alice, thread.id, user_id: dave)
      assert {:ok, %{ended: false}} = SharedThreads.leave(alice, thread.id)
      assert seated_ids(bob, thread) == [bob]
    end

    test "an invitation it holds stays an invitation at sign-in, and becomes the seat once the recovery closes",
         %{alice: alice, bob: bob} do
      thread = thread!(alice) |> seated!(alice, [bob])
      held = identifier()
      {:ok, :added} = SharedThreads.add(alice, thread.id, identifier: held)
      restore = open_restore!(bob)
      user = remote!(held)

      assert {:ok, 0} = SharedThreads.activate_invited(user)

      assert [%{identifier: ^held, status: "invited"}] =
               Enum.filter(people!(alice, thread), &(&1.status == "invited"))

      refute user.id in seated_ids(alice, thread)

      :ok = close_restore!(restore)
      assert {:ok, 1} = SharedThreads.activate_invited(user)
      assert user.id in seated_ids(alice, thread)
      refute Enum.any?(people!(alice, thread), &(&1.status == "invited"))
    end
  end

  describe "what is said" do
    test "a member posts words, and the people read them in order", %{alice: alice, bob: bob} do
      thread = thread!(alice) |> seated!(alice, [bob])

      assert {:ok, %{seq: 1, author: ^alice, content: "hi", attachments: []}} =
               SharedThreads.post(alice, thread.id, "hi")

      assert {:ok, %{seq: 2}} = SharedThreads.post(bob, thread.id, "hello")

      assert {:ok, [%{content: "hi"}, %{content: "hello", author: ^bob}]} =
               SharedThreads.messages(alice, thread.id)

      assert {:ok, [%{seq: 2}]} = SharedThreads.messages(alice, thread.id, after_seq: 1)

      assert {:error, {:invalid_argument, _}} = SharedThreads.post(alice, thread.id, "")
    end

    test "a line said aloud keeps its provenance and nothing else of what it was given; a post keeps none",
         %{alice: alice, bob: bob} do
      thread = thread!(alice) |> seated!(alice, [bob])
      from = %{"thread_id" => "thread_own", "message_id" => "msg_own"}

      aloud = %{
        "aloud_from" => from,
        "shared_agent" => true,
        "attachments" => [%{"stored_name" => "0-forged"}],
        "author" => bob
      }

      assert {:ok, said} = SharedThreads.post(alice, thread.id, "my line", [], aloud)
      assert said.attachments == []

      assert {:ok, %{author: ^alice, payload: payload}} =
               Arca.SharedMessages.get(Prima.Actor.system(), thread.id, said.id)

      assert payload == %{"aloud_from" => from, "shared_agent" => true}

      file = %{filename: "a.txt", media_type: "text/plain", bytes: "a"}
      assert {:ok, posted} = SharedThreads.post(alice, thread.id, "plain", [file])

      assert {:ok, %{payload: payload}} =
               Arca.SharedMessages.get(Prima.Actor.system(), thread.id, posted.id)

      assert Map.keys(payload) == ["attachments"]

      assert {:ok, words} = SharedThreads.post(alice, thread.id, "words")

      assert {:ok, %{payload: payload}} =
               Arca.SharedMessages.get(Prima.Actor.system(), thread.id, words.id)

      assert payload == %{}
    end

    test "a message's files are stored under it and read back by a member alone",
         %{alice: alice, bob: bob, carol: carol} do
      thread = thread!(alice) |> seated!(alice, [bob])
      id = thread.id

      files = [
        %{filename: "notes.txt", media_type: "text/plain", bytes: "the notes"},
        %{filename: "../a b.csv", media_type: nil, bytes: "1,2"}
      ]

      assert {:ok, message} = SharedThreads.post(alice, id, "see these", files)

      assert [
               %{
                 "filename" => "notes.txt",
                 "stored_name" => first,
                 "media_type" => "text/plain",
                 "size" => 9
               },
               %{"filename" => ".._a b.csv", "stored_name" => second, "size" => 3}
             ] = message.attachments

      assert {:ok, "the notes"} =
               Arca.get(Prima.Actor.system(), ["shared", id, message.id, first])

      assert {:ok, %{filename: "notes.txt", media_type: "text/plain", bytes: "the notes"}} =
               SharedThreads.attachment(bob, id, message.id, first)

      assert {:ok, %{bytes: "1,2"}} = SharedThreads.attachment(alice, id, message.id, second)

      assert {:error, {:not_found, "Thread", ^id}} =
               SharedThreads.attachment(carol, id, message.id, first)

      assert {:error, {:not_found, "Attachment", "9-none"}} =
               SharedThreads.attachment(bob, id, message.id, "9-none")
    end

    test "a file over the per-file bound is refused with nothing stored, and that is the one bound",
         %{alice: alice} do
      thread = thread!(alice)
      assert %{max_file_bytes: max_bytes} = SharedThreads.limits()

      small = %{filename: "small.txt", media_type: "text/plain", bytes: "x"}
      big = %{filename: "big.bin", media_type: nil, bytes: :binary.copy(<<0>>, max_bytes + 1)}

      assert {:error, {:invalid_argument, _}} =
               SharedThreads.post(alice, thread.id, "big", [small, big])

      assert stored(thread.id) == []
      assert {:ok, []} = SharedThreads.messages(alice, thread.id)

      many = for n <- 1..11, do: %{small | filename: "#{n}.txt"}
      assert {:ok, %{attachments: refs}} = SharedThreads.post(alice, thread.id, "many", many)
      assert length(refs) == 11
    end

    test "a post to an archived thread is refused and leaves no file", %{alice: alice} do
      thread = thread!(alice)
      {:ok, _} = SharedThreads.archive(alice, thread.id)
      file = [%{filename: "late.txt", media_type: "text/plain", bytes: "late"}]

      assert {:error, {:shared_thread, :archived}} =
               SharedThreads.post(alice, thread.id, "late", file)

      assert {:error, {:shared_thread, :archived}} = SharedThreads.post(alice, thread.id, "late")
      assert stored(thread.id) == []
      assert {:ok, []} = SharedThreads.messages(alice, thread.id)
    end

    test "a person not seated posts nothing", %{alice: alice, bob: bob} do
      thread = thread!(alice)
      id = thread.id
      file = [%{filename: "x.txt", media_type: "text/plain", bytes: "x"}]

      assert {:error, {:not_found, "Thread", ^id}} = SharedThreads.post(bob, id, "hi", file)
      assert stored(id) == []
    end
  end

  describe "announcements" do
    setup do
      test = self()
      handler = "shared-thread-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:cyfr, :sanctum, :shared_thread, :changed], [:cyfr, :sanctum, :shared_thread, :posted]],
        fn [_, _, _, kind], _measurements, meta, _config -> send(test, {kind, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "a change is told to the thread's people and to anyone it took from it, a post to its people",
         %{alice: alice, bob: bob, carol: carol} do
      {:ok, thread} = SharedThreads.create(alice, "Plans")
      id = thread.id
      assert told(:changed, id) == [alice]

      {:ok, :added} = SharedThreads.add(alice, id, user_id: bob)
      assert told(:changed, id) == Enum.sort([alice, bob])

      {:ok, :added} = SharedThreads.add(alice, id, user_id: carol)
      assert told(:changed, id) == Enum.sort([alice, bob, carol])

      {:ok, _} = SharedThreads.post(bob, id, "hello")
      assert told(:posted, id) == Enum.sort([alice, bob, carol])

      {:ok, _} = SharedThreads.rename(alice, id, "Trip")
      assert told(:changed, id) == Enum.sort([alice, bob, carol])

      :ok = SharedThreads.remove(alice, id, user_id: carol)
      assert told(:changed, id) == Enum.sort([alice, bob, carol])

      {:ok, %{ended: false}} = SharedThreads.leave(bob, id)
      assert told(:changed, id) == Enum.sort([alice, bob])

      refute_receive {_kind, %{thread_id: ^id}}, 50
    end
  end
end

defmodule Sanctum.SharedThreadsReadThenWriteTest do
  @moduledoc """
  What a first read cannot decide. Each case reads as the rules module
  does, then pauses right after its first read of a thread's people,
  outside any transaction; the case changes the thread meanwhile, and the
  write that follows answers what the store reads under its lock, in its
  own transaction: a person removed meanwhile changes nothing, and a pair
  is made only while its two still share a thread. Also: a message's file
  is found by its message, however many came before it.

  The pause is outside any transaction, so it holds on SQLite as on
  PostgreSQL.
  """

  use ExUnit.Case, async: false

  alias Sanctum.SharedThreads

  @pause {__MODULE__, :pause}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])
    [alice, bob, carol] = for name <- ~w(alice bob carol), do: person!("#{name}-#{n}")
    {:ok, thread} = SharedThreads.create(alice, "Review")
    {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: bob)
    {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: carol)

    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.pause/4, nil)

    {:ok, alice: alice, bob: bob, carol: carol, thread: thread}
  end

  defp person!(name) do
    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|rtw-#{name}",
        provider: "github",
        email: "#{name}@example.com",
        verified: true,
        name: name
      })

    user.id
  end

  test "a member removed after the first read renames, archives, reopens, removes and withdraws nothing",
       %{alice: alice, bob: bob, carol: carol, thread: thread} do
    {:ok, :added} =
      SharedThreads.add(alice, thread.id, identifier: "per_" <> String.duplicate("a", 64))

    acts = [
      fn -> SharedThreads.rename(bob, thread.id, "Theirs") end,
      fn -> SharedThreads.archive(bob, thread.id) end,
      fn -> SharedThreads.remove(bob, thread.id, user_id: carol) end,
      fn -> SharedThreads.withdraw(bob, thread.id, "per_" <> String.duplicate("a", 64)) end
    ]

    for act <- acts do
      {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: bob)
      assert {:error, {:not_found, "Thread", _}} = removed_meanwhile(act, alice, thread, bob)
    end

    {:ok, people} = SharedThreads.people(alice, thread.id)
    assert Enum.sort(for %{user_id: id} <- people, do: id) == Enum.sort([alice, carol])
    assert Enum.any?(people, &(&1.status == "invited"))
    assert {:ok, %{title: "Review", status: "active"}} = SharedThreads.get(alice, thread.id)

    {:ok, :added} = SharedThreads.add(alice, thread.id, user_id: bob)
    {:ok, _} = SharedThreads.archive(alice, thread.id)
    reopen = fn -> SharedThreads.unarchive(bob, thread.id) end
    assert {:error, {:not_found, "Thread", _}} = removed_meanwhile(reopen, alice, thread, bob)
    assert {:ok, %{status: "archived"}} = SharedThreads.get(alice, thread.id)
  end

  test "a pair is not made once its two no longer share a thread",
       %{alice: alice, bob: bob, thread: thread} do
    pairing = fn -> SharedThreads.pair(alice, bob) end

    assert {:error, {:shared_thread, :not_together}} =
             removed_meanwhile(pairing, alice, thread, bob)

    assert {:ok, [%{id: id}]} = SharedThreads.list(alice)
    assert id == thread.id
  end

  test "a file on the 501st message is read back by its message", %{alice: alice, thread: thread} do
    for _ <- 1..500, do: {:ok, _} = SharedThreads.post(alice, thread.id, "words")
    file = %{filename: "proof.txt", media_type: "text/plain", bytes: "proof"}
    {:ok, message} = SharedThreads.post(alice, thread.id, "", [file])
    assert message.seq == 501

    [ref] = message.attachments

    assert {:ok, %{bytes: "proof", filename: "proof.txt"}} =
             SharedThreads.attachment(alice, thread.id, message.id, ref["stored_name"])
  end

  # `act` runs in a task that pauses right after its first read of the
  # thread's people; `by` removes `member` meanwhile; then `act` goes on
  # and its answer is returned. On SQLite the task shares the case's
  # sandboxed connection, so the removal runs between its statements.
  defp removed_meanwhile(act, by, thread, member) do
    test = self()

    task =
      Task.async(fn ->
        Process.put(@pause, test)
        act.()
      end)

    assert_receive {:paused, actor}, 5_000

    assert :ok = SharedThreads.remove(by, thread.id, user_id: member)

    send(actor, :continue)
    Task.await(task, 10_000)
  end

  @doc false
  def pause(_event, _measurements, %{query: query}, _config) do
    with test when is_pid(test) <- Process.get(@pause),
         true <- String.starts_with?(query, "SELECT"),
         true <- String.contains?(query, ~s("shared_thread_members")) do
      Process.delete(@pause)
      send(test, {:paused, self()})

      receive do
        :continue -> :ok
      after
        15_000 -> raise "paused past the case"
      end
    end

    :ok
  end
end
