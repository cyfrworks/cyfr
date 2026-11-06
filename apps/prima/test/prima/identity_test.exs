# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.IdentityTest do
  @moduledoc """
  The account log as data (`tests/fixtures/identity.json`): every key
  derives from its seed or scalar and has its kid; every entry an Ed25519
  key signed re-signs to its bytes over the JCS form without `sig`; every
  hash and identifier is SHA-256 over JCS bytes, and an identifier maps to
  its passkey user id and back; every chain walks to its state or to the
  index and reason it is refused; and every passkey assertion is checked
  at its directory to its result.
  """

  use ExUnit.Case, async: true

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, Key, State, WebAuthn}

  @vectors Path.expand("../../../../tests/fixtures/identity.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp key(name), do: vectors()["keys"][name]
  defp private(name), do: unb64(key(name)["seed"])
  defp public(name), do: unb64(key(name)["public"])

  # The signature convention, spelled independently of Prima.Identity.
  defp raw_signature(map, private_key) do
    {:ok, message} = Prima.JCS.encode(Map.delete(map, "sig"))

    Base.url_encode64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]),
      padding: false
    )
  end

  defp tag({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)

  # A chain's refusal as Prima answers it, its field or kind included.
  defp refusal(%{"index" => index, "reason" => reason} = error) do
    reason = String.to_existing_atom(reason)

    detail =
      case error do
        %{"field" => field} -> {reason, field}
        %{"kind" => kind} -> {reason, kind}
        _ -> reason
      end

    {:error, {index, detail}}
  end

  defp entries(names), do: Enum.map(names, &vectors()["entries"][&1]["entry"])

  defp ed25519?(signer), do: is_binary(signer) and key(signer)["alg"] == "ed25519"

  test "the protocol, prefix, bounds and kinds are the fixture's" do
    v = vectors()
    assert v["protocol"] == Identity.protocol()
    assert v["prefix"] == Identity.prefix()
    assert v["max_entry_bytes"] == Identity.max_entry_bytes()
    assert v["max_recovery"] == Identity.max_recovery()
    assert v["max_keys"] == Identity.max_keys()
    assert v["kinds"] == Enum.map(Identity.kinds(), &Atom.to_string/1)
  end

  test "every public key derives from its seed or scalar, and its kid is SHA-256 over it" do
    for {name, %{"alg" => alg, "public" => public, "kid" => kid} = vector} <- vectors()["keys"] do
      derived =
        case alg do
          "ed25519" ->
            elem(:crypto.generate_key(:eddsa, :ed25519, unb64(vector["seed"])), 0)

          "es256" ->
            elem(:crypto.generate_key(:ecdh, :secp256r1, unb64(vector["private"])), 0)
        end

      assert Encoding.b64(derived) == public, name
      assert kid == "sha256:" <> Base.encode16(:crypto.hash(:sha256, derived), case: :lower)
      assert Identity.kid(derived) == kid, name
    end
  end

  test "a recovery seed derives its signing key, and nothing but 32 bytes is a seed" do
    kits = vectors()["kits"]

    for %{"seed" => seed, "public" => public} <- kits["valid"] do
      assert {:ok, {derived, private}} = Identity.derive_recovery_key(unb64(seed))
      assert Encoding.b64(derived) == public
      assert private == unb64(seed)
      assert Identity.recovery_signer(derived) == "recovery:" <> Identity.kid(derived)
    end

    for seed <- kits["invalid"] do
      assert Identity.derive_recovery_key(unb64(seed)) == {:error, :invalid_seed}
    end
  end

  test "an identifier is its passkey user id's 32 bytes, in both directions" do
    v = vectors()

    for {person, %{"identifier" => identifier, "user_id" => user_id}} <- v["identifiers"] do
      assert Identity.user_id(identifier) == {:ok, unb64(user_id)}, person
      assert Identity.identifier_for_user_id(unb64(user_id)) == {:ok, identifier}, person
    end

    for identifier <- v["user_ids"]["refused_identifiers"] do
      assert Identity.user_id(identifier) == :error, identifier
    end

    for user_id <- v["user_ids"]["refused_user_ids"] do
      assert Identity.identifier_for_user_id(unb64(user_id)) == :error, user_id
    end
  end

  test "every entry an Ed25519 key signed re-signs to its bytes, and every entry hashes to its hash" do
    for {name, %{"entry" => entry, "signer" => signer, "hash" => hash}} <- vectors()["entries"] do
      if ed25519?(signer), do: assert(entry["sig"] == raw_signature(entry, private(signer)), name)

      {:ok, canonical} = Prima.JCS.encode(entry)
      assert hash == Prima.Digest.sha256(canonical), name

      case Entry.decode(entry) do
        {:ok, decoded} ->
          assert Entry.encode(decoded) == entry, name
          assert Identity.hash(decoded) == hash, name

          if ed25519?(signer),
            do: assert(Identity.sign(%{decoded | sig: nil}, private(signer)) == decoded, name)

        {:error, _reason} ->
          :ok
      end
    end
  end

  test "an identifier is per_ and the hex of SHA-256 over the genesis's JCS bytes" do
    v = vectors()

    for {person, genesis} <- [{"alice", "alice_genesis"}, {"bob", "bob_genesis"}] do
      entry = v["entries"][genesis]["entry"]
      {:ok, bytes} = Prima.JCS.encode(entry)
      expected = "per_" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert v["identifiers"][person]["identifier"] == expected
      assert Identity.identifier(entry) == expected
      {:ok, decoded} = Entry.decode(entry)
      assert Identity.identifier(decoded) == expected
    end

    assert_raise ArgumentError, fn ->
      Identity.identifier(v["entries"]["alice_add_device_1"]["entry"])
    end
  end

  test "every chain walks to its state, or to the index and reason it is refused" do
    for %{"name" => name, "entries" => names} = chain <- vectors()["chains"] do
      result = Identity.verify_chain(entries(names))

      case chain do
        %{"state" => state} ->
          assert {:ok, %State{} = verified} = result, name
          assert State.encode(verified) == state, name
          assert State.decode(state) == {:ok, verified}, name

        %{"error" => error} ->
          assert result == refusal(error), name
      end
    end
  end

  test "a state reads back only in its own spelling" do
    %{"state" => state} =
      Enum.find(vectors()["chains"], &(&1["name"] == "a passkey removed by the recovery key"))

    assert State.decode(Map.put(state, "extra", 1)) == :error
    assert State.decode(Map.delete(state, "seq")) == :error
    assert State.decode(%{state | "head" => "head-1"}) == :error
    assert State.decode(%{state | "recovery" => []}) == :error
    assert State.decode(%{state | "keys" => [%{"kid" => "x"}]}) == :error
    assert State.decode(nil) == :error
  end

  test "extend/2 is verify_chain's step, one entry at a time" do
    %{"entries" => names} =
      Enum.find(vectors()["chains"], &(&1["name"] == "a passkey removed by the recovery key"))

    [genesis | rest] = entries(names)
    {:ok, state} = Identity.verify_chain([genesis])

    stepped =
      Enum.reduce(rest, state, fn entry, state ->
        {:ok, state} = Identity.extend(state, entry)
        state
      end)

    assert {:ok, stepped} == Identity.verify_chain([genesis | rest])
    assert Identity.extend(stepped, genesis) == {:error, :unexpected_genesis}
    assert Identity.extend(stepped, List.last(rest)) == {:error, :broken_link}
  end

  test "structs walk the same as their maps, and an unsigned entry is refused" do
    maps = entries(~w(alice_genesis alice_add_device_1 alice_add_passkey_1))
    structs = Enum.map(maps, fn map -> elem(Entry.decode(map), 1) end)
    assert Identity.verify_chain(structs) == Identity.verify_chain(maps)

    [genesis | _] = structs
    assert {:error, {0, {:missing_field, "sig"}}} = Identity.verify_chain([%{genesis | sig: nil}])
    assert Identity.verify_chain(:not_a_list) == {:error, {0, {:invalid_field, "entries"}}}
  end

  test "an entry over 16 KiB is refused before its fields are read" do
    genesis = vectors()["entries"]["alice_genesis"]["entry"]
    padded = Map.put(genesis, "padding", String.duplicate("a", Identity.max_entry_bytes()))
    assert Entry.decode(padded) == {:error, :too_large}
    assert Identity.verify_chain([padded]) == {:error, {0, :too_large}}
  end

  test "every passkey assertion is checked at its directory to its result" do
    v = vectors()

    for %{"name" => name, "key" => key, "assertion" => map} = vector <- v["webauthn"] do
      {:ok, assertion} = WebAuthn.decode(map)
      assert WebAuthn.encode(assertion) == map, name

      result =
        WebAuthn.verify(
          assertion,
          public(key),
          unb64(vector["challenge"]),
          vector["origin"],
          vector["rp_id"]
        )

      assert tag_ok(result) == (vector["result"] || vector["error"]), name
    end
  end

  defp tag_ok(:ok), do: "ok"
  defp tag_ok(result), do: tag(result)

  test "the constructors build what the fixture holds" do
    v = vectors()
    e = v["entries"]
    directory = v["directory"]

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: e["alice_genesis"]["entry"]["at"],
        signer: Identity.recovery_signer(public("kit_a")),
        directory: directory,
        recovery: [public("kit_a")]
      )

    assert Entry.encode(Identity.sign(genesis, private("kit_a"))) ==
             e["alice_genesis"]["entry"]

    {:ok, device_1} = Key.new(alg: :ed25519, kind: :device, pub: public("device_1"))

    {:ok, add} =
      Entry.new(
        kind: :add_key,
        prev: e["alice_genesis"]["hash"],
        seq: 1,
        at: e["alice_add_device_1"]["entry"]["at"],
        signer: Identity.recovery_signer(public("kit_a")),
        key: device_1
      )

    assert Entry.encode(Identity.sign(add, private("kit_a"))) == e["alice_add_device_1"]["entry"]

    {:ok, passkey_1} =
      Key.new(
        alg: :es256,
        kind: :passkey,
        pub: public("passkey_1"),
        credential_id: unb64(key("passkey_1")["credential_id"])
      )

    assert Key.encode(passkey_1) == e["alice_add_passkey_1"]["entry"]["key"]

    # A passkey signs the SHA-256 of the entry's bytes without sig, and its
    # assertion is attached as the sig.
    {:ok, by_passkey} = Entry.decode(e["alice_add_device_2_by_passkey"]["entry"])
    unsigned = %{by_passkey | sig: nil}
    client = Jason.decode!(by_passkey.sig.client_data)
    assert client["challenge"] == Encoding.b64(Identity.challenge(unsigned))
    assert Identity.attach(unsigned, by_passkey.sig) == by_passkey

    {:ok, remove} =
      Entry.new(
        kind: :remove_key,
        prev: e["alice_add_device_2_by_passkey"]["hash"],
        seq: 4,
        at: e["alice_remove_device_1"]["entry"]["at"],
        signer: Identity.kid(public("device_2")),
        kid: Identity.kid(public("device_1"))
      )

    assert Entry.encode(Identity.sign(remove, private("device_2"))) ==
             e["alice_remove_device_1"]["entry"]

    {:ok, add_recovery} =
      Entry.new(
        kind: :add_recovery,
        prev: e["alice_remove_device_1"]["hash"],
        seq: 5,
        at: e["alice_add_recovery"]["entry"]["at"],
        signer: Identity.recovery_signer(public("kit_a")),
        recovery: [public("kit_a"), public("kit_b")]
      )

    assert Entry.encode(Identity.sign(add_recovery, private("kit_a"))) ==
             e["alice_add_recovery"]["entry"]

    {:ok, recover} =
      Entry.new(
        kind: :recover,
        prev: e["alice_add_recovery"]["hash"],
        seq: 6,
        at: e["alice_recover"]["entry"]["at"],
        signer: Identity.recovery_signer(public("kit_b")),
        keys: Enum.map(e["alice_recover"]["entry"]["keys"], &elem(Key.decode(&1), 1)),
        recovery: [public("kit_b")]
      )

    assert Entry.encode(Identity.sign(recover, private("kit_b"))) == e["alice_recover"]["entry"]

    assert {:error, {:invalid_field, "directory"}} =
             Entry.new(
               kind: :genesis,
               seq: 0,
               at: 0,
               signer: Identity.recovery_signer(public("kit_a")),
               directory: "https://directory.example/",
               recovery: [public("kit_a")]
             )

    assert Key.new(alg: :ed25519, kind: :passkey, pub: public("device_1")) == :error
  end

  describe "the shared encodings" do
    test "base64url is unpadded and has one spelling" do
      key = public("device_1")
      spelled = Encoding.b64(key)
      assert Encoding.unb64(spelled, 32) == {:ok, key}
      assert Encoding.unb64(Base.url_encode64(key), 32) == :error
      assert Encoding.unb64(spelled, 31) == :error
      assert Encoding.unb64("QR", 1) == :error
      assert Encoding.unb64("QQ", 1) == {:ok, "A"}
      assert Encoding.unb64(nil, 1) == :error
    end

    test "a home has exactly one spelling" do
      for home <- [
            "https://alice.example",
            "https://alice.example:8443",
            "http://localhost:4000",
            "http://10.0.0.2"
          ] do
        assert Encoding.home?(home), home
      end

      for home <- [
            "https://Alice.example",
            "https://alice.example/",
            "https://alice.example:443",
            "http://alice.example:80",
            "https://alice.example/carry",
            "https://user@alice.example",
            "https://alice.example?x=1",
            "https://alice.example#top",
            "ftp://alice.example",
            "alice.example",
            "https://[::1]",
            nil
          ] do
        refute Encoding.home?(home), inspect(home)
      end

      assert Encoding.home_host("https://alice.example:8443") == "alice.example"
    end

    test "a home written another way is given its one spelling, and nothing else is a home" do
      for {spelling, home} <- [
            {"https://alice.example", "https://alice.example"},
            {"HTTPS://Alice.EXAMPLE", "https://alice.example"},
            {"https://alice.example/", "https://alice.example"},
            {"https://alice.example:443", "https://alice.example"},
            {"http://localhost:80", "http://localhost"},
            {"http://localhost:443", "http://localhost:443"},
            {"https://alice.example:8443/", "https://alice.example:8443"}
          ] do
        assert {spelling, {:ok, home}} == {spelling, Encoding.canonical_home(spelling)}
        assert Encoding.home?(home), home
      end

      for value <- [
            "https://alice.example/carry",
            "https://user@alice.example",
            "https://alice.example?x=1",
            "https://alice.example#top",
            "ftp://alice.example",
            "alice.example",
            "https://[::1]",
            "https://alice.eKample",
            nil
          ] do
        assert {value, :error} == {value, Encoding.canonical_home(value)}
      end
    end

    test "a directory URL is a home and an optional path with no trailing slash" do
      assert Encoding.directory_url?("https://directory.example")
      assert Encoding.directory_url?("https://directory.example/cyfr/v1")
      refute Encoding.directory_url?("https://directory.example/")
      refute Encoding.directory_url?("https://directory.example/cyfr/")
      refute Encoding.directory_url?("https://directory.example?x=1")
      refute Encoding.directory_url?("https://DIRECTORY.example")
      refute Encoding.directory_url?("https://directory.example:443/x")
    end

    test "a map is held to exactly its fields, unknown before missing" do
      assert Encoding.fields(%{"a" => 1, "b" => 2}, ["a"], ["b"]) == :ok

      assert Encoding.fields(%{"a" => 1, "z" => 2}, ["a", "b"], []) ==
               {:error, {:unknown_field, "z"}}

      assert Encoding.fields(%{"a" => 1}, ["a", "b"], []) == {:error, {:missing_field, "b"}}
    end

    test "a key that is no string is unknown, and hides no unknown key after it" do
      assert Encoding.fields(%{nil => 1}, [], []) == {:error, {:unknown_field, "nil"}}

      assert Encoding.fields(%{nil => 1, "a" => 1}, ["a"], []) ==
               {:error, {:unknown_field, "nil"}}

      assert {:error, {:unknown_field, field}} =
               Encoding.fields(%{nil => 1, "z" => 2, "a" => 1}, ["a"], [])

      assert field in ["nil", "z"]
    end

    test "a preview row with a key that is no string is refused, at the top and in its values" do
      row = %{
        "kind" => "tools",
        "node" => "formula",
        "values" => %{"tools" => ["execution.run"]},
        "narrowed" => false
      }

      assert {:ok, _row} = Prima.ConsentPreview.Row.decode(row)

      assert {:error, {:unknown_field, field}} =
               Prima.ConsentPreview.Row.decode(Map.merge(row, %{nil => 1, "extra" => 2}))

      assert field in ["nil", "extra"]

      assert {:error, {:unknown_field, "nil"}} =
               Prima.ConsentPreview.Row.decode(put_in(row, ["values", nil], 1))
    end
  end
end
