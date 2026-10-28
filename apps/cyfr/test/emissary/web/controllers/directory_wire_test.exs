# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DirectoryWireTest do
  @moduledoc """
  The directory's shared HTTP scenarios through the endpoint. The same
  literal requests and expected answers hold cyfr.run's Go writer to this
  wire contract, including canonical entry bytes inside JSON responses.
  """
  use CyfrWeb.ConnCase, async: false

  @fixture Path.expand("../../../../../../tests/fixtures/directory_wire.json", __DIR__)
  @external_resource @fixture
  @vectors @fixture |> File.read!() |> Jason.decode!()

  setup do
    for {key, value} <- [
          public_url: @vectors["directory"],
          proxy_trust: {:cidrs, ["192.0.2.1"]}
        ] do
      previous = Application.fetch_env(:sanctum, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:sanctum, key, value)
          :error -> Application.delete_env(:sanctum, key)
        end
      end)

      Application.put_env(:sanctum, key, value)
    end

    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Cyfr.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  test "the signing seeds and canonical entries are portable" do
    for {_name, key} <- @vectors["keys"] do
      seed = Base.url_decode64!(key["seed"], padding: false)
      {public, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
      assert Base.url_encode64(public, padding: false) == key["public"]
    end

    for {_name, canonical} <- @vectors["entries"] do
      {:ok, entry} = canonical |> Jason.decode!() |> Prima.Identity.Entry.decode()
      assert Prima.Identity.canonical(entry) == canonical
    end
  end

  for scenario <- @vectors["scenarios"] do
    @scenario scenario
    test scenario["name"] do
      for {key, value} <- @scenario["settings"] || %{} do
        Cyfr.Test.Settings.put("directory_" <> key, value)
      end

      for {step, index} <- Enum.with_index(@scenario["steps"], 1) do
        request = step["request"]
        expected = step["expect"]
        context = "#{@scenario["name"]}, step #{index}: #{request["method"]} #{request["path"]}"
        response = send_request(request, expected["status"])
        assert response.status == expected["status"], context

        body = if response.status == 413, do: %{}, else: Jason.decode!(response.resp_body)

        for {field, value} <- expected["body"] do
          assert Map.has_key?(body, field), "#{context}: missing #{field}"
          assert_field(body[field], value, field, context)
        end

        for {name, value} <- expected["headers"] do
          value =
            case value do
              %{"body_field" => field} -> Integer.to_string(Map.fetch!(body, field))
              literal -> literal
            end

          assert get_resp_header(response, String.downcase(name)) == [value], context
        end

        for entry <- Map.get(body, "entries", []) ++ List.wrap(body["entry"]) do
          assert String.contains?(response.resp_body, Prima.Identity.Encoding.jcs!(entry)),
                 "#{context}: entry bytes are not canonical"
        end
      end
    end
  end

  defp send_request(request, status) do
    conn =
      %{build_conn() | remote_ip: {192, 0, 2, 1}}
      |> Sanctum.ClientIp.put_ingress(:proxy)
      |> put_req_header("x-forwarded-for", request["source"] || "198.51.100.1")
      |> put_req_header("content-type", "application/json")

    target = request["path"]
    query = request["query"] || %{}
    target = if map_size(query) == 0, do: target, else: target <> "?" <> URI.encode_query(query)
    body = if is_nil(request["body"]), do: nil, else: Jason.encode!(request["body"])
    send = fn -> dispatch(conn, @endpoint, String.downcase(request["method"]), target, body) end

    if status == 413 do
      {status, headers, body} = assert_error_sent(413, send)
      %Plug.Conn{status: status, resp_headers: headers, resp_body: body}
    else
      send.()
    end
  end

  defp assert_field(actual, %{"min" => min, "max" => max}, "retry_after", context),
    do: assert(is_integer(actual) and actual >= min and actual <= max, context)

  defp assert_field(actual, expected, _field, context), do: assert(actual == expected, context)
end
