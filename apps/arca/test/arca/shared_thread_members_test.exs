# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedThreadMembersTest do
  @moduledoc """
  The people of a shared thread: a person seated once and an identifier
  invited once, each only into an active thread; the invitations an
  identifier holds turned into that person's seats at their sign-in,
  except where they sit already or the thread is archived; an invitation
  withdrawn and a seat removed, whatever the thread's status. Every
  function is the platform's and refuses an athanor's actor.
  """

  use ExUnit.Case, async: true

  alias Arca.{SharedThreadMembers, SharedThreads}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    by = person()
    {:ok, thread} = SharedThreads.create(server(), %{title: "Plans", created_by: by})
    {:ok, by: by, thread: thread}
  end

  defp server, do: Prima.Actor.system()
  defp person, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
  defp identifier, do: "per_#{System.unique_integer([:positive])}"

  defp archived!(thread) do
    {:ok, _} = SharedThreads.archive(server(), thread.id)
    :ok
  end

  describe "seat/4" do
    test "seats a person once", %{by: by, thread: thread} do
      who = person()

      assert {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)

      assert %{
               thread_id: thread_id,
               user_id: ^who,
               person_identifier: nil,
               status: "active",
               added_by: ^by
             } = seat

      assert thread_id == thread.id
      assert "stm_" <> _ = seat.id
      assert {:ok, ^seat} = SharedThreadMembers.find(server(), thread.id, who)

      assert {:error, :conflict} = SharedThreadMembers.seat(server(), thread.id, who, by)
      assert {:ok, people} = SharedThreadMembers.list(server(), thread.id)
      assert Enum.count(people, &(&1.user_id == who)) == 1
    end

    test "refuses an archived or unknown thread and a seat for someone who is not a person",
         %{by: by, thread: thread} do
      assert {:error, :not_found} = SharedThreadMembers.seat(server(), "sth_nobody", person(), by)

      assert {:error, {:invalid, %{user_id: [_]}}} =
               SharedThreadMembers.seat(server(), thread.id, "system", by)

      :ok = archived!(thread)
      who = person()
      assert {:error, :archived} = SharedThreadMembers.seat(server(), thread.id, who, by)
      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)
    end
  end

  describe "invite/4" do
    test "invites an identifier once, as a row naming no person", %{by: by, thread: thread} do
      id = identifier()

      assert {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert %{person_identifier: ^id, user_id: nil, status: "invited", added_by: ^by} =
               invitation

      assert {:error, :conflict} = SharedThreadMembers.invite(server(), thread.id, id, by)
    end

    test "refuses an archived or unknown thread and an empty identifier",
         %{by: by, thread: thread} do
      assert {:error, :not_found} =
               SharedThreadMembers.invite(server(), "sth_nobody", identifier(), by)

      assert {:error, {:invalid, %{person_identifier: [_]}}} =
               SharedThreadMembers.invite(server(), thread.id, "", by)

      :ok = archived!(thread)

      assert {:error, :archived} =
               SharedThreadMembers.invite(server(), thread.id, identifier(), by)
    end
  end

  describe "activate/3" do
    test "turns an identifier's invitations into the person's seats and names their threads",
         %{by: by, thread: thread} do
      {:ok, other} = SharedThreads.create(server(), %{title: "Trip", created_by: by})
      id = identifier()
      who = person()
      {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, _} = SharedThreadMembers.invite(server(), other.id, id, by)

      assert {:ok, threads} = SharedThreadMembers.activate(server(), who, id)
      assert threads == Enum.sort([thread.id, other.id])

      for t <- [thread, other] do
        assert {:ok, %{status: "active", person_identifier: nil, added_by: ^by}} =
                 SharedThreadMembers.find(server(), t.id, who)
      end

      assert {:ok, []} = SharedThreadMembers.activate(server(), who, id)
    end

    test "drops an invitation where the person sits already, and keeps one in an archived thread",
         %{by: by, thread: thread} do
      {:ok, ended} = SharedThreads.create(server(), %{title: "Ended", created_by: by})
      id = identifier()
      who = person()
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, _} = SharedThreadMembers.invite(server(), ended.id, id, by)
      :ok = archived!(ended)

      assert {:ok, []} = SharedThreadMembers.activate(server(), who, id)

      {:ok, people} = SharedThreadMembers.list(server(), thread.id)
      assert Enum.filter(people, &(&1.user_id == who or &1.person_identifier == id)) == [seat]

      {:ok, ended_people} = SharedThreadMembers.list(server(), ended.id)

      assert [%{status: "invited", person_identifier: ^id}] =
               Enum.reject(ended_people, &(&1.user_id == by))
    end

    test "refuses someone who is not a person or an empty identifier" do
      assert {:error, {:invalid, %{user_id: [_]}}} =
               SharedThreadMembers.activate(server(), "system", identifier())

      assert {:error, {:invalid, %{person_identifier: [_]}}} =
               SharedThreadMembers.activate(server(), person(), "")
    end
  end

  describe "withdraw/3 and remove/3" do
    test "withdraw an invitation and remove a seat once each, in an archived thread too",
         %{by: by, thread: thread} do
      id = identifier()
      who = person()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      :ok = archived!(thread)

      assert {:ok, ^invitation} = SharedThreadMembers.withdraw(server(), thread.id, id)
      assert {:error, :not_found} = SharedThreadMembers.withdraw(server(), thread.id, id)

      assert {:ok, ^seat} = SharedThreadMembers.remove(server(), thread.id, who)
      assert {:error, :not_found} = SharedThreadMembers.remove(server(), thread.id, who)
      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)

      assert {:ok, [%{user_id: ^by}]} = SharedThreadMembers.list(server(), thread.id)
    end

    test "withdraw takes no seat and remove takes no invitation", %{by: by, thread: thread} do
      id = identifier()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert {:error, :not_found} = SharedThreadMembers.remove(server(), thread.id, id)
      assert {:error, :not_found} = SharedThreadMembers.withdraw(server(), thread.id, by)

      {:ok, people} = SharedThreadMembers.list(server(), thread.id)
      assert invitation in people
      assert Enum.any?(people, &(&1.user_id == by))
    end
  end

  describe "list/2" do
    test "names the thread's seats and invitations, oldest first", %{by: by, thread: thread} do
      who = person()
      id = identifier()
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert {:ok, [%{user_id: ^by}, ^seat, ^invitation]} =
               SharedThreadMembers.list(server(), thread.id)

      assert {:ok, []} = SharedThreadMembers.list(server(), "sth_nobody")
    end
  end

  test "an athanor's actor reaches no function", %{by: by, thread: thread} do
    actor = Prima.Actor.in_athanor("ath_stm_#{System.unique_integer([:positive])}")
    id = identifier()

    for call <- [
          fn -> SharedThreadMembers.seat(actor, thread.id, person(), by) end,
          fn -> SharedThreadMembers.invite(actor, thread.id, id, by) end,
          fn -> SharedThreadMembers.activate(actor, person(), id) end,
          fn -> SharedThreadMembers.withdraw(actor, thread.id, id) end,
          fn -> SharedThreadMembers.remove(actor, thread.id, by) end,
          fn -> SharedThreadMembers.find(actor, thread.id, by) end,
          fn -> SharedThreadMembers.list(actor, thread.id) end
        ] do
      assert {:error, :cross_tenant} = call.()
    end

    assert {:ok, [%{user_id: ^by}]} = SharedThreadMembers.list(server(), thread.id)
  end
end
