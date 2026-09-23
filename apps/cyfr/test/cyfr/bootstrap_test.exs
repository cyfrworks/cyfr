# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BootstrapTest do
  @moduledoc """
  What boot puts right: the operators are the ones
  `CYFR_PLATFORM_ADMIN_EMAILS` names.

  A sign-in reconciles a platform row against that list, but only for
  someone the door still admits — drop an operator from the env list *and*
  from the allowlist and nothing else would ever revoke the row, or the
  session holding its capability.

  And it is a gate: only a checked success lets the boot go on. Every way
  the reconcile can fail — no slot, a claim a peer keeps, a lost slot or
  claim, a malformed list, a person missing behind a grant, a database
  error, a raise, a release that did not land — refuses the boot.
  """
  use ExUnit.Case, async: false

  alias Arca.JobClaims
  alias Sanctum.Tenancy.{Members, Users}

  @control_plane_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    unless tags[:unboxed] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    end

    prev = Application.get_env(:sanctum, :platform_admin_emails, [])
    claim_enabled = Application.get_env(:arca, :control_plane_claim_enabled)
    standing = Map.new(@control_plane_keys, &{&1, :persistent_term.get(&1, :absent)})

    # The suite disables the boot task (a write before any sandbox checkout);
    # these tests are about what it does, so they turn it back on.
    Application.put_env(:cyfr, :provisioning_boot_enabled, true)

    on_exit(fn ->
      Application.put_env(:sanctum, :platform_admin_emails, prev)
      Application.put_env(:cyfr, :provisioning_boot_enabled, false)
      Application.put_env(:arca, :control_plane_claim_enabled, claim_enabled)

      for {key, value} <- standing do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    # `job_claims` is shared, cross-node, node-global state many test
    # files write. Each case here claims under a key of its own and reads
    # back the row it wrote.
    {:ok, key: "cell-boot-#{System.unique_integer([:positive])}"}
  end

  defp operator(n, email) do
    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|ops-#{n}",
        provider: "github",
        email: email,
        verified: true
      })

    {:ok, _} = Members.ensure_platform(user.id)
    user
  end

  defp platform?(user_id) do
    {:ok, rows} = Members.list_by_user(user_id)
    Enum.any?(rows, &(&1.scope == "platform"))
  end

  test "a platform row the env list no longer names loses its scope and its sessions", %{
    key: key
  } do
    n = System.unique_integer([:positive])
    kept = operator(n, "kept#{n}@example.com")
    dropped = operator(n + 1, "dropped#{n}@example.com")

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: dropped.id,
          athanor_id: Sanctum.TestContext.athanor_id(),
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    Application.put_env(:sanctum, :platform_admin_emails, ["kept#{n}@example.com"])
    :ok = Cyfr.Bootstrap.run(key: key)

    assert {:ok, kept_rows} = Members.list_by_user(kept.id)
    assert Enum.any?(kept_rows, &(&1.scope == "platform"))
    assert {:ok, dropped_rows} = Members.list_by_user(dropped.id)
    refute Enum.any?(dropped_rows, &(&1.scope == "platform"))
    assert {:error, _} = Sanctum.Session.load(session.token, surface: :console)
  end

  describe "the claimed job" do
    test "is taken under its own row, records its success, and is given up for the next boot",
         %{key: key} do
      Application.put_env(:sanctum, :platform_admin_emails, [])

      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-a")

      assert {:ok, row} = JobClaims.read("bootstrap", key)
      assert row.owner == "member-a"

      refute JobClaims.live?(row),
             "bootstrap was left claimed, so the next boot waits a lease out"

      assert %{
               "version" => 1,
               "status" => "complete",
               "owner" => "member-a",
               "policy_digest" => _
             } =
               Jason.decode!(row.detail)

      # The seed offer is not this module's: it has a claim of its own.
      assert {:error, :not_found} = JobClaims.read("seed_release", key)
    end

    test "a live peer's claim is waited for, and a peer that keeps it refuses this boot", %{
      key: key
    } do
      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")
      Application.put_env(:sanctum, :platform_admin_emails, [])

      {:ok, peer} = JobClaims.claim("bootstrap", key, "member-b", 60_000)

      began = System.monotonic_time(:millisecond)
      assert {:error, :busy} = Cyfr.Bootstrap.run(key: key, owner: "member-a", wait_ms: 400)
      waited = System.monotonic_time(:millisecond) - began

      # It waited for the holder rather than reconciling beside it, and
      # then refused rather than opening beside a reconcile it did not run.
      assert waited >= 400

      assert {:ok, still_held} = JobClaims.read("bootstrap", key)
      assert still_held.fence == peer.fence
      assert still_held.owner == "member-b"

      assert platform?(dropped.id), "this boot reconciled under a claim a peer held"
    end

    test "a peer that gives the claim up within the wait is followed by this member's own reconcile",
         %{key: key} do
      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")
      Application.put_env(:sanctum, :platform_admin_emails, [])

      {:ok, peer} = JobClaims.claim("bootstrap", key, "member-b", 60_000)
      spawn(fn -> Process.sleep(300) && JobClaims.release(peer) end)

      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-a", wait_ms: 5_000)
      refute platform?(dropped.id)
      assert {:ok, %{owner: "member-a"}} = JobClaims.read("bootstrap", key)
    end

    test "a peer's recorded success is not this member's: every member reconciles", %{key: key} do
      Application.put_env(:sanctum, :platform_admin_emails, [])
      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-b")

      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")

      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-a")
      refute platform?(dropped.id)
    end
  end

  describe "the boot child gates the web tier" do
    # Synchronous initialization must finish before the web tier starts
    # accepting requests.

    test "start_link does its work before returning, and leaves nothing behind" do
      me = self()

      Application.put_env(:sanctum, :platform_admin_emails, [])

      # `:ignore` is the one-shot answer: the work already happened inside
      # `init/1`, so there is no process for the supervisor to hold.
      assert :ignore = Cyfr.Bootstrap.start_link([])

      # Nothing was left linked to this process — a lingering child would mean
      # the work had been handed off rather than completed.
      {:links, links} = Process.info(me, :links)
      assert Enum.all?(links, &Process.alive?/1)
    end

    test "a malformed operator list refuses the boot instead of serving beside it" do
      Process.flag(:trap_exit, true)

      for malformed <- [:not_a_list, ["Ops@Example.com"], [" ops@example.com"], [""], [nil]] do
        Application.put_env(:sanctum, :platform_admin_emails, malformed)

        assert {:error, {:bootstrap_refused, :malformed_configuration}} =
                 Cyfr.Bootstrap.start_link([])
      end
    end

    test "a boot that holds no slot in the cell asks the store nothing, and refuses" do
      Process.flag(:trap_exit, true)
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      assert {:error, {:bootstrap_refused, :slot_not_held}} =
               Arca.Test.QueryCounter.assert_queries(0, fn -> Cyfr.Bootstrap.start_link([]) end)
    end

    test "a member that should hold a slot and has none recorded refuses", %{key: key} do
      Application.put_env(:arca, :control_plane_claim_enabled, true)
      Arca.ControlPlane.forget()
      Arca.ControlPlane.forget_generation()
      Arca.ControlPlane.record(:unclaimed)

      assert {:error, :slot_not_held} = Cyfr.Bootstrap.run(key: key)
    end
  end

  describe "every failure refuses the boot" do
    test "a grant naming a person with no row", %{key: key} do
      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")
      {:ok, _} = Members.create(%{user_id: "usr_ghost#{n}", scope: "platform"})
      Application.put_env(:sanctum, :platform_admin_emails, [])

      assert {:error, :missing_user} = Cyfr.Bootstrap.run(key: key)

      # Nothing committed, and the claim was given back for the next attempt.
      assert platform?(dropped.id)
      assert {:ok, row} = JobClaims.read("bootstrap", key)
      refute JobClaims.live?(row)
      assert row.detail == nil
    end

    test "a claim a peer took while the reconcile ran", %{key: key} do
      reconcile = fn claim, opts ->
        {:ok, _moved} = JobClaims.record(claim, "a peer's write")
        Sanctum.reconcile_platform_admins(claim, opts)
      end

      Application.put_env(:sanctum, :platform_admin_emails, [])
      assert {:error, :claim_taken} = Cyfr.Bootstrap.run(key: key, reconcile: reconcile)
    end

    test "a claim whose lease ran out before the reconcile committed", %{key: key} do
      reconcile = fn claim, opts ->
        Process.sleep(50)
        Sanctum.reconcile_platform_admins(claim, opts)
      end

      Application.put_env(:sanctum, :platform_admin_emails, [])

      assert {:error, :claim_lapsed} =
               Cyfr.Bootstrap.run(key: key, lease_ms: 20, reconcile: reconcile)
    end

    test "a slot lost before the reconcile, or after it but before the boot goes on", %{key: key} do
      slot = hold_slot!()
      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")
      Application.put_env(:sanctum, :platform_admin_emails, [])

      lose_first = fn claim, opts ->
        expire_slot!(slot)
        Sanctum.reconcile_platform_admins(claim, opts)
      end

      assert {:error, :slot_lost} = Cyfr.Bootstrap.run(key: key, reconcile: lose_first)
      assert platform?(dropped.id), "a reconcile under a lost slot committed"

      slot = hold_slot!()

      lose_after = fn claim, opts ->
        result = Sanctum.reconcile_platform_admins(claim, opts)
        take_over_slot!(slot)
        result
      end

      assert {:error, :slot_lost} = Cyfr.Bootstrap.run(key: key <> "-2", reconcile: lose_after)
    end

    test "under a slot this member holds, the reconcile lands", %{key: key} do
      hold_slot!()
      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")
      Application.put_env(:sanctum, :platform_admin_emails, [])

      assert :ok = Cyfr.Bootstrap.run(key: key)
      refute platform?(dropped.id)
    end

    test "a release that does not land", %{key: key} do
      reconcile = fn claim, opts ->
        {:ok, renewed} = Sanctum.reconcile_platform_admins(claim, opts)
        {:ok, _moved} = JobClaims.record(renewed, "a peer's write")
        {:ok, renewed}
      end

      Application.put_env(:sanctum, :platform_admin_emails, [])
      assert {:error, :release_failed} = Cyfr.Bootstrap.run(key: key, reconcile: reconcile)
    end

    test "a database error and any other raise are refusals of their own class", %{key: key} do
      Application.put_env(:sanctum, :platform_admin_emails, [])

      db = fn _claim, _opts -> raise DBConnection.ConnectionError, "connection lost" end
      assert {:error, :database_error} = Cyfr.Bootstrap.run(key: key, reconcile: db)

      # The claim a refusal took is given back, so the next attempt is not
      # held behind a lease nobody uses.
      assert {:ok, row} = JobClaims.read("bootstrap", key)
      refute JobClaims.live?(row)

      for {class, fun} <- [
            exception: fn _claim, _opts -> raise "boom" end,
            exception: fn _claim, _opts -> throw(:boom) end,
            exception: fn _claim, _opts -> exit(:boom) end,
            database_error: fn _claim, _opts -> {:error, :database_error} end
          ] do
        assert {:error, ^class} = Cyfr.Bootstrap.run(key: key, reconcile: fun)
      end

      Process.flag(:trap_exit, true)

      assert {:error, {:bootstrap_refused, :exception}} =
               Cyfr.Bootstrap.start_link(key: key, reconcile: fn _c, _o -> raise "boom" end)
    end

    test "a refusal is logged by its class, with nothing from the failure's own text", %{
      key: key
    } do
      Application.put_env(:sanctum, :platform_admin_emails, [])
      secret = "sk-live-#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :exception} =
                   Cyfr.Bootstrap.run(key: key, reconcile: fn _c, _o -> raise secret end)
        end)

      assert log =~ "security reconcile refused: exception (RuntimeError)"
      refute log =~ secret
    end
  end

  describe "two connections" do
    @describetag :unboxed

    test "a claim that runs out while the reconcile waits for a lock refuses the boot", %{
      key: key
    } do
      alias Ecto.Adapters.SQL.Sandbox
      import Ecto.Query

      n = System.unique_integer([:positive])

      {:ok, user} =
        Sandbox.unboxed_run(Arca.Repo, fn ->
          {:ok, user} =
            Users.upsert_from_provider(%{
              id: "github|https://github.com|lockwait-#{n}",
              provider: "github",
              email: "lockwait#{n}@example.com",
              verified: true
            })

          {:ok, _} = Members.ensure_platform(user.id)
          {:ok, user}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Arca.Repo, fn ->
          Arca.Repo.delete_all(from(m in Arca.Schemas.Membership, where: m.user_id == ^user.id))

          Arca.Repo.delete_all(
            from(i in Arca.Schemas.ExternalIdentity, where: i.user_id == ^user.id)
          )

          Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user.id))
          Arca.Repo.delete_all(from(c in Arca.Schemas.JobClaim, where: c.key == ^key))
        end)
      end)

      Application.put_env(:sanctum, :platform_admin_emails, [])
      test = self()

      # The claim is taken first — on SQLite a claim written behind the
      # holder would start its lease only after the wait — and the
      # reconcile starts once the holder has the lock.
      paused = fn claim, opts ->
        send(test, :claimed)

        receive do
          :go -> Sanctum.reconcile_platform_admins(claim, opts)
        end
      end

      boot =
        Task.async(fn ->
          Sandbox.unboxed_run(Arca.Repo, fn ->
            Cyfr.Bootstrap.run(key: key, lease_ms: 400, reconcile: paused)
          end)
        end)

      assert_receive :claimed, 5_000

      # Holds the person's row (and on SQLite the one write lock) past the
      # claim's lease.
      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Arca.Repo, fn ->
            Arca.Repo.locking_transaction(fn ->
              from(u in Arca.Schemas.User, where: u.id == ^user.id)
              |> Arca.QueryHelpers.for_update()
              |> Arca.Repo.one()

              send(test, :holding)

              receive do
                :commit -> :ok
              end
            end)
          end)
        end)

      assert_receive :holding, 5_000
      send(boot.pid, :go)

      refute Task.yield(boot, 200)
      Process.sleep(500)
      send(holder.pid, :commit)
      assert {:ok, :ok} = Task.await(holder, 25_000)
      assert {:error, :claim_lapsed} = Task.await(boot, 25_000)

      # Nothing the reconcile decided before its wait was committed.
      assert Sandbox.unboxed_run(Arca.Repo, fn ->
               {:ok, rows} = Members.list_by_user(user.id)
               Enum.any?(rows, &(&1.scope == "platform"))
             end)
    end
  end

  # A slot this member holds, written as the claimant writes it.
  defp hold_slot! do
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-boot-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, "boot-#{node}", 60_000)
    slot
  end

  defp expire_slot!(slot) do
    import Ecto.Query
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
        set: [lease_until: past]
      )

    :ok
  end

  defp take_over_slot!(slot) do
    import Ecto.Query

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^slot.node),
        set: [owner: "successor", generation: slot.generation + 1]
      )

    :ok
  end
end
