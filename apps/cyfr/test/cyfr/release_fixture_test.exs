# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseFixtureTest do
  @moduledoc """
  The release proofs' fixture (`tests/release-boot/fixture.exs`), evaluated
  as `bin/cyfr rpc` evaluates it inside a release: its `person` command
  publishes an account at the deployment's directory and brings its
  person in by the device's hello, the installation's first under a setup
  token and every later one by the door, held to the open admission's
  caps, each with a paired device whose record it keeps; a person made
  before comes in again by the same hello, and every person's session
  stands past the freshness bound on a public home; a kept record is the
  device a first person made again comes in with; `device_confirm` and
  `confirmed` confirm a record by the person's own device answering this
  CYFR's request, a record made wrong and another person's key are
  refused; and a fill that failed stops the fixture.
  """

  # The setup token the fixture puts for its call, the pinned directory,
  # the directory client's seam, the registry, the door, the caps, the
  # access mode, the seed and the working directory the fixture keeps its
  # devices' records in are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DirectoryHead, PersonIdentity, User}
  alias Prima.Identity
  alias Prima.Identity.{Entry, Key}
  alias Sanctum.Test.DirectoryServer

  @fixture Path.expand("../../../../tests/release-boot/fixture.exs", __DIR__)

  # The home's refusal of an answer that is not the person's own device's
  # over the record it was asked for, as the fixture answers it.
  @answer_refused %{
    "reason" => "answer_refused",
    "message" => "That answer does not confirm this change here: confirm it again"
  }

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

    # No registry: the fixture claims no name, and the sign-in learns none.
    Prima.Test.Env.put_app_env(:sanctum, :registry_url, "none")
    Prima.Test.Env.put_app_env(:cyfr, :registry_url, "none")

    # The installation holds no person inside this test's transaction,
    # whatever the suite committed: the fixture's first person is setup's.
    Arca.Repo.delete_all(User)

    # The fixture keeps its devices' records in the working directory, as
    # a release cell's: each test's own, never the checkout.
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

  defp person!(fixture, sub) do
    "FIXTURE=" <> json = fixture.(["person", sub])
    Jason.decode!(json)
  end

  defp identifier_of(person),
    do: Arca.Repo.get_by!(PersonIdentity, user_id: person["user_id"]).identifier

  # The account SUB names, as the fixture derives it: the genesis its
  # recovery key signs at this deployment's directory.
  defp identifier_for(sub) do
    {pub, recovery} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, ["release-proof|", sub]))

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: 1_700_000_000_000,
        signer: Identity.recovery_signer(pub),
        directory: Sanctum.directory_url(),
        recovery: [pub]
      )

    genesis |> Identity.sign(recovery) |> Identity.identifier()
  end

  defp paired(person) do
    {:ok, rows} =
      Arca.PairedClients.list(Prima.Actor.system(),
        user_id: person["user_id"],
        standing: :active
      )

    Enum.filter(rows, &(&1.source_kind == "device_cert"))
  end

  defp record(dir, identifier),
    do: Path.join(dir, "device-#{identifier}.json") |> File.read!() |> Jason.decode!()

  # A confirmation the person's change asks for: entering a credential.
  defp asked(ctx) do
    {:error, {:confirmation_required, %{id: id}}} =
      Sanctum.Consent.Authz.check(ctx, :credential_entry, %{
        operation: "vault.create",
        arguments: %{"name" => "fixture"},
        resource: "fixture"
      })

    Prima.Confirmation.ref(id)
  end

  defp state(ctx, ref) do
    {:ok, %{state: state}} = Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
    state
  end

  test "person makes the first person by their device's hello under the setup token, and a later one by the door, each with a paired device whose record it keeps",
       %{fixture: fixture, dir: dir} do
    configured = Application.fetch_env(:sanctum, :setup_token)
    first = person!(fixture, "fixture-first")

    assert {:ok, %{admission: "setup", email: nil, display_name: nil}} =
             Sanctum.Tenancy.Users.get(first["user_id"])

    assert Sanctum.Tenancy.platform_admin?(first["user_id"])
    # The token put for the call is taken away after it.
    assert Application.fetch_env(:sanctum, :setup_token) == configured

    # A later person is refused while the door's `*` admits no newcomer.
    assert_raise RuntimeError, ~r/the door admitted no per_/, fn ->
      person!(fixture, "fixture-second")
    end

    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    second = person!(fixture, "fixture-second")

    refute second["user_id"] == first["user_id"]

    assert {:ok, %{admission: "open", email: nil, display_name: nil}} =
             Sanctum.Tenancy.Users.get(second["user_id"])

    refute Sanctum.Tenancy.platform_admin?(second["user_id"])

    assert {:ok, %{owner_user_id: owner}} = Sanctum.Tenancy.Athanors.get(second["athanor_id"])
    assert owner == second["user_id"]

    # Each holds one paired device, a key of their account, and the record
    # names it, readable by this user alone.
    for person <- [first, second] do
      identifier = identifier_of(person)
      assert [%{id: client_id, device_public_key: pub, holder_kind: "software"}] = paired(person)
      kept = record(dir, identifier)
      assert kept["client_id"] == client_id
      assert kept["home"] == Sanctum.origin()
      assert kept["certificate"]["client_id"] == client_id
      {:ok, seed} = Base.url_decode64(kept["seed"], padding: false)
      assert {^pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

      assert {:ok, %{mode: mode}} = File.stat(Path.join(dir, "device-#{identifier}.json"))
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end

  test "a person made before comes in again by the same hello, in a new session, their device paired once",
       %{fixture: fixture} do
    first = person!(fixture, "fixture-first")
    again = person!(fixture, "fixture-first")

    assert again["user_id"] == first["user_id"]
    refute again["token"] == first["token"]
    assert [_one] = paired(first)

    for person <- [first, again] do
      assert {:ok, %{user_id: user_id}} = Sanctum.Caller.establish({:session, person["token"]})
      assert user_id == first["user_id"]
    end
  end

  test "each account is published at the deployment's directory, and its person's session stands past the freshness bound on a public home",
       %{fixture: fixture, directory: directory} do
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)
    first = person!(fixture, "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    second = person!(fixture, "fixture-second")

    for person <- [first, second] do
      identifier = identifier_of(person)
      [%{device_public_key: pub}] = paired(person)

      assert [%Entry{kind: :genesis}, %Entry{kind: :add_key, key: %Key{kind: :device, pub: ^pub}}] =
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

  test "a first person made where their device's record is kept comes in with that device; a record of another home refuses",
       %{fixture: fixture, dir: dir} do
    identifier = identifier_for("fixture-first")
    path = Path.join(dir, "device-#{identifier}.json")
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
    first = person!(fixture, "fixture-first")
    assert identifier_of(first) == identifier

    # The hello's device is the kept one, under the client id its hello
    # reserved; the record is written back with it.
    assert [%{id: client_id, device_public_key: ^device_key}] = paired(first)
    written = record(dir, identifier)
    assert Map.take(written, ~w(seed home)) == Map.take(kept, ~w(seed home))
    assert written["client_id"] == client_id
    assert written["certificate"]["client_id"] == client_id
    assert {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(first["user_id"])
    assert written["athanor_id"] == athanor_id

    File.write!(path, Jason.encode!(%{kept | "home" => "https://another.example"}))

    assert_raise RuntimeError, ~r/names no device of this home/, fn ->
      fixture.(["person", "fixture-first"])
    end
  end

  test "device_confirm confirms a record by its own person's device, refuses one made wrong, and another person's key confirms nothing",
       %{fixture: fixture, dir: dir} do
    first = person!(fixture, "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    second = person!(fixture, "fixture-second")
    {:ok, ctx} = Sanctum.Caller.establish({:session, first["token"]})

    # An answer over a changed record, or by a key of no device, is refused
    # as the home refuses an answer; one under another ref names no record
    # of the person's; each leaves the record pending.
    for tamper <- ["digest", "key", "ref"] do
      ref = asked(ctx)
      "FIXTURE=" <> json = fixture.(["device_confirm", ref, tamper])
      assert %{"error" => error, "operation" => "vault.create"} = Jason.decode!(json), tamper

      if tamper == "ref",
        do: assert(error =~ ~r/^\{:not_found, "confirmation", "cnr_[A-Za-z0-9_-]+"\}$/),
        else: assert(error == @answer_refused, tamper)

      assert state(ctx, ref) == "pending"
    end

    # Another person's device, kept at this home beside the first's,
    # answering the first person's record's request with its own key, is
    # refused: its key is none of the first person's account.
    ref = asked(ctx)
    "FIXTURE=" <> json = fixture.(["device_confirm", ref, "other"])
    assert %{"error" => @answer_refused, "operation" => "vault.create"} = Jason.decode!(json)
    assert state(ctx, ref) == "pending"

    # Without the first person's device, no device here holds the record:
    # the second's sees only its own person's records.
    first_record = Path.join(dir, "device-#{identifier_of(first)}.json")
    kept = File.read!(first_record)
    File.rm!(first_record)
    "FIXTURE=" <> json = fixture.(["device_confirm", ref])
    assert %{"error" => "no device kept at this home holds " <> ^ref} = Jason.decode!(json)
    assert state(ctx, ref) == "pending"
    _ = second

    # The first person's own device, kept again, confirms the record, at
    # the digest its request names.
    File.write!(first_record, kept)
    "FIXTURE=" <> json = fixture.(["device_confirm", ref])
    assert %{"ok" => %{"state" => "confirmed"}, "digest" => digest} = Jason.decode!(json)

    assert {:ok, %{state: "confirmed", digest: ^digest}} =
             Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
  end

  test "confirmed makes a sensitive change under the person's own device's confirmation once the wrong answers are refused, and vault enters an entry by it",
       %{fixture: fixture} do
    first = person!(fixture, "fixture-first")
    {:ok, ctx} = Sanctum.Caller.establish({:session, first["token"]})

    arguments =
      Jason.encode!(%{
        "name" => "Confirmed entry",
        "kind" => "api_key",
        "fields" => %{"TOKEN" => "confirmed-value"},
        "destination" => %{"hosts" => ["fixture.test"]}
      })

    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    _second = person!(fixture, "fixture-second")

    # Another person's device and an answer over a changed record are each
    # refused before the person's own device confirms the change.
    "FIXTURE=" <> json =
      fixture.(["confirmed", first["token"], "vault/create", arguments, "refused"])

    assert %{
             "ok" => %{"entry" => %{"id" => confirmed_id, "name" => "Confirmed entry"}},
             "refused" => %{"other" => @answer_refused, "changed" => @answer_refused}
           } = Jason.decode!(json)

    "FIXTURE=" <> json = fixture.(["vault", first["token"], "seeded", "API_KEY", "seeded-value"])
    assert %{"id" => seeded_id, "name" => "seeded"} = Jason.decode!(json)

    {:ok, entries} = Arca.VaultStorage.list(Sanctum.Context.actor(ctx))
    assert Enum.sort([confirmed_id, seeded_id]) == entries |> Enum.map(& &1.id) |> Enum.sort()

    # Each change spent its own record, confirmed by the device.
    {:ok, %{confirmations: open}} =
      Sanctum.Gate.call_external("confirmation", ctx, %{"action" => "pending"})

    assert open == []
  end

  test "a fill that failed stops the fixture where it waits on the fill",
       %{fixture: fixture} do
    # A seed that holds no Aqua template: the fill the sign-in starts
    # fails, and the athanor is left unfilled.
    root =
      Path.join(System.tmp_dir!(), "release_fixture_seed_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "seed"))
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(root, "base"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, Path.join(root, "seed"))

    first = person!(fixture, "fixture-first")
    {:ok, row} = Sanctum.Tenancy.Athanors.get(first["athanor_id"])
    assert %{step: _failed} = Sanctum.Tenancy.Athanors.provisioning_failure(row)

    tincture = Path.join(root, "tincture")
    File.mkdir_p!(tincture)
    File.write!(Path.join(tincture, "index.html"), "<p>probe</p>")

    assert_raise RuntimeError, ~r/the fill of #{first["athanor_id"]} failed/, fn ->
      fixture.(["tincture", first["user_id"], tincture, "fill-probe", "private"])
    end
  end

  test "a later person is held to the open admission's cap, and none is made past it",
       %{fixture: fixture} do
    _first = person!(fixture, "fixture-first")
    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
    Cyfr.Test.Settings.put("max_athanors", 1)

    assert_raise RuntimeError, ~r/limit_reached/, fn ->
      person!(fixture, "fixture-capped")
    end

    assert Arca.Repo.aggregate(User, :count) == 1
  end
end
