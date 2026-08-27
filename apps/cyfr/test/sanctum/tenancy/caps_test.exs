# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.CapsTest.UnreadableAdapter do
  @moduledoc false
  # A storage adapter whose usage walk always fails — the fail-closed
  # branch's only door.
  @behaviour Arca.Storage

  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate put(ctx, path, content), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
  defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(conn, ctx, path, opts), to: Arca.Adapters.Local

  def usage(_ctx, _path), do: {:error, :eacces}
end

defmodule Sanctum.Tenancy.CapsTest do
  @moduledoc """
  The public-door caps: off unless set, and when set, enforced where each
  applies — athanors per server, groups per person, members per group,
  mints per hour, bytes per athanor.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Athanors, Caps, Members}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Application.get_env(:cyfr, :caps)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :caps, prev),
        else: Application.delete_env(:cyfr, :caps)
    end)

    :ok
  end

  test "an unset cap is off; a set cap is a ceiling" do
    Application.delete_env(:cyfr, :caps)
    assert Caps.get(:max_athanors) == nil
    assert :ok = Caps.check(:max_athanors, 1_000_000)

    Application.put_env(:cyfr, :caps, max_athanors: 3, max_groups_per_person: 0)
    assert :ok = Caps.check(:max_athanors, 2)
    assert {:error, {:limit_reached, :max_athanors, 3}} = Caps.check(:max_athanors, 3)
    # zero and negatives read as off, never as "nothing allowed"
    assert Caps.get(:max_groups_per_person) == nil
  end

  test "max_athanors stops Athanors.create; max_groups_per_person stops create_group" do
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count())

    assert {:error, {:limit_reached, :max_athanors, _}} =
             Athanors.create(%{
               kind: "group",
               name: "One more",
               slug: "onemore-#{System.unique_integer([:positive])}",
               created_by: "system"
             })

    # An archived athanor frees its place: the cap counts active furnaces.
    uid0 = "github|https://github.com|freed-#{System.unique_integer([:positive])}"
    Application.delete_env(:cyfr, :caps)
    {:ok, doomed} = Athanors.create_group(uid0, "Doomed")
    {:ok, _} = Athanors.archive(doomed)
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count() + 1)
    assert {:ok, _} = Athanors.create_group(uid0, "Fits")

    # ...and taking the place back has to ask for it, or archive-then-reopen
    # would be the way past the cap.
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count())
    assert {:error, {:limit_reached, :max_athanors, _}} = Athanors.unarchive(doomed)
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count() + 1)
    assert {:ok, %{status: "active"}} = Athanors.unarchive(doomed)

    Application.put_env(:cyfr, :caps, max_groups_per_person: 1)
    uid = "github|https://github.com|capped-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Athanors.create_group(uid, "First")

    assert {:error, {:limit_reached, :max_groups_per_person, 1}} =
             Athanors.create_group(uid, "Second")
  end

  test "mint_per_hour bounds personal athanors minted per hour" do
    Application.put_env(:cyfr, :caps, mint_per_hour: 0)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|mint-#{n}",
        provider: "github",
        email: "mint#{n}@example.com",
        verified: true
      })

    {:ok, user} = Sanctum.Tenancy.Users.set_namespace(user, "mint#{n}")
    # a cap of 0 reads as off (nil), so the mint goes through
    assert {:ok, _} = Sanctum.Provisioning.ensure_personal_athanor(user)

    Application.put_env(:cyfr, :caps, mint_per_hour: 1)
    n2 = n + 1

    {:ok, user2} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|mint-#{n2}",
        provider: "github",
        email: "mint#{n2}@example.com",
        verified: true
      })

    {:ok, user2} = Sanctum.Tenancy.Users.set_namespace(user2, "mint#{n2}")
    # one was minted this hour already (above)
    assert {:error, {:limit_reached, :mint_per_hour, 1}} =
             Sanctum.Provisioning.ensure_personal_athanor(user2)

    # Groups people create do not draw on the mint budget: the cap measures
    # person athanors, so a member's `athanor.create` cannot starve sign-ins.
    Application.put_env(:cyfr, :caps, mint_per_hour: 2)
    {:ok, _} = Athanors.create_group(user.id, "Not a mint")
    assert {:ok, _} = Sanctum.Provisioning.ensure_personal_athanor(user2)
  end

  test "athanor_storage_bytes is one check for every writer" do
    # An athanor nothing else has written under, so the usage walk starts
    # at zero regardless of what ran before.
    ctx =
      Sanctum.Context.build(
        user_id: "local|local|caps",
        athanor_id: "ath_caps_#{System.unique_integer([:positive])}",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 100)
    assert :ok = Caps.check_storage(ctx, 50)

    assert {:error, {:limit_reached, :athanor_storage_bytes, 100}} =
             Caps.check_storage(ctx, 1_000)

    Application.delete_env(:cyfr, :caps)
    assert :ok = Caps.check_storage(ctx, 1_000_000_000)
  end

  test "athanor_storage_bytes counts the component tree on every write, not only a publish" do
    ctx = Sanctum.TestContext.local()

    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 1_000_000_000)
    assert :ok = Caps.check_storage(ctx, 10)

    # A cap below what this athanor's components already hold refuses the
    # next write of any kind — a chat attachment and a guest storage write
    # come through the same function a publish does.
    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 1)

    assert {:error, {:limit_reached, :athanor_storage_bytes, 1}} =
             Caps.check_storage(ctx, 10)
  end

  test "an unreadable usage walk fails CLOSED while a cap is configured" do
    prev_adapter = Application.get_env(:cyfr, :storage_adapter)
    Application.put_env(:cyfr, :storage_adapter, Sanctum.Tenancy.CapsTest.UnreadableAdapter)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:cyfr, :storage_adapter, prev_adapter),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    ctx = Sanctum.TestContext.local()
    Arca.Cache.invalidate(Arca.Cache.Keys.athanor_usage(ctx.athanor_id))
    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 100)

    # A walk that cannot answer must refuse the write — treating the tree
    # as empty would let writes march past the ceiling.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :storage_unverifiable} = Caps.check_storage(ctx, 50)
      end)

    assert log =~ "usage walk failed"

    # With no cap configured, no walk runs — the broken adapter is never
    # even asked.
    Application.delete_env(:cyfr, :caps)
    assert :ok = Caps.check_storage(ctx, 50)
  end

  test "the athanor total is cached, bumped by writes, and dropped by deletes" do
    ctx = Sanctum.TestContext.local()
    key = Arca.Cache.Keys.athanor_usage(ctx.athanor_id)

    Arca.Cache.invalidate(key)
    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 1_000_000_000)

    # The first check walks the tree and remembers what it found.
    assert :ok = Caps.check_storage(ctx, 1)
    assert {:ok, cached} = Arca.Cache.get(key)
    assert is_integer(cached)

    # A write anywhere in the athanor's tree bumps the total by exactly
    # what was written — no re-walk — components and guest files alike.
    :ok = Arca.put(ctx, ["components", "cap-probe.txt"], "bytes")
    assert Arca.Cache.get(key) == {:ok, cached + 5}

    :ok = Arca.put(ctx, ["guest", "cap-probe.txt"], "1234567890")
    assert Arca.Cache.get(key) == {:ok, cached + 15}

    # A delete reclaims space: the entry drops so the next check walks the
    # tree afresh instead of guessing what the delete removed.
    :ok = Arca.delete(ctx, ["guest", "cap-probe.txt"])
    assert Arca.Cache.get(key) == :miss

    # A write to a global root is the server's bytes, not the athanor's,
    # and leaves the total alone.
    assert :ok = Caps.check_storage(ctx, 1)
    assert {:ok, rewalked} = Arca.Cache.get(key)
    sys = Sanctum.internal_context(user_id: "_s", athanor_id: ctx.athanor_id, scope: :athanor)
    :ok = Arca.put(sys, ["cache", "cap-probe.txt"], "bytes")
    assert Arca.Cache.get(key) == {:ok, rewalked}
  end

  test "max_members_per_group counts seats — active and invited" do
    Application.put_env(:cyfr, :caps, max_members_per_group: 2)
    uid = "github|https://github.com|seat-#{System.unique_integer([:positive])}"
    {:ok, group} = Athanors.create_group(uid, "Seats")
    # creator holds one seat; one invitation fills the second
    assert {:ok, :invited} = Members.add(group, [email: "a-#{uid}@example.com"], uid)

    assert {:error, {:limit_reached, :max_members_per_group, 2}} =
             Members.add(group, [email: "b@example.com"], uid)
  end
end
