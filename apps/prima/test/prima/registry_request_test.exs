# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RegistryRequestTest do
  @moduledoc """
  The registry request as data (`tests/fixtures/registry_wire.json`, which
  the registry at cyfr.run reads too): every key derives from its seed,
  the identity walks to each head with its `key_epoch` and
  `recovery_epoch`, every request re-signs to its bytes from its fields
  and seed, one for each operation; every request is checked as the
  registry checks it, under a head and a clock, to its result or refusal,
  in the order the protocol fixes; every refusal that needs no database is
  reached by its input, and the signer refuses the same malformed fields
  before it signs anything.
  """

  use ExUnit.Case, async: true

  alias Prima.{ComponentRef, Identity, RegistryRequest}
  alias Prima.Identity.{Encoding, RecoverRequest}

  @vectors Path.expand("../../../../tests/fixtures/registry_wire.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp private(v, name), do: unb64(v["keys"][name]["seed"])

  # The signature convention, spelled independently of Prima.Identity.Encoding.
  defp raw_signature(map, private_key) do
    {:ok, message} = Prima.JCS.encode(Map.delete(map, "sig"))

    Base.url_encode64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]),
      padding: false
    )
  end

  defp head(v, name) do
    identity = v["identity"]
    names = identity["heads"][name]["entries"]
    {:ok, state} = Identity.verify_chain(Enum.map(names, &identity["entries"][&1]["entry"]))
    state
  end

  defp registry(%{"host" => host, "directory" => directory}),
    do: %{host: host, directory: directory}

  defp bytes(v, %{"request" => name} = vector) when is_binary(name) do
    {:ok, bytes} = Prima.JCS.encode(v["requests"][name]["request"])

    case vector do
      %{"pad_with_spaces_to" => size} -> bytes <> String.duplicate(" ", size - byte_size(bytes))
      _ -> bytes
    end
  end

  defp bytes(_v, %{"request" => map}), do: Jason.encode!(map)
  defp bytes(_v, %{"raw" => raw}), do: raw

  defp check(v, vector) do
    RegistryRequest.verify(
      bytes(v, vector),
      head(v, vector["head"]),
      registry(vector["registry"]),
      vector["now_ms"]
    )
  end

  defp tag({:ok, %RegistryRequest{}}), do: "ok"
  defp tag({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)

  defp new(map) do
    RegistryRequest.new(
      registry: map["registry"],
      operation: map["operation"],
      identifier: map["identifier"],
      key_epoch: map["key_epoch"],
      nonce: unb64(map["nonce"]),
      expires_at: map["expires_at"],
      body: map["body"]
    )
  end

  test "the protocol's constants" do
    assert RegistryRequest.protocol() == "cyfr-registry-request/v1"
    assert RegistryRequest.max_bytes() == 16_384
    assert RegistryRequest.nonce_bytes() == 16
    assert RegistryRequest.lifetime_ms() == 120_000
    assert RegistryRequest.max_ahead_ms() == 360_000

    assert RegistryRequest.operations() ==
             ~w(address.set appeal.file handle.claim policy.accept publisher.claim publisher.verify tokens.mint)
  end

  test "every public key derives from its seed" do
    for {name, %{"seed" => seed, "public" => public}} <- vectors()["keys"] do
      {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, unb64(seed))
      assert Encoding.b64(derived) == public, name
    end
  end

  test "every entry re-signs to its bytes, and each head is its walk's" do
    v = vectors()

    for {name, %{"entry" => entry, "hash" => hash, "signer" => signer}} <-
          v["identity"]["entries"] do
      signed = if entry["kind"] == "recover", do: entry["request"], else: entry
      assert signed["sig"] == raw_signature(signed, private(v, signer)), name
      assert {:ok, decoded} = Identity.Entry.decode(entry)
      assert Identity.hash(decoded) == hash, name
    end

    {:ok, recover} =
      RecoverRequest.decode(v["identity"]["entries"]["recover"]["entry"]["request"])

    assert recover.live_key != head(v, "rotated").live_key

    for {name, expected} <- v["identity"]["heads"] do
      state = head(v, name)
      assert state.identifier == expected["identifier"], name
      assert state.directory == expected["directory"], name
      assert state.key_epoch == expected["key_epoch"], name
      assert state.recovery_epoch == expected["recovery_epoch"], name
      assert Encoding.b64(state.live_key) == expected["live_key"], name
    end

    heads = v["identity"]["heads"]
    # A rotation moves key_epoch and keeps recovery_epoch; a recovery that
    # replaces the live key moves both.
    assert heads["rotated"]["key_epoch"] != heads["genesis"]["key_epoch"]
    assert heads["rotated"]["recovery_epoch"] == heads["genesis"]["recovery_epoch"]
    assert heads["recovered"]["recovery_epoch"] != heads["rotated"]["recovery_epoch"]
  end

  test "every request re-signs to its bytes from its fields and seed, one for each operation" do
    v = vectors()

    for {name, %{"request" => map, "signer" => signer}} <- v["requests"] do
      assert map["sig"] == raw_signature(map, private(v, signer)), name
      assert {:ok, request} = new(map)
      bytes = Encoding.jcs!(map)

      # A request whose escaped bytes pass the size bound the signer refuses,
      # as the registry does.
      if byte_size(bytes) > RegistryRequest.max_bytes() do
        assert RegistryRequest.sign(request, private(v, signer)) == {:error, :request_malformed},
               name
      else
        assert RegistryRequest.sign(request, private(v, signer)) == {:ok, bytes}, name
      end

      assert RegistryRequest.encode(%{request | sig: unb64(map["sig"])}) == map, name
    end

    operations =
      for {_name, %{"request" => map}} <- v["requests"], uniq: true, do: map["operation"]

    assert Enum.sort(operations) == RegistryRequest.operations()
  end

  test "every request is checked under its head, registry and clock to its result" do
    v = vectors()

    for vector <- v["verify"] do
      assert tag(check(v, vector)) == (vector["result"] || vector["error"]), vector["name"]
    end
  end

  test "every refusal that needs no database is reached by its input" do
    v = vectors()

    for vector <- v["refusals"] do
      assert tag(check(v, vector)) == vector["error"], vector["name"]

      case vector do
        %{"signer" => signer, "request" => map} when is_binary(signer) ->
          assert map["sig"] == raw_signature(map, private(v, signer)), vector["name"]

        _ ->
          :ok
      end
    end

    reached = v["refusals"] |> Enum.map(& &1["error"]) |> Enum.uniq() |> Enum.sort()

    assert reached ==
             ~w(bad_signature expired expiry_too_far request_malformed stale_key_epoch unknown_identity unknown_operation wrong_directory wrong_protocol wrong_registry)
  end

  test "every refusal has one name, the registry's code and its status, as the vectors spell them" do
    v = vectors()

    table =
      for {name, {code, status}} <- RegistryRequest.refusals(),
          do: %{"refusal" => Atom.to_string(name), "code" => code, "status" => status}

    assert v["codes"] == table
    assert table |> Enum.map(& &1["code"]) |> Enum.uniq() |> length() == length(table)

    names = MapSet.new(table, & &1["refusal"])

    named =
      for section <- [v["verify"], v["refusals"], v["answers"]],
          %{"error" => error} <- section,
          error != "malformed_answer",
          do: error

    named = named ++ for(%{"refusal" => refusal} <- v["envelopes"], do: refusal)
    assert Enum.reject(named, &MapSet.member?(names, &1)) == []
  end

  test "every registry envelope reads back to its refusal, or is refused" do
    for %{"name" => name, "bytes" => bytes} = envelope <- vectors()["envelopes"] do
      expected =
        case envelope do
          %{"refusal" => refusal} -> {:ok, String.to_existing_atom(refusal)}
          %{"error" => "malformed_answer"} -> {:error, :malformed_answer}
        end

      assert RegistryRequest.refusal(bytes) == expected, name

      with {:ok, map} when is_map(map) <- Jason.decode(bytes) do
        assert RegistryRequest.refusal(map) == expected, name
      end
    end
  end

  test "the signer refuses an operation or a body the registry would refuse, before signing" do
    v = vectors()
    valid = v["requests"]["handle_claim"]["request"]

    # Every refusal whose only fault is in its operation or body: with a
    # valid request's operation and body in their place it is no longer
    # malformed. The signer builds nothing from those fields.
    faults =
      for %{"request" => map, "error" => error} = vector <- v["refusals"],
          error in ["request_malformed", "unknown_operation"],
          repaired = Map.merge(map, Map.take(valid, ~w(operation body))),
          tag(check(v, %{vector | "request" => repaired})) != "request_malformed",
          do: {vector["name"], map, error}

    assert length(faults) > 30

    for {name, map, error} <- faults do
      assert {:error, String.to_existing_atom(error)} == new(map), name
    end

    # A body of the wrong shape, and fields the wrong shape.
    assert {:error, :request_malformed} = new(Map.put(valid, "body", ["alice"]))
    assert {:error, :request_malformed} = new(Map.put(valid, "registry", "CYFR.RUN"))
    assert {:error, :request_malformed} = new(Map.put(valid, "key_epoch", "epoch-1"))
    assert {:error, :request_malformed} = new(Map.put(valid, "expires_at", -1))

    assert {:error, :request_malformed} =
             RegistryRequest.new(
               registry: "cyfr.run",
               operation: "handle.claim",
               identifier: valid["identifier"],
               key_epoch: valid["key_epoch"],
               nonce: :binary.copy(<<1>>, 15),
               expires_at: valid["expires_at"],
               body: %{"handle" => "alice"}
             )

    # A key the operation does not take is refused even when its value is
    # nil, and the signer signs no bytes past the size bound: 4000 NUL bytes
    # fit the argument's own bound and escape to six bytes each.
    assert {:error, :request_malformed} =
             new(Map.put(valid, "body", %{"handle" => "alice", "unexpected" => nil}))

    {:ok, appeal} =
      new(%{
        valid
        | "operation" => "appeal.file",
          "body" => %{
            "action_type" => "ban",
            "action_ref" => valid["identifier"],
            "argument" => :binary.copy(<<0>>, 4000)
          }
      })

    assert RegistryRequest.sign(appeal, private(v, "alice_live_1")) ==
             {:error, :request_malformed}
  end

  test "an address withdrawn is a body without one, and a null address is refused" do
    v = vectors()
    map = v["requests"]["address_withdraw"]["request"]
    assert map["body"] == %{}

    assert {:ok, request} = new(map)
    assert RegistryRequest.sign(request, private(v, "alice_live_1")) == {:ok, Encoding.jcs!(map)}
    assert new(Map.put(map, "body", %{"address" => nil})) == {:error, :request_malformed}
  end

  test "each handle and publisher spelling is held to the slug grammar on both sides" do
    v = vectors()
    valid = v["requests"]["handle_claim"]["request"]
    genesis = head(v, "genesis")
    registry = %{host: "cyfr.run", directory: genesis.directory}
    now = valid["expires_at"] - 1

    for {kind, operation, key, grammar} <- [
          {"handles", "handle.claim", "handle", &ComponentRef.valid_personal_slug?/1},
          {"publishers", "publisher.claim", "slug",
           &(String.contains?(&1, ".") and ComponentRef.validate_namespace(&1) == :ok)}
        ],
        {verdict, spellings} <- v["slugs"][kind],
        spelling <- spellings do
      expected = if verdict == "valid", do: "ok", else: "request_malformed"
      assert grammar.(spelling) == (verdict == "valid"), spelling

      fields = %{valid | "operation" => operation, "body" => %{key => spelling}}

      case new(fields) do
        {:ok, %RegistryRequest{}} -> assert expected == "ok", spelling
        {:error, reason} -> assert Atom.to_string(reason) == expected, spelling
      end

      signed = fields |> Map.delete("sig") |> Encoding.sign(private(v, "alice_live_1"))
      result = RegistryRequest.verify(Jason.encode!(signed), genesis, registry, now)
      assert tag(result) == expected, spelling
    end
  end

  test "a request the signer makes now stands at the registry until its expiry" do
    v = vectors()
    genesis = head(v, "genesis")
    now = 1_800_000_000_000

    {:ok, request} =
      RegistryRequest.new(
        registry: "cyfr.run",
        operation: "tokens.mint",
        identifier: genesis.identifier,
        key_epoch: genesis.key_epoch,
        nonce: :crypto.strong_rand_bytes(RegistryRequest.nonce_bytes()),
        expires_at: now + RegistryRequest.lifetime_ms(),
        body: %{"label" => "laptop"}
      )

    {:ok, bytes} = RegistryRequest.sign(request, private(v, "alice_live_1"))
    registry = %{host: "cyfr.run", directory: genesis.directory}

    assert {:ok, verified} = RegistryRequest.verify(bytes, genesis, registry, now)
    assert %{verified | sig: nil} == request

    assert {:error, :expired} =
             RegistryRequest.verify(bytes, genesis, registry, request.expires_at)
  end
end
