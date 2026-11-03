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

  import Cyfr.Test.ProtectedDevice, only: [key: 0, b64: 1, signed: 2, reported: 2]

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

  test "the request log keeps no setup token" do
    assert Prima.Sanitizer.sanitize(%{"x-cyfr-setup-token" => @token}) == %{
             "x-cyfr-setup-token" => "[REDACTED]"
           }
  end
end
