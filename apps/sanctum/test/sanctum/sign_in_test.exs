# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignInTest do
  use ExUnit.Case, async: false

  alias Sanctum.SignIn
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp info(n, overrides \\ %{}) do
    Map.merge(
      %{
        id: "github|https://github.com|#{n}",
        provider: :github,
        email: "user#{n}@example.com",
        verified: true,
        name: "User #{n}"
      },
      overrides
    )
  end

  test "an admitted person gets a users row, refreshed on every sign-in" do
    i = info(1)
    assert {:ok, user} = SignIn.admitted(i, :allowed)
    # The person's id is this server's; the identity that signed in names it.
    assert Arca.Schemas.User.person_id?(user.id)
    assert {:ok, %{id: same}} = Users.get_by_identity(i.id)
    assert same == user.id
    assert user.email == "user1@example.com"
    assert user.display_name == "User 1"
    assert user.email_verified
    first = user.first_seen_at

    assert {:ok, again} = SignIn.admitted(%{i | name: "Renamed"}, :allowed)
    assert again.id == user.id
    assert again.first_seen_at == first
    assert again.display_name == "Renamed"
    assert DateTime.compare(again.last_seen_at, first) in [:gt, :eq]
  end

  test "an operator gets the platform row, minted once and audited once" do
    handler = "signin-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
      fn _e, _m, meta, _c -> send(parent, {:bootstrap, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    i = info(2)
    assert {:ok, user} = SignIn.admitted(i, :admin)
    assert_receive {:bootstrap, %{user_id: uid}}
    assert uid == user.id

    rows = rows!(Members.list_by_user(user.id))
    assert Enum.any?(rows, &(&1.scope == "platform"))

    assert {:ok, _} = SignIn.admitted(i, :admin)
    refute_receive {:bootstrap, _}
    # the platform row and the seat in their own athanor, and nothing else:
    # no estate is shared server-wide for an operator to be seated in
    assert length(rows!(Members.list_by_user(user.id))) == 2
  end

  test "an email dropped from the operator list loses the platform row on the next sign-in" do
    i = info(3)
    assert {:ok, user} = SignIn.admitted(i, :admin)
    assert Enum.any?(rows!(Members.list_by_user(user.id)), &(&1.scope == "platform"))

    assert {:ok, _} = SignIn.admitted(i, :allowed)
    refute Enum.any?(rows!(Members.list_by_user(user.id)), &(&1.scope == "platform"))
    # their own athanor is theirs whatever the operator list says
    assert Enum.any?(rows!(Members.list_by_user(user.id)), &(&1.scope == "athanor"))
  end

  test "invited rows for the person's verified email activate on first sign-in" do
    {:ok, group} = Athanors.create_group("github|https://github.com|creator", "Home Team")
    {:ok, :invited} = Members.add(group, [email: "User4@Example.com"], "creator")

    assert [%{status: "invited", email: "user4@example.com"}] =
             Enum.filter(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))

    i = info(4)
    assert {:ok, user} = SignIn.admitted(i, :allowed)

    assert Members.member?(user.id, group.id)
    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
  end

  test "only a proved address claims its invitations; the seat waits for the rest" do
    # Admission and seating are different questions. The door may let an
    # identity in on an unasserted address (`*`, or a `user_id` entry), but an
    # invited row is keyed on the email alone, so seating it needs the address
    # proved — otherwise an issuer asserting someone else's address inherits
    # their groups. The seat is held, not withdrawn.
    for {n, claim} <- [{5, :unknown}, {9, false}] do
      {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Team #{n}")
      {:ok, :invited} = Members.add(group, [email: "user#{n}@example.com"], "creator2")

      assert {:ok, user} = SignIn.admitted(info(n, %{verified: claim}), :allowed)

      refute Members.member?(user.id, group.id)
      assert Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
    end

    {:ok, group} = Athanors.create_group("github|https://github.com|creator2", "Proved Team")
    {:ok, :invited} = Members.add(group, [email: "user11@example.com"], "creator2")

    assert {:ok, %{email_verified: true}} =
             SignIn.admitted(info(11, %{verified: true}), :allowed)

    assert {:ok, %{id: proved}} = Users.get_by_identity(info(11).id)
    assert Members.member?(proved, group.id)
    refute Enum.any?(rows!(Members.list_by_athanor(group.id)), &(&1.status == "invited"))
  end

  test "record_namespace/2 lands the claim on the users row and refuses a slug another identity holds" do
    i = info(6)
    assert {:ok, %{id: uid, personal_athanor_id: pid}} = SignIn.admitted(i, :allowed)

    assert {:ok, user} = SignIn.record_namespace(uid, "user6ns")
    assert user.namespace == "user6ns"
    assert {:ok, %{id: id}} = Users.get_by_namespace("user6ns")
    assert id == uid
    # the athanor was theirs since admission; the claim does not re-address it
    assert {:ok, %{personal_athanor_id: ^pid}} = Users.get(uid)
    assert {:ok, %{kind: "person"}} = Athanors.get(pid)
    assert Sanctum.Namespace.lookup(uid) == "user6ns"

    # Idempotent; a different slug from the registry keeps the recorded one.
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(uid, "user6ns")
    assert {:ok, %{namespace: "user6ns"}} = SignIn.record_namespace(uid, "user6other")

    # Another person cannot take it, and a malformed slug is refused.
    j = info(7)
    assert {:ok, %{id: jid}} = SignIn.admitted(j, :allowed)

    assert {:error, :namespace_owned_by_another_identity} =
             SignIn.record_namespace(jid, "user6ns")

    assert {:error, :invalid_slug} = SignIn.record_namespace(jid, "Not A Slug")

    assert {:error, :not_found} = SignIn.record_namespace("usr_ghost", "ghost")
  end

  test "`*` on the door admits a stranger who then gets their own athanor — no platform bit, no group" do
    n = System.unique_integer([:positive])
    i = info(n, %{email: "stranger#{n}@example.com"})
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")

    assert {:ok, verdict} = Sanctum.Door.admit(i.id, i.email, true)
    assert verdict == :allowed

    assert {:ok, %{id: uid, personal_athanor_id: pid}} = SignIn.admitted(i, verdict)
    assert {:ok, user} = SignIn.record_namespace(uid, "stranger#{n}")

    assert {:ok, %{kind: "person", owner_user_id: owner}} = Athanors.get(pid)
    assert owner == user.id

    rows = rows!(Members.list_by_user(user.id))
    refute Enum.any?(rows, &(&1.scope == "platform"))
    assert Enum.map(Athanors.list_for_user(user.id), & &1.kind) == ["person"]
  end

  describe "the identity facts a sign-in grants or revokes on" do
    test "are this assertion's: its lowercased email, or the stored one when it carried none" do
      row = %Arca.Schemas.User{email: "stored@example.com", email_verified: true}

      assert %{email: "mixed@example.com", email_verified: true} =
               SignIn.expected_identity(%{email: "Mixed@Example.com", verified: true}, row)

      for absent <- [nil, ""] do
        assert %{email: "stored@example.com"} =
                 SignIn.expected_identity(%{email: absent, verified: true}, row)
      end

      # A concurrent first sign-in that lost the mint is answered the
      # winner's row; the winner's address never becomes the loser's.
      assert %{email: "loser@example.com"} =
               SignIn.expected_identity(%{email: "loser@example.com"}, row)

      for {claim, stored} <- [{true, true}, {false, false}, {:unknown, nil}, {nil, nil}] do
        assert %{email_verified: ^stored} =
                 SignIn.expected_identity(%{email: "a@example.com", verified: claim}, row)
      end
    end

    test "an earlier operator assertion overtaken by a later one grants nothing" do
      n = System.unique_integer([:positive])
      ops = info(n, %{email: "ops#{n}@example.com"})
      assert {:ok, user} = SignIn.identify(ops, :admin)
      asserted = SignIn.expected_identity(ops, user)

      # A later assertion for the same identity carries another address, and
      # the door no longer calls it an operator.
      later = %{ops | email: "someone#{n}@example.com"}
      assert {:ok, _} = SignIn.identify(later, :allowed)
      refute platform?(user.id)

      # The earlier sign-in's delayed grant lands on facts that are gone.
      assert {:error, :stale_identity} = Members.grant_platform(user.id, asserted)
      refute platform?(user.id)
    end

    test "an earlier non-operator assertion overtaken by an operator one revokes nothing" do
      n = System.unique_integer([:positive])
      plain = info(n, %{email: "plain#{n}@example.com"})
      assert {:ok, user} = SignIn.identify(plain, :allowed)
      asserted = SignIn.expected_identity(plain, user)

      assert {:ok, _} = SignIn.identify(%{plain | email: "ops#{n}@example.com"}, :admin)
      assert platform?(user.id)

      assert {:error, :stale_identity} =
               Members.revoke_platform(user.id, expected_identity: asserted)

      assert platform?(user.id)
    end

    test "an unchanged delayed verdict still lands" do
      n = System.unique_integer([:positive])
      ops = info(n)
      assert {:ok, user} = Users.upsert_from_provider(ops)
      asserted = SignIn.expected_identity(ops, user)

      # The same facts asserted again in between: the delayed grant stands.
      assert {:ok, _} = Users.upsert_from_provider(%{ops | name: "Renamed"})
      assert {:ok, :granted} = Members.grant_platform(user.id, asserted)
      assert {:ok, :held} = Members.grant_platform(user.id, asserted)
    end

    test "a grant that fails refuses the sign-in before anything after it" do
      n = System.unique_integer([:positive])

      # An explicitly unverified address is never granted, whatever verdict
      # the caller hands over.
      assert {:error, :stale_identity} = SignIn.admitted(info(n, %{verified: false}), :admin)

      assert {:ok, user} = Users.get_by_identity(info(n).id)
      refute platform?(user.id)
      assert user.personal_athanor_id == nil, "the sign-in went on past a refused grant"
    end
  end

  describe "concurrent sign-ins, on connections of their own" do
    setup do
      # These race on real connections: the shared sandbox connection would
      # serialize the very interleavings under test.
      Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)
      :ok
    end

    test "differing first sign-ins of one identity leave a grant only on the operator's facts" do
      for order <- [[:admin, :allowed], [:allowed, :admin]], _round <- 1..3 do
        n = System.unique_integer([:positive])
        ops = info(n, %{email: "ops#{n}@example.com"})
        plain = %{ops | email: "plain#{n}@example.com"}
        assertion = %{admin: ops, allowed: plain}

        results =
          order
          |> Enum.map(fn verdict ->
            Task.async(fn -> {verdict, unboxed(fn -> SignIn.identify(assertion[verdict], verdict) end)} end)
          end)
          |> Enum.map(&Task.await(&1, 25_000))

        {:ok, user} = unboxed(fn -> Users.get_by_identity(ops.id) end)
        on_exit(fn -> purge!(user.id) end)

        # Whoever wrote last, the operator bit is on exactly when the row
        # carries the operator's address.
        assert unboxed(fn -> platform?(user.id) end) == (user.email == ops.email)

        # And no sign-in that went on did so on facts other than its own.
        for {verdict, {:ok, row}} <- results do
          assert row.email == assertion[verdict].email
        end

        for {_verdict, {:error, reason}} <- results, do: assert(reason == :stale_identity)
      end
    end

    test "concurrent operator sign-ins write one grant and announce it once" do
      handler = "signin-race-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap],
        fn _e, _m, meta, _c -> send(parent, {:bootstrap, meta.user_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      n = System.unique_integer([:positive])
      ops = info(n)
      {:ok, user} = unboxed(fn -> Users.upsert_from_provider(ops) end)
      on_exit(fn -> purge!(user.id) end)

      # Two racers, as `Arca.MembersLockTest` explains: more SQLite waiters
      # than a partition's dirty I/O schedulers starve the lock's holder.
      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> unboxed(fn -> SignIn.identify(ops, :admin) end) end) end)
        |> Enum.map(&Task.await(&1, 25_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert_receive {:bootstrap, uid}
      assert uid == user.id
      refute_receive {:bootstrap, _}, 200

      assert 1 ==
               unboxed(fn ->
                 {:ok, rows} = Members.list_by_user(user.id)
                 Enum.count(rows, &(&1.scope == "platform"))
               end)
    end
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

  defp purge!(user_id) do
    import Ecto.Query

    unboxed(fn ->
      Arca.Repo.delete_all(from(m in Arca.Schemas.Membership, where: m.user_id == ^user_id))
      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.user_id == ^user_id))

      Arca.Repo.delete_all(
        from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user_id)
      )

      Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user_id))
    end)
  end

  defp platform?(user_id) do
    {:ok, rows} = Members.list_by_user(user_id)
    Enum.any?(rows, &(&1.scope == "platform"))
  end

  defp rows!({:ok, rows}), do: rows
end
