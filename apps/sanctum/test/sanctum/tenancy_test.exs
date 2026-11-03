# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyTest do
  # async: false — global :tenancy_resolver_override mutation.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.{Athanors, Members}

  # An athanor row owned by `owner` (by default an id no person holds).
  defp athanor!(name, owner \\ Prima.UUID7.generate_id(Prima.PersonId.prefix())) do
    {:ok, athanor} =
      Athanors.create(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        owner_user_id: owner,
        created_by: "system"
      })

    athanor
  end

  defp person!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|#{name}-#{n}",
        provider: "github",
        email: "#{name}-#{n}@example.com",
        verified: true
      })

    user
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

      orig_override = Application.get_env(:sanctum, :tenancy_resolver_override)
      # Membership resolution must run, not the override seam.
      Application.delete_env(:sanctum, :tenancy_resolver_override)

      on_exit(fn ->
        restore(:tenancy_resolver_override, orig_override)
      end)

      :ok
    end

    test "no membership leaves athanor_id unresolved" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", athanor_id: nil}
      assert {:ok, %{athanor_id: nil}} = Tenancy.resolve_status(ctx, force: true)
    end

    test "the person's own athanor is the working athanor" do
      uid = "u-ath-#{System.unique_integer([:positive])}"
      athanor = athanor!("home-a", uid)
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})

      {:ok, result} = Tenancy.resolve_status(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.athanor_id == athanor.id
    end

    test "a platform admin keeps :athanor scope with the capability; works in their own athanor" do
      uid = "u-multi-#{System.unique_integer([:positive])}"
      athanor = athanor!("home-b", uid)
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: athanor.id})
      {:ok, _} = Sanctum.TestContext.ensure_platform(uid)

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
      {:ok, _} = Sanctum.TestContext.ensure_platform(uid)

      {:ok, result} = Tenancy.resolve_status(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.platform_admin
      assert result.athanor_id == nil
    end

    test "resolution never mints anything — the platform grant is the first person's mint alone" do
      uid = "u-admin-#{System.unique_integer([:positive])}"

      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin@example.com"}
      {:ok, result} = Tenancy.resolve_status(ctx, force: true)

      refute result.platform_admin
      assert rows!(Members.list_by_user(uid)) == []
    end

    test "an archived own athanor leaves none" do
      uid = "u-archived-#{System.unique_integer([:positive])}"
      a = athanor!("arch-a", uid)
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: a.id})
      Sanctum.TestContext.archive!(a.id)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: uid, athanor_id: a.id}, force: true)

      assert result.athanor_id == nil
    end

    test "a seat in another person's athanor is never chosen, even named by the context" do
      uid = "u-seated-#{System.unique_integer([:positive])}"
      own = athanor!("seated-own", uid)
      theirs = athanor!("seated-theirs")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: own.id})
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: theirs.id})

      for named <- [nil, theirs.id] do
        {:ok, result} =
          Tenancy.resolve_status(%Context{user_id: uid, athanor_id: named}, force: true)

        assert result.athanor_id == own.id
      end

      # With their own athanor archived, the seat elsewhere still names none.
      Sanctum.TestContext.archive!(own.id)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: uid, athanor_id: theirs.id}, force: true)

      assert result.athanor_id == nil
    end
  end

  describe "focus_basis/3" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "is the person's seat in the athanor, never their platform row" do
      uid = "u-basis-#{System.unique_integer([:positive])}"
      seated = athanor!("basis-seated", uid)
      other = athanor!("basis-other")
      {:ok, seat} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: seated.id})
      {:ok, _} = Sanctum.TestContext.ensure_platform(uid)
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
      {:ok, _} = Sanctum.TestContext.ensure_platform(uid)

      # The session names an athanor the operator holds no seat in: the
      # capability is over the instance, not a seat, so it keeps them in
      # no athanor.
      ctx = %Context{
        user_id: uid,
        athanor_id: athanor!("reval-keep").id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      {:ok, out} = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.scope == :athanor
      assert out.athanor_id == nil

      # With a seat elsewhere, they fall back to it like anyone else.
      seated = athanor!("reval-seated", uid)
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: seated.id})

      {:ok, out} = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.athanor_id == seated.id
    end

    test "drops the capability once the platform membership is gone" do
      uid = "u-reval-revoke-#{System.unique_integer([:positive])}"
      {:ok, grant} = Sanctum.TestContext.ensure_platform(uid)

      ctx = %Context{
        user_id: uid,
        athanor_id: athanor!("reval-revoke").id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      assert {:ok, %{platform_admin: true}} = Tenancy.revalidate(ctx)

      [%{id: grant_id}] = rows!(Members.list_by_user(uid))
      assert grant_id == grant.id
      Arca.Repo.delete!(%Arca.Schemas.Membership{id: grant.id})

      # No memberships → no capability, no athanor; the tenant gate then
      # rejects tenant-scoped routes.
      {:ok, revalidated} = Tenancy.revalidate(ctx)
      refute revalidated.platform_admin
      assert revalidated.athanor_id == nil
    end

    test "a stale capability on the context does not survive revalidation" do
      uid = "u-reval-down-#{System.unique_integer([:positive])}"
      athanor = athanor!("home-c", uid)
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

    test "moves a session naming another athanor to the person's own" do
      uid = "u-reval-switch-#{System.unique_integer([:positive])}"
      athanor = athanor!("home-d", uid)
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

    test "a person sees their own athanor" do
      uid = "u-list-#{System.unique_integer([:positive])}"
      a = athanor!("list-a", uid)
      _other = athanor!("list-b")
      {:ok, _} = Members.create(%{user_id: uid, scope: "athanor", athanor_id: a.id})

      ids = Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor}) |> Enum.map(& &1.id)
      assert ids == [a.id]
    end

    test "a platform admin with no athanor of their own sees none" do
      uid = "u-list-plat-#{System.unique_integer([:positive])}"
      _other = athanor!("list-other")
      {:ok, _} = Sanctum.TestContext.ensure_platform(uid)

      assert Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor, platform_admin: true}) ==
               []
    end

    test "a person with no athanor sees none" do
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
      athanor = athanor!("chan-a")
      user = person!("chan")
      bystander = person!("bystander")

      assert Tenancy.channel_active?(athanor.id, user.id)
      # a creator who merely leaves (or never was a member) leaves the channel running
      assert Tenancy.channel_active?(athanor.id, bystander.id)
      # synthetic principals are never denied
      assert Tenancy.channel_active?(athanor.id, "webhook:abc")
      assert Tenancy.channel_active?(athanor.id, "system")
      assert Tenancy.channel_active?(athanor.id, nil)

      # rows are never deleted: a minted id without one was never a person
      refute Tenancy.channel_active?(athanor.id, "usr_never-seen")
      # an id of another shape with no row names no person here
      assert Tenancy.channel_active?(athanor.id, "someone-else")

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      refute Tenancy.channel_active?(athanor.id, user.id)

      Sanctum.TestContext.archive!(athanor.id)
      refute Tenancy.channel_active?(athanor.id, bystander.id)
    end

    test "false for a missing or unknown athanor" do
      refute Tenancy.channel_active?(nil, "u")
      refute Tenancy.channel_active?("", "u")
      refute Tenancy.channel_active?("ath_ghost", "u")
    end
  end

  defp restore(k, nil), do: Application.delete_env(:sanctum, k)
  defp restore(k, v), do: Application.put_env(:sanctum, k, v)
  defp rows!({:ok, rows}), do: rows
end
