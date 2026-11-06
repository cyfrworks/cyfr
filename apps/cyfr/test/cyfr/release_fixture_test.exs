# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseFixtureTest do
  @moduledoc """
  The release proofs' fixture (`tests/release-boot/fixture.exs`), evaluated
  as `bin/cyfr rpc` evaluates it inside a release: its `person` command
  makes the installation's first person by the setup admission, their
  enrollment finished with no network and their name recorded, and every
  later one with the rows an open admission writes, held to the open
  admission's caps; a setup device's record already kept where it runs is
  the device a first person made again is enrolled with.
  """

  # The setup token the fixture puts for its call, the pinned directory,
  # the door, the caps and the working directory the fixture keeps its
  # setup device's record in are process-wide.
  use ExUnit.Case, async: false

  alias Arca.Schemas.{PersonIdentity, User}

  @fixture Path.expand("../../../../tests/release-boot/fixture.exs", __DIR__)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.Test.Newcomers.directory!()

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
    %{fixture: fixture, dir: dir}
  end

  defp person!(fixture, email, sub) do
    "FIXTURE=" <> json = fixture.(["person", email, sub])
    Jason.decode!(json)
  end

  test "person makes the first person by setup, and a later one with an open admission's rows",
       %{fixture: fixture} do
    first = person!(fixture, "first@example.com", "fixture-first")
    assert Sanctum.Tenancy.platform_admin?(first["user_id"])

    assert %PersonIdentity{enrollment: "enrolled", identifier: "per_" <> _} =
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

    assert Map.take(written, ~w(seed client_id athanor_id home)) ==
             Map.delete(kept, "certificate")

    assert written["certificate"]["client_id"] == client_id

    Arca.Repo.delete_all(User)
    File.write!(path, Jason.encode!(%{kept | "home" => "https://another.example"}))

    assert_raise RuntimeError, ~r/names no device of this home's setup/, fn ->
      fixture.(["person", "again@example.com", "fixture-again"])
    end
  end

  test "a later person is held to the open admission's cap, and none is made past it",
       %{fixture: fixture} do
    _first = person!(fixture, "first@example.com", "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    Cyfr.Test.Settings.put("max_athanors", 1)

    assert_raise MatchError, ~r/limit_reached/, fn ->
      fixture.(["person", "capped@example.com", "fixture-capped"])
    end

    assert {:error, :not_found} =
             Sanctum.Tenancy.Users.get_by_identity("github|https://github.com|fixture-capped")

    assert Arca.Repo.aggregate(User, :count) == 1
  end
end
