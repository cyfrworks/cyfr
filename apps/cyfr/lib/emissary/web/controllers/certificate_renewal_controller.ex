# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.CertificateRenewalController do
  @moduledoc """
  A certified device's renewal at its person's home
  (`Sanctum.RemoteCertification`): `POST /certify/v1/renew`, which the
  device's page at the other home reaches with `fetch` and no
  credentials.

  The body is a JSON object of at most 16 KiB
  (`CyfrWeb.Plugs.RawBodyReader`): `certificate`, a certificate this home
  issued for the device, which only locates its certification, and, on the
  second call, `proof`, the device key's signature over the challenge the
  first call answered. The request is the anonymous operation
  `person.renew_certificate`, through the gate under the request's own
  call id: nothing about the caller chooses the person, no session is
  read, and the proof is the only credential.

  Answers `200 {"challenge": …}` to a first call and `200 {"certificate":
  …}`, the replacement, to the proof. A refusal is the refusal shape
  (`CyfrWeb.ApiError`, `{"code", "message"}`) at its class's status:
  `404` no certification here, `409` a certification that ended (the
  person's keys changed) or was replaced, `401` a refused proof, `429` a
  spent verification bound, `503` a store that could not answer. CORS
  answers every origin `*` and never allows credentials, so no cookie
  travels with it in either direction.
  """

  use Emissary.Web, :controller

  alias CyfrWeb.Plugs.CallIdentity

  @fields ["certificate", "proof"]

  @doc "`POST /certify/v1/renew`."
  def renew_certificate(conn, params) do
    ctx = context(conn)
    args = params |> Map.take(@fields) |> Map.put("action", "renew_certificate")

    case Grimoire.call_external("person", ctx, args, call_id: ctx.call_id) do
      {:ok, answer} ->
        conn
        |> CallIdentity.decided()
        |> json(answer)

      {:error, reason} ->
        conn
        |> CallIdentity.decided()
        |> CyfrWeb.ApiError.refuse(reason)
    end
  end

  # The anonymous caller a device is here: no person, no athanor, no auth
  # method, and the request's address, by which the verification bounds
  # count it. A person's device acting is an interactive admission.
  defp context(conn) do
    ctx =
      Sanctum.Context.build(
        user_id: nil,
        athanor_id: nil,
        permissions: [],
        scope: :athanor,
        auth_method: nil,
        authenticated: false,
        client_ip: Sanctum.ClientIp.resolve(conn),
        origin: :interactive
      )

    CallIdentity.stamp(conn, ctx)
  end
end
