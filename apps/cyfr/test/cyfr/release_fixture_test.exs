# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseFixtureTest do
  @moduledoc """
  The release proofs' fixture (`tests/release-boot/fixture.exs`), evaluated
  as `bin/cyfr rpc` evaluates it inside a release: its `person` command
  makes the installation's first person by the setup admission of an
  account published at the deployment's directory, their setup device
  paired in it and their name recorded, and every later one by the open
  admission, held to its caps; a person made before is signed in again
  under the key their admission listed, and every person's session stands
  past the freshness bound on a public home; a setup device's record
  already kept where it runs is the device a first person made again is
  paired with; and `device_confirm` confirms a record by that device's
  answer to this CYFR's request, and refuses one made wrong on purpose.
  """

  # The setup token the fixture puts for its call, the pinned directory,
  # the directory client's seam, the door, the caps, the access mode and
  # the working directory the fixture keeps its setup device's record in
  # are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DirectoryHead, PersonIdentity, User}
  alias Prima.Identity.Entry
  alias Sanctum.Test.DirectoryServer

  @fixture Path.expand("../../../../tests/release-boot/fixture.exs", __DIR__)

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Cyfr.Test.Sandbox.setup!(tags)

    # The deployment's directory, a scripted one the fixture publishes
    # each account at.
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    directory = DirectoryServer.start!(tls)
    Sanctum.Test.Newcomers.directory!(directory.url)

    # The installation holds no person inside this test's transaction,
    # whatever the suite committed: the fixture's first person is setup's.
    Arca.Repo.delete_all(User)

    # The fixture keeps its setup device's record in the working directory,
    # as a release cell's: each test's own, never the checkout.
    dir = Path.join(System.tmp_dir!(), "release_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = File.cwd!()

    on_exit(fn ->
      File.cd!(original)
      File.rm_rf!(dir)
    end)

    File.cd!(dir)

    {fixture, _bindings} = Code.eval_file(@fixture)
    %{fixture: fixture, dir: dir, directory: directory}
  end

  defp person!(fixture, email, sub) do
    "FIXTURE=" <> json = fixture.(["person", email, sub])
    Jason.decode!(json)
  end

  test "person makes the first person by setup, and a later one with an open admission's rows",
       %{fixture: fixture} do
    first = person!(fixture, "first@example.com", "fixture-first")
    assert Sanctum.Tenancy.platform_admin?(first["user_id"])

    assert %PersonIdentity{identifier: "per_" <> _} =
             Arca.Repo.get_by!(PersonIdentity, user_id: first["user_id"])

    assert {:ok, %{namespace: "release-proof"}} = Sanctum.Tenancy.Users.get(first["user_id"])

    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    second = person!(fixture, "second@example.com", "fixture-second")

    refute second["user_id"] == first["user_id"]
    assert {:ok, %{admission: "open"}} = Sanctum.Tenancy.Users.get(second["user_id"])
    refute Sanctum.Tenancy.platform_admin?(second["user_id"])

    assert {:ok, %{owner_user_id: owner}} =
             Sanctum.Tenancy.Athanors.get(second["athanor_id"])

    assert owner == second["user_id"]

    # Signed in again, the identity names the person made first.
    assert person!(fixture, "second@example.com", "fixture-second")["user_id"] ==
             second["user_id"]
  end

  test "the first person signs in again under their setup device's key, in a new session",
       %{fixture: fixture} do
    first = person!(fixture, "first@example.com", "fixture-first")
    again = person!(fixture, "first@example.com", "fixture-first")

    assert again["user_id"] == first["user_id"]
    refute again["token"] == first["token"]

    for person <- [first, again] do
      assert {:ok, %{user_id: user_id}} = Sanctum.Caller.establish({:session, person["token"]})
      assert user_id == first["user_id"]
    end
  end

  test "each account is published at the deployment's directory, and its person's session stands past the freshness bound on a public home",
       %{fixture: fixture, directory: directory} do
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)
    first = person!(fixture, "first@example.com", "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    second = person!(fixture, "second@example.com", "fixture-second")

    for person <- [first, second] do
      identifier = Arca.Repo.get_by!(PersonIdentity, user_id: person["user_id"]).identifier

      assert [%Entry{kind: :genesis}, %Entry{kind: :add_key}] =
               DirectoryServer.log(directory.dir, identifier)

      # The cached head an hour old, far past the bound: the session
      # stands on the head read again from the directory.
      assert {1, _} =
               Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
                 set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -3600, :second)]
               )

      assert {:ok, %{user_id: user_id}} = Sanctum.Caller.establish({:session, person["token"]})
      assert user_id == person["user_id"]

      assert {:ok, %{fresh: true}} =
               Arca.DirectoryHeads.fresh(Prima.Actor.system(), identifier, 300)
    end
  end

  test "a first person made again where the setup device's record is kept is enrolled with that device; a record of another home refuses",
       %{fixture: fixture, dir: dir} do
    path = Path.join(dir, "setup-device.json")
    seed = :crypto.strong_rand_bytes(32)
    {device_key, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

    kept = %{
      "seed" => Base.url_encode64(seed, padding: false),
      "client_id" => Prima.UUID7.generate_id("pcl"),
      "athanor_id" => Prima.UUID7.generate_id("ath"),
      "home" => Sanctum.origin(),
      "certificate" => %{}
    }

    File.write!(path, Jason.encode!(kept))
    first = person!(fixture, "first@example.com", "fixture-first")

    assert {:ok, [%{id: client_id, device_public_key: ^device_key}]} =
             Arca.PairedClients.list(Prima.Actor.system(),
               user_id: first["user_id"],
               standing: :active
             )
             |> then(fn {:ok, rows} ->
               {:ok, Enum.filter(rows, &(&1.holder_kind == "software"))}
             end)

    assert client_id == kept["client_id"]

    # Written back with the certificate the enrollment issued, the seed and
    # the client as they were.
    written = path |> File.read!() |> Jason.decode!()

    assert Map.take(written, ~w(seed client_id home)) ==
             Map.take(kept, ~w(seed client_id home))

    assert written["certificate"]["client_id"] == client_id

    # The athanor is the one the admission made now.
    assert {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(first["user_id"])
    assert written["athanor_id"] == athanor_id

    Arca.Repo.delete_all(User)
    File.write!(path, Jason.encode!(%{kept | "home" => "https://another.example"}))

    assert_raise RuntimeError, ~r/names no device of this home's setup/, fn ->
      fixture.(["person", "again@example.com", "fixture-again"])
    end
  end

  test "device_confirm confirms a record by the setup device's answer, and refuses one made wrong",
       %{fixture: fixture} do
    first = person!(fixture, "first@example.com", "fixture-first")
    {:ok, ctx} = Sanctum.Caller.establish({:session, first["token"]})

    asked = fn ->
      {:error, {:confirmation_required, %{id: id}}} =
        Sanctum.Consent.Authz.check(ctx, :credential_entry, %{
          operation: "vault.create",
          arguments: %{"name" => "fixture"},
          resource: "fixture"
        })

      Prima.Confirmation.ref(id)
    end

    for tamper <- ["digest", "ref", "key"] do
      ref = asked.()
      "FIXTURE=" <> json = fixture.(["device_confirm", ref, tamper])
      assert %{"error" => _refused, "operation" => "vault.create"} = Jason.decode!(json), tamper

      assert {:ok, %{state: "pending"}} =
               Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
    end

    ref = asked.()
    "FIXTURE=" <> json = fixture.(["device_confirm", ref])
    assert %{"ok" => %{"state" => "confirmed"}, "digest" => digest} = Jason.decode!(json)

    assert {:ok, %{digest: ^digest}} =
             Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
  end

  test "a later person is held to the open admission's cap, and none is made past it",
       %{fixture: fixture} do
    _first = person!(fixture, "first@example.com", "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    Cyfr.Test.Settings.put("max_athanors", 1)

    assert_raise MatchError, ~r/limit_reached/, fn ->
      fixture.(["person", "capped@example.com", "fixture-capped"])
    end

    assert Arca.Repo.aggregate(User, :count) == 1
  end
end
