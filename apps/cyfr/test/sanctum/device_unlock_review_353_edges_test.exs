# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockReview353EdgesTest do
  use PrismWeb.ConnCase, async: false
  import Cyfr.Test.ProtectedDevice
  import Ecto.Query
  alias Prima.DeviceCert
  alias Prima.DeviceCert.Challenge
  alias Sanctum.{Context, DeviceUnlock}
  @token String.duplicate("53", 32)
  @restore_token String.duplicate("54", 32)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :restore_token, @restore_token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    :ok
  end

  defp restore_session!(user_id) do
    id = Prima.UUID7.generate_id("iat")
    now = DateTime.utc_now()

    Arca.Repo.insert_all(Arca.Schemas.IdentityAttempt, [
      %{
        id: id,
        kind: "restore",
        request_id: Prima.UUID7.generate_id("rst"),
        user_id: user_id,
        identifier: "per_" <> String.duplicate("d", 64),
        directory_url: "https://dir.example",
        phase: "completed",
        entry: "recover-request",
        request_digest: Prima.Digest.sha256("recover-#{id}"),
        expected_revision: 0,
        token_digest: Prima.Digest.sha256("token-#{id}"),
        staged_live_public_key: :crypto.strong_rand_bytes(32),
        staged_operational_public_key: :crypto.strong_rand_bytes(32),
        revision: 1,
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, %{id: athanor_id}} = Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id)

    built =
      Context.build(
        user_id: user_id,
        provider: "restore",
        athanor_id: athanor_id,
        permissions: Context.person_permissions(),
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} =
      Sanctum.Session.create(built,
        generation_snapshot: Sanctum.TestContext.snapshot!(built),
        restore: id
      )

    {:ok, ctx} = Sanctum.Caller.establish(session.token)
    ctx
  end

  defp resume_http(body, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/device/enrollment/resume", Jason.encode!(body))
  end

  test "review353 a restore enrollment resumes over HTTP only with its token and key proof" do
    # A local person holding no first method, as a restore leaves them: a
    # device's setup with the device, its certificate and the mark taken away.
    %{certificate: %{subject: %{user_id: user_id}}} = enrolled!(@token)
    Arca.Repo.delete_all(from(c in Arca.Schemas.DeviceCertificate, where: c.user_id == ^user_id))
    Arca.Repo.delete_all(from(c in Arca.Schemas.PairedClient, where: c.user_id == ^user_id))

    {1, _} =
      Arca.Repo.update_all(from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user_id),
        set: [first_method_at: nil]
      )

    ctx = restore_session!(user_id)
    pair = key()
    request_id = Prima.UUID7.generate_id("req")

    {:ok, %{challenge: challenge}} =
      DeviceUnlock.enrollment_challenge({:restore, ctx}, reported(pair, request_id, "restore"))

    {:ok, %{certificate: certificate}} =
      DeviceUnlock.enroll({:restore, ctx}, %{"proof" => signed(challenge, elem(pair, 1))})

    count = Arca.Repo.aggregate(Arca.Schemas.PairedClient, :count)

    ask = %{
      "admission" => "restore",
      "device_key" => b64(elem(pair, 0)),
      "request_id" => request_id
    }

    assert json_response(resume_http(ask, "wrong"), 401) == %{"error" => "invalid_token"}
    conn = resume_http(ask, @restore_token)
    %{"challenge" => raw} = json_response(conn, 200)
    {:ok, held} = Challenge.decode(raw)
    {_pub, wrong} = key()

    assert json_response(resume_http(%{"proof" => signed(held, wrong)}, @restore_token), 422) ==
             %{"error" => "proof_refused"}

    %{"challenge" => raw} = json_response(resume_http(ask, @restore_token), 200)
    {:ok, held} = Challenge.decode(raw)

    %{"certificate" => got} =
      json_response(resume_http(%{"proof" => signed(held, elem(pair, 1))}, @restore_token), 200)

    assert got == DeviceCert.encode(certificate)
    assert Arca.Repo.aggregate(Arca.Schemas.PairedClient, :count) == count
  end

  test "review353 another person's certified device reads and confirms no victim record" do
    device = enrolled!(@token)
    ctx = connected!(device)

    change = %{
      operation: "pairing.revoke",
      arguments: %{"client_id" => "pcl_x"},
      resource: "pcl_x"
    }

    {:error, {:confirmation_required, %{id: secret}}} =
      Sanctum.Consent.Authz.check(ctx, :pairing_revocation, change)

    ref = Prima.Confirmation.ref(secret)

    {:ok, %{confirmations: [record]}} =
      Sanctum.Providers.Confirmation.handle(ctx, %{"action" => "pending", "request" => ref})

    {:ok, held} = Challenge.decode(record.challenge)
    n = System.unique_integer([:positive])

    {:ok, other} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|review#{n}",
        provider: "github",
        name: "review#{n}"
      })

    room = Sanctum.Test.People.athanor!(other)
    actor = Prima.Actor.in_athanor(room.id)
    pair = key()

    {:ok, client} =
      Arca.PairedClients.enroll(
        actor,
        %{
          user_id: other.id,
          source_kind: "device_cert",
          source_id: "req_review#{n}",
          device_public_key: elem(pair, 0),
          holder_kind: "chip",
          display_name: "Other"
        },
        first_method: :mark,
        also: &Sanctum.Pairing.certify_first(actor, &1)
      )

    {:ok, cert} = Arca.DeviceCertificates.current(actor, client.id)
    {:ok, certificate} = cert.certificate |> Jason.decode!() |> DeviceCert.decode()
    other_ctx = connected!(%{certificate: certificate, key: pair})

    assert {:ok, %{confirmations: []}} =
             Sanctum.Providers.Confirmation.handle(other_ctx, %{
               "action" => "pending",
               "request" => ref
             })

    assert {:error, _} =
             Sanctum.Providers.Confirmation.handle(other_ctx, %{
               "action" => "confirm",
               "ref" => ref,
               "device_proof" => signed(held, elem(pair, 1))
             })

    {:ok, unchanged} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
    assert unchanged.state == "pending"
  end

  test "review353 a dangling device reference grants no session" do
    device = enrolled!(@token)
    ctx = connected!(device)
    answer = unlocked!(ctx, device.key)
    {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.id == ^answer.session_id),
      set: [client_id: "pcl_missing"]
    )

    assert {:error, :invalid_session} = Sanctum.Session.load(token)
  end

  test "review353 certificate renewal never revives a retired browser session" do
    device = enrolled!(@token)
    ctx = connected!(device)
    answer = unlocked!(ctx, device.key)
    {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
    actor = Context.actor(ctx)
    {:ok, old} = Arca.DeviceCertificates.current(actor, ctx.client_id)
    {:ok, _} = Arca.DeviceCertificates.revoke(actor, old.id)
    assert {:error, :invalid_session} = Sanctum.Session.load(token)

    {:ok, challenge} =
      Challenge.new(
        purpose: :renew,
        home: device.certificate.audience,
        athanor: ctx.athanor_id,
        client_id: ctx.client_id,
        device_key: elem(device.key, 0),
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    proof = Prima.DeviceCert.Proof.sign(challenge, elem(device.key, 1))

    {:ok, renewal} =
      Sanctum.DeviceCerts.verify_connect(
        %{client_id: ctx.client_id, certificate: device.certificate, source: "198.51.100.43"},
        proof,
        challenge
      )

    assert {:ok, _} =
             Sanctum.Pairing.renew(renewal, %{
               client_id: ctx.client_id,
               device_key: elem(device.key, 0),
               proof: Prima.DeviceCert.Proof.encode(proof)
             })

    assert {:error, :invalid_session} = Sanctum.Session.load(token)
  end
end
