# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CredentialRetirementTest do
  @moduledoc """
  Retirement is permanent, and an issuance answers to the standing its
  context read.

  A denial, an archive or a membership removal retires what it retires in
  one transaction and announces only what that transaction committed; an
  allow or a reopen restores standing and nothing it retired. A context
  read before a retirement — a signed-in identity, a session, a key —
  carries the generations it read (`Sanctum.Context.credential_binding`),
  and issuing a session or a key from it after the restore is refused,
  because the issuance locks and rereads the rows it rests on.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.{ApiKey, Caller, Context, Session}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp person!(label) do
    n = uniq()

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|#{label}-#{n}",
        provider: "github",
        email: "#{label}#{n}@example.com",
        verified: true
      })

    user
  end

  # A person with their own estate and a seat in it, as sign-in leaves them.
  defp owner!(label) do
    user = person!(label)
    n = uniq()

    {:ok, own} =
      Athanors.create(%{
        kind: "person",
        name: "Own #{n}",
        slug: "own-#{label}-#{n}",
        owner_user_id: user.id,
        created_by: user.id
      })

    {:ok, user} = Users.set_personal_athanor(user, own.id)
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: own.id, added_by: "system")
    {user, own}
  end

  # What an admitted sign-in carries into session creation: the context the
  # door admitted, resolved and bound by `Sanctum.Tenancy.resolve_status/2`.
  defp admitted!(user) do
    {:ok, ctx} =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        permissions: Context.person_permissions(),
        auth_method: :oidc,
        authenticated: true
      )
      |> Sanctum.Tenancy.resolve_status(force: true)

    ctx
  end

  # A session signed in and established, as a console request holds it.
  defp signed_in!(user) do
    {:ok, session} = Session.create(admitted!(user))
    {:ok, ctx} = Caller.establish(session.token)
    {session, ctx}
  end

  describe "the binding a context carries" do
    test "a sign-in, a session and a key are each bound to what issued them" do
      {user, own} = owner!("bound")
      identity = admitted!(user)

      assert %{
               source_kind: :identity,
               source_id: nil,
               user_generation: 1,
               athanor_generation: 1
             } = identity.credential_binding

      assert identity.athanor_id == own.id
      assert {:ok, seat} = Members.active_seat(user.id, own.id)
      assert identity.credential_binding.focus_basis == seat.id

      {session, ctx} = signed_in!(user)
      hash = Session.token_hash(session.token)
      assert ctx.session_token_hash == hash
      assert ctx.credential_binding.source_kind == :session
      assert ctx.credential_binding.source_id == Base.url_encode64(hash, padding: false)
      assert ctx.credential_binding.focus_basis == seat.id

      {:ok, %{api_key: key}} = ApiKey.create(ctx, %{name: "bound-#{uniq()}"})
      {:ok, key_ctx} = Caller.establish({:api_key, key})
      assert key_ctx.credential_binding.source_kind == :api_key
      assert key_ctx.credential_binding.source_id == key_ctx.api_key_id
      assert key_ctx.credential_binding.focus_basis == :key
    end

    test "an issuing context without generations is refused, and so is a key with no person" do
      user = person!("unbound")

      bare =
        Context.build(
          user_id: user.id,
          provider: "github",
          permissions: [:*],
          athanor_id: Sanctum.TestContext.athanor_id(),
          auth_method: :oidc,
          authenticated: true
        )

      assert {:error, :missing_generation} = Session.create(bare)
      assert {:error, :missing_generation} = ApiKey.create(bare, %{name: "unbound"})

      # A person focused on an estate through no membership has no standing
      # to issue there, whatever generations the binding names; unfocused,
      # the same binding issues.
      Sanctum.TestContext.athanor!()
      {:ok, snapshot} = Sanctum.Tenancy.generation_snapshot(user.id, bare.athanor_id)

      unbacked = %{
        bare
        | credential_binding: %{
            source_kind: :identity,
            source_id: nil,
            focus_basis: nil,
            user_generation: snapshot.user_generation,
            athanor_generation: snapshot.athanor_generation
          }
      }

      assert {:error, :missing_generation} = Session.create(unbacked)
      assert {:error, :missing_generation} = ApiKey.create(unbacked, %{name: "unbacked"})

      assert {:ok, _} =
               Session.create(%{
                 unbacked
                 | athanor_id: nil,
                   credential_binding: %{unbacked.credential_binding | athanor_generation: nil}
               })

      # A snapshot of another person proves nothing about this context.
      other = person!("other")
      {:ok, snapshot} = Sanctum.Tenancy.generation_snapshot(other.id, nil)

      assert {:error, :missing_generation} =
               Session.create(%{bare | athanor_id: nil}, generation_snapshot: snapshot)

      # A key the server's own principal created stands as a key and can
      # issue nothing.
      Sanctum.TestContext.athanor!()

      system_key =
        Context.build(
          user_id: "system",
          athanor_id: Sanctum.TestContext.athanor_id(),
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, snapshot} = Sanctum.Tenancy.generation_snapshot(user.id, "ath_test")

      {:ok, %{api_key: raw}} =
        ApiKey.create(%{system_key | user_id: user.id}, %{name: "orphan-#{uniq()}"},
          generation_snapshot: snapshot
        )

      {1, _} =
        Arca.Repo.update_all(
          from(k in Arca.Schemas.ApiKey, where: k.created_by == ^user.id),
          set: [created_by: "system"]
        )

      {:ok, orphan_ctx} = Caller.establish({:api_key, raw})
      assert orphan_ctx.credential_binding == nil
      assert {:error, :missing_generation} = ApiKey.create(orphan_ctx, %{name: "from-orphan"})
    end
  end

  describe "a context read before a retirement" do
    test "a sign-in admitted before a denial cannot mint a session after the allow" do
      {user, _own} = owner!("pre-deny")
      identity = admitted!(user)

      {:ok, denied} = Users.deny(user)
      {:ok, _} = Users.allow(denied)

      assert {:error, :stale_generation} = Session.create(identity)

      # A sign-in after the allow reads the new generation and is admitted.
      assert {:ok, _} = Session.create(admitted!(user))
    end

    test "a session context established before a denial cannot issue a key after the allow" do
      {user, _own} = owner!("pre-deny-key")
      {session, ctx} = signed_in!(user)

      {:ok, denied} = Users.deny(user)
      {:ok, _} = Users.allow(denied)

      assert {:error, reason} = ApiKey.create(ctx, %{name: "late-#{uniq()}"})
      assert reason in [:stale_generation, :not_standing]

      # And the session itself stays retired: the allow restores no
      # credential, and signing in again mints a different one.
      assert {:error, _} = Session.load(session.token, surface: :console)
      {fresh, _ctx} = signed_in!(user)
      refute fresh.token == session.token
    end

    test "a context read before an archive cannot issue in the estate after the reopen" do
      {user, _own} = owner!("pre-archive")
      {:ok, group} = Athanors.create_group(user.id, "Pre-archive #{uniq()}")
      {_session, ctx} = signed_in!(user)
      {:ok, ctx} = Context.focus(ctx, group.id)
      {:ok, %{api_key: key}} = ApiKey.create(ctx, %{name: "in-group-#{uniq()}"})

      {:ok, archived} = Athanors.archive(group)
      assert archived.security_generation == 2
      {:ok, reopened} = Athanors.unarchive(archived)
      assert reopened.security_generation == 3

      assert {:error, :stale_generation} = ApiKey.create(ctx, %{name: "late-#{uniq()}"})
      assert {:error, :revoked} = ApiKey.validate(key, [])

      # Focusing again is a new standing read, and issues; the context read
      # before the archive still cannot rotate what the new one minted.
      {:ok, refocused} = Context.focus(ctx, group.id)
      fresh = "fresh-#{uniq()}"
      assert {:ok, _} = ApiKey.create(refocused, %{name: fresh})
      assert {:error, :stale_generation} = ApiKey.rotate(ctx, fresh)
      assert {:ok, _} = ApiKey.rotate(refocused, fresh)
    end

    test "a context whose seat was removed cannot issue in that estate" do
      {user, _own} = owner!("seatless")
      other = person!("stays")
      {:ok, group} = Athanors.create_group(user.id, "Seat #{uniq()}")
      {:ok, :added} = Members.add(group, [user_id: other.id], user.id)
      {_session, ctx} = signed_in!(user)
      {:ok, ctx} = Context.focus(ctx, group.id)

      :ok = Members.remove_member(group, user_id: user.id)
      assert {:error, :not_standing} = ApiKey.create(ctx, %{name: "gone-#{uniq()}"})

      # Rejoining is a new row: the old focus is not restored by it.
      {:ok, :added} = Members.add(group, [user_id: user.id], other.id)
      assert {:error, :not_standing} = ApiKey.create(ctx, %{name: "rejoined-#{uniq()}"})
    end
  end

  describe "deny/1 and allow/1" do
    test "announce exactly what the denial committed" do
      {user, own} = owner!("announce")
      {session, _ctx} = signed_in!(user)
      hash = Session.token_hash(session.token)
      Cyfr.Bus.subscribe_global(Cyfr.Bus.sessions())

      handler =
        attach([[:cyfr, :sanctum, :caller, :invalidated], [:cyfr, :sanctum, :athanor, :archived]])

      assert {:ok, denied} = Users.deny(user)
      assert denied.status == "denied"
      assert denied.security_generation == 2
      assert denied.denied_at

      assert_receive %Cyfr.Bus.Session{kind: :revoked, user_id: uid}
      assert uid == user.id
      assert_receive {:telemetry, [:cyfr, :sanctum, :caller, :invalidated], %{hash: ^hash}}
      assert_receive {:telemetry, [:cyfr, :sanctum, :athanor, :archived], %{athanor_id: own_id}}
      assert own_id == own.id
      :telemetry.detach(handler)
    end

    test "a failed denial announces nothing and leaves the person's credentials standing" do
      {user, own} = owner!("silent")
      {session, _ctx} = signed_in!(user)
      Cyfr.Bus.subscribe_global(Cyfr.Bus.sessions())

      handler =
        attach([[:cyfr, :sanctum, :caller, :invalidated], [:cyfr, :sanctum, :athanor, :archived]])

      failure = fail_session_delete!()

      assert {:error, :database_error} = Users.deny(user)

      refute_receive %Cyfr.Bus.Session{kind: :revoked}, 100
      refute_receive {:telemetry, _, _}, 100
      assert {:ok, %{status: "active"}} = Users.get(user.id)
      assert {:ok, %{status: "active"}} = Athanors.get(own.id)
      assert {:ok, _} = Session.load(session.token, surface: :console)

      clear!(failure)
      :telemetry.detach(handler)
    end

    test "a repeated denial answers the denied person and moves no generation" do
      {user, _own} = owner!("twice")
      {:ok, denied} = Users.deny(user)
      assert {:ok, again} = Users.deny(denied)
      assert again.status == "denied"
      assert again.security_generation == 2
    end

    test "a restore past the server's cap leaves the person denied" do
      {user, own} = owner!("capped")
      {:ok, denied} = Users.deny(user)
      {:ok, count} = Athanors.count()
      original = Application.get_env(:sanctum, :caps, [])
      Application.put_env(:sanctum, :caps, Keyword.put(original, :max_athanors, count))
      on_exit(fn -> Application.put_env(:sanctum, :caps, original) end)

      assert {:error, {:limit_reached, :max_athanors, ^count}} = Users.allow(denied)
      assert {:ok, %{status: "denied", security_generation: 2}} = Users.get(user.id)
      assert {:ok, %{status: "archived"}} = Athanors.get(own.id)
    end

    test "a frozen estate ended by a denial stays ended" do
      {user, _own} = owner!("frozen")
      other = person!("partner")
      {:ok, pair} = Athanors.create_pair(user.id, other.id)

      {:ok, denied} = Users.deny(user)
      assert {:ok, %{status: "archived"}} = Athanors.get(pair.id)
      {:ok, _} = Users.allow(denied)

      assert {:ok, %{status: "archived"}} = Athanors.get(pair.id)
      assert {:error, :frozen_is_final} = Athanors.unarchive(pair)
      refute Members.member?(user.id, pair.id)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp attach(events) do
    handler = "retirement-#{uniq()}"
    test = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, _measure, meta, _ -> send(test, {:telemetry, event, meta}) end,
      nil
    )

    handler
  end

  defp fail_session_delete! do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!(
          "CREATE TRIGGER retire_fail BEFORE DELETE ON sessions " <>
            "BEGIN SELECT RAISE(ABORT, 'injected'); END"
        )

      _postgres ->
        Arca.Repo.query!(
          "CREATE FUNCTION retire_fail() RETURNS trigger LANGUAGE plpgsql AS " <>
            "$$ BEGIN RAISE EXCEPTION 'injected'; END $$"
        )

        Arca.Repo.query!(
          "CREATE TRIGGER retire_fail BEFORE DELETE ON sessions " <>
            "FOR EACH ROW EXECUTE FUNCTION retire_fail()"
        )
    end

    :retire_fail
  end

  defp clear!(:retire_fail) do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!("DROP TRIGGER retire_fail")

      _postgres ->
        Arca.Repo.query!("DROP TRIGGER retire_fail ON sessions")
        Arca.Repo.query!("DROP FUNCTION retire_fail()")
    end
  end
end

defmodule Sanctum.CredentialRetirementLockTest do
  @moduledoc """
  An issuance from a context read before a denial, and the denial, on two
  real connections outside the sandbox: the issuance that waits behind
  the denial reads what it committed and refuses.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.{Context, Session}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)
  defp uniq, do: System.unique_integer([:positive])

  test "a session minted from a context read before the denial is refused after it" do
    {user, own, identity} =
      unboxed(fn ->
        n = uniq()

        {:ok, user} =
          Users.upsert_from_provider(%{
            id: "github|https://github.com|race-#{n}",
            provider: "github",
            email: "race#{n}@example.com",
            verified: true
          })

        {:ok, own} =
          Athanors.create(%{
            kind: "person",
            name: "Race #{n}",
            slug: "race-#{n}",
            owner_user_id: user.id,
            created_by: user.id
          })

        {:ok, user} = Users.set_personal_athanor(user, own.id)
        {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: own.id)

        {:ok, identity} =
          Context.build(
            user_id: user.id,
            email: user.email,
            provider: "github",
            permissions: Context.person_permissions(),
            auth_method: :oidc,
            authenticated: true
          )
          |> Sanctum.Tenancy.resolve_status(force: true)

        {user, own, identity}
      end)

    on_exit(fn -> unboxed(fn -> cleanup!(user.id, own.id) end) end)
    test = self()

    denier =
      Task.async(fn ->
        unboxed(fn ->
          Arca.SecurityTransitions.deny_user(Prima.Actor.system(), user.id,
            verify: fn _rows ->
              send(test, :denial_holds)

              receive do
                :go -> :ok
              end
            end
          )
        end)
      end)

    assert_receive :denial_holds, 5_000
    issuer = Task.async(fn -> unboxed(fn -> Session.create(identity) end) end)
    refute Task.yield(issuer, 300), "the session was decided while the denial held the person"

    send(denier.pid, :go)
    assert {:ok, _} = Task.await(denier, 25_000)
    assert {:error, :not_standing} = Task.await(issuer, 25_000)

    refute unboxed(fn -> Arca.Repo.exists?(where(Arca.Schemas.Session, user_id: ^user.id)) end)
  end

  defp cleanup!(user_id, athanor_id) do
    Arca.Repo.delete_all(where(Arca.Schemas.Membership, user_id: ^user_id))
    Arca.Repo.delete_all(where(Arca.Schemas.Membership, athanor_id: ^athanor_id))
    Arca.Repo.delete_all(where(Arca.Schemas.Session, user_id: ^user_id))
    Arca.Repo.delete_all(where(Arca.Schemas.ApiKey, created_by: ^user_id))
    Arca.Repo.delete_all(where(Arca.Schemas.ExternalIdentity, user_id: ^user_id))
    Arca.Repo.delete_all(where(Arca.Schemas.User, id: ^user_id))
    Arca.Repo.delete_all(where(Arca.Schemas.Athanor, id: ^athanor_id))
  end
end
