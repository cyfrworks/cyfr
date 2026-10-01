# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.PairingTest do
  @moduledoc """
  The `pairing` tool through the gate, as the wire reaches it.

  A person begins a pairing under their session and is answered the
  invitation's secret for the pairing code and the link the pairing QR
  encodes, this home's `/pair` page with the secret in its fragment; the
  new glass, holding no
  credential, completes it anonymously in two calls, the challenge and
  then its proof, and is answered its client and certificate, bound to
  the person the invitation names whatever session asks. The person lists
  and revokes their paired clients. Renewal is the device channel's alone.
  The invitation's secret, its link and the proof reach no log.
  """

  # The rate limiter's table is the node's.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    seated!()
  end

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
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
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, athanor: athanor, session_ctx: session_ctx}
  end

  # A glass as the anonymous surface builds its context: no person, no
  # athanor, no credential, and its address.
  defp glass, do: Context.build(%{authenticated: false, client_ip: "198.51.100.44"})

  defp call(ctx, action, args),
    do: Grimoire.call_external("pairing", ctx, Map.put(args, "action", action))

  defp refusal({:error, reason}), do: Grimoire.Error.classify(reason)

  # Beginning a pairing and revoking a device are sensitive changes: the
  # person proves each, and the call repeats naming it
  # (`Sanctum.TestContext.confirming/2`).
  defp confirmed_call(ctx, action, args),
    do: Sanctum.TestContext.confirming(ctx, &call(&1, action, args))

  defp pair!(session_ctx, completing \\ glass()) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, %{invitation_secret: secret, invitation_url: url}} =
      confirmed_call(session_ctx, "begin", %{})

    submission = %{"invitation_secret" => secret, "device_key" => Encoding.b64(device_key)}

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
    assert {:ok,
            %{
              invitation_secret: secret,
              invitation_url: url,
              client_id: reserved,
              expires_at: expires_at
            }} = confirmed_call(session_ctx, "begin", %{})

    assert {:ok, <<_::binary-size(16)>>} = Encoding.unb64(secret, 16)

    # The link the QR encodes: this home's `/pair` page, the secret in the
    # fragment's `code`, which no request line carries.
    assert url == Sanctum.Person.home() <> "/pair#code=" <> secret
    assert %URI{path: "/pair", query: nil, fragment: "code=" <> ^secret} = URI.parse(url)
    assert "pcl_" <> _ = reserved
    assert {:ok, _at, 0} = DateTime.from_iso8601(expires_at)

    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    submission = %{"invitation_secret" => secret, "device_key" => Encoding.b64(device_key)}

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
    {device_key, _} = :crypto.generate_key(:eddsa, :ed25519)

    used =
      call(glass(), "complete", %{
        "invitation_secret" => device.secret,
        "device_key" => Encoding.b64(device_key)
      })

    assert %Prima.Refusal{class: :unauthenticated, message: message} = refusal(used)
    assert message =~ "not valid"

    for {secret, key} <- [
          {"too-short", Encoding.b64(device_key)},
          {device.secret, "not-a-key"},
          {Encoding.b64(:crypto.strong_rand_bytes(32)), Encoding.b64(device_key)}
        ] do
      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(
                 call(glass(), "complete", %{"invitation_secret" => secret, "device_key" => key})
               )
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
