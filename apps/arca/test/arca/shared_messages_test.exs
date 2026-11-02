# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedMessagesTest do
  @moduledoc """
  The messages of a shared thread: appended at the next `seq`, dense from
  1, with their author, text and payload, each setting the thread's
  `last_message_at`; refused in an archived or unknown thread and for an
  author who is not a person; read oldest first, after a `seq` and by the
  page. The baseline holds one message per `seq` in a thread, and many
  appending at once each land on a `seq` of their own
  (`Arca.SharedMessagesRaceTest`). Every function is the platform's and
  refuses an athanor's actor.
  """

  use ExUnit.Case, async: true

  alias Arca.{SharedMessages, SharedThreads}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    by = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    {:ok, thread} = SharedThreads.create(server(), %{title: "Plans", created_by: by})
    {:ok, by: by, thread: thread}
  end

  defp server, do: Prima.Actor.system()

  describe "append/3" do
    test "writes each message at the next seq and moves the thread's last message",
         %{by: by, thread: thread} do
      payload = %{"attachments" => [%{"name" => "a.txt", "size" => 3}]}

      assert {:ok, first} =
               SharedMessages.append(server(), thread.id, %{
                 author: by,
                 content: "hello",
                 payload: payload
               })

      assert %{thread_id: thread_id, seq: 1, author: ^by, content: "hello", payload: ^payload} =
               first

      assert thread_id == thread.id
      assert "shm_" <> _ = first.id

      assert {:ok, second} = SharedMessages.append(server(), thread.id, %{author: by})
      assert %{seq: 2, content: "", payload: %{}} = second

      assert {:ok, %{last_message_at: last}} = SharedThreads.get(server(), thread.id)
      assert last == second.inserted_at
    end

    test "refuses an archived or unknown thread, writing nothing", %{by: by, thread: thread} do
      assert {:error, :not_found} =
               SharedMessages.append(server(), "sth_nobody", %{author: by, content: "x"})

      {:ok, _} = SharedThreads.archive(server(), thread.id)

      assert {:error, :archived} =
               SharedMessages.append(server(), thread.id, %{author: by, content: "x"})

      assert {:ok, []} = SharedMessages.list(server(), thread.id)
      assert {:ok, %{last_message_at: nil}} = SharedThreads.get(server(), thread.id)
    end

    test "refuses an author who is not a person, text that is not text and a payload that is not a map",
         %{by: by, thread: thread} do
      assert {:error, {:invalid, %{author: [_]}}} =
               SharedMessages.append(server(), thread.id, %{author: "system", content: "x"})

      assert {:error, {:invalid, %{content: [_], payload: [_]}}} =
               SharedMessages.append(server(), thread.id, %{
                 author: by,
                 content: 7,
                 payload: ["x"]
               })

      assert {:ok, []} = SharedMessages.list(server(), thread.id)
    end
  end

  describe "list/3" do
    test "reads oldest first, after a seq and by the page", %{by: by, thread: thread} do
      for n <- 1..5,
          do:
            {:ok, _} = SharedMessages.append(server(), thread.id, %{author: by, content: "#{n}"})

      assert {:ok, all} = SharedMessages.list(server(), thread.id)
      assert Enum.map(all, & &1.seq) == [1, 2, 3, 4, 5]
      assert Enum.map(all, & &1.content) == ~w(1 2 3 4 5)

      assert {:ok, page} = SharedMessages.list(server(), thread.id, after_seq: 2, limit: 2)
      assert Enum.map(page, & &1.seq) == [3, 4]

      assert {:ok, [%{seq: 5}]} = SharedMessages.list(server(), thread.id, after_seq: 4)
      assert {:ok, []} = SharedMessages.list(server(), "sth_nobody")
    end
  end

  test "the baseline holds one message per seq in a thread", %{by: by, thread: thread} do
    {:ok, _} = SharedMessages.append(server(), thread.id, %{author: by, content: "first"})

    duplicate = %{
      id: Prima.UUID7.generate_id("shm"),
      thread_id: thread.id,
      seq: 1,
      author: by,
      content: "again",
      inserted_at: DateTime.utc_now()
    }

    message =
      try do
        Arca.Repo.transaction(fn -> Arca.Repo.insert_all("shared_messages", [duplicate]) end)
        nil
      rescue
        error -> Exception.message(error)
      end

    # The index's name on PostgreSQL, its columns on SQLite.
    assert message =~
             ~r/shared_messages_thread_id_seq_index|shared_messages\.thread_id, shared_messages\.seq/

    assert {:ok, [%{content: "first"}]} = SharedMessages.list(server(), thread.id)
  end

  test "an athanor's actor reaches no function", %{by: by, thread: thread} do
    actor = Prima.Actor.in_athanor("ath_shm_#{System.unique_integer([:positive])}")

    assert {:error, :cross_tenant} =
             SharedMessages.append(actor, thread.id, %{author: by, content: "x"})

    assert {:error, :cross_tenant} = SharedMessages.list(actor, thread.id)
    assert {:ok, []} = SharedMessages.list(server(), thread.id)
  end
end

defmodule Arca.SharedMessagesRaceTest do
  @moduledoc """
  Many people posting into one thread at once, on real connections
  outside the sandbox: every append lands, each on a `seq` of its own, and
  the thread's messages are dense from 1. On PostgreSQL an appender that
  read a last `seq` another took first writes nothing and takes the next;
  on SQLite each waits for the one before it at its transaction's entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, SharedMessages, SharedThreads}
  alias Arca.Schemas.{CellLease, SharedMessage, SharedThread, SharedThreadMember}
  alias Ecto.Adapters.SQL.Sandbox

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @appenders 8

  defp server, do: Prima.Actor.system()
  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  test "every append lands on a seq of its own" do
    hold_slot!()
    by = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    on_exit(fn ->
      unboxed(fn ->
        ids = from(t in SharedThread, where: t.created_by == ^by, select: t.id)
        Arca.Repo.delete_all(from(m in SharedMessage, where: m.thread_id in subquery(ids)))
        Arca.Repo.delete_all(from(m in SharedThreadMember, where: m.thread_id in subquery(ids)))
        Arca.Repo.delete_all(from(t in SharedThread, where: t.created_by == ^by))
      end)
    end)

    {:ok, thread} =
      unboxed(fn -> SharedThreads.create(server(), %{title: "Race", created_by: by}) end)

    answers =
      1..@appenders
      |> Enum.map(fn n ->
        Task.async(fn ->
          unboxed(fn ->
            SharedMessages.append(server(), thread.id, %{author: by, content: "#{n}"})
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.all?(answers, &match?({:ok, _}, &1)), inspect(answers)
    seqs = for {:ok, message} <- answers, do: message.seq
    assert Enum.sort(seqs) == Enum.to_list(1..@appenders)

    {:ok, messages} = unboxed(fn -> SharedMessages.list(server(), thread.id) end)
    assert Enum.map(messages, & &1.seq) == Enum.to_list(1..@appenders)

    assert Enum.sort(Enum.map(messages, & &1.content)) ==
             Enum.sort(Enum.map(1..@appenders, &to_string/1))
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease. Each process-wide value is restored after the case,
  # registered before it changes (`Prima.Test.Env`), and the lease row is
  # deleted.
  defp hold_slot! do
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)
    end)

    for key <- @slot_keys, do: Prima.Test.Env.erase_persistent_term(key)
    Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end
end
