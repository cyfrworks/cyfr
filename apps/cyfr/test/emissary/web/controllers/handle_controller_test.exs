# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.HandleControllerTest do
  @moduledoc """
  The handle registry's routes beside the directory, through the endpoint:
  a handle's answer as `cyfr-handle/v1` bytes, a claim `201` then `200`,
  each refusal in the registry's envelope with its code and status from
  `Prima.RegistryRequest.refusals/0`, and a node serving no directory or
  a mirror answering as the directory's routes do.
  """

  # The directory setting, this node's public URL and this member's rate
  # counters are process-wide.
  use CyfrWeb.ConnCase, async: false

  alias Prima.{HandleAnswer, RegistryRequest}
  alias Prima.Identity
  alias Prima.Identity.Entry

  @directory "https://dir.example"

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.Env.put_app_env(:sanctum, :public_url, @directory)
    Cyfr.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp now, do: System.os_time(:millisecond)

  # An account registered here, its genesis signed by its recovery key.
  defp account! do
    {pub, priv} = recovery = keypair()

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: now(),
        signer: Identity.recovery_signer(pub),
        directory: @directory,
        recovery: [pub]
      )

    genesis = Identity.sign(genesis, priv)

    {:ok, %{identifier: identifier}} =
      Sanctum.Directory.register(%{genesis: Entry.encode(genesis), source: "203.0.113.4"})

    %{identifier: identifier, recovery: recovery}
  end

  # A `handle.claim` request signed by the account's recovery key, or by
  # `private` under the same signer.
  defp claim_bytes(account, handle, private \\ nil) do
    {pub, priv} = account.recovery

    {:ok, request} =
      RegistryRequest.new(
        registry: "dir.example",
        operation: "handle.claim",
        identifier: account.identifier,
        signer: Identity.recovery_signer(pub),
        nonce: :crypto.strong_rand_bytes(16),
        expires_at: now() + RegistryRequest.lifetime_ms(),
        body: %{"handle" => handle}
      )

    {:ok, bytes} = RegistryRequest.sign(request, private || priv)
    bytes
  end

  defp claim(conn, bytes) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/namespaces/personal/claim", bytes)
  end

  defp code(conn, status) do
    assert %{"errors" => [%{"code" => code}]} = json_response(conn, status)
    code
  end

  test "a claim is 201, the same claim again 200, and the handle answers the account", %{
    conn: conn
  } do
    alice = account!()

    assert code(get(conn, "/v1/handles/alice"), 404) == "HANDLE_NOT_FOUND"

    assert json_response(claim(build_conn(), claim_bytes(alice, "alice")), 201) == %{
             "handle" => "alice",
             "identifier" => alice.identifier
           }

    assert %{"handle" => "alice"} =
             json_response(claim(build_conn(), claim_bytes(alice, "alice")), 200)

    answered = get(build_conn(), "/v1/handles/alice")
    assert answered.status == 200
    assert {:ok, answer} = HandleAnswer.parse(answered.resp_body, "alice", "dir.example")
    assert answer.identifier == alice.identifier
    assert answer.directory == @directory
    assert answered.resp_body == HandleAnswer.encode(answer)
  end

  test "each refusal is the registry's code and status", %{conn: conn} do
    alice = account!()
    bob = account!()
    {_pub, stranger} = keypair()
    assert %{"handle" => "alice"} = json_response(claim(conn, claim_bytes(alice, "alice")), 201)

    assert code(claim(build_conn(), claim_bytes(bob, "alice")), 409) == "SLUG_TAKEN"
    assert code(claim(build_conn(), claim_bytes(alice, "other")), 409) == "ALREADY_CLAIMED"
    assert code(claim(build_conn(), claim_bytes(bob, "bob", stranger)), 401) == "BAD_SIGNATURE"
    assert code(claim(build_conn(), "{}"), 400) == "REQUEST_MALFORMED"

    stranger_account = %{bob | identifier: "per_" <> String.duplicate("c", 64)}

    assert code(claim(build_conn(), claim_bytes(stranger_account, "carol")), 404) ==
             "UNKNOWN_IDENTITY"
  end

  test "a node serving no directory answers 404 not_served, and a mirror takes no claim", %{
    conn: conn
  } do
    alice = account!()
    bytes = claim_bytes(alice, "alice")

    Cyfr.Test.Settings.put("directory_serve", "mirror")
    refused = claim(conn, bytes)
    assert json_response(refused, 405) == %{"error" => "read_only"}
    assert get_resp_header(refused, "allow") == ["GET"]

    Cyfr.Test.Settings.put("directory_serve", "off")
    assert json_response(claim(build_conn(), bytes), 404) == %{"error" => "not_served"}

    assert json_response(get(build_conn(), "/v1/handles/alice"), 404) == %{
             "error" => "not_served"
           }
  end

  test "the only registry routes are the handle's answer and a personal claim", %{conn: conn} do
    for {method, path} <- [
          {:post, "/v1/namespaces/publisher/claim"},
          {:post, "/v1/tokens/mint"},
          {:get, "/v1/legal/current"},
          {:get, "/v1/namespaces/alice"}
        ] do
      assert_error_sent 404, fn -> dispatch(conn, @endpoint, method, path, nil) end
    end
  end
end
