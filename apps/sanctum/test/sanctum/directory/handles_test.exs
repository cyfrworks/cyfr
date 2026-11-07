# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.HandlesTest do
  @moduledoc """
  The handle registry a CYFR serving a directory serves beside it: a
  handle's answer as `cyfr-handle/v1` names this CYFR as the registry and
  its directory; a claim is a `handle.claim` request verified against the
  account's log as this directory stores it, one handle per account and
  one account per handle, its nonce spent once; an account the directory
  does not hold, or holds gone, is an unknown identity; a node serving no
  directory serves no handle, and a mirror takes no claim.
  """

  # The directory setting, this node's public URL and this member's rate
  # counters are process-wide.
  use ExUnit.Case, async: false

  alias Prima.{HandleAnswer, RegistryRequest}
  alias Prima.Identity
  alias Prima.Identity.{Entry, Key}
  alias Sanctum.Directory
  alias Sanctum.Directory.Handles

  @directory "https://dir.example"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.Env.put_app_env(:sanctum, :public_url, @directory)
    Sanctum.Test.Settings.put("directory_serve", "writer")
    :ok
  end

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp source, do: "203.0.113.#{rem(System.unique_integer([:positive]), 250) + 1}"
  defp now, do: System.os_time(:millisecond)

  # An account registered here: a genesis signed by its recovery key, and
  # one device key that key added.
  defp account! do
    {recovery_pub, recovery_priv} = recovery = keypair()
    {device_pub, _} = device = keypair()
    signer = Identity.recovery_signer(recovery_pub)

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: now(),
        signer: signer,
        directory: @directory,
        recovery: [recovery_pub]
      )

    genesis = Identity.sign(genesis, recovery_priv)

    {:ok, %{identifier: identifier}} =
      Directory.register(%{genesis: Entry.encode(genesis), source: source()})

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

    {:ok, %{result: :accepted}} =
      Directory.append(identifier, %{
        entry: Entry.encode(Identity.sign(added, recovery_priv)),
        source: source()
      })

    %{identifier: identifier, recovery: recovery, device: device}
  end

  # A request of `account`'s, signed by its device key unless `opts` names
  # another signer (`:signer` and `:private`) or field.
  defp request(account, handle, opts \\ []) do
    {device_pub, device_priv} = account.device

    {:ok, request} =
      RegistryRequest.new(
        registry: Keyword.get(opts, :registry, "dir.example"),
        operation: Keyword.get(opts, :operation, "handle.claim"),
        identifier: Keyword.get(opts, :identifier, account.identifier),
        signer: Keyword.get(opts, :signer, Key.kid(device_pub)),
        nonce: Keyword.get(opts, :nonce, :crypto.strong_rand_bytes(16)),
        expires_at: now() + RegistryRequest.lifetime_ms(),
        body: Keyword.get(opts, :body, %{"handle" => handle})
      )

    {:ok, bytes} = RegistryRequest.sign(request, Keyword.get(opts, :private, device_priv))
    bytes
  end

  defp claim(bytes, from \\ source()), do: Handles.claim(%{request: bytes, source: from})
  defp resolve(handle), do: Handles.resolve(%{handle: handle, source: source()})

  # ---- claims ------------------------------------------------------------------

  test "a claim makes the handle the account's once, and the handle answers it" do
    alice = account!()

    assert {:error, :handle_not_found} = resolve("alice")

    assert {:ok, %{handle: "alice", identifier: id, created: true}} =
             claim(request(alice, "alice"))

    assert id == alice.identifier

    assert {:ok, %{created: false}} = claim(request(alice, "alice"))

    assert {:ok, %HandleAnswer{} = answer} = resolve("alice")
    assert answer.registry == "dir.example"
    assert answer.directory == @directory
    assert answer.identifier == alice.identifier

    assert {:ok, ^answer} =
             HandleAnswer.parse(HandleAnswer.encode(answer), "alice", "dir.example")

    # A recovery key signs for the account too.
    {recovery_pub, recovery_priv} = alice.recovery

    assert {:ok, %{created: false}} =
             claim(
               request(alice, "alice",
                 signer: Identity.recovery_signer(recovery_pub),
                 private: recovery_priv
               )
             )
  end

  test "one handle per account and one account per handle, a nonce spent once" do
    alice = account!()
    bob = account!()
    {:ok, %{created: true}} = claim(request(alice, "alice"))

    assert {:error, :handle_taken} = claim(request(bob, "alice"))
    assert {:error, :has_other_handle} = claim(request(alice, "alice-two"))

    nonce = :crypto.strong_rand_bytes(16)
    assert {:ok, %{created: true}} = claim(request(bob, "bob", nonce: nonce))
    assert {:error, :replayed} = claim(request(bob, "bob", nonce: nonce))
  end

  test "a claim is verified against the account's log, in the protocol's order" do
    alice = account!()
    {_pub, stranger} = keypair()

    assert {:error, :bad_signature} = claim(request(alice, "alice", private: stranger))

    assert {:error, :bad_signature} =
             claim(request(alice, "alice", signer: Key.kid(elem(keypair(), 0))))

    assert {:error, :wrong_registry} = claim(request(alice, "alice", registry: "cyfr.run"))
    assert {:error, :request_malformed} = claim("not a request")

    assert {:error, :unknown_operation} =
             claim(
               request(alice, nil, operation: "policy.accept", body: %{"policy_version" => "1"})
             )

    assert {:error, :handle_not_found} = resolve("alice")
  end

  test "an account this directory does not hold, or holds gone, is an unknown identity" do
    alice = account!()
    stranger = %{alice | identifier: "per_" <> String.duplicate("b", 64)}

    assert {:error, :unknown_identity} = claim(request(stranger, "stranger"))

    {:ok, %{created: true}} = claim(request(alice, "alice"))
    :ok = Directory.tombstone(alice.identifier)

    assert {:error, :unknown_identity} = claim(request(alice, "alice"))

    # The name stays reserved: its answer still names the account.
    assert {:ok, %HandleAnswer{identifier: id}} = resolve("alice")
    assert id == alice.identifier
  end

  test "a node serving no directory serves no handle, and a mirror takes no claim" do
    alice = account!()
    bytes = request(alice, "alice")

    Sanctum.Test.Settings.put("directory_serve", "mirror")
    assert {:error, :read_only} = claim(bytes)
    assert {:error, :handle_not_found} = resolve("alice")

    Sanctum.Test.Settings.put("directory_serve", "off")
    assert {:error, :not_served} = claim(bytes)
    assert {:error, :not_served} = resolve("alice")
  end

  test "a handle outside the slug grammar is no one's, before any read" do
    assert {:error, :handle_not_found} = resolve("Alice")
    assert {:error, :handle_not_found} = resolve("a/b")
  end
end
