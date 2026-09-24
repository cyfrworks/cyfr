# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SecretMaskerTest do
  # The masker is what stands between a component that echoes its credential
  # and everyone downstream of the run — the audit row, the MCP client, a
  # parent formula, a public tincture's anonymous caller.
  use ExUnit.Case, async: true

  alias Prima.SecretMasker

  @redacted "[REDACTED]"

  describe "masking" do
    test "replaces a secret wherever it appears in a nested structure" do
      output = %{
        "note" => "the key is sk-secret123",
        "nested" => %{"copy" => "sk-secret123"},
        "list" => ["safe", "sk-secret123"]
      }

      masked = SecretMasker.mask(output, ["sk-secret123"])

      assert masked["note"] == "the key is #{@redacted}"
      assert masked["nested"]["copy"] == @redacted
      assert masked["list"] == ["safe", @redacted]
      refute inspect(masked) =~ "sk-secret123"
    end

    test "masks base64 and hex re-encodings of the secret" do
      secret = "sk-secret123"

      output = %{
        "b64" => Base.encode64(secret),
        "b64url" => Base.url_encode64(secret),
        "hex" => Base.encode16(secret, case: :lower),
        "hex_upper" => Base.encode16(secret, case: :upper)
      }

      masked = SecretMasker.mask(output, [secret])

      assert masked["b64"] == @redacted
      assert masked["b64url"] == @redacted
      assert masked["hex"] == @redacted
      assert masked["hex_upper"] == @redacted
    end

    test "masks a bare string output and leaves unrelated output untouched" do
      assert SecretMasker.mask("token=abcd1234", ["abcd1234"]) == "token=#{@redacted}"
      assert SecretMasker.mask(%{"a" => 1}, ["abcd1234"]) == %{"a" => 1}
    end
  end

  describe "unusable secret values" do
    # `String.replace/3` with "" inserts the marker between every character,
    # which would corrupt the entire output instead of redacting anything.
    # An empty projection is caller data (a vault field with no value), not
    # a bug, so it must be ignored rather than applied.
    test "an empty-string secret leaves the output unchanged" do
      output = %{"result" => "nothing secret here"}

      assert SecretMasker.mask(output, [""]) == output
      refute inspect(SecretMasker.mask(output, [""])) =~ @redacted
    end

    test "an empty-string secret alongside a real one still masks the real one" do
      output = %{"result" => "key sk-real"}

      assert SecretMasker.mask(output, ["", "sk-real"]) == %{"result" => "key #{@redacted}"}
    end

    test "a non-binary secret value is ignored rather than raising" do
      output = %{"result" => "plain"}

      assert SecretMasker.mask(output, [nil]) == output
      assert SecretMasker.mask(output, [123]) == output
      assert SecretMasker.mask(output, [%{"a" => 1}]) == output
    end

    test "no secrets at all is a pass-through" do
      assert SecretMasker.mask(%{"a" => "b"}, []) == %{"a" => "b"}
      assert SecretMasker.mask(%{"a" => "b"}, nil) == %{"a" => "b"}
    end

    test "a map JSON cannot carry is masked directly" do
      assert SecretMasker.mask(%{"pid" => self(), "note" => "sk-secret123"}, ["sk-secret123"]) ==
               %{"pid" => self(), "note" => @redacted}
    end
  end
end
