# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DeviceEnrollmentControllerTest do
  @moduledoc """
  A protected device's enrollment over HTTP (`tests/fixtures/device_unlock.json`,
  `exchange.http`): the setup token in its own header and nowhere else, a
  challenge and a completion that answer the certificate and the recovery
  code, a resume by the committed key, and each refusal as `{error}` under
  the status the fixture names. The request log never keeps the token.
  """

  use Emissary.Web.ConnCase, async: false

  import Cyfr.Test.ProtectedDevice, only: [key: 0, b64: 1, signed: 2, reported: 2, reported: 3]

  alias Prima.DeviceCert
  alias Prima.DeviceCert.Challenge

  @token String.duplicate("4c", 32)
  @vectors Path.expand("../../../../../../tests/fixtures/device_unlock.json", __DIR__)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
    end)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    :ok
  end

  defp http, do: (@vectors |> File.read!() |> Jason.decode!())["exchange"]["http"]

  defp post_json(path, body, token \\ @token) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "x-cyfr-setup-token", token), else: conn
    post(conn, path, Jason.encode!(body))
  end

  test "setup enrolls the device and answers its certificate and the recovery code, in the fixture's fields" do
    http = http()
    device = key()
    identity = Sanctum.Test.Newcomers.identity()
    request = reported(device, identity.request_id)
    assert Enum.sort(Map.keys(request)) == http["enrollment_challenge"]["request"]

    conn = post_json(http["enrollment_challenge"]["path"], request)
    assert %{"challenge" => challenge} = body = json_response(conn, 200)
    assert Map.keys(body) == http["enrollment_challenge"]["response"]
    {:ok, challenge} = Challenge.decode(challenge)

    complete = %{
      "proof" => signed(challenge, elem(device, 1)),
      "name" => identity.name,
      "recovery_secret" => b64(identity.recovery_secret)
    }

    assert Enum.sort(Map.keys(complete)) == http["enrollment_complete"]["request"]["setup"]
    conn = post_json(http["enrollment_complete"]["path"], complete)
    assert %{"certificate" => certificate, "recovery" => recovery} = json_response(conn, 200)
    assert Enum.sort(Map.keys(recovery)) == http["enrollment_complete"]["recovery"]
    assert {:ok, %DeviceCert{device_key: device_key}} = DeviceCert.decode(certificate)
    assert device_key == elem(device, 0)

    # The resume answers the same, to the same key's proof.
    ask = %{
      "admission" => "setup",
      "device_key" => b64(elem(device, 0)),
      "request_id" => identity.request_id
    }

    [first, second] = http["enrollment_resume"]
    conn = post_json(first["path"], ask)
    assert %{"challenge" => resume} = json_response(conn, 200)
    {:ok, resume} = Challenge.decode(resume)
    conn = post_json(second["path"], %{"proof" => signed(resume, elem(device, 1))})
    assert %{"certificate" => ^certificate, "recovery" => ^recovery} = json_response(conn, 200)
  end

  test "each refusal is the fixture's code under its status" do
    http = http()
    codes = http["refusals"]["codes"]
    request = reported(key(), "req_refused")

    conn = post_json(http["enrollment_challenge"]["path"], request, nil)
    assert json_response(conn, codes["invalid_token"]) == %{"error" => "invalid_token"}

    conn = post_json(http["enrollment_challenge"]["path"], %{request | "holder_kind" => "x"})
    assert json_response(conn, codes["invalid_request"]) == %{"error" => "invalid_request"}

    conn = post_json(http["enrollment_complete"]["path"], %{"proof" => %{}})
    assert json_response(conn, codes["proof_refused"]) == %{"error" => "proof_refused"}

    conn =
      post_json(
        http["enrollment_resume"] |> hd() |> Map.fetch!("path"),
        Map.delete(request, "holder_kind")
      )

    assert json_response(conn, codes["not_found"]) == %{"error" => "not_found"}

    # Restore's challenge without a restore's session.
    conn = post_json(http["enrollment_challenge"]["path"], %{request | "admission" => "restore"})
    assert json_response(conn, codes["not_restored"]) == %{"error" => "not_restored"}
  end

  defp post_with(path, body, headers) do
    conn = put_req_header(build_conn(), "content-type", "application/json")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    post(conn, path, Jason.encode!(body))
  end

  defp new_person(http, headers, admission) do
    device = key()
    identity = Sanctum.Test.Newcomers.identity()

    conn =
      post_with(
        http["enrollment_challenge"]["path"],
        reported(device, identity.request_id, admission),
        headers
      )

    %{"challenge" => challenge} = json_response(conn, 200)
    {:ok, challenge} = Challenge.decode(challenge)

    complete = %{
      "proof" => signed(challenge, elem(device, 1)),
      "name" => identity.name,
      "recovery_secret" => b64(identity.recovery_secret)
    }

    assert Enum.sort(Map.keys(complete)) == http["enrollment_complete"]["request"][admission]
    {post_with(http["enrollment_complete"]["path"], complete, headers), device, identity}
  end

  describe "a new person under an invitation or the open admission" do
    setup do
      %{certificate: %{subject: %{user_id: admin_id}}} =
        Cyfr.Test.ProtectedDevice.enrolled!(@token)

      ctx = Sanctum.TestContext.session!(admin_id)
      {:ok, %{code: code}} = Sanctum.Invitations.create(ctx, nil)
      %{code: code}
    end

    test "an invitation's code travels in its header, enrolls, and resumes under the same header",
         %{code: code} do
      http = http()
      header = http["credentials"]["invitation"]["challenge"]["header"]
      assert http["credentials"]["invitation"]["resume"]["header"] == header

      {conn, {public, private}, identity} = new_person(http, [{header, code}], "invitation")
      assert %{"certificate" => certificate, "recovery" => _recovery} = json_response(conn, 200)

      ask = %{
        "admission" => "invitation",
        "device_key" => b64(public),
        "request_id" => identity.request_id
      }

      [first, second] = http["enrollment_resume"]

      assert json_response(
               post_with(first["path"], ask, []),
               http["refusals"]["codes"]["invalid_token"]
             ) ==
               %{"error" => "invalid_token"}

      conn = post_with(first["path"], ask, [{header, code}])
      {:ok, resume} = Challenge.decode(json_response(conn, 200)["challenge"])

      conn = post_with(second["path"], %{"proof" => signed(resume, private)}, [{header, code}])
      assert %{"certificate" => ^certificate} = json_response(conn, 200)

      # The code is spent.
      codes = http["refusals"]["codes"]
      {conn, _device, _identity} = new_person_refused(http, [{header, code}], "invitation")

      assert json_response(conn, codes["invitation_invalid"]) == %{
               "error" => "invitation_invalid"
             }

      assert Prima.Sanitizer.sanitize([{header, code}]) == [{header, "[REDACTED]"}]
    end

    test "an invitation enrollment cannot return its recovery through a header-free open resume",
         %{code: code} do
      entries = http()

      {conn, {public, private}, identity} =
        new_person(entries, [{"x-cyfr-invitation", code}], "invitation")

      assert %{"recovery" => %{"code" => _code}} = json_response(conn, 200)
      [first, second] = entries["enrollment_resume"]

      conn =
        post_with(
          first["path"],
          %{
            "admission" => "open",
            "device_key" => b64(public),
            "request_id" => identity.request_id
          },
          []
        )

      conn =
        if conn.status == 200 do
          {:ok, challenge} = Challenge.decode(json_response(conn, 200)["challenge"])
          post_with(second["path"], %{"proof" => signed(challenge, private)}, [])
        else
          conn
        end

      assert conn.status in 400..499,
             "header-free open resume returned HTTP #{conn.status} for an invitation enrollment"
    end

    test "the second resume request needs the redeemed invitation header too", %{code: code} do
      entries = http()

      {conn, {public, private}, identity} =
        new_person(entries, [{"x-cyfr-invitation", code}], "invitation")

      assert %{"certificate" => _certificate} = json_response(conn, 200)
      [first, second] = entries["enrollment_resume"]

      conn =
        post_with(
          first["path"],
          %{
            "admission" => "invitation",
            "device_key" => b64(public),
            "request_id" => identity.request_id
          },
          [{"x-cyfr-invitation", code}]
        )

      {:ok, challenge} = Challenge.decode(json_response(conn, 200)["challenge"])
      other = b64(:crypto.strong_rand_bytes(32))
      assert {:ok, _hash} = Sanctum.Invitations.code_hash(other)

      conn =
        post_with(second["path"], %{"proof" => signed(challenge, private)}, [
          {"x-cyfr-invitation", other}
        ])

      assert conn.status in 400..499,
             "another invitation header completed the resume with HTTP #{conn.status}"
    end

    test "the open admission takes no credential, and answers its refusals under the fixture's codes" do
      http = http()
      codes = http["refusals"]["codes"]
      assert http["credentials"]["open"]["challenge"] == "none"

      {conn, _device, _identity} = new_person_refused(http, [], "open")
      assert json_response(conn, codes["not_admitted"]) == %{"error" => "not_admitted"}

      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
      {conn, _device, _identity} = new_person(http, [], "open")
      assert %{"certificate" => _certificate} = json_response(conn, 200)

      Sanctum.Test.Settings.put("max_athanors", 1)
      {conn, _device, _identity} = new_person(http, [], "open")
      assert json_response(conn, codes["limit_reached"]) == %{"error" => "limit_reached"}

      for _ <- 1..20, do: new_person_refused(http, [], "open")
      {conn, _device, _identity} = new_person_refused(http, [], "open")
      assert json_response(conn, codes["rate_limited"]) == %{"error" => "rate_limited"}
      assert "rate_limited" in http["refusals"]["retry_after"]
      assert [_seconds] = get_resp_header(conn, "retry-after")
    end
  end

  # A challenge alone, whatever it answers.
  defp new_person_refused(http, headers, admission) do
    device = key()
    identity = Sanctum.Test.Newcomers.identity()

    conn =
      post_with(
        http["enrollment_challenge"]["path"],
        reported(device, identity.request_id, admission),
        headers
      )

    {conn, device, identity}
  end

  test "the request log keeps no setup token" do
    assert Prima.Sanitizer.sanitize(%{"x-cyfr-setup-token" => @token}) == %{
             "x-cyfr-setup-token" => "[REDACTED]"
           }
  end
end
