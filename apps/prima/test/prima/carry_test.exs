# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CarryTest do
  @moduledoc """
  The sign-in carry as data (`tests/fixtures/carry.json`): each envelope
  re-signs to its bytes; each is checked under a verified head against
  its destination, action, payload and clock, so a forged, substituted,
  stale or old-`key_epoch` envelope is refused and one under the new
  `key_epoch` is taken; a replayed action id answers its recorded
  acknowledgment for the exact bytes and refuses any other; payloads and
  fragments are held to 8 and 16 KiB before they are read; and a return
  reports navigation only and is recorded once.
  """

  use ExUnit.Case, async: true

  alias Prima.{Carry, Identity}
  alias Prima.Carry.{Envelope, Return}

  @vectors Path.expand("../../../../tests/fixtures/carry.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp private(name), do: unb64(vectors()["keys"][name]["seed"])

  defp raw_signature(map, private_key) do
    {:ok, message} = Prima.JCS.encode(Map.delete(map, "sig"))

    Base.url_encode64(:crypto.sign(:eddsa, :none, message, [private_key, :ed25519]),
      padding: false
    )
  end

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp head(name) do
    identity = vectors()["identity"]
    names = identity["heads"][name]["entries"]
    {:ok, state} = Identity.verify_chain(Enum.map(names, &identity["entries"][&1]))
    state
  end

  defp envelope(name) do
    {:ok, envelope} = Envelope.decode(vectors()["envelopes"][name]["envelope"])
    envelope
  end

  test "the protocol, bounds, operations and outcomes are the fixture's" do
    v = vectors()
    assert v["protocol"] == Carry.protocol()
    assert v["max_payload_bytes"] == Carry.max_payload_bytes()
    assert v["max_fragment_bytes"] == Carry.max_fragment_bytes()
    assert v["operations"] == Enum.map(Envelope.operations(), &Atom.to_string/1)
    assert v["outcomes"] == Enum.map(Return.outcomes(), &Atom.to_string/1)
  end

  test "the payload's digest is SHA-256 over its JCS bytes" do
    v = vectors()
    {:ok, bytes} = Prima.JCS.encode(v["payload"])

    assert v["payload_digest"] ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert Carry.payload_digest(v["payload"]) == {:ok, v["payload_digest"]}
  end

  test "every signed envelope re-signs to its bytes; those that read write back to themselves" do
    for {name, %{"envelope" => map, "signer" => signer}} <- vectors()["envelopes"] do
      if signer, do: assert(map["sig"] == raw_signature(map, private(signer)), name)

      case Envelope.decode(map) do
        {:ok, envelope} ->
          assert Envelope.encode(envelope) == map, name

          if signer,
            do: assert(Envelope.sign(%{envelope | sig: nil}, private(signer)) == envelope)

        {:error, _reason} ->
          :ok
      end
    end
  end

  test "every envelope is checked under its head to its result" do
    v = vectors()

    for %{
          "name" => name,
          "envelope" => envelope,
          "head" => head,
          "expected" => expected,
          "clock" => clock
        } =
          vector <- v["verify"] do
      result =
        Envelope.verify(
          v["envelopes"][envelope]["envelope"],
          head(head),
          %{
            destination: expected["destination"],
            action_id: expected["action_id"],
            payload_digest: expected["payload_digest"]
          },
          now: clock["now"],
          skew: clock["skew"],
          max_age: clock["max_age"]
        )

      case vector do
        %{"result" => "ok"} -> assert {:ok, %Envelope{}} = result, name
        %{"error" => error} -> assert tag(result) == error, name
      end
    end
  end

  test "a replayed action id returns its acknowledgment for the exact bytes and refuses any other" do
    v = vectors()

    for %{"name" => name, "envelope" => envelope} = vector <- v["replay"] do
      recorded =
        case vector["recorded"] do
          nil ->
            nil

          %{"envelope" => accepted, "digest" => digest, "ack" => ack} ->
            assert Envelope.digest(envelope(accepted)) == digest
            %{digest: digest, ack: ack}
        end

      result = Envelope.check_replay(envelope(envelope), recorded)

      case vector do
        %{"result" => "fresh"} -> assert result == :fresh, name
        %{"result" => "duplicate", "ack" => ack} -> assert result == {:duplicate, ack}, name
        %{"error" => error} -> assert tag(result) == error, name
      end
    end
  end

  test "the envelope's digest is over its JCS bytes, signature included" do
    map = vectors()["envelopes"]["valid"]["envelope"]
    {:ok, bytes} = Prima.JCS.encode(map)
    assert Envelope.digest(envelope("valid")) == Prima.Digest.sha256(bytes)
  end

  test "new/1 fixes the return URL to the source's /carry and the operation to join" do
    map = vectors()["envelopes"]["valid"]["envelope"]

    {:ok, built} =
      Envelope.new(
        action_id: map["action_id"],
        identifier: map["identifier"],
        source: map["source"],
        destination: map["destination"],
        payload_digest: map["payload_digest"],
        key_epoch: map["key_epoch"],
        issued_at: map["issued_at"]
      )

    assert built.return_url == map["source"] <> "/carry"
    assert built.operation == :join
    assert Envelope.encode(Envelope.sign(built, private("alice_live_1"))) == map
  end

  describe "fragments" do
    test "the fixture's fragment is the envelope and payload, and reads back to them" do
      v = vectors()

      %{"fragment" => fragment, "envelope" => name, "payload" => payload} =
        v["fragments"]["valid"]

      assert Carry.fragment(envelope(name), payload) == {:ok, fragment}
      assert {:ok, %{envelope: read, payload: ^payload}} = Carry.parse_fragment(fragment)
      assert read == envelope(name)
      assert byte_size(fragment) <= Carry.max_fragment_bytes()
    end

    test "a payload is held to 8 KiB of JCS bytes" do
      for %{"name" => name, "filler_length" => length} = vector <-
            vectors()["fragments"]["payload_bound"] do
        payload = %{"filler" => String.duplicate("a", length)}
        result = Carry.payload_digest(payload)

        case vector do
          %{"result" => "ok"} -> assert {:ok, _digest} = result, name
          %{"error" => error} -> assert tag(result) == error, name
        end
      end

      big = %{"filler" => String.duplicate("a", 8180)}
      assert Carry.fragment(envelope("valid"), big) == {:error, :carry_too_large}
    end

    test "a fragment is held to 16 KiB before it is decoded, and read exactly" do
      for %{"name" => name} = vector <- vectors()["fragments"]["parse"] do
        fragment =
          case vector do
            %{"repeat" => %{"char" => char, "length" => length}} -> String.duplicate(char, length)
            %{"fragment" => fragment} -> fragment
          end

        assert tag(Carry.parse_fragment(fragment)) == vector["error"], name
      end

      assert Carry.parse_fragment(nil) == {:error, :invalid_fragment}
    end
  end

  describe "returns" do
    test "every return reads, writes back, and is its fragment" do
      v = vectors()["returns"]

      for name <- ["admitted", "refused"] do
        %{"return" => map, "fragment" => fragment} = v[name]
        assert {:ok, return} = Return.decode(map)
        assert Return.encode(return) == map
        assert Return.fragment(return) == fragment
        assert Return.parse_fragment(fragment) == {:ok, return}
        assert Return.new(map["action_id"], String.to_existing_atom(name)) == {:ok, return}
      end

      assert Return.parse_fragment(String.duplicate("A", 16_385)) == {:error, :carry_too_large}
    end

    test "every malformed return is refused; none carries a session" do
      for %{"name" => name, "return" => map, "error" => error} <- vectors()["returns"]["refusals"] do
        assert tag(Return.decode(map)) == error, name
      end
    end

    test "a return is recorded once: the same outcome returns it, a changed one is refused" do
      v = vectors()["returns"]
      read = fn name -> elem(Return.decode(v[name]["return"]), 1) end

      for %{"name" => name, "return" => return, "recorded" => recorded} = vector <- v["replay"] do
        result = Return.check_replay(read.(return), recorded && read.(recorded))

        case vector do
          %{"result" => "fresh"} -> assert result == :fresh, name
          %{"result" => "duplicate"} -> assert result == {:duplicate, read.(recorded)}, name
          %{"error" => error} -> assert tag(result) == error, name
        end
      end
    end
  end
end
