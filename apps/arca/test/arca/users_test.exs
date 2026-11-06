# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsersTest do
  @moduledoc """
  The person rows. None of this is athanor-scoped — a person exists before any athanor does and sits in
  several at once — so every function is asked for with the platform
  scope and refuses an athanor-scoped actor.
  """
  use ExUnit.Case, async: true

  alias Arca.Users

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()

  defp user_attrs do
    now = DateTime.utc_now()

    %{
      id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
      first_seen_at: now,
      last_seen_at: now,
      created_at: now,
      updated_at: now
    }
  end

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  defp person!(overrides \\ %{}) do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    user_attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          email: "p#{n}@example.com",
          email_verified: true,
          display_name: "P#{n}",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        overrides
      )

    {:ok, user} = Arca.Test.People.mint(server(), user_attrs)
    user
  end

  # A person id minted after `id`: ids are time-ordered by the
  # millisecond, so a later millisecond's id is greater. Bounded by a
  # second of wall time, far more than the clock needs to move.
  defp later_id(id, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    candidate = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    cond do
      candidate > id -> candidate
      System.monotonic_time(:millisecond) < deadline -> later_id(id, deadline)
      true -> flunk("no person id later than #{id} within a second")
    end
  end

  defp watch_queries! do
    handler = "users-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measure, _meta, _config -> if self() == parent, do: send(parent, :queried) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Every query this process has run so far, forgotten: what the refusals
  # below must not produce is a query of their own.
  defp drain_queries! do
    receive do
      :queried -> drain_queries!()
    after
      0 -> :ok
    end
  end

  # Called through `apply/3`: the refusal under test is the one a caller
  # makes at run time, and a literal call the compiler can type-check
  # would be refused before this file ever runs.
  defp refused!(fun, args) do
    assert_raise FunctionClauseError, fn -> apply(Users, fun, args) end
  end

  describe "the actor is the first argument, and a wrong one refuses before any query" do
    test "an athanor-scoped actor is refused by every function" do
      watch_queries!()
      member = in_athanor("ath_somewhere")
      row = %Arca.Schemas.User{id: "usr_x"}

      assert {:error, :cross_tenant} = Users.get(member, "usr_1")
      assert {:error, :cross_tenant} = Users.get_by_namespace(member, "alice")
      assert {:error, :cross_tenant} = Users.list(member)
      assert {:error, :cross_tenant} = Users.update(member, row.id, %{display_name: "X"})
      assert {:error, :cross_tenant} = Users.mint(member, %{}, admission: "open")
      refute_received :queried

      # The probe is live: the server's own actor does query.
      assert {:error, :not_found} = Users.get(server(), "usr_nobody")
      assert_received :queried
    end

    test "a plain map, or a bare person id, raises before any query" do
      watch_queries!()
      user = person!()
      drain_queries!()

      # A map carrying the actor's own fields is still not a `%Prima.Actor{}`:
      # every head matches the struct, so the shape is refused rather than
      # read for the scope it claims.
      not_an_actor = %{user_id: user.id, scope: :platform}
      refused!(:get, [not_an_actor, user.id])
      refused!(:get_by_namespace, [not_an_actor, "alice"])
      refused!(:list, [not_an_actor, []])
      refused!(:get, [user.id, user.id])
      refused!(:list, [user.id, []])
      refute_received :queried
    end
  end

  describe "mint/3 is one transaction" do
    # An installation that holds a person already: the mints below are
    # open admissions, which the first person never is.
    setup do
      %{first: person!()}
    end

    test "the person and their admission land together" do
      user = user_attrs()

      assert {:ok, %{id: id, admission: "open"}} = Users.mint(server(), user, admission: "open")
      assert {:ok, %{id: ^id, admission: "open"}} = Users.get(server(), id)
    end

    test "the admission is required, one of the five, and never rewritten" do
      user = user_attrs()

      assert_raise KeyError, fn -> Users.mint(server(), user, []) end

      assert {:error, {:invalid, %{admission: _}}} =
               Users.mint(server(), user, admission: "github")

      assert {:error, :not_found} = Users.get(server(), user.id)

      {:ok, %{id: id}} = Users.mint(server(), user, admission: "remote")

      assert {:error, {:invalid, %{admission: _}}} =
               Users.update(server(), id, %{admission: "setup"})
    end

    test "a second mint of the same id is a conflict and writes nothing" do
      user = user_attrs()
      {:ok, %{id: id}} = Users.mint(server(), user, admission: "open")
      people = Arca.Repo.aggregate(Arca.Schemas.User, :count)

      assert {:error, :conflict} = Users.mint(server(), user, admission: "open")
      assert {:ok, %{id: ^id}} = Users.get(server(), id)
      assert Arca.Repo.aggregate(Arca.Schemas.User, :count) == people
    end

    test "a row whose id is not a person's is refused" do
      now = DateTime.utc_now()

      assert {:error, {:invalid, %{id: [_ | _]}}} =
               Users.mint(
                 server(),
                 %{
                   id: "system",
                   first_seen_at: now,
                   last_seen_at: now,
                   created_at: now,
                   updated_at: now
                 },
                 admission: "open"
               )

      assert {:error, :not_found} = Users.get(server(), "system")
    end
  end

  describe "mint/3's also: closure" do
    setup do
      %{first: person!()}
    end

    test "runs inside the mint's transaction, after the person row is written" do
      user = user_attrs()
      me = self()

      also = fn person ->
        # The person row is already there for the closure to write beside.
        {:ok, _} = Users.update(server(), person.id, %{display_name: "Written beside"})
        send(me, {:also, person.id, Arca.Repo.in_transaction?()})
        :ok
      end

      assert {:ok, person} = Users.mint(server(), user, admission: "open", also: also)
      assert_received {:also, id, true}
      assert id == person.id
      assert {:ok, %{display_name: "Written beside"}} = Users.get(server(), person.id)
    end

    test "a failing closure writes no person row" do
      user = user_attrs()

      assert {:error, :keys_unavailable} =
               Users.mint(server(), user,
                 admission: "open",
                 also: fn _person -> {:error, :keys_unavailable} end
               )

      assert {:error, :not_found} = Users.get(server(), user.id)
    end

    test "a closure that answers anything else raises, and writes nothing" do
      user = user_attrs()

      assert_raise ArgumentError, fn ->
        Users.mint(server(), user, admission: "open", also: fn _person -> :nope end)
      end

      assert {:error, :not_found} = Users.get(server(), user.id)
    end
  end

  describe "mint/3's verify: closure" do
    setup do
      %{first: person!()}
    end

    test "runs inside the mint's transaction, before any row is written" do
      user = user_attrs()
      me = self()

      verify = fn ->
        send(me, {:verify, Users.get(server(), user.id), Arca.Repo.in_transaction?()})
        :ok
      end

      assert {:ok, %{id: id}} =
               Users.mint(server(), user, admission: "open", verify: verify)

      assert_received {:verify, {:error, :not_found}, true}
      assert id == user.id
    end

    test "a refusing check is the mint's answer: no row is inserted and the also: never runs" do
      user = user_attrs()
      me = self()
      handler = "users-verify-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measure, meta, _config ->
          if self() == me and meta[:source] == "users" and
               String.starts_with?(meta[:query] || "", "INSERT"),
             do: send(me, :person_inserted)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, {:limit_reached, :max_athanors, 1}} =
               Users.mint(server(), user,
                 admission: "open",
                 verify: fn -> {:error, {:limit_reached, :max_athanors, 1}} end,
                 also: fn _person ->
                   send(me, :also_ran)
                   :ok
                 end
               )

      refute_received :person_inserted
      refute_received :also_ran
      assert {:error, :not_found} = Users.get(server(), user.id)
    end
  end

  describe "the reads and writes" do
    test "a person is found by id and namespace" do
      user = person!()
      id = user.id

      assert {:ok, %{id: ^id}} = Users.get(server(), id)
      assert {:error, :not_found} = Users.get_by_namespace(server(), "nobody-here")

      assert {:ok, updated} = Users.update(server(), user.id, %{namespace: "ns-#{id}"})
      assert {:ok, %{id: ^id}} = Users.get_by_namespace(server(), updated.namespace)
    end

    test "list/2 pages, newest first" do
      _a = person!()
      _b = person!()

      assert {:ok, [_one]} = Users.list(server(), limit: 1)
      assert {:ok, first} = Users.list(server(), limit: 1)
      assert {:ok, second} = Users.list(server(), limit: 1, offset: 1)
      refute first == second
    end

    test "list/2 in id order pages after the last id: whoever signs in between pages is read " <>
           "once, by a later page" do
      for _ <- 1..3, do: person!()
      {:ok, everyone} = Users.list(server(), order: :id)
      ids = Enum.map(everyone, & &1.id)
      assert ids == Enum.sort(ids)

      assert {:ok, first} = Users.list(server(), order: :id, limit: 2)
      assert Enum.map(first, & &1.id) == Enum.take(ids, 2)

      # A sign-in between the pages, minted after them: its time-ordered id
      # follows every id read so far, so the next page has it, and repeats
      # none.
      newcomer = person!(%{id: later_id(List.last(ids))})

      assert {:ok, rest} =
               Users.list(server(), order: :id, after: List.last(first).id, limit: 1_000)

      read = Enum.map(first ++ rest, & &1.id)
      assert read == Enum.uniq(read)
      assert Enum.sort(read) == Enum.sort([newcomer.id | ids])
      assert {:ok, []} = Users.list(server(), order: :id, after: List.last(read))
    end
  end
end
