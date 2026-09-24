# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.MacEnvelopeTest do
  @moduledoc """
  The shared construction: a header parses back to the fields it was built
  from, and parsing refuses anything but exactly one well-formed header of
  the envelope's kind; a MAC verifies only under the same key, fields and
  body; a sealed value opens only under the same key, label and fields.
  """
  use ExUnit.Case, async: true

  alias Prima.MacEnvelope

  @envelope %MacEnvelope{
    prefix: "cyfr-test/v1",
    kind: "ping",
    fields: [who: :string, gen: :integer, ts: :integer],
    header_names: %{gen: "g"}
  }
  @message %{who: "ath_1", gen: 3, ts: 1_789_305_249_602}
  @key String.duplicate("k", 32)
  @body ~s({"a":1})

  defp header!(message \\ @message, key \\ @key, body \\ @body) do
    {:ok, header} = MacEnvelope.header(@envelope, key, message, body)
    header
  end

  defp mac_of(header), do: header |> String.split("mac=") |> List.last()

  describe "canonical string and header" do
    test "are built from the fields in order and parse back to them" do
      assert {:ok, canonical} = MacEnvelope.canonical(@envelope, @message, @body)

      assert canonical ==
               Enum.join(
                 [
                   "cyfr-test/v1/ping",
                   "ath_1",
                   "3",
                   "1789305249602",
                   Prima.Digest.sha256_hex(@body)
                 ],
                 "\n"
               )

      mac = :crypto.mac(:hmac, :sha256, @key, canonical) |> Base.url_encode64(padding: false)
      header = header!()

      assert header == "v1 kind=ping who=ath_1 g=3 ts=1789305249602 mac=#{mac}"
      assert {:ok, @message, ^mac} = MacEnvelope.parse(@envelope, header)
      assert MacEnvelope.verify(@envelope, @key, @message, mac, @body)
    end

    test "a header parses whatever the order of its pairs" do
      mac = mac_of(header!())
      reordered = "v1 ts=1789305249602 mac=#{mac} g=3 kind=ping who=ath_1"

      assert {:ok, @message, ^mac} = MacEnvelope.parse(@envelope, reordered)
    end

    test "an invalid field is refused by name" do
      for {name, value} <- [
            who: "",
            who: "ath 1",
            who: "ath\n1",
            who: "café",
            who: String.duplicate("a", 257),
            who: 7,
            gen: -1,
            gen: 9_007_199_254_740_992,
            gen: 1.5,
            gen: "3",
            gen: nil
          ] do
        message = Map.put(@message, name, value)

        assert {:error, {:invalid_field, ^name}} =
                 MacEnvelope.canonical(@envelope, message, @body)

        assert {:error, {:invalid_field, ^name}} =
                 MacEnvelope.header(@envelope, @key, message, @body)
      end
    end
  end

  describe "parse" do
    test "refuses anything but exactly one well-formed header of the kind" do
      valid = header!()
      mac = mac_of(valid)

      refused = [
        String.replace(valid, "v1 ", "v2 "),
        String.replace(valid, "kind=ping", "kind=pong"),
        String.replace(valid, " g=3", ""),
        String.replace(valid, " mac=#{mac}", ""),
        valid <> " extra=1",
        valid <> " g=3",
        valid <> " who=ath_1",
        String.replace(valid, "g=3", "g=03"),
        String.replace(valid, "g=3", "g=-3"),
        String.replace(valid, "g=3", "g=3a"),
        String.replace(valid, "g=3", "g=" <> String.duplicate("9", 257)),
        String.replace(valid, "who=ath_1", "who=" <> String.duplicate("a", 257)),
        String.replace(valid, "who=ath_1", "who=ath\t1"),
        String.replace(valid, "who=ath_1", "who=ath\x7F1"),
        String.replace(valid, "who=ath_1", "who=athé"),
        String.replace(valid, "who=ath_1", "who="),
        String.replace(valid, "who=ath_1", "=ath_1"),
        String.replace(valid, "who=ath_1", "who"),
        String.replace(valid, " who=", "  who="),
        String.replace(valid, "mac=#{mac}", "mac="),
        "v1",
        ""
      ]

      for header <- refused do
        assert {:error, :malformed} = MacEnvelope.parse(@envelope, header), inspect(header)
      end

      assert {:error, :malformed} = MacEnvelope.parse(@envelope, nil)
    end

    test "reads a value containing = as the value" do
      message = %{@message | who: "a=b"}

      assert {:ok, ^message, _mac} = MacEnvelope.parse(@envelope, header!(message))
    end

    test "an integer field holds 0 to 2^53 - 1, and a string field keeps what it spells" do
      message = %{@message | who: "0042", gen: 0, ts: 9_007_199_254_740_991}

      assert {:ok, ^message, _mac} = MacEnvelope.parse(@envelope, header!(message))

      for ts <- ["9007199254740992", "18446744073709551616", "100000000000000000000"] do
        header = String.replace(header!(), "ts=1789305249602", "ts=" <> ts)
        assert {:error, :malformed} = MacEnvelope.parse(@envelope, header), ts
      end
    end

    test "refuses a name no field has, whatever it spells" do
      valid = header!()

      for extra <- ["__proto__=x", "constructor=x", "hasOwnProperty=x", "kind=ping"] do
        assert {:error, :malformed} = MacEnvelope.parse(@envelope, valid <> " " <> extra), extra
      end
    end
  end

  describe "verify" do
    test "fails on a tampered body, field, MAC or key" do
      {:ok, message, mac} = MacEnvelope.parse(@envelope, header!())

      assert MacEnvelope.verify(@envelope, @key, message, mac, @body)
      refute MacEnvelope.verify(@envelope, @key, message, mac, ~s({"a":2}))
      refute MacEnvelope.verify(@envelope, @key, %{message | gen: 4}, mac, @body)
      refute MacEnvelope.verify(@envelope, @key, %{message | who: "ath_2"}, mac, @body)
      refute MacEnvelope.verify(@envelope, String.duplicate("j", 32), message, mac, @body)

      refute MacEnvelope.verify(
               @envelope,
               @key,
               message,
               mac_of(header!(message, @key, "")),
               @body
             )

      refute MacEnvelope.verify(@envelope, @key, message, "short", @body)
      refute MacEnvelope.verify(@envelope, @key, %{message | gen: -1}, mac, @body)
    end

    test "an envelope naming its body's hash in the header parses it and verifies it against the body" do
      envelope = %{@envelope | body_hash_in_header: true}
      hash = Prima.Digest.sha256_hex(@body)
      {:ok, plain} = MacEnvelope.header(@envelope, @key, @message, @body)
      {:ok, header} = MacEnvelope.header(envelope, @key, @message, @body)

      assert header == String.replace(plain, " mac=", " body=#{hash} mac=")
      assert {:ok, message, mac} = MacEnvelope.parse(envelope, header)
      assert message == Map.put(@message, :body_hash, hash)
      assert mac == mac_of(plain)
      assert MacEnvelope.verify(envelope, @key, message, mac, @body)
      refute MacEnvelope.verify(envelope, @key, @message, mac, @body)

      refute MacEnvelope.verify(
               envelope,
               @key,
               %{message | body_hash: String.duplicate("0", 64)},
               mac,
               @body
             )

      for refused <- [
            plain,
            String.replace(header, "body=#{hash}", "body=#{String.upcase(hash)}"),
            String.replace(header, "body=#{hash}", "body=#{String.slice(hash, 1..-1//1)}"),
            header <> " body=#{hash}"
          ] do
        assert {:error, :malformed} = MacEnvelope.parse(envelope, refused), refused
      end

      assert {:error, :malformed} = MacEnvelope.parse(@envelope, header)
    end

    test "fails under another kind or prefix of the same fields" do
      {:ok, message, mac} = MacEnvelope.parse(@envelope, header!())

      refute MacEnvelope.verify(%{@envelope | kind: "pong"}, @key, message, mac, @body)
      refute MacEnvelope.verify(%{@envelope | prefix: "cyfr-other/v1"}, @key, message, mac, @body)
    end

    test "a header naming its body verifies before the body is read, and the body after" do
      envelope = %{@envelope | body_hash_in_header: true}
      {:ok, header} = MacEnvelope.header(envelope, @key, @message, @body)
      {:ok, message, mac} = MacEnvelope.parse(envelope, header)

      assert MacEnvelope.verify_header(envelope, @key, message, mac)
      assert MacEnvelope.verify_body(envelope, message, @body)
      refute MacEnvelope.verify_body(envelope, message, ~s({"a":2}))

      # The pair answers what the one-step verifier answers.
      refute MacEnvelope.verify_header(envelope, String.duplicate("j", 32), message, mac)
      refute MacEnvelope.verify_header(envelope, @key, %{message | gen: 4}, mac)
      refute MacEnvelope.verify_header(envelope, @key, message, "short")
      refute MacEnvelope.verify_header(%{envelope | kind: "pong"}, @key, message, mac)

      # A header claiming another body's hash has another MAC.
      other = Prima.Digest.sha256_hex(~s({"a":2}))
      refute MacEnvelope.verify_header(envelope, @key, %{message | body_hash: other}, mac)
      refute MacEnvelope.verify_header(envelope, @key, Map.delete(message, :body_hash), mac)
      refute MacEnvelope.verify_header(envelope, @key, %{message | body_hash: "xyz"}, mac)

      # An envelope that names no body cannot be verified without it.
      {:ok, plain_message, plain_mac} = MacEnvelope.parse(@envelope, header!())
      refute MacEnvelope.verify_header(@envelope, @key, plain_message, plain_mac)
      refute MacEnvelope.verify_body(@envelope, plain_message, @body)
    end
  end

  describe "derive" do
    @root :binary.list_to_bin(Enum.to_list(0..31))

    test "over fields is the label and the values, one per line" do
      assert {:ok, key} =
               MacEnvelope.derive(@root, "cyfr-test/v1/owner", @envelope.fields, @message)

      assert key == MacEnvelope.derive(@root, "cyfr-test/v1/owner\nath_1\n3\n1789305249602")
      assert byte_size(key) == 32
      refute key == MacEnvelope.derive(@root, "cyfr-test/v1/owner")
    end

    test "refuses an invalid field" do
      assert {:error, {:invalid_field, :gen}} =
               MacEnvelope.derive(@root, "label", @envelope.fields, %{@message | gen: -1})
    end
  end

  describe "seal and open" do
    @label "cyfr-test/v1/seal"
    @fields [who: :string, gen: :integer]
    @plaintext ~s({"API_TOKEN":"sk-canary"})

    test "round-trip under the same key, label and fields" do
      assert {:ok, sealed} = MacEnvelope.seal(@key, @label, @fields, @message, @plaintext)
      assert {:ok, @plaintext} = MacEnvelope.open(@key, @label, @fields, @message, sealed)

      iv = :binary.copy(<<1>>, 12)
      assert {:ok, same} = MacEnvelope.seal(@key, @label, @fields, @message, @plaintext, iv)
      assert {:ok, ^same} = MacEnvelope.seal(@key, @label, @fields, @message, @plaintext, iv)
      refute same == sealed
    end

    test "open fails under another field, label or key, or a tampered value" do
      {:ok, sealed} = MacEnvelope.seal(@key, @label, @fields, @message, @plaintext)

      assert {:error, :unsealable} =
               MacEnvelope.open(@key, @label, @fields, %{@message | gen: 4}, sealed)

      assert {:error, :unsealable} =
               MacEnvelope.open(@key, @label, @fields, %{@message | who: "ath_2"}, sealed)

      assert {:error, :unsealable} =
               MacEnvelope.open(@key, "cyfr-test/v1/other", @fields, @message, sealed)

      assert {:error, :unsealable} =
               MacEnvelope.open(String.duplicate("j", 32), @label, @fields, @message, sealed)

      <<iv_tag::binary-size(28), first, rest::binary>> =
        Base.url_decode64!(sealed, padding: false)

      tampered =
        Base.url_encode64(<<iv_tag::binary, Bitwise.bxor(first, 1), rest::binary>>,
          padding: false
        )

      assert {:error, :unsealable} = MacEnvelope.open(@key, @label, @fields, @message, tampered)

      assert {:error, :unsealable} =
               MacEnvelope.open(@key, @label, @fields, @message, "not-sealed")

      assert {:error, :unsealable} = MacEnvelope.open(@key, @label, @fields, @message, nil)
    end

    test "refuses an invalid field before sealing or opening" do
      message = %{@message | who: "a b"}

      assert {:error, {:invalid_field, :who}} =
               MacEnvelope.seal(@key, @label, @fields, message, @plaintext)

      assert {:error, {:invalid_field, :who}} =
               MacEnvelope.open(@key, @label, @fields, message, "anything")
    end
  end
end
