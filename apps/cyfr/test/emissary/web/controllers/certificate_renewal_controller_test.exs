# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.CertificateRenewalControllerTest do
  @moduledoc """
  `POST /certify/v1/renew`: a certified device's renewal at its person's
  home, from another home's page. No session is read and no credential
  travels: CORS answers every origin `*` without credentials, a cookie the
  browser sends chooses nobody, and the device key's proof over this
  home's challenge is the only credential. A refusal is the refusal shape
  at its class's status.
  """

  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.PersonIdentity
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry}
  alias Sanctum.{Context, TestContext}
  alias Sanctum.Tenancy.{Athanors, Users}

  @directory "https://dir.example"
  @hub "https://hub.example"

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    person = enrolled!()

    certify = %{
      "action" => "certify",
      "device_key" => Encoding.b64(device_key),
      "audience" => @hub,
      "athanor" => "ath_hub",
      "client_id" => "pcl_hub"
    }

    {:ok, %{certificate: certificate}} =
      TestContext.confirming(person.ctx, &Grimoire.call_external("person", &1, certify))

    %{person: person, certificate: certificate, private: private}
  end

  # A person signed in at this home, their keys here, enrolled.
  defp enrolled! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|renewal-#{n}",
        provider: "github",
        email: "renewal#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Renewal #{n}")

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

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    keys = Arca.Repo.get_by!(PersonIdentity, user_id: user.id)

    {:ok, operational} =
      Sanctum.Cipher.decrypt(
        keys.operational_key_sealed,
        Sanctum.CipherAAD.person_key(user.id, :operational)
      )

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: user.id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: "req_#{n}",
        user_id: user.id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "submitted", "accepted")
    %{user: user, ctx: ctx, token: session.token}
  end

  defp renew(conn, body) do
    conn
    |> put_req_header("origin", @hub)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post("/certify/v1/renew", Jason.encode!(body))
  end

  test "answers the challenge, then the replacement for the device key's proof, to any origin with no credentials",
       %{conn: conn, certificate: certificate, private: private} do
    first = renew(conn, %{"certificate" => certificate})
    assert %{"challenge" => challenge} = json_response(first, 200)
    assert get_resp_header(first, "access-control-allow-origin") == ["*"]
    assert get_resp_header(first, "access-control-allow-credentials") == []
    assert get_resp_header(first, "set-cookie") == []

    {:ok, held} = Challenge.decode(challenge)
    proof = Proof.encode(Proof.sign(held, private))

    second = renew(build_conn(), %{"certificate" => certificate, "proof" => proof})
    assert %{"certificate" => replacement} = json_response(second, 200)
    assert {:ok, renewed} = Prima.DeviceCert.decode(replacement)
    assert renewed.client_id == "pcl_hub"
    assert renewed.expires_at >= certificate["expires_at"]
  end

  test "the preflight is answered before anything is read", %{conn: conn} do
    preflight =
      conn
      |> put_req_header("origin", @hub)
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "content-type")
      |> options("/certify/v1/renew")

    assert preflight.status == 204
    assert get_resp_header(preflight, "access-control-allow-origin") == ["*"]
    assert get_resp_header(preflight, "access-control-allow-methods") |> hd() =~ "POST"
  end

  test "a session cookie the browser sends chooses nobody; the proof is still asked for",
       %{conn: conn, person: person, certificate: certificate} do
    signed_in =
      conn
      |> Plug.Test.init_test_session(%{sanctum_session_token: person.token})
      |> renew(%{"certificate" => certificate, "proof" => %{"not" => "a proof"}})

    assert %{"code" => "unauthenticated"} = json_response(signed_in, 401)
  end

  test "each refusal is the refusal shape at its class's status",
       %{conn: conn, person: person, certificate: certificate, private: private} do
    # The challenge reads nothing: a certification this home does not hold
    # is answered to the proof.
    nobody = %{certificate | "client_id" => "pcl_nobody"}
    unknown = renew(conn, %{"certificate" => nobody, "proof" => proved(nobody, private)})
    assert %{"code" => "not_found", "message" => message} = json_response(unknown, 404)
    assert message =~ "certify it again"

    malformed = renew(build_conn(), %{"certificate" => "nope"})
    assert %{"code" => "invalid_argument"} = json_response(malformed, 400)

    {1, _} =
      Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^person.user.id),
        set: [head_hash: Prima.Digest.sha256("rotated")]
      )

    ended =
      renew(build_conn(), %{"certificate" => certificate, "proof" => proved(certificate, private)})

    assert %{"code" => "conflict", "message" => message} = json_response(ended, 409)
    assert message =~ "keys changed"
  end

  # The challenge the first call answers for `certificate`, signed by
  # `private`: the proof the second call carries.
  defp proved(certificate, private) do
    first = renew(build_conn(), %{"certificate" => certificate})
    assert %{"challenge" => challenge} = json_response(first, 200)
    {:ok, held} = Challenge.decode(challenge)
    Proof.encode(Proof.sign(held, private))
  end
end
