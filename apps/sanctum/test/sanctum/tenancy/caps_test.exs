# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.CapsTest.UnreadableAdapter do
  @moduledoc false
  # A storage adapter whose usage walk always fails — the fail-closed
  # branch's only door.
  use Arca.Storage.TestDouble

  def usage(_ctx, _path), do: {:error, :eacces}
end

defmodule Sanctum.Tenancy.CapsTest do
  @moduledoc """
  The public-door caps: off unless set, and when set, enforced where each
  applies — athanors per server, groups per person, members per group,
  mints per hour, bytes per athanor. Each is a platform setting, set here
  as an operator's write leaves it and read on the next check, and a cap
  the store cannot answer refuses.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Test.Settings
  alias Sanctum.Tenancy.{Athanors, Caps, Members}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  # Every cap named in `caps` stored at its value; the rest stand.
  defp put_caps(caps),
    do: Enum.each(caps, fn {key, value} -> Settings.put(Atom.to_string(key), value) end)

  # Every cap back to its default: off, but for the group, pair and
  # thread caps that ship on.
  defp reset_caps, do: Enum.each(Prima.Caps.keys(), &Settings.reset(Atom.to_string(&1)))

  test "check_counted/2 counts only while the cap is on, and refuses an uncountable current" do
    # Cap off: the count is never even asked for.
    reset_caps()
    assert :ok = Caps.check_counted(:max_athanors, fn -> raise "must not be called" end)

    put_caps(max_athanors: 3)
    assert :ok = Caps.check_counted(:max_athanors, fn -> {:ok, 2} end)

    assert {:error, {:limit_reached, :max_athanors, 3}} =
             Caps.check_counted(:max_athanors, fn -> {:ok, 3} end)

    # A count the store cannot answer refuses — fail closed, like the
    # storage cap's unverifiable walk; a DB blink must not admit a mint.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:cap_unverifiable, :max_athanors}} =
                 Caps.check_counted(:max_athanors, fn -> {:error, :database_error} end)
      end)

    assert log =~ "count failed"
  end

  test "the write gate checks every tenant create by default; :exempt is the stated exception" do
    ctx = Sanctum.TestContext.local()
    Arca.Usage.invalidate(Sanctum.Context.actor(ctx))
    put_caps(athanor_storage_bytes: 1)

    # Default posture: a writer that states nothing is capped.
    assert {:error, {:limit_reached, :athanor_storage_bytes, 1}} =
             Arca.put(Sanctum.Context.actor(ctx), ["data", "capped.txt"], "too many bytes")

    refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", "capped.txt"])

    # The uncapped-by-design writers say so, visibly, per call.
    assert :ok =
             Arca.put(Sanctum.Context.actor(ctx), ["data", "exempted.txt"], "still lands",
               cap: :exempt
             )

    # Anything else is caller misuse, not a policy.
    assert_raise ArgumentError, ~r/cap: must be :checked or :exempt/, fn ->
      Arca.put(Sanctum.Context.actor(ctx), ["data", "typo.txt"], "x", cap: :always)
    end
  end

  test "an unset cap is off; a set cap is a ceiling" do
    reset_caps()
    assert Caps.get(:max_athanors) == {:ok, nil}
    assert :ok = Caps.check(:max_athanors, 1_000_000)

    # The group cap ships on; zero turns it off, never "nothing allowed".
    assert Caps.get(:max_groups_per_person) == {:ok, 50}

    put_caps(max_athanors: 3, max_groups_per_person: 0)
    assert :ok = Caps.check(:max_athanors, 2)
    assert {:error, {:limit_reached, :max_athanors, 3}} = Caps.check(:max_athanors, 3)
    assert Caps.get(:max_groups_per_person) == {:ok, nil}
  end

  test "a cap the store cannot answer refuses, never reads as off" do
    put_caps(max_athanors: 3)
    Settings.expire("max_athanors")
    Settings.expire("athanor_storage_bytes")
    Settings.break_store!()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Caps.get(:max_athanors) == {:error, :unavailable}

        assert {:error, {:cap_unverifiable, :max_athanors}} =
                 Caps.check_counted(:max_athanors, fn -> raise "must not be counted" end)

        assert {:error, {:cap_unverifiable, :max_athanors}} = Caps.check(:max_athanors, 0)

        assert {:error, :storage_unverifiable} =
                 Caps.check_storage(Sanctum.Context.actor(Sanctum.TestContext.local()), 1)
      end)

    assert log =~ "the max_athanors cap could not be read"

    # The refusal is the unavailable class: the caller retries, and it is
    # not a limit the account reached.
    assert %Prima.Refusal{class: :unavailable} =
             Prima.Refusal.classify({:cap_unverifiable, :max_athanors})
  end

  test "max_athanors stops Athanors.create; max_groups_per_person stops create_group" do
    put_caps(max_athanors: active_count())

    assert {:error, {:limit_reached, :max_athanors, _}} =
             Athanors.create(%{
               kind: "group",
               name: "One more",
               slug: "onemore-#{System.unique_integer([:positive])}",
               created_by: "system"
             })

    # An archived athanor frees its place: the cap counts active furnaces.
    uid0 = "github|https://github.com|freed-#{System.unique_integer([:positive])}"
    reset_caps()
    {:ok, doomed} = Athanors.create_group(uid0, "Doomed")
    {:ok, _} = Athanors.archive(doomed)
    put_caps(max_athanors: active_count() + 1)
    assert {:ok, _} = Athanors.create_group(uid0, "Fits")

    # ...and taking the place back has to ask for it, or archive-then-reopen
    # would be the way past the cap.
    put_caps(max_athanors: active_count())
    assert {:error, {:limit_reached, :max_athanors, _}} = Athanors.unarchive(doomed)
    put_caps(max_athanors: active_count() + 1)
    assert {:ok, %{status: "active"}} = Athanors.unarchive(doomed)

    reset_caps()
    put_caps(max_groups_per_person: 1)
    uid = "github|https://github.com|capped-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Athanors.create_group(uid, "First")

    assert {:error, {:limit_reached, :max_groups_per_person, 1}} =
             Athanors.create_group(uid, "Second")
  end

  test "mint_per_hour bounds personal athanors minted per hour" do
    put_caps(mint_per_hour: 0)
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

    put_caps(mint_per_hour: 1)
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
    put_caps(mint_per_hour: 2)
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

    put_caps(athanor_storage_bytes: 100)
    assert :ok = Caps.check_storage(Sanctum.Context.actor(ctx), 50)

    assert {:error, {:limit_reached, :athanor_storage_bytes, 100}} =
             Caps.check_storage(Sanctum.Context.actor(ctx), 1_000)

    reset_caps()
    assert :ok = Caps.check_storage(Sanctum.Context.actor(ctx), 1_000_000_000)
  end

  test "athanor_storage_bytes counts the component tree on every write, not only a publish" do
    ctx = Sanctum.TestContext.local()

    put_caps(athanor_storage_bytes: 1_000_000_000)
    assert :ok = Caps.check_storage(Sanctum.Context.actor(ctx), 10)

    # A cap below what this athanor's components already hold refuses the
    # next write of any kind — a chat attachment and a guest storage write
    # come through the same function a publish does.
    put_caps(athanor_storage_bytes: 1)

    assert {:error, {:limit_reached, :athanor_storage_bytes, 1}} =
             Caps.check_storage(Sanctum.Context.actor(ctx), 10)
  end

  test "an unreadable usage walk fails CLOSED while a cap is configured" do
    prev_adapter = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, Sanctum.Tenancy.CapsTest.UnreadableAdapter)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:arca, :storage_adapter, prev_adapter),
        else: Application.delete_env(:arca, :storage_adapter)
    end)

    ctx = Sanctum.TestContext.local()
    Arca.Usage.invalidate(Sanctum.Context.actor(ctx))
    put_caps(athanor_storage_bytes: 100)

    # A walk that cannot answer must refuse the write — treating the tree
    # as empty would let writes march past the ceiling.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :storage_unverifiable} =
                 Caps.check_storage(Sanctum.Context.actor(ctx), 50)
      end)

    assert log =~ "usage walk failed"

    # With no cap configured, no walk runs — the broken adapter is never
    # even asked.
    reset_caps()
    assert :ok = Caps.check_storage(Sanctum.Context.actor(ctx), 50)
  end

  test "the athanor total is cached, bumped by writes, and dropped by deletes" do
    ctx = Sanctum.TestContext.local()
    key = Arca.Cache.Keys.athanor_usage(Sanctum.Context.actor(ctx))

    Arca.Cache.invalidate(key)
    put_caps(athanor_storage_bytes: 1_000_000_000)

    # The first check walks the tree and remembers what it found.
    assert :ok = Caps.check_storage(Sanctum.Context.actor(ctx), 1)
    assert {:ok, cached} = Arca.Cache.get(key)
    assert is_integer(cached)

    # A write anywhere in the athanor's tree bumps the total by exactly
    # what was written — no re-walk — components and guest files alike.
    :ok = Arca.put(Sanctum.Context.actor(ctx), ["components", "cap-probe.txt"], "bytes")
    assert Arca.Cache.get(key) == {:ok, cached + 5}

    :ok = Arca.put(Sanctum.Context.actor(ctx), ["data", "cap-probe.txt"], "1234567890")
    assert Arca.Cache.get(key) == {:ok, cached + 15}

    # A delete reclaims space: the entry drops so the next check walks the
    # tree afresh instead of guessing what the delete removed.
    :ok = Arca.delete(Sanctum.Context.actor(ctx), ["data", "cap-probe.txt"])
    assert Arca.Cache.get(key) == :miss

    # A write to a global root is the server's bytes, not the athanor's,
    # and leaves the total alone.
    assert :ok = Caps.check_storage(Sanctum.Context.actor(ctx), 1)
    assert {:ok, rewalked} = Arca.Cache.get(key)
    sys = %{Prima.Actor.system() | user_id: "_s", athanor_id: ctx.athanor_id, scope: :athanor}
    :ok = Arca.put(sys, ["cache", "cap-probe.txt"], "bytes")
    assert Arca.Cache.get(key) == {:ok, rewalked}
  end

  test "max_members_per_group counts seats — active and invited" do
    put_caps(max_members_per_group: 2)
    uid = "github|https://github.com|seat-#{System.unique_integer([:positive])}"
    {:ok, group} = Athanors.create_group(uid, "Seats")
    # creator holds one seat; one invitation fills the second
    assert {:ok, :invited} = Members.add(group, [email: "a-#{uid}@example.com"], uid)

    assert {:error, {:limit_reached, :max_members_per_group, 2}} =
             Members.add(group, [email: "b@example.com"], uid)
  end

  defp active_count do
    {:ok, n} = Athanors.count()
    n
  end
end
