# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.HandleControllerTest do
  @moduledoc """
  The handle registry's routes beside the directory, through the endpoint:
  a handle's answer as `cyfr-handle/v1` bytes, by its name and by the
  account holding it, a claim `201` then `200`,
  each refusal in the registry's envelope with its code and status from
  `Prima.RegistryRequest.refusals/0`, and a node serving no directory or
  a mirror answering as the directory's routes do. A home that is its own
  registry learns a person's name at sign-in from these routes, over HTTP.
  """

  # The directory setting, this node's public URL and this member's rate
  # counters are process-wide.
  use CyfrWeb.ConnCase, async: false

  alias Prima.{HandleAnswer, RegistryRequest}
  alias Prima.Identity
  alias Prima.Identity.{Entry, Key}

  @directory "https://dir.example"
  @token String.duplicate("4e", 32)

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

  test "an account's handle answers by its identifier, and one holding none is not found", %{
    conn: conn
  } do
    alice = account!()
    bob = account!()

    by_identifier = fn account ->
      get(build_conn(), "/v1/identities/#{account.identifier}/handle")
    end

    assert code(get(conn, "/v1/identities/#{alice.identifier}/handle"), 404) ==
             "HANDLE_NOT_FOUND"

    assert %{"handle" => "alice"} =
             json_response(claim(build_conn(), claim_bytes(alice, "alice")), 201)

    answered = by_identifier.(alice)
    assert answered.status == 200
    assert get_resp_header(answered, "content-type") == ["application/json; charset=utf-8"]
    assert {:ok, answer} = HandleAnswer.parse(answered.resp_body, "alice", "dir.example")

    assert answer == %HandleAnswer{
             registry: "dir.example",
             handle: "alice",
             identifier: alice.identifier,
             directory: @directory
           }

    # The same bytes the handle's own answer is.
    assert answered.resp_body == get(build_conn(), "/v1/handles/alice").resp_body

    # An account holding no name, one this directory does not hold, and an
    # identifier outside its grammar: no one's name.
    for identifier <- [bob.identifier, "per_" <> String.duplicate("c", 64), "per_x", "alice"] do
      assert code(get(build_conn(), "/v1/identities/#{identifier}/handle"), 404) ==
               "HANDLE_NOT_FOUND",
             identifier
    end

    # A mirror answers the read.
    Cyfr.Test.Settings.put("directory_serve", "mirror")
    assert by_identifier.(alice).resp_body == answered.resp_body
  end

  test "the reads by name and by identifier share the directory's per-source window", %{
    conn: conn
  } do
    alice = account!()
    path = "/v1/identities/#{alice.identifier}/handle"

    refused =
      Stream.repeatedly(fn -> get(build_conn(), path) end)
      |> Enum.find(&(&1.status == 429))

    assert code(refused, 429) == "RATE_LIMITED"
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) > 0
    assert code(get(conn, "/v1/handles/alice"), 429) == "RATE_LIMITED"
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

    assert json_response(get(build_conn(), "/v1/identities/#{alice.identifier}/handle"), 404) ==
             %{"error" => "not_served"}
  end

  # A home that names itself as its account service: it serves the
  # directory and the registry as their writer, at its origin, and names
  # that origin as its directory and its registry.
  defp self_named!(home) do
    Prima.Test.Env.put_app_env(:sanctum, :public_url, home)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, home)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    registry = URI.parse(home) |> then(&"#{&1.host}:#{&1.port}")

    for app <- [:sanctum, :cyfr],
        do: Prima.Test.Env.put_app_env(app, :registry_url, registry)

    targets = Application.get_env(:sanctum, :private_egress_targets, [])

    Prima.Test.Env.put_app_env(
      :sanctum,
      :private_egress_targets,
      Enum.uniq(targets ++ ["127.0.0.1"])
    )

    # The installation holds no person: the first comes in under setup.
    Arca.Repo.delete_all(Arca.Schemas.User)
  end

  # An account at the home's directory with one device key, its name
  # `handle` claimed at the home's registry: the account pages' genesis,
  # the key the recovery key adds, and the claim it signs.
  defp named_account!(home, handle) do
    {pub, priv} = keypair()
    {device_pub, _device_priv} = device = keypair()
    signer = Identity.recovery_signer(pub)
    source = "203.0.113.4"

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: now(),
        signer: signer,
        directory: home,
        recovery: [pub]
      )

    genesis = Identity.sign(genesis, priv)
    {:ok, key} = Key.new(alg: :ed25519, kind: :device, pub: device_pub)

    {:ok, added} =
      Entry.new(
        kind: :add_key,
        prev: Identity.hash(genesis),
        seq: 1,
        at: now(),
        signer: signer,
        key: key
      )

    {:ok, %{identifier: identifier}} =
      Sanctum.Directory.register(%{genesis: Entry.encode(genesis), source: source})

    {:ok, _appended} =
      Sanctum.Directory.append(identifier, %{
        entry: Entry.encode(Identity.sign(added, priv)),
        source: source
      })

    {:ok, request} =
      RegistryRequest.new(
        registry: URI.parse(home).host,
        operation: "handle.claim",
        identifier: identifier,
        signer: signer,
        nonce: :crypto.strong_rand_bytes(16),
        expires_at: now() + RegistryRequest.lifetime_ms(),
        body: %{"handle" => handle}
      )

    {:ok, bytes} = RegistryRequest.sign(request, priv)
    assert %{"handle" => ^handle} = json_response(claim(build_conn(), bytes), 201)
    %{identifier: identifier, device: device}
  end

  # The device's hello under the setup token: the first person, and the
  # name their sign-in recorded.
  defp signed_in_name(account) do
    admitted =
      Sanctum.Test.Devices.admitted!(
        %{identifier: account.identifier},
        account.device,
        {:setup, @token}
      )

    {:ok, user} = Sanctum.Tenancy.Users.get(admitted.user.id)
    user.namespace
  end

  # Its listener answers nothing at its origin's address, as in the shipped
  # stack, where it binds the edge network's: the lookup reads the
  # registry where it is kept.
  test "a sign-in on a home that names itself as its account service learns the person's name, and its names resolve" do
    {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(closed)
    :ok = :gen_tcp.close(closed)
    home = "http://127.0.0.1:#{port}"
    self_named!(home)
    account = named_account!(home, "mira")

    assert signed_in_name(account) == "mira"

    # Its people are named by their name there too, as when one is added
    # to an allowlist by it.
    assert {:ok, %HandleAnswer{identifier: identifier}} = Sanctum.Handle.resolve("mira")
    assert identifier == account.identifier
    assert {:error, :not_found} = Sanctum.Handle.resolve("nobody")
  end

  # The registry a CYFR reached over HTTP: this endpoint on loopback,
  # answering as a mirror of the account service, which a home reads over
  # the wire as it reads any registry it is not the writer of.
  test "a sign-in on a home whose registry is a CYFR reached over HTTP learns the person's name" do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: CyfrWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    home = "http://127.0.0.1:#{port}"
    self_named!(home)
    account = named_account!(home, "mira")
    Cyfr.Test.Settings.put("directory_serve", "mirror")

    assert signed_in_name(account) == "mira"
  end

  test "the only registry routes are the handle's answer and a personal claim", %{conn: conn} do
    for {method, path} <- [
          {:post, "/v1/namespaces/publisher/claim"},
          {:post, "/v1/tokens/mint"},
          {:get, "/v1/legal/current"},
          {:get, "/v1/namespaces/alice"}
        ] do
      assert dispatch(conn, @endpoint, method, path, nil).status == 404, "#{method} #{path}"
    end
  end
end
