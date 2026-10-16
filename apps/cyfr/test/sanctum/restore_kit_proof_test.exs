# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RestoreKitProofTest do
  @moduledoc """
  The kit ingress on a home restored from a backup, through the endpoint
  (`POST /restore/kit/challenge`, `POST /restore/kit`,
  `POST /restore/kit/reenable`): a recovering person with every restored
  method suspended and no door proves their printed kit over this home's
  challenge, against the recovery keys of their identity read fresh from
  its directory (`Sanctum.Test.DirectoryServer`), and re-enables what they
  choose under the credential it answers, which admits the four re-enable
  operations and nothing else.

  Two people recover independently: one's re-enable closes their own
  recovery and leaves the other's open. A proof by a kit that is not one
  of the identity's now, a replayed challenge and a person whose recovery
  has closed are refused. The kit proof's vectors (`tests/fixtures/
  restore_kit.json`) verify here as the browser signs them. A group with a
  member still recovering admits no new member.
  """

  # The directory client's seam and the rate counters are process-wide.
  use CyfrWeb.ConnCase, async: false

  alias Arca.Schemas
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, RestoreKit}
  alias Sanctum.{Context, TestContext}
  alias Sanctum.Test.DirectoryServer, as: Directory
  alias Sanctum.Tenancy.{Athanors, Users}

  @fixture "../../../../tests/fixtures/restore_kit.json"

  setup_all do
    %{tls: Directory.tls()}
  end

  setup %{tls: tls} do
    Prima.Test.RateLimiter.reset!()

    on_exit(fn ->
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      Prima.Test.RateLimiter.reset!()
    end)

    Directory.listen!()
    directory = Directory.start!(tls)
    Directory.seam!(tls)
    %{directory: directory}
  end

  # ---- fixtures ----------------------------------------------------------------

  # A person signed in at this home, their keys here, enrolled at the
  # scripted directory under a kit whose seed the test holds, with a
  # passkey, a paired device and an API key.
  defp enrolled!(directory) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|kit-#{n}",
        provider: "github",
        email: "kit#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Kit #{n}")

    ctx =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(ctx)
    keys = Arca.Repo.get_by!(Schemas.PersonIdentity, user_id: user.id)

    {:ok, operational} =
      Sanctum.Cipher.decrypt(
        keys.operational_key_sealed,
        Sanctum.CipherAAD.person_key(user.id, :operational)
      )

    seed = :crypto.strong_rand_bytes(32)
    {:ok, {recovery, recovery_private}} = Identity.derive_recovery_key(seed)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: directory.url
      )

    genesis = Identity.sign(genesis, operational)
    identifier = Identity.identifier(genesis)
    Directory.publish(directory.dir, identifier, [genesis])
    as = %Prima.Actor{user_id: user.id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: "req_kit_#{n}",
        user_id: user.id,
        identifier: identifier,
        directory_url: directory.url,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")

    %{
      user: user,
      athanor: athanor,
      token: session.token,
      identifier: identifier,
      recovery_private: recovery_private,
      passkey: passkey!(user.id),
      paired: paired!(athanor.id, user.id),
      key: key!(athanor.id, user.id)
    }
  end

  defp insert!(schema, row) do
    {1, _} = Arca.Repo.insert_all(schema, [row])
    row
  end

  defp passkey!(user_id) do
    id = Prima.UUID7.generate_id("psk")
    now = DateTime.utc_now()

    insert!(Schemas.Passkey, %{
      id: id,
      user_id: user_id,
      credential_id: "cred-#{System.unique_integer([:positive])}",
      rp_id: Sanctum.Passkeys.rp_id(),
      relying_home: Sanctum.Passkeys.origin(),
      public_key: "cose",
      sign_count: 0,
      state: "active",
      registration_digest: Prima.Digest.sha256("reg-#{id}"),
      possession_verified: true,
      label: "a passkey",
      inserted_at: now,
      updated_at: now
    })

    id
  end

  defp paired!(athanor_id, user_id) do
    id = Prima.UUID7.generate_id("pcl")
    now = DateTime.utc_now()

    insert!(Schemas.PairedClient, %{
      id: id,
      athanor_id: athanor_id,
      user_id: user_id,
      source_kind: "session",
      source_id: "src_#{id}",
      standing: "active",
      label: "a phone",
      inserted_at: now,
      updated_at: now
    })

    id
  end

  defp key!(athanor_id, user_id) do
    id = Prima.UUID7.generate_id("key")
    now = DateTime.utc_now()

    insert!(Schemas.ApiKey, %{
      id: id,
      name: "k-#{id}",
      key_hash: :crypto.strong_rand_bytes(32),
      key_prefix: "cyfr_sk_kit",
      type: "service",
      scope: "[]",
      revoked: false,
      suspended: false,
      created_by: user_id,
      athanor_id: athanor_id,
      inserted_at: now,
      updated_at: now
    })

    id
  end

  # The home restored from its backup, as the boot declares it.
  defp restored! do
    {:ok, _restore_id} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    {:ok, %{restore_id: restore_id}} = Arca.SecurityTransitions.restore(slot: :none)
    restore_id
  end

  defp post_json(path, body, bearer \\ nil) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if bearer, do: put_req_header(conn, "authorization", "Bearer " <> bearer), else: conn
    post(conn, path, Jason.encode!(body))
  end

  defp challenge(person) do
    json_response(post_json("/restore/kit/challenge", %{"identifier" => person.identifier}), 200)
  end

  defp signed(person, %{"challenge" => challenge, "restore_id" => restore_id}, private) do
    {:ok, bytes} = Encoding.unb64(challenge, 32)

    {:ok, proof} =
      RestoreKit.new(restore_id: restore_id, identifier: person.identifier, challenge: bytes)

    proof |> Identity.sign(private) |> RestoreKit.encode()
  end

  # The kit proven over a fresh challenge: the credential it answers.
  defp credential!(person) do
    proof = signed(person, challenge(person), person.recovery_private)

    assert %{"credential" => credential} =
             json_response(post_json("/restore/kit", %{"proof" => proof}), 200)

    credential
  end

  defp reenable(credential, body), do: post_json("/restore/kit/reenable", body, credential)

  defp restore_open(user_id),
    do: Arca.SecurityTransitions.restore_open(Prima.Actor.system(), user_id)

  # ---- the kit ------------------------------------------------------------------

  test "with every restored method suspended and no door, the kit re-enables what the person chooses",
       %{directory: directory} do
    person = enrolled!(directory)
    restore_id = restored!()

    # The restored session no longer stands, and nothing of theirs does.
    assert {:error, _retired} = Sanctum.Caller.establish({:session, person.token})
    assert Arca.Repo.get(Schemas.Passkey, person.passkey).state == "suspended"
    assert Arca.Repo.get(Schemas.PairedClient, person.paired).standing == "suspended"

    credential = credential!(person)

    # The previews: each class's suspended items.
    assert %{"items" => [%{"id" => key_id}]} =
             json_response(reenable(credential, %{"operation" => "key.reenable"}), 200)

    assert key_id == person.key

    assert %{"items" => [%{"id" => passkey_id}]} =
             json_response(reenable(credential, %{"operation" => "passkey.reenable"}), 200)

    # A key re-enabled under the kit leaves the recovery open.
    assert %{"reenabled" => _} =
             json_response(
               reenable(credential, %{"operation" => "key.reenable", "key_id" => person.key}),
               200
             )

    refute Arca.Repo.get(Schemas.ApiKey, person.key).suspended
    assert {:ok, ^restore_id} = restore_open(person.user.id)

    # A passkey re-enabled closes it, and with it the credential.
    assert %{"reenabled" => _} =
             json_response(
               reenable(credential, %{
                 "operation" => "passkey.reenable",
                 "passkey_id" => passkey_id
               }),
               200
             )

    assert Arca.Repo.get(Schemas.Passkey, person.passkey).state == "active"
    assert {:ok, nil} = restore_open(person.user.id)

    assert %{"error" => "invalid_credential"} =
             json_response(reenable(credential, %{"operation" => "pairing.reenable"}), 401)

    # The device stays suspended until the person re-enables it as well.
    assert Arca.Repo.get(Schemas.PairedClient, person.paired).standing == "suspended"
  end

  test "two people recover on their own: one's re-enable leaves the other's recovery open",
       %{directory: directory} do
    alice = enrolled!(directory)
    bob = enrolled!(directory)
    restore_id = restored!()

    alice_credential = credential!(alice)

    assert %{"reenabled" => _} =
             json_response(
               reenable(alice_credential, %{
                 "operation" => "passkey.reenable",
                 "passkey_id" => alice.passkey
               }),
               200
             )

    assert {:ok, nil} = restore_open(alice.user.id)
    assert {:ok, ^restore_id} = restore_open(bob.user.id)

    # Alice's credential reaches nothing of Bob's.
    bob_credential = credential!(bob)

    assert %{"items" => [%{"id" => bob_passkey}]} =
             json_response(reenable(bob_credential, %{"operation" => "passkey.reenable"}), 200)

    assert bob_passkey == bob.passkey

    assert %{"reenabled" => _} =
             json_response(
               reenable(bob_credential, %{
                 "operation" => "passkey.reenable",
                 "passkey_id" => bob.passkey
               }),
               200
             )

    assert {:ok, nil} = restore_open(bob.user.id)
  end

  test "a kit that is not one of the identity's now, a replayed challenge and a closed recovery are refused",
       %{directory: directory} do
    person = enrolled!(directory)
    other = enrolled!(directory)
    restored!()

    # Another kit's signature: not a recovery key of the head read fresh.
    {_other, other_private} = :crypto.generate_key(:eddsa, :ed25519)
    forged = signed(person, challenge(person), other_private)

    assert %{"error" => "not_a_holder"} =
             json_response(post_json("/restore/kit", %{"proof" => forged}), 409)

    # The challenge is redeemed once.
    held = challenge(person)
    proof = signed(person, held, person.recovery_private)

    assert %{"credential" => _} =
             json_response(post_json("/restore/kit", %{"proof" => proof}), 200)

    assert %{"error" => "challenge_refused"} =
             json_response(post_json("/restore/kit", %{"proof" => proof}), 409)

    # A proof for another person's challenge names their identifier, not this one's.
    restored_other = challenge(other)
    crossed = signed(person, restored_other, person.recovery_private)

    assert %{"error" => "challenge_refused"} =
             json_response(post_json("/restore/kit", %{"proof" => crossed}), 409)

    # Once the person's recovery closes, the ingress no longer answers them.
    {:ok, _} =
      Arca.Repo.locking_transaction(fn ->
        Arca.SecurityTransitions.close_restore!(person.user.id)
      end)

    assert %{"error" => "not_recovering"} =
             json_response(
               post_json("/restore/kit/challenge", %{"identifier" => person.identifier}),
               404
             )

    assert %{"error" => "not_recovering"} =
             json_response(
               post_json("/restore/kit", %{
                 "proof" => signed(person, held, person.recovery_private)
               }),
               404
             )

    assert %{"error" => "invalid_proof"} =
             json_response(post_json("/restore/kit", %{"proof" => %{"not" => "a proof"}}), 422)
  end

  test "the kit credential admits the four re-enables and nothing else; no restored method approves itself",
       %{directory: directory} do
    person = enrolled!(directory)
    restored!()
    credential = credential!(person)

    for operation <- ["key.create", "passkey.register", "person.link_door", "session.whoami"] do
      assert %{"error" => "operation_not_permitted"} =
               json_response(reenable(credential, %{"operation" => operation}), 403)
    end

    # Not a session: the console and /mcp refuse it.
    assert {:error, _} = Sanctum.Caller.establish({:session, credential})

    # A suspended passkey asserts nothing, so it can re-enable nothing.
    assert Arca.Repo.get(Schemas.Passkey, person.passkey).state == "suspended"

    assert %{"error" => "invalid_credential"} =
             json_response(
               reenable("rkc_not.a-credential", %{"operation" => "key.reenable"}),
               401
             )
  end

  test "an identifier no enrolled person of this home holds is answered as not recovering",
       %{directory: directory} do
    _person = enrolled!(directory)
    restored!()

    assert %{"error" => "not_recovering"} =
             json_response(
               post_json("/restore/kit/challenge", %{
                 "identifier" => "per_" <> String.duplicate("0", 64)
               }),
               404
             )
  end

  # ---- the group freeze ------------------------------------------------------------

  test "a group with a member still recovering admits no new member; removal stays admitted",
       %{directory: directory} do
    person = enrolled!(directory)
    restored!()

    {:ok, newcomer} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|kit-new-#{System.unique_integer([:positive])}",
        provider: "github",
        email: "kit-new@example.com",
        verified: true
      })

    ctx =
      Context.build(
        user_id: person.user.id,
        provider: "github",
        athanor_id: person.athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    assert {:error, %Prima.Refusal{reason: :recovering_from_restore, message: message}} =
             Sanctum.Providers.Member.handle(ctx, %{
               "action" => "add",
               "athanor" => person.athanor.id,
               "user_id" => newcomer.id
             })

    assert message =~ "restored from a backup"

    {:ok, _} =
      Arca.Repo.locking_transaction(fn ->
        Arca.SecurityTransitions.close_restore!(person.user.id)
      end)

    assert {:ok, %{state: "added"}} =
             Sanctum.Providers.Member.handle(ctx, %{
               "action" => "add",
               "athanor" => person.athanor.id,
               "user_id" => newcomer.id
             })
  end

  # ---- the administrator's close ------------------------------------------------------

  # A platform administrator signed in after the restore, in an athanor of
  # their own: no recovery of theirs is open.
  defp admin! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|kit-admin-#{n}",
        provider: "github",
        email: "kit-admin#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Kit admin #{n}")

    ctx =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    %{ctx | platform_admin: true}
  end

  test "person.close_recovery ends one person's recovery and leaves another's; a non-admin is refused",
       %{directory: directory} do
    alice = enrolled!(directory)
    bob = enrolled!(directory)
    restore_id = restored!()
    admin = admin!()

    close = fn ctx, person ->
      Sanctum.Providers.Person.handle(ctx, %{
        "action" => "close_recovery",
        "user_id" => person.user.id
      })
    end

    # Not a platform administrator: refused, and nothing closes.
    assert {:error, _refused} = close.(%{admin | platform_admin: false}, alice)
    assert {:ok, ^restore_id} = restore_open(alice.user.id)

    # The administrator's close, under their fresh confirmation.
    assert {:ok, %{user_id: closed, closed_restore_ids: [^restore_id]}} =
             TestContext.confirming(admin, &close.(&1, alice))

    assert closed == alice.user.id
    assert {:ok, nil} = restore_open(alice.user.id)
    assert {:ok, ^restore_id} = restore_open(bob.user.id)

    # What the restore suspended stays suspended.
    assert Arca.Repo.get(Schemas.Passkey, alice.passkey).state == "suspended"

    # A person with no recovery open is answered so.
    assert {:error, %Prima.Refusal{reason: :not_recovering}} =
             TestContext.confirming(admin, &close.(&1, alice))
  end

  test "a person who signs in only through a door has no recovery to make", %{
    directory: directory
  } do
    person = enrolled!(directory)
    door_only = admin!()
    restored!()

    assert {:ok, _restore_id} = restore_open(person.user.id)
    assert {:ok, nil} = restore_open(door_only.user_id)
  end

  # ---- the vectors -------------------------------------------------------------------

  test "the kit proof's vectors verify here as the browser signs them" do
    vectors = @fixture |> Path.expand(__DIR__) |> File.read!() |> Jason.decode!()
    valid = vectors["valid"]

    {:ok, public} = Encoding.unb64(vectors["kit"]["public"], 32)
    assert {:ok, proof} = RestoreKit.decode(valid["proof"])
    assert {:ok, ^public} = RestoreKit.signer(proof, [public])

    for %{"proof" => refused} <- vectors["refused"] do
      refute match?(
               {:ok, _key},
               with({:ok, p} <- RestoreKit.decode(refused), do: RestoreKit.signer(p, [public]))
             )
    end
  end
end
