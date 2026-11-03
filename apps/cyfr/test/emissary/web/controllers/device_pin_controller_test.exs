# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DevicePinControllerTest do
  @moduledoc """
  A locked remote device's PIN over HTTP (`POST /device/pin/evaluate` and
  `/device/pin/reset`, `tests/fixtures/device_pin.json`, `exchange`): no
  session, channel or cookie; the answer and every refusal in the wire's
  shapes and codes; an unknown, a suspended and a revoked evaluator
  answered byte for byte alike; the wait's `next_allowed_at` and
  `retry-after`; and the evaluator identifier admitted nowhere else.
  """

  use Emissary.Web.ConnCase, async: false

  import Cyfr.Test.ProtectedDevice
  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DevicePinEvaluator, PairedClient}

  @token String.duplicate("5f", 32)
  @vectors Path.expand("../../../../../../tests/fixtures/device_pin.json", __DIR__)

  setup do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(Arca.Schemas.User)
    device = enrolled!(@token)
    client_id = device.certificate.client_id

    {1, _} =
      Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^client_id),
        set: [holder_kind: "software"]
      )

    ctx = connected!(device)
    %{device: device, ctx: ctx, evaluator: pin!(device, ctx)}
  end

  defp exchange, do: (@vectors |> File.read!() |> Jason.decode!())["exchange"]

  defp pin!(device, ctx) do
    {:error, {:confirmation_required, %{id: secret}}} = Sanctum.DevicePin.enroll(ctx)
    ref = Prima.Confirmation.ref(secret)

    {:ok, %{confirmations: [record]}} =
      Sanctum.Providers.Confirmation.handle(ctx, %{"action" => "pending", "request" => ref})

    {:ok, challenge} = Prima.DeviceCert.Challenge.decode(record.challenge)

    {:ok, _} =
      Sanctum.Providers.Confirmation.handle(ctx, %{
        "action" => "confirm",
        "ref" => ref,
        "device_proof" => signed(challenge, elem(device.key, 1))
      })

    {:ok, %{evaluator: evaluator}} = Sanctum.DevicePin.enroll(%{ctx | confirmation_id: secret})
    evaluator
  end

  defp element, do: :libsodium_crypto_core_ristretto255.from_hash(:crypto.strong_rand_bytes(64))

  defp post_json(entry, body) do
    %{"method" => "POST", "path" => path} = exchange()[entry]

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp evaluate(evaluator, blinded \\ element()),
    do: post_json("evaluate", %{"evaluator" => evaluator, "blinded" => b64(blinded)})

  defp waited!(evaluator) do
    digest = :crypto.hash(:sha256, evaluator)

    {1, _} =
      Arca.Repo.update_all(from(e in DevicePinEvaluator, where: e.identifier_digest == ^digest),
        set: [next_allowed_at: 0]
      )
  end

  defp code(error), do: exchange()["refusals"]["codes"][error]

  test "an evaluation answers its element and reset challenge, then waits, and a reset clears it",
       %{
         device: device,
         evaluator: evaluator
       } do
    conn = evaluate(evaluator)
    body = json_response(conn, 200)
    assert Enum.sort(Map.keys(body)) == exchange()["evaluate"]["answer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []

    conn = evaluate(evaluator)
    wait = json_response(conn, code("pin_wait"))
    assert Enum.sort(Map.keys(wait)) == Enum.sort(exchange()["refusals"]["pin_wait"])
    assert %{"error" => "pin_wait", "next_allowed_at" => next} = wait
    assert is_integer(next)
    assert [retry] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) in 1..2

    {:ok, challenge} = Prima.DeviceCert.Challenge.decode(body["reset"])
    proof = signed(challenge, elem(device.key, 1))
    conn = post_json("reset", %{"proof" => proof})
    assert json_response(conn, 200) == %{"reset" => true}
    assert Enum.sort(Map.keys(json_response(conn, 200))) == exchange()["reset"]["answer"]

    replayed = post_json("reset", %{"proof" => proof})
    assert json_response(replayed, code("proof_refused")) == %{"error" => "proof_refused"}

    assert json_response(evaluate(evaluator), 200)
  end

  test "an unknown, a suspended and a revoked evaluator are answered alike", %{
    device: device,
    ctx: ctx,
    evaluator: evaluator
  } do
    answers = fn id ->
      conn = evaluate(id)
      {conn.status, conn.resp_body, get_resp_header(conn, "retry-after")}
    end

    unknown = answers.(Prima.DevicePin.new_evaluator())
    assert {404, _, []} = unknown
    assert Jason.decode!(elem(unknown, 1)) == %{"error" => "not_found"}
    assert code("not_found") == 404

    client_id = device.certificate.client_id

    {1, _} =
      Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^client_id),
        set: [standing: "suspended"]
      )

    assert answers.(evaluator) == unknown

    {1, _} =
      Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^client_id),
        set: [standing: "active"]
      )

    {:ok, _} = Arca.PairedClients.revoke(Sanctum.Context.actor(ctx), client_id)
    assert answers.(evaluator) == unknown
  end

  test "a body that is not exactly one element is a bad request and charges nothing", %{
    evaluator: evaluator
  } do
    for body <- [
          %{"evaluator" => evaluator, "blinded" => b64(element()), "extra" => 1},
          %{"evaluator" => evaluator, "blinded" => [b64(element()), b64(element())]},
          %{"evaluator" => evaluator, "blinded" => b64(<<0::256>>)},
          [%{"evaluator" => evaluator, "blinded" => b64(element())}]
        ] do
      conn = post_json("evaluate", body)

      assert json_response(conn, code("bad_request")) == %{"error" => "bad_request"},
             inspect(body)
    end

    assert json_response(post_json("reset", %{"proof" => %{}}), 400) == %{
             "error" => "bad_request"
           }

    digest = :crypto.hash(:sha256, evaluator)
    assert %{attempts: 0} = Arca.Repo.get_by!(DevicePinEvaluator, identifier_digest: digest)
  end

  test "one source past its minute's calls is refused, with its retry-after", %{
    evaluator: evaluator
  } do
    for _ <- 1..30, do: post_json("evaluate", %{})
    conn = evaluate(evaluator)
    assert json_response(conn, code("rate_limited")) == %{"error" => "rate_limited"}
    assert [_retry] = get_resp_header(conn, "retry-after")
    waited!(evaluator)
  end

  test "the evaluator identifier is no credential anywhere else", %{evaluator: evaluator} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> evaluator)
      |> put_req_header("content-type", "application/json")
      |> post("/device/session", Jason.encode!(%{"ticket" => evaluator}))

    assert json_response(conn, 403) == %{"error" => "ticket_refused"}

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> evaluator)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    assert conn.status == 401
  end

  test "the request log keeps neither the identifier, the elements nor the proof" do
    assert Prima.Sanitizer.sanitize(%{
             "evaluator" => "pev_x",
             "blinded" => "b",
             "evaluated" => "e",
             "proof" => %{"sig" => "s"}
           }) == %{
             "evaluator" => "[REDACTED]",
             "blinded" => "[REDACTED]",
             "evaluated" => "[REDACTED]",
             "proof" => "[REDACTED]"
           }
  end
end
