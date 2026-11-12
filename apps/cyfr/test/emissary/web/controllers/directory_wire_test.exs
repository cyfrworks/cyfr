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

  The fixture's handles section holds the handle registry's name routes
  beside it to the same answers here as at cyfr.run: a claim, its repeat,
  each name read by name and by identifier, and no one's name, in what
  this CYFR's own client reads of them.
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

  for scenario <- @vectors["handles"]["scenarios"] do
    @scenario scenario
    test "names: " <> scenario["name"] do
      for {step, index} <- Enum.with_index(@scenario["steps"], 1) do
        name_step("#{@scenario["name"]}, step #{index}", step)
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

  defp name_step(_context, %{"tombstone" => _identifier} = step), do: run_step(nil, step, nil)

  defp name_step(context, %{"register" => entry}) do
    request = %{
      "method" => "POST",
      "path" => "/directory/v1/register",
      "body" => Jason.decode!(@vectors["entries"][entry])
    }

    response = send_request(Map.put(request, "source", fresh_source()), 200)
    assert response.status == 200, "#{context}: register #{entry}: #{response.resp_body}"
  end

  defp name_step(context, %{"claim" => claim, "expect" => expected}) do
    request = %{
      "method" => "POST",
      "path" => "/v1/namespaces/personal/claim",
      "body" => claim_request(claim)
    }

    response = send_request(Map.put(request, "source", fresh_source()), expected["status"])
    assert_named(response, expected, "#{context}: claim #{claim["handle"]}")
  end

  defp name_step(context, %{"request" => request, "expect" => expected}) do
    response = send_request(Map.put(request, "source", fresh_source()), expected["status"])
    assert_named(response, expected, "#{context}: #{request["method"]} #{request["path"]}")
  end

  # The step's handle.claim, signed now by its key as the recovery signer.
  defp claim_request(%{"signer" => signer, "identifier" => identifier, "handle" => handle}) do
    seed = Base.url_decode64!(@vectors["keys"][signer]["seed"], padding: false)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)

    {:ok, request} =
      Prima.RegistryRequest.new(
        registry: @vectors["handles"]["registry"],
        operation: "handle.claim",
        identifier: identifier,
        signer: Prima.Identity.recovery_signer(public),
        nonce: :crypto.strong_rand_bytes(Prima.RegistryRequest.nonce_bytes()),
        expires_at: System.os_time(:millisecond) + Prima.RegistryRequest.lifetime_ms(),
        body: %{"handle" => handle}
      )

    {:ok, bytes} = Prima.RegistryRequest.sign(request, private)
    Jason.decode!(bytes)
  end

  # An answer is the whole object; a refusal is the envelope in the grammar
  # every client reads it by, its first error naming the code.
  defp assert_named(response, expected, context) do
    assert response.status == expected["status"], "#{context}: #{response.resp_body}"
    body = Jason.decode!(response.resp_body)

    case expected do
      %{"answer" => answer} ->
        assert body == answer, context

      %{"code" => code} ->
        assert %{"errors" => [%{"code" => ^code, "message" => message} | _]} = body, context
        assert is_binary(message), context

        assert jcs_value?(body),
               "#{context}: the envelope holds a null or a number no client reads"
    end
  end

  # Whether a decoded value is in the domain every client's JCS takes: no
  # null, and every number an integer of at most 2^53 - 1 in magnitude.
  defp jcs_value?(value) when is_map(value), do: Enum.all?(value, fn {_k, v} -> jcs_value?(v) end)
  defp jcs_value?(value) when is_list(value), do: Enum.all?(value, &jcs_value?/1)
  defp jcs_value?(value) when is_integer(value), do: abs(value) <= 9_007_199_254_740_991
  defp jcs_value?(value), do: is_binary(value) or is_boolean(value)

  # A source no other request of the run has presented, so no rate window
  # is reached.
  defp fresh_source do
    n = System.unique_integer([:positive])
    "198.18.#{rem(div(n, 254), 254)}.#{rem(n, 254) + 1}"
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
