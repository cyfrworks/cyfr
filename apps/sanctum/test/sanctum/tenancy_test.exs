# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyTest do
  # async: false — global :tenancy_resolver_override mutation.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Sanctum.Context
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.Athanors

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

  describe "resolve_status/2 — the person's own athanor" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)

      orig_override = Application.get_env(:sanctum, :tenancy_resolver_override)
      # The resolution from the person must run, not the override seam.
      Application.delete_env(:sanctum, :tenancy_resolver_override)

      on_exit(fn ->
        restore(:tenancy_resolver_override, orig_override)
      end)

      :ok
    end

    test "no athanor of their own leaves athanor_id unresolved" do
      ctx = %Context{user_id: "nobody-#{System.unique_integer([:positive])}", athanor_id: nil}
      assert {:ok, %{athanor_id: nil}} = Tenancy.resolve_status(ctx, force: true)
    end

    test "the person's own athanor is the working athanor" do
      uid = "u-ath-#{System.unique_integer([:positive])}"
      athanor = athanor!("home-a", uid)

      {:ok, result} = Tenancy.resolve_status(%Context{user_id: uid, athanor_id: nil}, force: true)
      assert result.scope == :athanor
      assert result.athanor_id == athanor.id
    end

    test "a platform admin keeps :athanor scope with the capability; works in their own athanor" do
      user = person!("multi")
      athanor = Sanctum.Test.People.athanor!(user)
      {:ok, _} = Sanctum.TestContext.ensure_platform(user.id)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: user.id, athanor_id: nil}, force: true)

      assert result.scope == :athanor
      assert result.platform_admin
      assert result.athanor_id == athanor.id
    end

    test "a platform admin whose own athanor is archived has no athanor to work in" do
      # No athanor is shared server-wide, so the mark alone places nobody.
      # What guarantees an operator an athanor is the one minted for them
      # at admission, past the server caps.
      user = person!("plat-only")
      {:ok, _} = Sanctum.TestContext.ensure_platform(user.id)
      Sanctum.TestContext.archive!(Sanctum.Test.People.athanor!(user).id)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: user.id, athanor_id: nil}, force: true)

      assert result.platform_admin
      assert result.athanor_id == nil
    end

    test "resolution never mints anything — the platform administrator's mark is the first person's mint alone" do
      uid = "u-admin-#{System.unique_integer([:positive])}"

      ctx = %Context{user_id: uid, athanor_id: nil, email: "admin@example.com"}
      {:ok, result} = Tenancy.resolve_status(ctx, force: true)

      refute result.platform_admin
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get(uid)
    end

    test "an archived own athanor leaves none" do
      uid = "u-archived-#{System.unique_integer([:positive])}"
      a = athanor!("arch-a", uid)
      Sanctum.TestContext.archive!(a.id)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: uid, athanor_id: a.id}, force: true)

      assert result.athanor_id == nil
    end

    test "another person's athanor is never chosen, even named by the context" do
      uid = "u-owner-#{System.unique_integer([:positive])}"
      own = athanor!("owner-own", uid)
      theirs = athanor!("owner-theirs")

      for named <- [nil, theirs.id] do
        {:ok, result} =
          Tenancy.resolve_status(%Context{user_id: uid, athanor_id: named}, force: true)

        assert result.athanor_id == own.id
      end

      # With their own athanor archived, the one named elsewhere still names none.
      Sanctum.TestContext.archive!(own.id)

      {:ok, result} =
        Tenancy.resolve_status(%Context{user_id: uid, athanor_id: theirs.id}, force: true)

      assert result.athanor_id == nil
    end
  end

  describe "platform_admin?/1" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "is the mark on an active person's row, read as the row" do
      now = DateTime.utc_now()

      assert Tenancy.platform_admin?(%{status: "active", platform_admin_at: now})
      refute Tenancy.platform_admin?(%{status: "active", platform_admin_at: nil})
      refute Tenancy.platform_admin?(%{status: "denied", platform_admin_at: now})
      refute Tenancy.platform_admin?(nil)
    end

    test "is the mark on an active person's row, read by their id" do
      user = person!("mark")
      refute Tenancy.platform_admin?(user.id)

      {:ok, %{platform_admin_at: %DateTime{}}} = Sanctum.TestContext.ensure_platform(user.id)
      assert Tenancy.platform_admin?(user.id)

      # Denied with the mark still on the row: no capability.
      Arca.Repo.update_all(
        from(u in Arca.Schemas.User, where: u.id == ^user.id),
        set: [status: "denied"]
      )

      refute Tenancy.platform_admin?(user.id)
      refute Tenancy.platform_admin?(Prima.UUID7.generate_id(Prima.PersonId.prefix()))
    end
  end

  describe "revalidate/1" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      :ok
    end

    test "keeps the capability and leaves the athanor it names for their own" do
      user = person!("reval-keep")
      own = Sanctum.Test.People.athanor!(user)
      {:ok, _} = Sanctum.TestContext.ensure_platform(user.id)

      # The session names another person's athanor: the capability is over
      # the instance, not that athanor, so it keeps them in their own.
      ctx = %Context{
        user_id: user.id,
        athanor_id: athanor!("reval-keep").id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      {:ok, out} = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.scope == :athanor
      assert out.athanor_id == own.id

      # With their own athanor archived, they work in none.
      Sanctum.TestContext.archive!(own.id)

      {:ok, out} = Tenancy.revalidate(ctx)
      assert out.platform_admin
      assert out.athanor_id == nil
    end

    test "drops the capability once the mark is cleared" do
      user = person!("reval-revoke")
      own = Sanctum.Test.People.athanor!(user)
      {:ok, _} = Sanctum.TestContext.ensure_platform(user.id)

      ctx = %Context{
        user_id: user.id,
        athanor_id: own.id,
        scope: :athanor,
        platform_admin: true,
        authenticated: true
      }

      assert {:ok, %{platform_admin: true}} = Tenancy.revalidate(ctx)

      {1, _} =
        Arca.Repo.update_all(
          from(u in Arca.Schemas.User, where: u.id == ^user.id),
          set: [platform_admin_at: nil]
        )

      # No mark, no capability; their athanor stays theirs.
      {:ok, revalidated} = Tenancy.revalidate(ctx)
      refute revalidated.platform_admin
      assert revalidated.athanor_id == own.id
    end

    test "a stale capability on the context does not survive revalidation" do
      uid = "u-reval-down-#{System.unique_integer([:positive])}"
      athanor = athanor!("home-c", uid)

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

      # Session points at an athanor that is not the user's.
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

      ids = Tenancy.list_athanors(%Context{user_id: uid, scope: :athanor}) |> Enum.map(& &1.id)
      assert ids == [a.id]
    end

    test "a platform admin sees their own athanor alone" do
      user = person!("list-plat")
      _other = athanor!("list-other")
      {:ok, _} = Sanctum.TestContext.ensure_platform(user.id)

      ids =
        %Context{user_id: user.id, scope: :athanor, platform_admin: true}
        |> Tenancy.list_athanors()
        |> Enum.map(& &1.id)

      assert ids == [Sanctum.Test.People.athanor!(user).id]
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
      # a creator who is not the athanor's person leaves the channel running
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
end
