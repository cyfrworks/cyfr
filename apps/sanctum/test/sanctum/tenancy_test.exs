# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyTest do
  # async: false — global :tenancy_resolver_override / :platform_admin_emails mutation.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.{Athanors, Members}

  defp group!(name) do
    {:ok, athanor} =
      Athanors.create(%{
        kind: "group",
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    athanor
  end

  describe "resolve_status/2 — override seam" do
    setup do
      original = Application.get_env(:sanctum, :tenancy_resolver_override)

      on_exit(fn ->
        if original,
          do: Application.put_env(:sanctum, :tenancy_resolver_override, original),
          else: Application.delete_env(:sanctum, :tenancy_resolver_override)
      end)

      :ok
    end

    test "is a no-op when ctx already carries an athanor_id" do
      ctx = %Context{user_id: "u1", athanor_id: "ath_acme"}
      assert Tenancy.resolve_status(ctx) == {:ok, ctx}
    end

    test "merges resolver result when ctx has no athanor_id" do
      Application.put_env(:sanctum, :tenancy_resolver_override, Sanctum.Test.OtherAthanorResolver)

      ctx = %Context{user_id: "u1", athanor_id: nil}
      {:ok, result} = Tenancy.resolve_status(ctx)
      assert result.athanor_id == "ath_other"
      assert result.scope == :athanor
    end

    test "logs and refuses as unavailable when the override resolver errors" do
      Application.put_env(:sanctum, :tenancy_resolver_override, Sanctum.Test.FailingResolver)

      ctx = %Context{user_id: "u1", athanor_id: nil}

      log =
        capture_log(fn ->
          assert Tenancy.resolve_status(ctx) == {:error, :unavailable}
        end)

      assert log =~ "[Sanctum.Tenancy] resolve override failed"
      assert log =~ "resolve_failed"
    end
  end

  describe "resolve_status/2 — membership resolution" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)

      orig_admins = Application.get_env(:sanctum, :platform_admin_emails)
      orig_override = Application.get_env(:sanctum, :tenancy_resolver_override)
      # Membership resolution must run, not the override seam.
      Application.delete_env(:sanctum, :tenancy_resolver_override)

      on_exit(fn ->
        restore(:platform_admin_emails, orig_admins)
        restore(:tenancy_resolver_override, orig_override)
      end)

      :ok
    end

    test "no membership leaves athanor_id unresolved" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", athanor_id: nil}
      assert {:ok, %{athanor_id: nil}} = Tenancy.resolve_status(ctx, force: true)
    end

    test "an athanor membership resolves scope and athanor" do
      uid = "u-ath-#{System.unique_integer([:positive])}"
      athanor = group!("home-a")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      {:ok, result} = Tenancy.resolve_status(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.athanor_id == athanor.id
    end

    test "a platform admin keeps :athanor scope with the capability; works in the first athanor" do
      uid = "u-multi-#{System.unique_integer([:positive])}"
      athanor = group!("home-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})
      {:ok, _} = Members.ensure(uid, scope: "platform")

      {:ok, result} = Tenancy.resolve_status(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.platform_admin
      assert result.athanor_id == athanor.id
    end

    test "a platform admin with no athanor membership has no athanor to work in" do
      # No athanor is shared server-wide, so the operator bit alone seats
      # nobody. What guarantees an operator an athanor is the one minted for
      # them at admission, past the server caps.
      uid = "u-plat-only-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      {:ok, result} = Tenancy.resolve_status(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.platform_admin
      assert result.athanor_id == nil
    end

    test "resolution never mints anything — the operator list is applied at sign-in only" do
      Application.put_env(:sanctum, :platform_admin_emails, ["admin@example.com"])
      uid = "u-admin-#{System.unique_integer([:positive])}"

      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin@example.com"}
      {:ok, result} = Tenancy.resolve_status(ctx, force: true)

      refute result.platform_admin
      assert rows!(Members.list_by_user(uid)) == []
    end

    test "an archived athanor is never chosen" do
      uid = "u-archived-#{System.unique_integer([:positive])}"
      a = group!("arch-a")
      b = group!("arch-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: a.id})
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: b.id})
      {:ok, _} = Athanors.archive(a)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: uid, athanor_id: a.id}, force: true)

      assert result.athanor_id == b.id
    end
  end

  describe "focus_basis/3" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "is the person's seat in the athanor, never their platform row" do
      uid = "u-basis-#{System.unique_integer([:positive])}"
      seated = group!("basis-seated")
      other = group!("basis-other")
      {:ok, seat} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: seated.id})
      {:ok, _} = Members.ensure(uid, scope: "platform")
      {:ok, memberships} = Members.list_by_user(uid)
      admin = %Context{user_id: uid, scope: :athanor, platform_admin: true}

      assert Tenancy.focus_basis(admin, seated, memberships) == seat.id
      assert Tenancy.focus_basis(admin, other, memberships) == nil
      assert Tenancy.focus_basis(admin, nil, memberships) == nil
    end
  end

  describe "platform_admin?/1" do
    test "requires an ACTIVE platform row, not merely a platform row" do
      # Platform-admin status requires an active platform membership.
      assert Tenancy.platform_admin?([%{scope: "platform", status: "active"}])
      refute Tenancy.platform_admin?([%{scope: "platform", status: "invited"}])
      refute Tenancy.platform_admin?([%{scope: "athanor", status: "active"}])
      refute Tenancy.platform_admin?([])
    end
  end

  describe "revalidate/1" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "keeps the capability and loses the athanor" do
      uid = "u-reval-keep-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      # The session names a group the operator holds no seat in: the
      # capability is over the instance, not a seat, so it keeps them in
      # no athanor.
      ctx = %Context{
        user_id: uid,
        athanor_id: group!("reval-keep").id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      {:ok, out} = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.scope == :athanor
      assert out.athanor_id == nil

      # With a seat elsewhere, they fall back to it like anyone else.
      seated = group!("reval-seated")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: seated.id})

      {:ok, out} = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.athanor_id == seated.id
    end

    test "drops the capability once the platform membership is revoked" do
      uid = "u-reval-revoke-#{System.unique_integer([:positive])}"
      {:ok, _} = Members.ensure(uid, scope: "platform")

      ctx = %Context{
        user_id: uid,
        athanor_id: group!("reval-revoke").id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      assert {:ok, %{platform_admin: true}} = Tenancy.revalidate(ctx)

      [_grant] = rows!(Members.list_by_user(uid))
      :ok = Members.revoke_platform(uid)

      # No memberships → no capability, no athanor; the tenant gate then
      # rejects tenant-scoped routes.
      {:ok, revalidated} = Tenancy.revalidate(ctx)
      refute revalidated.platform_admin
      assert revalidated.athanor_id == nil
    end

    test "a stale capability on the context does not survive revalidation" do
      uid = "u-reval-down-#{System.unique_integer([:positive])}"
      athanor = group!("home-c")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      ctx = %Context{
        user_id: uid,
        athanor_id: athanor.id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      {:ok, revalidated} = Tenancy.revalidate(ctx)
      refute revalidated.platform_admin
      assert revalidated.athanor_id == athanor.id
    end

    test "falls back to the broadest membership when the athanor is no longer granted" do
      uid = "u-reval-switch-#{System.unique_integer([:positive])}"
      athanor = group!("home-d")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      # Session points at an athanor the user is NOT a member of.
      ctx = %Context{user_id: uid, athanor_id: "ath_other", scope: :athanor, authenticated: true}

      {:ok, revalidated} = Tenancy.revalidate(ctx)
      assert revalidated.scope == :athanor
      assert revalidated.athanor_id == athanor.id
    end
  end

  describe "list_athanors/1" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "a member sees the athanors their memberships grant" do
      uid = "u-list-#{System.unique_integer([:positive])}"
      a = group!("list-a")
      b = group!("list-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: a.id})
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: b.id})

      ids = Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor}) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end

    test "a platform admin sees their own memberships only, not every athanor" do
      uid = "u-list-plat-#{System.unique_integer([:positive])}"
      _other = group!("list-other")
      {:ok, _} = Members.ensure(uid, scope: "platform")

      assert Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor, platform_admin: true}) ==
               []
    end

    test "a user with no membership sees no athanors" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", scope: :athanor}
      assert Tenancy.list_athanors(ctx) == []
    end
  end

  describe "channel_active?/2" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "true while the athanor is active and the creator is not denied" do
      athanor = group!("chan-a")
      uid = "github|https://github.com|chan-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: uid,
          provider: "github",
          email: "chan@example.com",
          verified: true
        })

      assert Tenancy.channel_active?(athanor.id, user.id)
      # a creator who merely leaves (or never was a member) leaves the channel running
      assert Tenancy.channel_active?(athanor.id, "someone-else")
      # synthetic principals are never denied
      assert Tenancy.channel_active?(athanor.id, "webhook:abc")
      assert Tenancy.channel_active?(athanor.id, nil)

      # an id minted here always has its row: one without was never a person
      refute Tenancy.channel_active?(athanor.id, "usr_never-seen")

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      refute Tenancy.channel_active?(athanor.id, user.id)

      # a denied person whose row predates minted ids — an in-place upgrade —
      # is read by the row, never waved through by the shape of the id
      legacy = "github|https://github.com|legacy-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.User, [
          %{
            id: legacy,
            provider: "github",
            status: "denied",
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          }
        ])

      refute Tenancy.channel_active?(athanor.id, legacy)

      {:ok, _} = Athanors.archive(athanor)
      refute Tenancy.channel_active?(athanor.id, "someone-else")
    end

    test "false for a missing or unknown athanor" do
      refute Tenancy.channel_active?(nil, "u")
      refute Tenancy.channel_active?("", "u")
      refute Tenancy.channel_active?("ath_ghost", "u")
    end
  end

  describe "membership by identifier, and leaving one athanor" do
    alias Sanctum.Test.DirectoryServer

    setup tags do
      Arca.Test.Sandbox.setup!(tags)

      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      directory = DirectoryServer.start!(tls)
      identity = DirectoryServer.identity!(directory.dir, directory.url)

      {:ok, directory: directory, identity: identity}
    end

    test "an invite names an identifier with no directory read; the cyfr sign-in claims it; a removal retires the person here; recovered, they sign in to nothing",
         %{directory: directory, identity: identity} do
      group = group!("join")
      {:ok, peer} = Sanctum.Tenancy.Users.upsert_from_provider(github("peer"))
      {:ok, :added} = Members.add(group, [user_id: peer.id], "system")

      # Invited before they ever signed in here: held as invited, queued for
      # the operator, and nothing asked of their directory, which only their
      # own sign-in can locate.
      assert {:ok, :invited} = Members.add(group, [identifier: identity.identifier], "system")
      assert DirectoryServer.requests() == []
      refute_received {:resolved, _}

      assert Enum.any?(
               Sanctum.Door.Store.requests(),
               &(&1.kind == "identifier" and &1.value == identity.identifier)
             )

      # The operator admits the identifier, and the person signs in through
      # the cyfr door: their head read fresh, then the door's admission.
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "ops")
      key = Sanctum.Auth.Identity.cyfr_key(directory.url, identity.identifier)
      user = cyfr_sign_in!(identity, key)
      assert Members.member?(user.id, group.id)

      session = session!(user.id, group.id)

      assert :ok = Members.remove_member(group, user_id: user.id)

      # The seat, their head here and every session of theirs are gone
      # together; their person row, identity row and door entry stand.
      refute Members.member?(user.id, group.id)

      assert {:error, :not_found} =
               Arca.DirectoryHeads.get(Prima.Actor.system(), identity.identifier)

      assert {:error, _} = Arca.SessionStorage.get_session(session.hash)
      assert {:ok, %{status: "active"}} = Sanctum.Tenancy.Users.get(user.id)

      assert {:ok, %{provenance: "remote", identifier: identifier}} =
               Arca.PersonIdentities.get(Prima.Actor.system(), user.id)

      assert identifier == identity.identifier
      assert {:ok, :allowed} = Sanctum.Door.admit(key, nil, :unknown)
      assert Members.member?(peer.id, group.id)

      # Recovered at their own home: their identity is current, and the
      # cyfr door admits them again as the same person — to nothing here.
      identity = DirectoryServer.recover!(directory.dir, identity)
      assert %{id: same} = cyfr_sign_in!(identity, key)
      assert same == user.id
      refute Members.member?(user.id, group.id)

      # Their new session stands, and opens nothing: they hold no athanor
      # here, and the one they were removed from refuses them.
      again = session!(user.id, nil)
      assert {:ok, _} = Arca.SessionStorage.get_session(again.hash)

      assert {:error, :no_athanor} =
               Sanctum.Caller.establish(again.token, focus: group.id, task_supervisor: nil)

      ctx =
        Context.build(
          user_id: user.id,
          provider: "cyfr",
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      assert {:error, :not_member} = Context.focus(ctx, group.id)
    end

    test "a person in two athanors leaving one keeps the other seat, their identity and their head",
         %{identity: identity} do
      stay = group!("stay")
      leave = group!("leave")
      {:ok, user} = Sanctum.Tenancy.Users.upsert_from_provider(github("two"))
      :ok = DirectoryServer.remote_person!(user.id, identity)
      {:ok, :added} = Members.add(stay, [user_id: user.id], "system")
      {:ok, :added} = Members.add(leave, [user_id: user.id], "system")

      bound = session!(user.id, leave.id)
      kept = session!(user.id, stay.id)

      assert :ok = Members.remove_member(leave, user_id: user.id)

      refute Members.member?(user.id, leave.id)
      assert Members.member?(user.id, stay.id)
      assert {:error, _} = Arca.SessionStorage.get_session(bound.hash)
      assert {:ok, _} = Arca.SessionStorage.get_session(kept.hash)
      assert {:ok, _} = Arca.DirectoryHeads.get(Prima.Actor.system(), identity.identifier)

      assert {:ok, %{provenance: "remote", identifier: identifier}} =
               Arca.PersonIdentities.get(Prima.Actor.system(), user.id)

      assert identifier == identity.identifier

      # The session that stands still establishes in the athanor they kept.
      assert {:ok, %{athanor_id: athanor_id}} =
               Sanctum.Caller.establish(kept.token, focus: stay.id, task_supervisor: nil)

      assert athanor_id == stay.id
    end

    defp github(name) do
      n = System.unique_integer([:positive])

      %{
        id: "github|https://github.com|#{name}-#{n}",
        provider: "github",
        email: "#{name}-#{n}@example.com",
        verified: true
      }
    end

    # What the cyfr door does once it verified the person's assertion: the
    # head read fresh from the directory their genesis names, then the
    # admitted sign-in.
    defp cyfr_sign_in!(identity, key) do
      _head = DirectoryServer.cached!(identity)

      {:ok, user} =
        Sanctum.SignIn.admitted(
          %{
            id: key,
            provider: "cyfr",
            email: nil,
            verified: :unknown,
            name: nil,
            remote: %{identifier: identity.identifier, directory_url: identity.url}
          },
          :allowed
        )

      user
    end

    # A session of the person, bound to `athanor_id` (or to none), as the
    # sign-in mints one: a remote person's carries their fresh head's epoch.
    defp session!(user_id, athanor_id) do
      {:ok, session} =
        Sanctum.TestContext.create_session(
          Context.build(
            user_id: user_id,
            athanor_id: athanor_id,
            provider: "cyfr",
            permissions: [:*],
            scope: :athanor,
            auth_method: :oidc,
            authenticated: true
          )
        )

      %{token: session.token, hash: Sanctum.Session.token_hash(session.token)}
    end
  end

  defp restore(k, nil), do: Application.delete_env(:sanctum, k)
  defp restore(k, v), do: Application.put_env(:sanctum, k, v)
  defp rows!({:ok, rows}), do: rows
end
