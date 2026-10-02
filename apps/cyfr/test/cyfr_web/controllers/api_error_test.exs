# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ApiErrorTest do
  @moduledoc """
  The plain-HTTP rejection every controller and plug writes: the class of
  its refusal as `code`, a public sentence as `message`, the class→HTTP
  status table, the 401 challenge, and `data` for a consent signal. A
  pending confirmation's 428 is the shared vector's
  (`tests/fixtures/confirmation.json`'s `signal`), byte for byte.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias CyfrWeb.ApiError

  @vectors Path.expand("../../../../../tests/fixtures/confirmation.json", __DIR__)

  defp signal_vector, do: @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("signal")

  # The vector's signal as its producer builds it: atom keys, the expiry a
  # UTC `DateTime`.
  defp produced(value) do
    %{"tag" => tag, "payload" => payload} = Jason.decode!(value)
    {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])

    {String.to_existing_atom(tag),
     %{id: payload["id"], operation: payload["operation"], expires_at: expires_at}}
  end

  @statuses %{
    invalid_argument: 400,
    unauthenticated: 401,
    forbidden: 403,
    consent_required: 403,
    confirmation_required: 428,
    not_found: 404,
    conflict: 409,
    not_owner: 409,
    rate_limited: 429,
    setup_required: 503,
    unavailable: 503,
    timeout: 504,
    corrupt: 500,
    cancelled: 500,
    uncertain: 500,
    internal: 500
  }

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "every class has its status" do
    assert Map.keys(@statuses) |> Enum.sort() == Enum.sort(Prima.Refusal.classes())

    for {class, status} <- @statuses, do: assert(ApiError.status(class) == status)
  end

  test "a refusal answers at its class's status with its class and sentence" do
    conn = ApiError.refuse(conn(:get, "/"), :no_agent)

    assert conn.status == 503

    assert body(conn) == %{
             "code" => "setup_required",
             "message" => Prima.Refusal.message(:no_agent)
           }
  end

  test "a 401 carries the challenge, and no other status does" do
    assert ["Bearer"] ==
             conn(:get, "/")
             |> ApiError.refuse(:invalid_api_key)
             |> Plug.Conn.get_resp_header("www-authenticate")

    assert [] ==
             conn(:get, "/")
             |> ApiError.refuse(:ip_not_allowed)
             |> Plug.Conn.get_resp_header("www-authenticate")
  end

  test "an adapter's status keeps the class as the code and the row's sentence as the message" do
    # An adapter chooses the status for its route; the words are the
    # table's for every caller, whatever the adapter passed.
    conn =
      ApiError.send(
        conn(:get, "/"),
        503,
        :auth_provider_error,
        "Authentication service unavailable"
      )

    assert conn.status == 503

    assert body(conn) == %{
             "code" => "unavailable",
             "message" => Prima.Refusal.message(:auth_provider_error)
           }
  end

  test "an authorization refusal is classed by its own vocabulary" do
    conn = ApiError.refuse(conn(:get, "/"), {:missing_permission, :execute})

    assert conn.status == 403
    assert %{"code" => "forbidden", "message" => message} = body(conn)
    assert message == Sanctum.Unauthorized.message({:missing_permission, :execute})
  end

  test "a consent signal carries its data" do
    signal = {:consent_required, %{"detail" => "scope widened"}}
    conn = ApiError.refuse(conn(:get, "/"), signal)

    assert conn.status == 403

    assert body(conn) == %{
             "code" => "consent_required",
             "message" => "Consent required: scope widened",
             "data" => %{"tag" => "consent_required", "payload" => %{"detail" => "scope widened"}}
           }
  end

  test "a pending confirmation answers 428 with its signal, naming its confirmation" do
    signal =
      {:confirmation_required,
       %{
         id: "confirmation-7f3a",
         operation: "vault/create",
         expires_at: ~U[2026-09-29 12:05:00Z]
       }}

    conn = ApiError.refuse(conn(:post, "/"), signal)

    # The request stands and waits for its confirmation: neither a denial
    # (403) nor a conflict (409).
    assert conn.status == 428
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []

    assert body(conn) == %{
             "code" => "confirmation_required",
             "message" => Prima.ConsentSignal.message(signal),
             "data" => %{
               "tag" => "confirmation_required",
               "payload" => %{
                 "id" => "confirmation-7f3a",
                 "operation" => "vault/create",
                 "expires_at" => "2026-09-29T12:05:00Z"
               }
             }
           }
  end

  test "the shared vector's pending confirmation answers its status and body, byte for byte" do
    %{"value" => value, "http" => %{"status" => status, "body" => body}} = signal_vector()

    conn = ApiError.refuse(conn(:post, "/"), produced(value))

    assert conn.status == status
    assert conn.resp_body == body
  end

  test "a confirmation signal that names no confirmation is internal, not 428" do
    ExUnit.CaptureLog.capture_log(fn ->
      conn = ApiError.refuse(conn(:post, "/"), {:confirmation_required, %{operation: "x/y"}})

      assert conn.status == 500
      assert body(conn) == %{"code" => "internal", "message" => Prima.Refusal.unconfirmed()}
    end)
  end

  test "an unknown term is internal and never spelled" do
    ExUnit.CaptureLog.capture_log(fn ->
      conn = ApiError.refuse(conn(:get, "/"), {:secret, %{"token" => "sk-live"}})

      assert conn.status == 500
      assert body(conn) == %{"code" => "internal", "message" => Prima.Refusal.unconfirmed()}
    end)
  end

  test "halt/2 halts" do
    assert conn(:get, "/") |> ApiError.halt(:rate_limited) |> Map.fetch!(:halted)
  end
end
