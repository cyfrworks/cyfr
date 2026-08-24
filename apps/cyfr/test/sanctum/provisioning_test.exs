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
    bundle_dir = Path.join(test_dir, "bundle")
    File.mkdir_p!(bundle_dir)
    prev_base = Application.get_env(:cyfr, :base_path)
    prev_bundle = Application.get_env(:cyfr, :bundle_path)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :bundle_path, bundle_dir)

    # The registry is unreachable in this suite: a bundle that needs a pull
    # cannot be provisioned, which is the failure path under test.
    prev_registry = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :bundle_path, prev_bundle)

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

  test "a group is provisioned when created: seeded, registered, consented, marked",
       %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    assert {:ok, group} = Provisioning.ensure_group_athanor(ctx, "Provisioned #{n}")
    assert group.provisioned_at
    assert Members.member?(ctx.user_id, group.id)

    in_group = %{ctx | athanor_id: group.id}
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

  test "a person's own athanor is minted once, from their namespace, and recorded",
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
    assert personal.provisioned_at
    assert Members.member?(user.id, personal.id)
    assert {:ok, %{personal_athanor_id: pid}} = Users.get(user.id)
    assert pid == personal.id

    # a second sign-in finds it
    assert {:ok, %{id: same}} = Provisioning.after_sign_in(user.id)
    assert same == personal.id
    assert [_] = Enum.filter(Athanors.list_for_user(user.id), &(&1.kind == "person"))
  end

  test "a person without a namespace yet is pending, not minted" do
    user = person(System.unique_integer([:positive]))
    assert :pending = Provisioning.after_sign_in(user.id)
    assert {:error, :no_namespace} = Provisioning.ensure_personal_athanor(user)
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

    # The row is answered even so — the group exists; the failure rides on it.
    assert {:ok, group} = Provisioning.ensure_group_athanor(ctx, "Unpullable #{n}")

    assert_receive {:failed, %{step: :closure, athanor_id: id}}
    assert id == group.id
    assert group.provisioned_at == nil
    assert Athanors.settings(group)["provisioning_error"]["step"] == "closure"

    # the seed itself landed; only the closure is missing, and a retry says so again
    in_group = %{ctx | athanor_id: group.id}
    {:ok, [_row]} = Arca.ComponentStorage.list_components(in_group, publisher: "local")
    assert {:error, {:provisioning_failed, :closure, _}} = Provisioning.provision(group, in_group)
  end

  test "an install without a bundle cannot provision" do
    n = System.unique_integer([:positive])
    ctx = %{Sanctum.TestContext.local() | user_id: "github|https://github.com|creator-#{n}"}

    assert {:ok, group} = Provisioning.ensure_group_athanor(ctx, "No bundle #{n}")
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
