# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PairingTest do
  @moduledoc """
  The `pairing` tool through the gate, as the wire reaches it.

  The new glass makes its key first and shows the key's digest. A person
  begins a pairing for that digest under their session (`key_digest`,
  which the catalog requires) and is answered the invitation's secret for
  the pairing code and the link the pairing QR encodes, this home's
  `/pair` page with the secret in its fragment; the new glass, holding no
  credential, completes it anonymously in two calls, the challenge and
  then its proof, each naming its key and that key's digest, and is
  answered its client and certificate, bound to the person the invitation
  names whatever session asks. Any other key, one with a valid proof of
  its own included, is refused and pairs nothing. The person lists and
  revokes their paired clients, and after a declared restore re-enables a
  suspended one on a door's re-authentication (`reenable`), which ends
  their recovery. Renewal is the device channel's alone. The invitation's
  secret, its link and the proof reach no log.
  """

  # The rate limiter's table is the node's.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    seated!()
  end

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|pairing-tool-#{n}",
        provider: "github",
        email: "pairing-tool#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Pairing tool #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    %{user: user, athanor: athanor, session_ctx: session_ctx}
  end

  # A glass as the anonymous surface builds its context: no person, no
  # athanor, no credential, and its address.
  defp glass, do: Context.build(%{authenticated: false, client_ip: "198.51.100.44"})

  defp call(ctx, action, args),
    do: Sanctum.Gate.call_external("pairing", ctx, Map.put(args, "action", action))

  defp refusal({:error, reason}), do: Sanctum.Refusals.classify(reason)

  # Beginning a pairing and revoking a device are sensitive changes: the
  # person proves each, and the call repeats naming it
  # (`Sanctum.TestContext.confirming/2`).
  defp confirmed_call(ctx, action, args),
    do: Sanctum.TestContext.confirming(ctx, &call(&1, action, args))

  # A new glass's key, made before any invitation, and its digest, the
  # code the glass shows.
  defp device_key! do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: device_key, private: private, digest: Prima.Device.key_digest(device_key)}
  end

  # What `complete` takes from the glass holding `key` for the invitation
  # `secret`.
  defp submission(secret, key),
    do: %{
      "invitation_secret" => secret,
      "device_key" => Encoding.b64(key.public),
      "key_digest" => key.digest
    }

  defp pair!(session_ctx, completing \\ glass()) do
    key = device_key!()
    private = key.private

    {:ok, %{invitation_secret: secret, invitation_url: url}} =
      confirmed_call(session_ctx, "begin", %{"key_digest" => key.digest})

    submission = submission(secret, key)

    {:ok, %{challenge: challenge}} = call(completing, "complete", submission)
    {:ok, challenge} = Challenge.decode(challenge)
    proof = Proof.encode(Proof.sign(challenge, private))

    {:ok, %{client_id: client_id, certificate: certificate}} =
      call(completing, "complete", Map.put(submission, "proof", proof))

    {:ok, certificate} = DeviceCert.decode(certificate)
    %{secret: secret, url: url, client_id: client_id, certificate: certificate, proof: proof}
  end

  test "a session begins, a glass holding nothing completes, and the certificate is the person's",
       %{session_ctx: session_ctx, user: user, athanor: athanor} do
    key = device_key!()
    device_key = key.public

    assert {:ok,
            %{
              invitation_secret: secret,
              invitation_url: url,
              client_id: reserved,
              key_digest: digest,
              expires_at: expires_at
            }} = confirmed_call(session_ctx, "begin", %{"key_digest" => key.digest})

    assert digest == key.digest

    assert {:ok, <<_::binary-size(16)>>} = Encoding.unb64(secret, 16)

    # The link the QR encodes: this home's `/pair` page, the secret in the
    # fragment's `code`, which no request line carries.
    assert url == Sanctum.Person.home() <> "/pair#code=" <> secret
    assert %URI{path: "/pair", query: nil, fragment: "code=" <> ^secret} = URI.parse(url)
    assert "pcl_" <> _ = reserved
    assert {:ok, _at, 0} = DateTime.from_iso8601(expires_at)

    private = key.private
    submission = submission(secret, key)

    # The first call answers the challenge to sign.
    assert {:ok, %{challenge: challenge_map}} = call(glass(), "complete", submission)

    assert {:ok, %Challenge{purpose: :pair, client_id: ^reserved} = challenge} =
             Challenge.decode(challenge_map)

    # The second, with the proof, the client and its first certificate.
    proof = Proof.encode(Proof.sign(challenge, private))

    assert {:ok, %{client_id: ^reserved, certificate: certificate_map}} =
             call(glass(), "complete", Map.put(submission, "proof", proof))

    assert {:ok, %DeviceCert{} = certificate} = DeviceCert.decode(certificate_map)
    assert certificate.subject == %{kind: :local, user_id: user.id}
    assert certificate.athanor == athanor.id
    assert certificate.device_key == device_key
    assert certificate.issuer == Sanctum.Person.home()
  end

  test "a session another person's browser still holds never chooses the person", %{
    session_ctx: session_ctx,
    user: user
  } do
    stranger = seated!()
    device = pair!(session_ctx, stranger.session_ctx)

    assert device.certificate.subject.user_id == user.id

    assert {:ok, %{clients: [%{client_id: client_id}]}} = call(session_ctx, "list", %{})
    assert client_id == device.client_id
    assert {:ok, %{clients: []}} = call(stranger.session_ctx, "list", %{})
  end

  test "a code used once opens nothing again, and a malformed one is no code", %{
    session_ctx: session_ctx
  } do
    device = pair!(session_ctx)
    key = device_key!()
    device_key = Encoding.b64(key.public)

    used = call(glass(), "complete", submission(device.secret, key))

    assert %Prima.Refusal{class: :unauthenticated, message: message} = refusal(used)
    assert message =~ "not valid"

    for {secret, device_key, digest} <- [
          {"too-short", device_key, key.digest},
          {device.secret, "not-a-key", key.digest},
          {Encoding.b64(:crypto.strong_rand_bytes(32)), device_key, key.digest},
          {device.secret, device_key, "not-a-digest"}
        ] do
      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(
                 call(glass(), "complete", %{
                   "invitation_secret" => secret,
                   "device_key" => device_key,
                   "key_digest" => digest
                 })
               )
    end
  end

  # The gate casts each call's arguments against the declared operation
  # (`Sanctum.Catalog.validate_arguments/2`) before any handler runs; these
  # cases cast them the same way first, so a declaration that drops
  # `key_digest` fails here.
  defp cast!(action, args) do
    assert {:ok, cast} =
             Sanctum.Catalog.validate_arguments("pairing", Map.put(args, "action", action))

    cast
  end

  defp open_records(ctx) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    rows
  end

  describe "the key the new glass made first" do
    test "begin names its digest through the public operation, and that key completes", %{
      session_ctx: session_ctx,
      user: user
    } do
      key = device_key!()
      begin = cast!("begin", %{"key_digest" => key.digest})
      assert begin["key_digest"] == key.digest

      assert {:ok, %{invitation_secret: secret, client_id: reserved, key_digest: digest}} =
               Sanctum.TestContext.confirming(
                 session_ctx,
                 &Sanctum.Gate.call_external("pairing", &1, begin)
               )

      assert digest == key.digest

      # Both completing calls carry the key's digest, and pass the cast.
      asked = cast!("complete", submission(secret, key))
      assert asked["key_digest"] == key.digest

      assert {:ok, %{challenge: challenge}} =
               Sanctum.Gate.call_external("pairing", glass(), asked)

      {:ok, challenge} = Challenge.decode(challenge)
      proof = Proof.encode(Proof.sign(challenge, key.private))

      proven = cast!("complete", Map.put(submission(secret, key), "proof", proof))

      assert {:ok, %{client_id: ^reserved, certificate: certificate}} =
               Sanctum.Gate.call_external("pairing", glass(), proven)

      assert {:ok, %DeviceCert{device_key: device_key, subject: subject}} =
               DeviceCert.decode(certificate)

      assert device_key == key.public
      assert subject == %{kind: :local, user_id: user.id}
    end

    test "begin without key_digest is refused by the cast, before any confirmation is asked", %{
      session_ctx: session_ctx
    } do
      assert {:error, {:invalid_argument, message}} =
               Sanctum.Catalog.validate_arguments("pairing", %{"action" => "begin"})

      assert message =~ "key_digest"

      for args <- [%{}, %{"key_digest" => nil}] do
        assert %Prima.Refusal{class: :invalid_argument} =
                 refusal(call(session_ctx, "begin", args))
      end

      assert open_records(session_ctx) == []
    end

    test "a digest that is not one is refused, and no confirmation is asked for it", %{
      session_ctx: session_ctx
    } do
      key = device_key!()

      for digest <- [String.slice(key.digest, 0, 42), "sha256:" <> key.digest, "not a digest"] do
        assert %Prima.Refusal{class: :invalid_argument} =
                 refusal(call(session_ctx, "begin", %{"key_digest" => digest}))
      end

      assert open_records(session_ctx) == []
    end

    test "complete naming a digest that is not its key's is refused by its shape", %{
      session_ctx: session_ctx
    } do
      key = device_key!()
      other = device_key!()

      {:ok, %{invitation_secret: secret}} =
        confirmed_call(session_ctx, "begin", %{"key_digest" => key.digest})

      # Another key beside the invitation's digest, and the invitation's key
      # beside another key's digest: neither names the key presented.
      for {device_key, digest} <- [{other.public, key.digest}, {key.public, other.digest}] do
        args = %{
          "invitation_secret" => secret,
          "device_key" => Encoding.b64(device_key),
          "key_digest" => digest
        }

        assert {:ok, _cast} =
                 Sanctum.Catalog.validate_arguments(
                   "pairing",
                   Map.put(args, "action", "complete")
                 )

        assert %Prima.Refusal{class: :invalid_argument} =
                 refusal(call(glass(), "complete", args))
      end

      assert {:ok, %{challenge: _}} = call(glass(), "complete", submission(secret, key))
      assert {:ok, %{clients: []}} = call(session_ctx, "list", %{})
    end

    test "a second key presented first, with a valid proof over its own challenge, is refused and pairs nothing",
         %{session_ctx: session_ctx} do
      key = device_key!()
      intruder = device_key!()

      {:ok, %{invitation_secret: secret, client_id: reserved}} =
        Sanctum.TestContext.confirming(
          session_ctx,
          &Sanctum.Gate.call_external(
            "pairing",
            &1,
            cast!("begin", %{"key_digest" => key.digest})
          )
        )

      # The second key, under its own digest, asks first: refused before any
      # challenge is answered.
      asked = cast!("complete", submission(secret, intruder))

      assert %Prima.Refusal{class: :forbidden, reason: :key_mismatch} =
               refusal(Sanctum.Gate.call_external("pairing", glass(), asked))

      # Its own valid signature, over a pair challenge for this invitation's
      # client and its own key: refused all the same.
      {:ok, own} =
        Challenge.new(
          purpose: :pair,
          home: Sanctum.Person.home(),
          athanor: session_ctx.athanor_id,
          client_id: reserved,
          device_key: intruder.public,
          nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
          now: System.system_time(:millisecond)
        )

      signed = Proof.encode(Proof.sign(own, intruder.private))
      proven = cast!("complete", Map.put(submission(secret, intruder), "proof", signed))

      assert %Prima.Refusal{class: :forbidden, reason: :key_mismatch} =
               refusal(Sanctum.Gate.call_external("pairing", glass(), proven))

      assert {:ok, %{clients: []}} = call(session_ctx, "list", %{})

      # The key the invitation names still completes it.
      submission = submission(secret, key)
      assert {:ok, %{challenge: challenge}} = call(glass(), "complete", submission)
      {:ok, challenge} = Challenge.decode(challenge)
      proof = Proof.encode(Proof.sign(challenge, key.private))

      assert {:ok, %{client_id: ^reserved, certificate: certificate}} =
               call(glass(), "complete", Map.put(submission, "proof", proof))

      assert {:ok, %DeviceCert{device_key: device_key}} = DeviceCert.decode(certificate)
      assert device_key == key.public
      assert {:ok, %{clients: [%{client_id: ^reserved}]}} = call(session_ctx, "list", %{})
    end
  end

  test "the person lists and revokes their own paired clients", %{session_ctx: session_ctx} do
    first = pair!(session_ctx)
    second = pair!(session_ctx)

    assert {:ok, %{clients: clients}} = call(session_ctx, "list", %{})
    assert Enum.map(clients, & &1.client_id) == [first.client_id, second.client_id]

    assert Enum.all?(clients, fn client ->
             client.source == "device_cert" and client.current == false and
               match?({:ok, _, 0}, DateTime.from_iso8601(client.certificate_expires_at))
           end)

    assert {:ok, %{client_id: revoked, standing: "revoked"}} =
             confirmed_call(session_ctx, "revoke", %{"client_id" => first.client_id})

    assert revoked == first.client_id

    assert {:ok, %{clients: [%{client_id: remaining}]}} = call(session_ctx, "list", %{})
    assert remaining == second.client_id

    assert %Prima.Refusal{class: :not_found} =
             refusal(call(session_ctx, "revoke", %{"client_id" => "pcl_nothing"}))
  end

  test "after a declared restore the person re-enables a suspended device, and a revoked one never",
       %{session_ctx: session_ctx, user: user, athanor: athanor} do
    %{client_id: client_id} = pair!(session_ctx)
    %{client_id: revoked_id} = pair!(session_ctx)

    {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)

    # Every session went with the restore: the person signs in again.
    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    assert {:ok, %{clients: []}} = call(ctx, "list", %{})
    {:ok, _} = Arca.PairedClients.revoke(Context.actor(ctx), revoked_id)

    assert %Prima.Refusal{class: :conflict, reason: :revoked} =
             refusal(call(ctx, "reenable", %{"client_id" => revoked_id}))

    assert {:error, {:confirmation_required, %{id: id, operation: "pairing.reenable"}}} =
             call(ctx, "reenable", %{"client_id" => client_id})

    # A door's re-authentication, from a session that names no client.
    {:ok, _} =
      Arca.PendingConfirmations.confirm(Context.actor(ctx), Prima.Confirmation.ref(id), %{
        proof: "oidc_reauth"
      })

    assert {:ok, %{client_id: ^client_id, standing: "active", recovery_closed: true}} =
             call(%{ctx | confirmation_id: id}, "reenable", %{"client_id" => client_id})

    assert {:ok, %{clients: [%{client_id: ^client_id}]}} = call(ctx, "list", %{})

    assert {:ok, nil} = Arca.SecurityTransitions.restore_open(Prima.Actor.system(), user.id)

    assert %Prima.Refusal{class: :conflict, reason: :not_suspended} =
             refusal(call(ctx, "reenable", %{"client_id" => client_id}))

    assert %Prima.Refusal{class: :invalid_argument} = refusal(call(ctx, "reenable", %{}))
  end

  test "renewal is the device channel's alone: a session is refused", %{session_ctx: session_ctx} do
    device = pair!(session_ctx)

    {:ok, challenge} =
      Challenge.new(
        purpose: :renew,
        home: device.certificate.audience,
        athanor: device.certificate.athanor,
        client_id: device.client_id,
        device_key: device.certificate.device_key,
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    assert %Prima.Refusal{class: :forbidden, reason: :renewal_exchange_only} =
             refusal(
               call(session_ctx, "renew", %{
                 "client_id" => device.client_id,
                 "device_key" => Encoding.b64(device.certificate.device_key),
                 "proof" => Proof.encode(%Proof{challenge: challenge, sig: <<0::512>>})
               })
             )
  end

  test "an anonymous caller reaches completion alone", %{session_ctx: session_ctx} do
    pair!(session_ctx)

    for action <- ~w(begin list) do
      assert %Prima.Refusal{} = refusal(call(glass(), action, %{}))
    end

    assert %Prima.Refusal{} = refusal(call(glass(), "revoke", %{"client_id" => "pcl_1"}))
  end

  test "the invitation's secret, its link and the device's proof reach no log", %{
    session_ctx: session_ctx
  } do
    device = pair!(session_ctx)
    sig = device.proof["sig"]

    logged =
      Arca.Repo.all(from(l in Arca.Schemas.McpLog, select: {l.input, l.output, l.error})) ++
        Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, select: {d.reason, d.tool, d.action}))

    refute logged == []
    refute inspect(logged) =~ device.secret
    refute inspect(logged) =~ device.url
    refute inspect(logged) =~ sig

    # The begin's answer is logged, its link under a redacted name.
    begun =
      Arca.Repo.all(
        from(l in Arca.Schemas.McpLog,
          where: l.tool == "pairing" and l.action == "begin" and l.status == "success",
          select: l.output
        )
      )

    assert [output] = begun
    assert %{"invitation_url" => "[REDACTED]"} = Jason.decode!(output)
  end
end
