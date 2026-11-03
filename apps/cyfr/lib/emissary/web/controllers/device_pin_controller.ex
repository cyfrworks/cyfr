# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DevicePinController do
  @moduledoc """
  A locked remote device's PIN evaluation and its reset
  (`Sanctum.DevicePin`, `tests/fixtures/device_pin.json`, `exchange`): no
  session, no channel and no cookie, so no CSRF token is asked. The
  evaluator identifier is the only credential the device holds while it
  is locked, and it reaches evaluation alone.

    * `POST /device/pin/evaluate` with exactly `{evaluator, blinded}`
      answers `200 {evaluated, reset}`, after the attempt is charged.
    * `POST /device/pin/reset` with exactly `{proof}`, the device key's
      `pin_reset` proof over that reset challenge, answers `200 {reset:
      true}`.

  Refusals, each `{error}` and `no-store`: `400 bad_request` for a body
  that is not exactly the request or an element that is not a group
  element; `404 not_found` for an unknown, revoked or suspended evaluator
  alike; `429 pin_wait` inside the wait, with `next_allowed_at` and a
  `retry-after` header; `422 proof_refused` for a reset that changes
  nothing; `429 rate_limited` with a `retry-after` header past 30 calls a
  minute from one source address; `503 unavailable` with a `retry-after`
  header when the store cannot answer. The identifier, the elements and the proof are
  redacted from the request log (`Prima.Sanitizer`).
  """

  use Emissary.Web, :controller

  alias CyfrWeb.Plugs.CallIdentity

  @doc "`POST /device/pin/evaluate`."
  def evaluate(conn, _params),
    do: answer(conn, Sanctum.DevicePin.evaluate(body(conn), Sanctum.ClientIp.resolve(conn)))

  @doc "`POST /device/pin/reset`."
  def reset(conn, _params),
    do: answer(conn, Sanctum.DevicePin.reset(body(conn), Sanctum.ClientIp.resolve(conn)))

  # The JSON body as sent: a body that is no object reads as one the
  # decoders refuse.
  defp body(%Plug.Conn{body_params: %{"_json" => _not_an_object}}), do: nil
  defp body(%Plug.Conn{body_params: params}) when is_map(params), do: params

  defp answer(conn, result) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case result do
      {:ok, answer} ->
        conn |> put_status(200) |> json(answer)

      {:error, {:pin_wait, next_allowed_at}} ->
        conn
        |> CallIdentity.refused(429, "pin_wait")
        |> put_resp_header("retry-after", retry_after(next_allowed_at))
        |> put_status(429)
        |> json(Prima.DevicePin.wait(next_allowed_at))

      {:error, {:rate_limited, retry_after_s}} ->
        conn
        |> CallIdentity.refused(429, "rate_limited")
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_status(429)
        |> json(%{error: "rate_limited"})

      {:error, :unavailable} ->
        conn
        |> CallIdentity.refused(503, "unavailable")
        |> put_resp_header("retry-after", "1")
        |> put_status(503)
        |> json(%{error: "unavailable"})

      {:error, reason} ->
        {status, error} = refusal(reason)

        conn
        |> CallIdentity.refused(status, error)
        |> put_status(status)
        |> json(%{error: error})
    end
  end

  defp refusal(:bad_request), do: {400, "bad_request"}
  defp refusal(:not_found), do: {404, "not_found"}
  defp refusal(:proof_refused), do: {422, "proof_refused"}

  defp retry_after(next_allowed_at) do
    wait_ms = next_allowed_at - System.system_time(:millisecond)
    Integer.to_string(max(div(wait_ms + 999, 1_000), 1))
  end
end
