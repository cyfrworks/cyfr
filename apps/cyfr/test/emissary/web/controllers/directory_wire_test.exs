# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DirectoryWireTest do
  @moduledoc """
  The directory's shared HTTP scenarios through the endpoint. The same
  literal requests and expected answers hold cyfr.run's Go writer to this
  wire contract, including canonical entry bytes inside JSON responses.
  A scenario's tombstone step is the operator's own path: the platform
  administrator's `directory.tombstone` through the gate, under their
  fresh confirmation; without the confirmation, or asked by anyone else,
  it leaves the log as it was.
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

  test "the signing keys and canonical entries are portable" do
    for {_name, key} <- @vectors["keys"] do
      {public, _private} =
        case key do
          %{"alg" => "es256", "private" => private} ->
            :crypto.generate_key(:ecdh, :secp256r1, Base.url_decode64!(private, padding: false))

          %{"seed" => seed} ->
            :crypto.generate_key(:eddsa, :ed25519, Base.url_decode64!(seed, padding: false))
        end

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
        run_step(@scenario["name"], step, index)
      end
    end
  end

  test "a tombstone without its confirmation, or asked by someone who is not the platform administrator, leaves the log as it was" do
    identifier = registered!()
    admin = administrator!()

    assert {:error, _waits} = tombstone(admin, identifier)
    assert {:ok, %{length: 1}} = page(identifier)

    {person, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    refute person.platform_admin

    assert {:error, _refused} = Sanctum.TestContext.confirming(person, &tombstone(&1, identifier))
    assert {:ok, %{length: 1}} = page(identifier)

    # Under the administrator's confirmation it is gone.
    assert {:ok, _gone} = Sanctum.TestContext.confirming(admin, &tombstone(&1, identifier))
    assert {:error, :gone} = page(identifier)
  end

  # A tombstone is the operator's: the platform administrator's
  # `directory.tombstone` through the gate under their fresh confirmation,
  # never over the wire.
  defp run_step(_scenario, %{"tombstone" => identifier}, _index) do
    assert {:ok, _gone} =
             Sanctum.TestContext.confirming(administrator!(), &tombstone(&1, identifier))
  end

  defp run_step(scenario, step, index) do
    request = step["request"]
    expected = step["expect"]
    context = "#{scenario}, step #{index}: #{request["method"]} #{request["path"]}"
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

    for entry <- Map.get(body, "entries", []) do
      assert String.contains?(response.resp_body, Prima.Identity.Encoding.jcs!(entry)),
             "#{context}: entry bytes are not canonical"
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

  defp tombstone(ctx, identifier),
    do:
      Sanctum.Gate.call_external("directory", ctx, %{
        "action" => "tombstone",
        "identifier" => identifier
      })

  # The installation's platform administrator, signed in.
  defp administrator! do
    {person, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    {:ok, _row} = Sanctum.TestContext.ensure_platform(user.id)
    %{person | platform_admin: true}
  end

  defp page(identifier),
    do: Sanctum.Directory.resolve(%{identifier: identifier, after: -1, source: "203.0.113.9"})

  # An account registered at this CYFR's directory: a genesis naming its
  # origin, signed by a recovery key.
  defp registered! do
    {:ok, directory} = Prima.Identity.Encoding.canonical_home(Sanctum.origin())
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Prima.Identity.Entry.new(
        kind: :genesis,
        seq: 0,
        at: System.os_time(:millisecond),
        signer: Prima.Identity.recovery_signer(pub),
        directory: directory,
        recovery: [pub]
      )

    genesis = Prima.Identity.sign(genesis, priv)

    {:ok, %{identifier: identifier, result: :created}} =
      Sanctum.Directory.register(%{
        genesis: Prima.Identity.Entry.encode(genesis),
        source: "203.0.113.9"
      })

    identifier
  end

  defp assert_field(actual, %{"min" => min, "max" => max}, "retry_after", context),
    do: assert(is_integer(actual) and actual >= min and actual <= max, context)

  defp assert_field(actual, expected, _field, context), do: assert(actual == expected, context)
end
