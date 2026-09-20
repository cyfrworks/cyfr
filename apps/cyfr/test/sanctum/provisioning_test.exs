# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningTest do
  @moduledoc """
  Provisioning turns an athanor row into a working athanor: the bundle
  copied in and registered, the closure pulled, a baseline consent minted
  per executable local component — idempotent, loud on failure, retried.
  """
  use ExUnit.Case, async: false

  alias Arca.ProvisioningClaims, as: Claims
  alias Compendium.Provisioning, as: Filler
  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  # Another attempt — another boot's — holding the estate's claim.
  defp held_elsewhere!(athanor_id, entry_kind \\ "first_need") do
    actor = %Cyfr.Actor{athanor_id: athanor_id}
    {:ok, claim} = Claims.claim(actor, "boot_elsewhere/own_held", entry_kind, 60_000)
    claim
  end

  @valid_wasm File.read!(Path.join([File.cwd!(), "test/support/test_wasm/math.wasm"]))

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_provisioning_#{:rand.uniform(100_000)}")
    seed_dir = Path.join(test_dir, "seed")
    bundle_dir = Path.join(seed_dir, "components")
    File.mkdir_p!(bundle_dir)
    # Provisioning also copies the AQUA template out of the seed tree.
    File.cp_r!(Path.expand("../../../../seed/aqua", __DIR__), Path.join(seed_dir, "aqua"))
    prev_base = Application.get_env(:cyfr, :base_path)
    prev_seed = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)

    # The registry is unreachable in this suite: a bundle that needs a pull
    # cannot be provisioned, which is the failure path under test.
    prev_registry = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)

      if prev_registry,
        do: Application.put_env(:cyfr, :registry_url, prev_registry),
        else: Application.delete_env(:cyfr, :registry_url)

      File.rm_rf!(test_dir)
    end)

    {:ok, bundle_dir: bundle_dir}
  end

  # A bundled catalyst with no published dependencies.
  defp write_bundle!(bundle_dir, opts \\ []) do
    src = Path.join([bundle_dir, "catalysts", "local", "foo", "1.0.0"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "catalyst.wasm"), @valid_wasm)

    manifest =
      %{
        "name" => "foo",
        "version" => "1.0.0",
        "type" => "catalyst",
        "caps" => %{"egress" => %{"domains" => []}}
      }
      |> maybe_deps(Keyword.get(opts, :deps))

    File.write!(Path.join(src, "cyfr-manifest.json"), Jason.encode!(manifest))
    :ok
  end

  defp maybe_deps(manifest, nil), do: manifest
  defp maybe_deps(manifest, deps), do: Map.put(manifest, "dependencies", %{"static" => deps})

  defp person(n) do
    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|prov-#{n}",
        provider: "github",
        email: "prov#{n}@example.com",
        verified: true,
        name: "Prov #{n}"
      })

    user
  end

  test "a group is filled at first need: seeded, registered, consented, marked",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    # The mint is a row and a seat — no registry round trip, so opening a
    # chat with someone cannot fail on the network.
    assert {:ok, group} = Athanors.create_group(ctx.user_id, "Provisioned #{n}")
    refute group.provisioned_at
    assert Members.member?(ctx.user_id, group.id)

    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)
    {:ok, group} = Athanors.get(group.id)
    assert group.provisioned_at

    {:ok, [row]} =
      Arca.ComponentStorage.list_components(Sanctum.Context.actor(in_group), publisher: "local")

    assert row.name == "foo"

    {:ok, [profile]} =
      Arca.ProfileStorage.list_for_source(Cyfr.Actor.in_athanor(group.id), "catalyst:local.foo")

    assert profile.kind == "owner"

    # the mint is attributed to the person who created the group
    {:ok, consent, _refs} =
      Arca.ConsentStorage.get_head(Cyfr.Actor.in_athanor(group.id), profile.id)

    assert consent.granted_by == ctx.user_id

    # provisioning again is a no-op
    assert {:ok, %{provisioned_at: at}} = Provisioning.provision(group, in_group)
    assert at == group.provisioned_at
  end

  test "a person's own athanor is minted once, under their namespace when it is free, and recorded",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    user = person(n)
    {:ok, user} = Users.set_namespace(user, "prov#{n}")

    assert {:ok, personal} = Provisioning.ensure_personal_athanor(user)
    assert personal.kind == "person"
    assert personal.slug == "prov#{n}"
    assert personal.owner_user_id == user.id
    assert personal.name == "Prov #{n}"

    # The mint answers with the row; filling it is background work, so the
    # mark is on the row rather than on what the mint returned.
    assert {:ok, %{provisioned_at: %DateTime{}}} = Athanors.get(personal.id)
    assert Members.member?(user.id, personal.id)
    assert {:ok, %{personal_athanor_id: pid}} = Users.get(user.id)
    assert pid == personal.id

    # a second sign-in finds it
    assert {:ok, %{id: same}} = Provisioning.after_sign_in(user.id)
    assert same == personal.id
    assert [_] = Enum.filter(Athanors.list_for_user(user.id), &(&1.kind == "person"))
  end

  test "a person without a namespace is minted one under a slug of their own", %{
    bundle_dir: bundle_dir
  } do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    user = person(n)

    assert {:ok, personal} = Provisioning.after_sign_in(user.id)
    assert personal.kind == "person"
    assert personal.slug == "prov-#{n}"
    assert personal.owner_user_id == user.id
    assert {:ok, %{personal_athanor_id: pid}} = Users.get(user.id)
    assert pid == personal.id

    # A namespace recorded later is a credential, not a new address.
    {:ok, user} = Users.set_namespace(user, "late#{n}")
    assert {:ok, %{id: same, slug: slug}} = Provisioning.ensure_personal_athanor(user)
    assert same == personal.id
    assert slug == "prov-#{n}"
  end

  test "a namespace another person's athanor already holds is not a refusal, just not the address",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    first = person(n)
    assert {:ok, %{slug: taken}} = Provisioning.ensure_personal_athanor(first)
    assert taken == "prov-#{n}"

    # The second person's namespace is the first person's address here.
    second = person(n + 1)
    {:ok, second} = Users.set_namespace(second, "prov-#{n}")
    assert {:ok, other} = Provisioning.ensure_personal_athanor(second)
    assert other.owner_user_id == second.id
    assert other.slug == "prov-#{n + 1}"
  end

  test "a fill lays every folder of the tree, and a boot sync lays a missing one again", %{
    bundle_dir: bundle_dir
  } do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|roots-#{n}"}

    {:ok, group} = Athanors.create_group(ctx.user_id, "Roots #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    {:ok, entries} = Arca.list_typed(Sanctum.Context.actor(in_group), [])

    assert Enum.sort(entries) ==
             Enum.sort(for root <- Arca.Storage.tenant_roots(), do: {root, :dir})

    :ok = Arca.delete_tree(Sanctum.Context.actor(in_group), ["notes"])
    assert :ok = Filler.sync_seeds()
    assert {:ok, [_ | _] = healed} = Arca.list_typed(Sanctum.Context.actor(in_group), [])
    assert {"notes", :dir} in healed
  end

  test "sync_seeds leaves the athanor's copies alone; what a release adds is pulled, not pushed",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|sync-#{n}"}

    {:ok, group} = Athanors.create_group(ctx.user_id, "Sync #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    # A member edited their copy of foo.
    version_dir = ["components", "catalysts", "local", "foo", "1.0.0"]
    :ok = Arca.put(Sanctum.Context.actor(in_group), version_dir ++ ["scratch.txt"], "x")
    assert {:ok, true} = Arca.Overlay.edited?(Sanctum.Context.actor(in_group), version_dir)

    # The next release ships a second bundled catalyst.
    src = Path.join([bundle_dir, "catalysts", "local", "fresh", "1.0.0"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "catalyst.wasm"), @valid_wasm)

    File.write!(
      Path.join(src, "cyfr-manifest.json"),
      Jason.encode!(%{
        "name" => "fresh",
        "version" => "1.0.0",
        "type" => "catalyst",
        "caps" => %{"egress" => %{"domains" => []}}
      })
    )

    assert :ok = Filler.sync_seeds()

    # The edit survives the release, and the new catalyst is only offered.
    assert Arca.Overlay.unit_status(Sanctum.Context.actor(in_group), version_dir) ==
             {:ok, :shipped}

    assert {:ok, "x"} = Arca.get(Sanctum.Context.actor(in_group), version_dir ++ ["scratch.txt"])

    fresh_dir = ["components", "catalysts", "local", "fresh", "1.0.0"]

    assert Arca.Overlay.unit_status(Sanctum.Context.actor(in_group), fresh_dir) ==
             {:ok, :available}

    {:ok, rows} =
      Arca.ComponentStorage.list_components(Sanctum.Context.actor(in_group),
        publisher: "local",
        limit: :none
      )

    refute Enum.any?(rows, &(&1.name == "fresh"))

    # Pulling it gives the athanor a row AND a baseline profile — invocable
    # without a human walking the consent sheet.
    assert {:ok, %{component_ref: "catalyst:local.fresh:1.0.0"}} =
             Filler.install_shipped(in_group, "catalyst:local.fresh")

    assert Arca.Overlay.unit_status(Sanctum.Context.actor(in_group), fresh_dir) == {:ok, :shipped}

    {:ok, rows} =
      Arca.ComponentStorage.list_components(Sanctum.Context.actor(in_group),
        publisher: "local",
        limit: :none
      )

    assert Enum.any?(rows, &(&1.name == "fresh"))

    {:ok, [profile]} =
      Arca.ProfileStorage.list_for_source(Cyfr.Actor.in_athanor(group.id), "catalyst:local.fresh")

    assert profile.kind == "owner"
  end

  test "installing a shipped component twice succeeds: its consent is already minted",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|twice-#{n}"}
    {:ok, group} = Athanors.create_group(ctx.user_id, "Twice #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    assert {:ok, %{component_ref: ref}} =
             Filler.install_shipped(in_group, "catalyst:local.foo")

    # The walk skips it as `:already_bootstrapped` the second time. That is
    # not this install failing — the consent it asked for is there.
    assert {:ok, %{component_ref: ^ref}} =
             Filler.install_shipped(in_group, "catalyst:local.foo")
  end

  test "an install refuses at once while another filler holds the claim, rather than queueing",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|busy-#{n}"}
    {:ok, group} = Athanors.create_group(ctx.user_id, "Busy #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    held = held_elsewhere!(group.id, "seed_sync")

    # A boot's sync waits 30s for a held estate. This must answer well inside it.
    {elapsed_us, result} =
      :timer.tc(fn -> Filler.install_shipped(in_group, "catalyst:local.foo") end)

    assert result == {:error, :provisioning_busy}
    assert elapsed_us < 5_000_000

    # The holder's claim is as it was, and once it lets go the install runs
    # — and gives the claim back with no verdict on readiness.
    actor = %Cyfr.Actor{athanor_id: group.id}
    assert {:ok, %{outcome: nil, fence: fence}} = Claims.current(actor)
    assert fence == held.fence
    :ok = Claims.release(actor, held.owner, held.fence)

    assert {:ok, _} = Filler.install_shipped(in_group, "catalyst:local.foo")

    assert {:ok, %{entry_kind: "install_shipped", outcome: "released"}} = Claims.current(actor)
  end

  test "with no registry, a bundle whose OPTIONAL dependency is not installed still provisions",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir,
      deps: [%{"ref" => "catalyst:someone.elsewhere", "optional" => true}]
    )

    previous = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:cyfr, :registry_url),
        else: Application.put_env(:cyfr, :registry_url, previous)
    end)

    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    assert {:ok, group} = Athanors.create_group(ctx.user_id, "Offline #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    {:ok, group} = Athanors.get(group.id)
    assert group.provisioned_at

    {:ok, [profile]} =
      Arca.ProfileStorage.list_for_source(Cyfr.Actor.in_athanor(group.id), "catalyst:local.foo")

    assert profile.kind == "owner"
  end

  test "with a registry that does not answer, an OPTIONAL dependency is left out and the estate still provisions",
       %{bundle_dir: bundle_dir} do
    # The suite's registry host is a closed port: configured, unreachable.
    assert Compendium.RegistryHost.configured?()

    write_bundle!(bundle_dir,
      deps: [%{"ref" => "catalyst:someone.elsewhere", "optional" => true}]
    )

    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    assert {:ok, group} = Athanors.create_group(ctx.user_id, "Unreachable #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    {:ok, group} = Athanors.get(group.id)
    assert group.provisioned_at
    refute Athanors.provisioning_failure(group)

    {:ok, [profile]} =
      Arca.ProfileStorage.list_for_source(Cyfr.Actor.in_athanor(group.id), "catalyst:local.foo")

    assert profile.kind == "owner"
  end

  test "a bundle whose closure cannot be pulled leaves the athanor unprovisioned, loudly, and retries",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir, deps: ["catalyst:someone.elsewhere"])
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    parent = self()
    handler = "prov-test-#{n}"

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :provisioning, :failed],
      fn _e, _m, meta, _c -> send(parent, {:failed, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The mint answers a bare row; the failure surfaces at first need.
    assert {:ok, group} = Athanors.create_group(ctx.user_id, "Unpullable #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    assert_receive {:failed, %{step: :closure, athanor_id: id}}
    assert id == group.id
    {:ok, group} = Athanors.get(group.id)
    assert group.provisioned_at == nil
    assert %{step: "closure"} = Athanors.provisioning_failure(group)

    # the seed itself landed; only the closure is missing, and a retry says so again
    {:ok, [_row]} =
      Arca.ComponentStorage.list_components(Sanctum.Context.actor(in_group), publisher: "local")

    assert {:error, {:provisioning_failed, :closure, _}} = Provisioning.provision(group, in_group)
  end

  test "a first need never waits on the caller already filling the estate" do
    # The suite runs provisioning inline so its assertions can read rows
    # straight after the call; this one is about the real path, where the
    # fill is a task and the caller does not await it.
    Application.put_env(:cyfr, :provisioning_inline, false)
    on_exit(fn -> Application.put_env(:cyfr, :provisioning_inline, true) end)

    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}
    {:ok, group} = Athanors.create_group(ctx.user_id, "Held #{n}")
    in_group = %{ctx | athanor_id: group.id}

    # Another caller is already filling this estate — the shape of two
    # people opening a fresh one at once. A reader that finds the claim
    # held starts nothing, so no fill this test never awaits reaches the
    # database without the connection the test owns.
    held_elsewhere!(group.id)

    started = System.monotonic_time(:millisecond)
    assert :ok = Provisioning.start_provisioning(in_group)

    # Nothing waits: the fill is started, never awaited, so a page's mount
    # cannot be held open by whoever else is filling the estate. Generous
    # for a loaded box, and still far below the lock's own 30 s.
    assert System.monotonic_time(:millisecond) - started < 5_000

    # Nothing was provisioned by this caller — the holder never let go.
    {:ok, group} = Athanors.get(group.id)
    refute group.provisioned_at
  end

  test "an install without a bundle cannot provision" do
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    assert {:ok, group} = Athanors.create_group(ctx.user_id, "No bundle #{n}")
    :ok = Provisioning.start_provisioning(%{ctx | athanor_id: group.id})

    {:ok, group} = Athanors.get(group.id)
    assert group.provisioned_at == nil
    assert %{step: "seed"} = Athanors.provisioning_failure(group)

    assert {:error, {:provisioning_failed, :seed, :bundle_missing}} =
             Provisioning.provision(group, nil)
  end

  describe "an attempt whose claim a later attempt took" do
    # An attempt that lost its lease mid-fill, and its successor: the first
    # claim's lease runs out, the second takes the estate at the next fence.
    defp overtaken!(athanor_id) do
      actor = %Cyfr.Actor{athanor_id: athanor_id}
      {:ok, stale} = Claims.claim(actor, "boot_elsewhere/own_stale", "first_need", 1)
      Cyfr.Test.Wait.wait_until(fn -> not Claims.live?(stale) end, 2_000, "the lease to run out")
      {:ok, successor} = Claims.claim(actor, "boot_elsewhere/own_successor", "provision", 60_000)
      assert successor.fence == stale.fence + 1
      {actor, stale, successor}
    end

    test "marks no readiness, mints no consent and replaces no agent index", %{
      bundle_dir: bundle_dir
    } do
      write_bundle!(bundle_dir)
      n = System.unique_integer([:positive])
      ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|stale-#{n}"}
      {:ok, group} = Athanors.create_group(ctx.user_id, "Stale #{n}")
      in_group = %{ctx | athanor_id: group.id}
      {actor, stale, successor} = overtaken!(group.id)

      # The whole fill would succeed — the same bundle fills a group in the
      # first test of this module. Run under the claim it lost, it is told
      # the estate is another attempt's, in progress.
      assert {:error, :provisioning_busy} = Filler.fill(stale, group, in_group)

      {:ok, row} = Athanors.get(group.id)
      refute row.provisioned_at
      refute Athanors.provisioning_failure(row)

      assert {:ok, []} =
               Arca.ProfileStorage.list_for_source(
                 Cyfr.Actor.in_athanor(group.id),
                 "catalyst:local.foo"
               )

      assert {:ok, []} = Arca.AgentStorage.list(Cyfr.Actor.in_athanor(group.id))

      # The mint refuses the lost claim on its own, whoever calls it.
      assert {:error, :claim_lost} = Sanctum.Consent.Bootstrap.run(in_group, stale)

      assert {:ok, []} =
               Arca.ProfileStorage.list_for_source(
                 Cyfr.Actor.in_athanor(group.id),
                 "catalyst:local.foo"
               )

      # The successor's claim is as it took it, and its own fill lands.
      assert {:ok, %{owner: owner, fence: fence, outcome: nil}} = Claims.current(actor)
      assert {owner, fence} == {successor.owner, successor.fence}

      assert {:ok, %{provisioned_at: %DateTime{}}} = Filler.fill(successor, group, in_group)
      assert {:ok, %{outcome: "ready"}} = Claims.current(actor)

      assert {:ok, [_profile]} =
               Arca.ProfileStorage.list_for_source(
                 Cyfr.Actor.in_athanor(group.id),
                 "catalyst:local.foo"
               )

      assert {:ok, [_ | _]} = Arca.AgentStorage.list(Cyfr.Actor.in_athanor(group.id))

      # Settled, the late one is still stale: it cannot turn ready to failed.
      assert :stale = Claims.settle(actor, stale.owner, stale.fence, "failed", "late")
      assert {:ok, %{outcome: "ready"}} = Claims.current(actor)
    end

    test "records no failure over its successor's" do
      # No bundle: the attempt fails at the seed step, and would record it.
      n = System.unique_integer([:positive])
      ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|stalefail-#{n}"}
      {:ok, group} = Athanors.create_group(ctx.user_id, "Stale failure #{n}")
      in_group = %{ctx | athanor_id: group.id}
      {actor, stale, successor} = overtaken!(group.id)

      # The successor fails first, and says where.
      assert {:error, {:provisioning_failed, :seed, :bundle_missing}} =
               Filler.fill(successor, group, in_group)

      {:ok, failed} = Athanors.get(group.id)
      assert %{step: "seed", at: recorded_at} = Athanors.provisioning_failure(failed)

      # The late attempt fails the same way and writes nothing over it.
      assert {:error, :provisioning_busy} = Filler.fill(stale, group, in_group)

      {:ok, after_late} = Athanors.get(group.id)
      assert Athanors.provisioning_failure(after_late).at == recorded_at

      assert {:ok, %{owner: owner, fence: fence, outcome: "failed"}} = Claims.current(actor)
      assert {owner, fence} == {successor.owner, successor.fence}
    end
  end

  test "a boot's seed sync waits for a held estate, then heals it once the holder settles",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|syncwait-#{n}"}
    {:ok, group} = Athanors.create_group(ctx.user_id, "Sync wait #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)
    assert {:ok, %{provisioned_at: %DateTime{}}} = Athanors.get(group.id)

    # Something for the sync to heal, and another attempt holding the estate.
    :ok = Arca.delete_tree(Sanctum.Context.actor(in_group), ["notes"])
    actor = %Cyfr.Actor{athanor_id: group.id}
    held = held_elsewhere!(group.id, "install_shipped")

    sync = Task.async(fn -> Filler.sync_seeds() end)

    # It waits rather than refusing or walking the estate beside the holder.
    assert Task.yield(sync, 750) == nil
    assert {:ok, entries} = Arca.list_typed(Sanctum.Context.actor(in_group), [])
    refute {"notes", :dir} in entries
    assert {:ok, %{owner: owner, outcome: nil}} = Claims.current(actor)
    assert owner == held.owner

    # The holder settles; the sync takes the estate and proceeds.
    :ok = Claims.release(actor, held.owner, held.fence)
    assert :ok = Task.await(sync, 30_000)

    assert {:ok, healed} = Arca.list_typed(Sanctum.Context.actor(in_group), [])
    assert {"notes", :dir} in healed

    assert {:ok, %{entry_kind: "seed_sync", outcome: "released", fence: fence}} =
             Claims.current(actor)

    assert fence == held.fence + 1
  end

  test "provisioned_at records the fill and nothing else: no claim's outcome stands in for it",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|init-#{n}"}
    {:ok, group} = Athanors.create_group(ctx.user_id, "Init #{n}")
    in_group = %{ctx | athanor_id: group.id}
    actor = %Cyfr.Actor{athanor_id: group.id}

    # A claim that reads `ready` on an estate the row does not mark filled
    # makes nothing ready.
    {:ok, claim} = Claims.claim(actor, "boot_elsewhere/own_said_so", "provision", 60_000)
    :ok = Claims.settle(actor, claim.owner, claim.fence, "ready", nil)
    refute Provisioning.provisioned?(in_group)
    assert Provisioning.status(in_group) == :unfilled

    # The fill marks it, once.
    assert {:error, :not_provisioned} = Provisioning.ready(in_group)
    assert {:ok, %{provisioned_at: %DateTime{} = at}} = Athanors.get(group.id)
    assert :ok = Provisioning.ready(in_group)
    assert Provisioning.status(in_group) == :ready

    # What follows on the claim — an install released, a sync released, a
    # claim settled failed — moves neither the mark nor the estate's standing.
    assert {:ok, _} = Filler.install_shipped(in_group, "catalyst:local.foo")
    assert :ok = Filler.sync_seeds()
    {:ok, later} = Claims.claim(actor, "boot_elsewhere/own_later", "provision", 60_000)
    :ok = Claims.settle(actor, later.owner, later.fence, "failed", "seed: :whatever")

    assert {:ok, %{provisioned_at: ^at}} = Athanors.get(group.id)
    assert :ok = Provisioning.ready(in_group)
    assert Provisioning.status(in_group) == :ready
  end

  test "Compendium.Pull.oci_reference_for refuses local refs and resolves published ones" do
    assert {:error, msg} = Compendium.Pull.oci_reference_for("catalyst:local.foo")
    assert msg =~ "local"

    assert {:ok, ref} = Compendium.Pull.oci_reference_for("catalyst:someone.thing:1.2.3")
    assert ref =~ "someone/catalysts/thing:1.2.3"
    assert {:error, _} = Compendium.Pull.oci_reference_for("nonsense")
  end
end
