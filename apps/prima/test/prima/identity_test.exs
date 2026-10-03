# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.IdentityTest do
  @moduledoc """
  The identity log as data: every key of `tests/fixtures/identity.json`
  derives from its seed, every signed entry and request re-signs to its
  bytes over the JCS form without `sig`, every hash, digest and identifier
  is SHA-256 over JCS bytes, every chain walks to its state or to the
  index and reason it is refused, and every genesis a relying home is
  handed is held to its identifier before its directory is used.
  """

  use ExUnit.Case, async: true

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, RecoverRequest, State}

  @vectors Path.expand("../../../../tests/fixtures/identity.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp private(name), do: unb64(vectors()["keys"][name]["seed"])
  defp public(name), do: unb64(vectors()["keys"][name]["public"])

  # The signature convention, spelled independently of Prima.Identity.Encoding.
  defp raw_signature(map, private_key) do
    {:ok, message} = Prima.JCS.encode(Map.delete(map, "sig"))

    Base.url_encode64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]),
      padding: false
    )
  end

  defp tag({:error, {index, reason}}) when is_integer(index),
    do: %{"index" => index, "reason" => tag(reason)}

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp entries(names), do: Enum.map(names, &vectors()["entries"][&1]["entry"])

  test "the protocol, prefix, bound and kinds are the fixture's" do
    v = vectors()
    assert v["protocol"] == Identity.protocol()
    assert v["prefix"] == Identity.prefix()
    assert v["max_entry_bytes"] == Identity.max_entry_bytes()
    assert v["kinds"] == Enum.map(Identity.kinds(), &Atom.to_string/1)
  end

  test "every public key derives from its seed" do
    for {name, %{"seed" => seed, "public" => public}} <- vectors()["keys"] do
      {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, unb64(seed))
      assert Encoding.b64(derived) == public, name
    end
  end

  test "a kit seed derives its recovery signing key, and nothing but 32 bytes is a seed" do
    kits = vectors()["kits"]

    for %{"seed" => seed, "public" => public} <- kits["valid"] do
      assert {:ok, {derived, private}} = Identity.derive_recovery_key(unb64(seed))
      assert Encoding.b64(derived) == public
      assert private == unb64(seed)
    end

    for seed <- kits["invalid"] do
      assert Identity.derive_recovery_key(unb64(seed)) == {:error, :invalid_seed}
    end
  end

  test "every signed entry re-signs to its bytes, and every entry that reads hashes to its hash" do
    for {name, %{"entry" => entry, "signer" => signer} = vector} <- vectors()["entries"] do
      if signer, do: assert(entry["sig"] == raw_signature(entry, private(signer)), name)

      case Entry.decode(entry) do
        {:ok, decoded} ->
          assert Entry.encode(decoded) == entry, name
          {:ok, canonical} = Prima.JCS.encode(entry)
          assert vector["hash"] == Prima.Digest.sha256(canonical), name
          assert Identity.hash(decoded) == vector["hash"], name

        {:error, _reason} ->
          refute Map.has_key?(vector, "hash"), name
      end
    end
  end

  test "Identity.sign reproduces each genesis and rotate signature" do
    for {name, %{"entry" => entry, "signer" => signer}} <- vectors()["entries"],
        signer != nil,
        {:ok, %Entry{kind: kind} = decoded} <- [Entry.decode(entry)],
        kind in [:genesis, :rotate] do
      assert Identity.sign(%{decoded | sig: nil}, private(signer)) == decoded, name
      assert Identity.verify(decoded, public(signer)) == :ok
    end
  end

  test "every recover request re-signs, verifies under its kit and has its digest" do
    for {name, %{"request" => map, "signer" => signer, "digest" => digest}} <-
          vectors()["requests"] do
      assert map["sig"] == raw_signature(map, private(signer)), name
      assert {:ok, request} = RecoverRequest.decode(map)
      assert RecoverRequest.encode(request) == map
      assert Identity.request_digest(request) == digest
      assert Identity.request_digest(map) == digest
      assert Identity.sign(%{request | sig: nil}, private(signer)) == request

      assert RecoverRequest.signer(request, [public("stranger"), public(signer)]) ==
               {:ok, public(signer)}

      assert RecoverRequest.signer(request, [public("stranger")]) == {:error, :wrong_signer}
    end
  end

  test "an identifier is per_ and the hex of SHA-256 over the genesis's JCS bytes" do
    v = vectors()

    for {person, genesis} <- [{"alice", "alice_genesis"}, {"bob", "bob_genesis"}] do
      entry = v["entries"][genesis]["entry"]
      {:ok, bytes} = Prima.JCS.encode(entry)
      expected = "per_" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert v["identifiers"][person] == expected
      assert Identity.identifier(entry) == expected
      {:ok, decoded} = Entry.decode(entry)
      assert Identity.identifier(decoded) == expected
      assert Encoding.identifier?(expected)
    end

    assert_raise ArgumentError, fn ->
      Identity.identifier(v["entries"]["alice_rotate"]["entry"])
    end
  end

  test "every chain walks to its state, or to the index and reason it is refused" do
    for %{"name" => name, "entries" => names} = chain <- vectors()["chains"] do
      result = Identity.verify_chain(entries(names))

      case chain do
        %{"state" => state} ->
          assert {:ok, %State{} = verified} = result, name
          assert State.encode(verified) == state, name

        %{"error" => error} ->
          assert tag(result) == error, name
      end
    end
  end

  test "key_epoch is the hash of the entry that introduced the current live key" do
    v = vectors()

    for %{"entries" => names, "state" => state} <- v["chains"] do
      last = List.last(names)
      assert state["key_epoch"] == v["entries"][last]["hash"]
      assert state["head"] == v["entries"][last]["hash"]
      assert state["length"] == length(names)
    end
  end

  test "extend/2 is verify_chain's step, one entry at a time" do
    names =
      ~w(alice_genesis alice_rotate alice_recover alice_rotate_after_recover alice_recover_add_holder)

    [genesis | rest] = entries(names)
    {:ok, state} = Identity.verify_chain([genesis])

    stepped =
      Enum.reduce(rest, state, fn entry, state ->
        {:ok, state} = Identity.extend(state, entry)
        state
      end)

    assert {:ok, stepped} == Identity.verify_chain([genesis | rest])

    {:ok, recovered} = Identity.verify_chain(Enum.take(entries(names), 3))

    [_, _, _, old_branch] =
      entries(~w(alice_genesis alice_rotate alice_recover alice_rotate_on_old_branch))

    assert Identity.extend(recovered, old_branch) == {:error, :broken_link}
    assert Identity.extend(recovered, genesis) == {:error, :unexpected_genesis}
  end

  test "structs walk the same as their maps, and an unsigned entry is refused" do
    maps = entries(~w(alice_genesis alice_rotate alice_recover))
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

  test "every genesis a relying home is handed is held to its identifier before it is used" do
    for %{"name" => name, "genesis" => genesis, "identifier" => identifier} = vector <-
          vectors()["locate"] do
      input =
        case genesis do
          %{"raw" => raw, "pad_with_spaces_to" => to} ->
            raw <> String.duplicate(" ", to - byte_size(raw))

          %{"raw" => raw} ->
            raw

          %{"entry" => entry} ->
            entry
        end

      case vector do
        %{"directory" => directory} ->
          assert {:ok, %Entry{kind: :genesis, directory: ^directory}} =
                   Identity.locate(input, identifier),
                 name

        %{"error" => error} ->
          assert tag(Identity.locate(input, identifier)) == error, name
      end
    end
  end

  test "the constructors build what the fixture holds" do
    v = vectors()
    genesis = v["entries"]["alice_genesis"]["entry"]

    {:ok, built} =
      Entry.genesis(
        live_key: public("alice_live_1"),
        operational_key: public("alice_op_1"),
        recovery_keys: [public("kit_a")],
        directory: v["directory"]
      )

    assert Entry.encode(Identity.sign(built, private("alice_op_1"))) == genesis

    {:ok, rotate} = Entry.rotate(v["entries"]["alice_genesis"]["hash"], public("alice_live_2"))

    assert Entry.encode(Identity.sign(rotate, private("alice_op_1"))) ==
             v["entries"]["alice_rotate"]["entry"]

    {:ok, request} = RecoverRequest.decode(v["requests"]["alice_recover"]["request"])
    {:ok, recover} = Entry.recover(v["entries"]["alice_rotate"]["hash"], request)
    assert Entry.encode(recover) == v["entries"]["alice_recover"]["entry"]

    assert {:error, {:missing_field, "sig"}} =
             Entry.recover(v["entries"]["alice_rotate"]["hash"], %{request | sig: nil})

    assert {:error, {:invalid_field, "directory"}} =
             Entry.genesis(
               live_key: public("alice_live_1"),
               operational_key: public("alice_op_1"),
               recovery_keys: [public("kit_a")],
               directory: "https://directory.example/"
             )
  end

  describe "recovery_epoch" do
    defp pair, do: :crypto.generate_key(:eddsa, :ed25519)

    # A log built here, so a recover that keeps the live key (one that only
    # adds a recovery holder) stands beside one that replaces it.
    defp built_log do
      directory = "https://directory.example"
      {live_1, _} = pair()
      {op_pub, op} = pair()
      {kit_pub, kit} = pair()
      {kit_2_pub, _} = pair()
      {live_2, _} = pair()
      {live_3, _} = pair()
      {op_3, _} = pair()

      {:ok, genesis} =
        Entry.genesis(
          live_key: live_1,
          operational_key: op_pub,
          recovery_keys: [kit_pub],
          directory: directory
        )

      genesis = Identity.sign(genesis, op)
      identifier = Identity.identifier(genesis)

      {:ok, rotate} = Entry.rotate(Identity.hash(genesis), live_2)
      rotate = Identity.sign(rotate, op)

      recover = fn prev, live, operational, recovery, revision, id ->
        {:ok, request} =
          RecoverRequest.new(
            identifier: identifier,
            directory: directory,
            live_key: live,
            operational_key: operational,
            recovery_keys: recovery,
            expected_revision: revision,
            request_id: id
          )

        {:ok, entry} = Entry.recover(prev, Identity.sign(request, kit))
        entry
      end

      add_holder =
        recover.(Identity.hash(rotate), live_2, op_pub, [kit_pub, kit_2_pub], 0, "req_holder")

      replace = recover.(Identity.hash(add_holder), live_3, op_3, nil, 1, "req_replace")

      %{genesis: genesis, rotate: rotate, add_holder: add_holder, replace: replace}
    end

    test "starts at the genesis, survives a rotation and a holder-adding recover, and moves at a recovery that replaces the live key" do
      log = built_log()
      genesis_hash = Identity.hash(log.genesis)

      {:ok, at_genesis} = Identity.verify_chain([log.genesis])
      assert at_genesis.recovery_epoch == genesis_hash
      assert at_genesis.key_epoch == genesis_hash

      {:ok, rotated} = Identity.verify_chain([log.genesis, log.rotate])
      assert rotated.key_epoch == Identity.hash(log.rotate)
      assert rotated.recovery_epoch == genesis_hash

      {:ok, holder} = Identity.verify_chain([log.genesis, log.rotate, log.add_holder])
      assert holder.key_epoch == Identity.hash(log.add_holder)
      assert holder.recovery_epoch == genesis_hash

      {:ok, replaced} =
        Identity.verify_chain([log.genesis, log.rotate, log.add_holder, log.replace])

      assert replaced.key_epoch == Identity.hash(log.replace)
      assert replaced.recovery_epoch == Identity.hash(log.replace)
      assert State.encode(replaced)["recovery_epoch"] == Identity.hash(log.replace)
    end

    test "extend/2 moves it as verify_chain/1 does" do
      log = built_log()
      {:ok, state} = Identity.verify_chain([log.genesis])

      stepped =
        Enum.reduce([log.rotate, log.add_holder, log.replace], state, fn entry, state ->
          {:ok, state} = Identity.extend(state, entry)
          state
        end)

      assert stepped.recovery_epoch == Identity.hash(log.replace)
    end
  end

  describe "the shared encodings" do
    test "base64url is unpadded and has one spelling" do
      key = public("alice_live_1")
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
