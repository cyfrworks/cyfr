# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CredentialShapeTest do
  use ExUnit.Case, async: true

  alias Prima.CredentialShape

  doctest Prima.CredentialShape

  # A value of the signed-token shape: the header, a payload and a whole
  # signature, as `match?/2`'s own case spells one.
  defp signed_token do
    CredentialShape.signed_token_header() <>
      ".cGF5bG9hZA." <> String.duplicate("s", CredentialShape.signed_token_signature_length())
  end

  describe "the declared shapes" do
    test "every API-key type has a prefixed shape, and every prefix is distinct" do
      api_keys =
        for {{:api_key, type}, prefix, _} <- CredentialShape.prefixed(), do: {type, prefix}

      assert Map.new(api_keys) == CredentialShape.api_key_prefixes()

      prefixes = Enum.map(CredentialShape.prefixed(), &elem(&1, 1))
      assert Enum.uniq(prefixes) == prefixes
    end

    test "a signed token's signature is an HMAC-SHA-256, unpadded base64url" do
      mac = :crypto.mac(:hmac, :sha256, "key", "message")

      assert CredentialShape.signed_token_signature_length() ==
               byte_size(Base.url_encode64(mac, padding: false))
    end
  end

  describe "mint/1" do
    test "draws a fresh credential of its kind's prefix, length and alphabet" do
      for {kind, prefix, length} <- CredentialShape.prefixed() do
        one = CredentialShape.mint(kind)
        two = CredentialShape.mint(kind)

        assert CredentialShape.match?(kind, one)
        assert one != two
        assert String.starts_with?(one, prefix)
        assert byte_size(one) == byte_size(prefix) + length
        assert one =~ ~r/\A[A-Za-z0-9_-]+\z/
      end
    end

    test "a kind with no prefix is not minted here" do
      for kind <- [:signed_token, {:api_key, :other}] do
        assert_raise FunctionClauseError, fn -> apply(CredentialShape, :mint, [kind]) end
      end
    end
  end

  describe "match?/2" do
    test "holds for the whole value only, and for its own kind only" do
      credential = CredentialShape.mint(:webhook_secret)

      assert CredentialShape.match?(:webhook_secret, credential)
      refute CredentialShape.match?(:confirmation_secret, credential)
      refute CredentialShape.match?(:webhook_secret, " " <> credential)
      refute CredentialShape.match?(:webhook_secret, credential <> " ")
      refute CredentialShape.match?(:webhook_secret, nil)
    end

    test "a signed token has a header, a non-empty payload and a whole signature" do
      header = CredentialShape.signed_token_header()
      signature = String.duplicate("s", CredentialShape.signed_token_signature_length())

      assert CredentialShape.match?(:signed_token, header <> ".cGF5bG9hZA." <> signature)
      refute CredentialShape.match?(:signed_token, header <> ".." <> signature)
      refute CredentialShape.match?(:signed_token, header <> ".cGF5bG9hZA." <> signature <> "s")
      refute CredentialShape.match?(:signed_token, header <> ".cGF5bG9hZA" <> signature)
    end
  end

  describe "redact/2" do
    test "replaces every run, keeps every other byte, and is a no-op on plain text" do
      a = CredentialShape.mint({:api_key, :admin})
      b = CredentialShape.mint(:confirmation_secret)

      assert CredentialShape.redact("a=#{a}&b=#{b}; done", "*") == "a=*&b=*; done"
      assert CredentialShape.redact("nothing here", "*") == "nothing here"
      assert CredentialShape.redact("", "*") == ""
    end

    test "a prefix inside a taken run is part of it, and a failed candidate hides no later one" do
      key = CredentialShape.mint({:api_key, :service})
      [{_, prefix, _} | _] = CredentialShape.prefixed()

      assert CredentialShape.redact(prefix <> key, "*") == prefix <> "*"
      assert CredentialShape.redact(prefix <> " " <> key, "*") == prefix <> " *"
    end

    test "a run ends where another credential begins, so credentials run together are all " <>
           "redacted" do
      key = CredentialShape.mint({:api_key, :service})
      other = CredentialShape.mint(:webhook_secret)
      token = signed_token()

      assert CredentialShape.redact(key <> key, "*") == "**"
      assert CredentialShape.redact(key <> key <> key, "*") == "***"
      assert CredentialShape.redact(key <> other <> key, "*") == "***"
      assert CredentialShape.redact(token <> key, "*") == "**"
      assert CredentialShape.redact(key <> token, "*") == "**"
    end

    test "a short run before a credential hides nothing of it" do
      key = CredentialShape.mint({:api_key, :service})
      [{_, prefix, _} | _] = CredentialShape.prefixed()
      short = prefix <> String.duplicate("A", 20)

      assert CredentialShape.redact(short <> key, "*") == short <> "*"
    end

    test "a longer malformed run stays readable" do
      key = CredentialShape.mint({:api_key, :service})

      assert CredentialShape.redact(key <> "A", "*") == key <> "A"
      assert CredentialShape.redact("A" <> key, "*") == "A*"
    end

    test "one redaction is a fixpoint" do
      key = CredentialShape.mint({:api_key, :service})
      other = CredentialShape.mint(:confirmation_secret)
      token = signed_token()
      [{_, prefix, _} | _] = CredentialShape.prefixed()

      for text <- [
            key <> key,
            key <> key <> key,
            key <> "." <> key,
            prefix <> String.duplicate("A", 20) <> key,
            token <> key <> token,
            "x=" <> key <> "&y=" <> other <> ";" <> token
          ] do
        once = CredentialShape.redact(text, "[REDACTED]")
        assert CredentialShape.redact(once, "[REDACTED]") == once, inspect(text)
        refute once =~ key
        refute once =~ other
      end

      # A credential continued by an alphabet character is a longer run,
      # which stays readable; the whole one after it is redacted, and the
      # result is still a fixpoint.
      once = CredentialShape.redact(key <> "A" <> key, "[REDACTED]")
      assert once == key <> "A[REDACTED]"
      assert CredentialShape.redact(once, "[REDACTED]") == once
    end
  end
end
