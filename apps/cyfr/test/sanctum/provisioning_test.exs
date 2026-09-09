# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningTest do
  @moduledoc """
  Provisioning turns an athanor row into a working athanor: the bundle
  copied in and registered, the closure pulled, a baseline consent minted
  per executable local component — idempotent, loud on failure, retried.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.{Athanors, Members, Users}

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
    {:ok, [row]} = Arca.ComponentStorage.list_components(in_group, publisher: "local")
    assert row.name == "foo"

    {:ok, [profile]} = Arca.ProfileStorage.list_for_source(group.id, "catalyst:local.foo")
    assert profile.kind == "owner"

    # the mint is attributed to the person who created the group
    {:ok, consent, _refs} = Arca.ConsentStorage.get_head(group.id, profile.id)
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

  test "sync_seeds registers, consents, and collapses pristine copies", %{
    bundle_dir: bundle_dir
  } do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|sync-#{n}"}

    {:ok, group} = Athanors.create_group(ctx.user_id, "Sync #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    # A member edited foo and reverted the edit by hand — a materialized,
    # byte-identical copy that costs quota and no longer tracks releases.
    version_dir = ["components", "catalysts", "local", "foo", "1.0.0"]
    :ok = Arca.put(in_group, version_dir ++ ["scratch.txt"], "x")
    :ok = Arca.delete(in_group, version_dir ++ ["scratch.txt"])
    assert Arca.Overlay.unit_status(in_group, version_dir) == {:ok, :materialized}

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

    assert :ok = Provisioning.sync_seeds()

    # The new component has a row AND a baseline profile — invocable
    # without a human walking every athanor's consent sheet.
    {:ok, rows} =
      Arca.ComponentStorage.list_components(in_group, publisher: "local", limit: :none)

    assert Enum.any?(rows, &(&1.name == "fresh"))

    {:ok, [profile]} = Arca.ProfileStorage.list_for_source(group.id, "catalyst:local.fresh")
    assert profile.kind == "owner"

    # The pristine copy collapsed — the seed serves the unit again.
    assert Arca.Overlay.unit_status(in_group, version_dir) == {:ok, :seed}
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
    {:ok, [profile]} = Arca.ProfileStorage.list_for_source(group.id, "catalyst:local.foo")
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
    refute Map.has_key?(Jason.decode!(group.settings || "{}"), "provisioning_error")
    {:ok, [profile]} = Arca.ProfileStorage.list_for_source(group.id, "catalyst:local.foo")
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
    assert Athanors.settings(group)["provisioning_error"]["step"] == "closure"

    # the seed itself landed; only the closure is missing, and a retry says so again
    {:ok, [_row]} = Arca.ComponentStorage.list_components(in_group, publisher: "local")
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

    # Another caller holds the estate's provisioning lock for the whole
    # test — the shape of two people opening a fresh estate at once.
    parent = self()

    holder =
      spawn_link(fn ->
        Arca.Overlay.UnitLock.with_lock({group.id, :provisioning}, fn ->
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held

    # The attempt the call starts finds the lock held and gives up without
    # touching the database, so nothing outlives this test holding a
    # connection it does not own.
    started = System.monotonic_time(:millisecond)
    assert :ok = Provisioning.start_provisioning(in_group)

    # Nothing waits: the fill is started, never awaited, so a page's mount
    # cannot be held open by whoever else is filling the estate. Generous
    # for a loaded box, and still far below the lock's own 30 s.
    assert System.monotonic_time(:millisecond) - started < 5_000

    # Nothing was provisioned by this caller — the holder never let go.
    {:ok, group} = Athanors.get(group.id)
    refute group.provisioned_at
    send(holder, :release)
  end

  test "an install without a bundle cannot provision" do
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    assert {:ok, group} = Athanors.create_group(ctx.user_id, "No bundle #{n}")
    :ok = Provisioning.start_provisioning(%{ctx | athanor_id: group.id})

    {:ok, group} = Athanors.get(group.id)
    assert group.provisioned_at == nil
    assert Athanors.settings(group)["provisioning_error"]["step"] == "seed"

    assert {:error, {:provisioning_failed, :seed, :bundle_missing}} =
             Provisioning.provision(group, nil)
  end

  test "Compendium.Pull.oci_reference_for refuses local refs and resolves published ones" do
    assert {:error, msg} = Compendium.Pull.oci_reference_for("catalyst:local.foo")
    assert msg =~ "local"

    assert {:ok, ref} = Compendium.Pull.oci_reference_for("catalyst:someone.thing:1.2.3")
    assert ref =~ "someone/catalysts/thing:1.2.3"
    assert {:error, _} = Compendium.Pull.oci_reference_for("nonsense")
  end
end
