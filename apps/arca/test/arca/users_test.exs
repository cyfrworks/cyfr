# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UsersTest do
  @moduledoc """
  The person rows and the IdP identities that name them. None of this is
  athanor-scoped — a person exists before any athanor does and sits in
  several at once — so every function is asked for with the platform
  scope and refuses an athanor-scoped actor.
  """
  use ExUnit.Case, async: true

  alias Arca.Users

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Cyfr.Actor.system()

  defp in_athanor(id), do: %{Cyfr.Actor.system() | athanor_id: id, scope: :athanor}

  defp person!(overrides \\ %{}) do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    user_attrs =
      Map.merge(
        %{
          id: Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix()),
          provider: "github",
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

    {:ok, user} =
      Users.mint(server(), user_attrs, %{
        key: "github|https://github.com|#{n}",
        provider: "github",
        issuer: "https://github.com",
        subject: "#{n}",
        first_seen_at: now,
        last_seen_at: now
      })

    user
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
      assert {:error, :cross_tenant} = Users.get_by_identity(member, "github|iss|sub")
      assert {:error, :cross_tenant} = Users.get_by_namespace(member, "alice")
      assert {:error, :cross_tenant} = Users.list_by_email(member, "a@example.com")
      assert {:error, :cross_tenant} = Users.list(member)
      assert {:error, :cross_tenant} = Users.identities(member, "usr_1")
      assert {:error, :cross_tenant} = Users.personal_athanor?(member, "ath_1")
      assert {:error, :cross_tenant} = Users.touch_identity(member, "k", DateTime.utc_now())
      assert {:error, :cross_tenant} = Users.update(member, row, %{display_name: "X"})
      assert {:error, :cross_tenant} = Users.mint(member, %{}, %{})
      refute_received :queried

      # The probe is live: the server's own actor does query.
      assert {:error, :not_found} = Users.get(server(), "usr_nobody")
      assert_received :queried
    end

    test "a plain map, or a bare person id, raises before any query" do
      watch_queries!()
      user = person!()
      drain_queries!()

      # A map carrying the actor's own fields is still not a `%Cyfr.Actor{}`:
      # every head matches the struct, so the shape is refused rather than
      # read for the scope it claims.
      not_an_actor = %{user_id: user.id, scope: :platform}
      refused!(:get, [not_an_actor, user.id])
      refused!(:get_by_identity, [not_an_actor, "github|iss|sub"])
      refused!(:list, [not_an_actor, []])
      refused!(:get, [user.id, user.id])
      refused!(:list, [user.id, []])
      refute_received :queried
    end
  end

  describe "mint/3 is one transaction" do
    test "the person and the identity that names them land together" do
      user = person!()

      assert {:ok, %{id: id}} = Users.get(server(), user.id)
      assert id == user.id
      assert {:ok, [identity]} = Users.identities(server(), user.id)
      assert identity.user_id == user.id
      assert {:ok, %{id: ^id}} = Users.get_by_identity(server(), identity.key)
    end

    test "an identity that cannot be written leaves no person behind" do
      now = DateTime.utc_now()
      id = Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix())

      assert {:error, {:invalid, %{subject: [_ | _]}}} =
               Users.mint(
                 server(),
                 %{
                   id: id,
                   provider: "github",
                   first_seen_at: now,
                   last_seen_at: now,
                   created_at: now,
                   updated_at: now
                 },
                 %{
                   key: "github|https://github.com|orphan",
                   provider: "github",
                   issuer: "https://github.com",
                   subject: nil,
                   first_seen_at: now,
                   last_seen_at: now
                 }
               )

      assert {:error, :not_found} = Users.get(server(), id)
    end

    test "a second mint of the same identity reads the person the first one wrote" do
      user = person!()
      {:ok, [identity]} = Users.identities(server(), user.id)
      now = DateTime.utc_now()

      assert {:ok, %{id: same}} =
               Users.mint(
                 server(),
                 %{
                   id: Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix()),
                   provider: "github",
                   first_seen_at: now,
                   last_seen_at: now,
                   created_at: now,
                   updated_at: now
                 },
                 %{
                   key: identity.key,
                   provider: "github",
                   issuer: "https://github.com",
                   subject: identity.subject,
                   first_seen_at: now,
                   last_seen_at: now
                 }
               )

      assert same == user.id
      assert {:ok, [_one]} = Users.identities(server(), user.id)
    end

    test "a row whose id is not a person's is refused" do
      now = DateTime.utc_now()

      assert {:error, {:invalid, %{id: [_ | _]}}} =
               Users.mint(
                 server(),
                 %{
                   id: "system",
                   provider: "github",
                   first_seen_at: now,
                   last_seen_at: now,
                   created_at: now,
                   updated_at: now
                 },
                 %{
                   key: "github|https://github.com|sys",
                   provider: "github",
                   issuer: "https://github.com",
                   subject: "sys",
                   first_seen_at: now,
                   last_seen_at: now
                 }
               )

      assert {:error, :not_found} = Users.get(server(), "system")
    end
  end

  describe "the reads and writes" do
    test "a person is found by id, identity, address and namespace" do
      user = person!()
      {:ok, [identity]} = Users.identities(server(), user.id)

      assert {:ok, %{id: id}} = Users.get_by_identity(server(), identity.key)
      assert id == user.id
      assert {:ok, [%{id: ^id}]} = Users.list_by_email(server(), user.email)
      assert {:error, :not_found} = Users.get_by_identity(server(), "github|iss|nobody")
      assert {:error, :not_found} = Users.get_by_namespace(server(), "nobody-here")

      assert {:ok, updated} = Users.update(server(), user, %{namespace: "ns-#{id}"})
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

    test "personal_athanor? answers whether any row names the athanor as its own" do
      user = person!()
      assert {:ok, false} = Users.personal_athanor?(server(), "ath_unclaimed")
      {:ok, _} = Users.update(server(), user, %{personal_athanor_id: "ath_claimed"})
      assert {:ok, true} = Users.personal_athanor?(server(), "ath_claimed")
    end

    test "touch_identity stamps the sighting without touching the person" do
      user = person!()
      {:ok, [identity]} = Users.identities(server(), user.id)
      later = DateTime.add(DateTime.utc_now(), 60)

      assert :ok = Users.touch_identity(server(), identity.key, later)
      assert {:ok, [touched]} = Users.identities(server(), user.id)
      assert DateTime.compare(touched.last_seen_at, identity.last_seen_at) == :gt
      assert {:ok, %{last_seen_at: unchanged}} = Users.get(server(), user.id)
      assert DateTime.compare(unchanged, user.last_seen_at) == :eq
    end
  end
end
