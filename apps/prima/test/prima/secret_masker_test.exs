# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.SecretMaskerTest do
  # The masker is what stands between a component that echoes its credential
  # and everyone downstream of the run — the audit row, the MCP client, a
  # parent formula, a public tincture's anonymous caller.
  use ExUnit.Case, async: true

  alias Prima.SecretMasker

  doctest Prima.SecretMasker

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

  describe "text encodings" do
    # The escaped form as Jason writes it inside a JSON string.
    defp json_inner(secret) do
      json = Jason.encode!(secret)
      binary_part(json, 1, byte_size(json) - 2)
    end

    for {label, secret} <- [
          {"a quote", ~s(pa"ss-word)},
          {"a backslash", ~S(pa\ss-word)},
          {"a newline", "pa\nss-word"},
          {"a control character", "pa\u0001ss-word"}
        ] do
      test "masks the JSON-escaped form of a secret with #{label}" do
        secret = unquote(secret)
        escaped = json_inner(secret)
        assert escaped != secret

        assert SecretMasker.mask("body: #{escaped}", [secret]) == "body: #{@redacted}"

        assert SecretMasker.mask(Jason.encode!(%{"k" => secret}), [secret]) ==
                 ~s({"k":"#{@redacted}"})
      end

      test "masks a secret with #{label} held in a map value" do
        secret = unquote(secret)
        masked = SecretMasker.mask(%{"note" => "key " <> secret, "safe" => "x"}, [secret])

        assert masked == %{"note" => "key #{@redacted}", "safe" => "x"}
      end
    end

    test "masks both URL encodings of a secret with an ampersand and a space" do
      secret = "tok&en val=ue"
      www = URI.encode_www_form(secret)
      percent = URI.encode(secret, &URI.char_unreserved?/1)
      assert www == "tok%26en+val%3Due"
      assert percent == "tok%26en%20val%3Due"

      assert SecretMasker.mask("?a=#{www}&b=#{percent}", [secret]) ==
               "?a=#{@redacted}&b=#{@redacted}"

      assert SecretMasker.mask("raw #{secret}", [secret]) == "raw #{@redacted}"
    end

    test "masks a non-ASCII secret raw, inside JSON and URL-encoded" do
      secret = "pässwörd"
      assert json_inner(secret) == secret

      assert SecretMasker.mask(Jason.encode!(%{"k" => secret}), [secret]) ==
               ~s({"k":"#{@redacted}"})

      assert SecretMasker.mask(URI.encode_www_form(secret), [secret]) == @redacted

      assert SecretMasker.mask(URI.encode(secret, &URI.char_unreserved?/1), [secret]) ==
               @redacted

      assert SecretMasker.mask(%{"k" => "a #{secret}"}, [secret]) == %{"k" => "a #{@redacted}"}
    end

    test "a secret shorter than four characters is searched raw only" do
      secret = ~s(a"&)

      assert SecretMasker.mask("x #{secret} y", [secret]) == "x #{@redacted} y"

      for encoded <- [
            json_inner(secret),
            URI.encode_www_form(secret),
            Base.encode64(secret),
            Base.encode16(secret)
          ] do
        assert SecretMasker.mask("x #{encoded} y", [secret]) == "x #{encoded} y"
      end

      assert SecretMasker.pending_prefix("x a%2", [secret]) == 0
      assert SecretMasker.pending_prefix(~s(x a"), [secret]) == 2
    end

    test "a form that prefixes another secret's form leaves no remainder" do
      short = ~s(pass"word)
      long = ~S(pass\"word-extended)
      assert String.starts_with?(long, json_inner(short))

      for secrets <- [[short, long], [long, short]] do
        assert SecretMasker.mask("got #{long}!", secrets) == "got #{@redacted}!"
        assert SecretMasker.mask("got #{json_inner(short)}!", secrets) == "got #{@redacted}!"
        assert SecretMasker.mask("got #{json_inner(long)}!", secrets) == "got #{@redacted}!"
      end
    end
  end

  describe "streaming hold-back" do
    @secret ~s(pass"word)

    test "holds back a tail that begins an encoded form" do
      assert SecretMasker.pending_prefix(~S(args: {"a":"pass\"wo), [@secret]) == 8
      assert SecretMasker.pending_prefix("q=pass%22wo", [@secret]) == 9
      assert SecretMasker.pending_prefix("q=pass", [@secret]) == 4
    end

    test "holds back up to one byte short of the longest form" do
      longest = Base.encode16(@secret, case: :upper)
      open = binary_part(longest, 0, byte_size(longest) - 1)

      assert SecretMasker.pending_prefix("x " <> open, [@secret]) == byte_size(longest) - 1
      assert SecretMasker.pending_prefix("x " <> longest, [@secret]) == 0
    end

    test "an encoded secret split across chunks is released masked whole" do
      for encoded <- [~S(pass\"word), "pass%22word", Base.encode64(@secret)],
          cut <- 1..(byte_size(encoded) - 1) do
        text = "before " <> encoded <> " after"
        split = 7 + cut
        chunks = [binary_part(text, 0, split), binary_part(text, split, byte_size(text) - split)]

        {released, held} =
          Enum.reduce(chunks, {"", ""}, fn chunk, {out, pending} ->
            masked = SecretMasker.mask(pending <> chunk, [@secret])
            hold = SecretMasker.pending_prefix(masked, [@secret])
            kept = byte_size(masked) - hold
            {out <> binary_part(masked, 0, kept), binary_part(masked, kept, hold)}
          end)

        assert released <> SecretMasker.mask(held, [@secret]) == "before #{@redacted} after"
      end
    end
  end

  describe "the forms" do
    # A header's name cannot be rewritten, only dropped, so a caller that
    # finds a secret there matches the forms themselves; they must be
    # exactly the ones masking replaces.
    test "forms/1 names exactly what mask/2 replaces, longest first" do
      secret = "Sk-Mixed+Case/9 key"
      forms = SecretMasker.forms([secret])

      assert secret in forms
      assert Base.encode64(secret) in forms
      assert Base.url_encode64(secret) in forms
      assert Base.encode16(secret, case: :lower) in forms
      assert Base.encode16(secret, case: :upper) in forms
      assert URI.encode_www_form(secret) in forms
      assert forms == Enum.sort_by(forms, &byte_size/1, :desc)
      assert forms == Enum.uniq(forms)

      for form <- forms, do: assert(SecretMasker.mask(form, [secret]) == @redacted)
    end

    test "a secret whose length is no multiple of three is masked in its unpadded base64" do
      # Twenty-nine characters: every padded base64 form ends in "=", which
      # an echo can leave off.
      secret = "sk-Attached-MIXED-Canary-4200"
      unpadded = Base.encode64(secret, padding: false)
      url_unpadded = Base.url_encode64(secret, padding: false)

      assert unpadded in SecretMasker.forms([secret])
      assert url_unpadded in SecretMasker.forms([secret])

      assert SecretMasker.mask("token: " <> unpadded <> " end", [secret]) ==
               "token: #{@redacted} end"

      assert SecretMasker.mask("token: " <> url_unpadded <> " end", [secret]) ==
               "token: #{@redacted} end"

      assert SecretMasker.mask("t: " <> Base.encode64(secret) <> ".", [secret]) ==
               "t: #{@redacted}."
    end

    test "the standard and the url-safe unpadded forms are each masked" do
      # Fourteen characters whose base64 holds "+" and "/": the two
      # alphabets' unpadded forms differ, and each is its own form.
      secret = "sk-~~~???>>>9q"
      standard = Base.encode64(secret, padding: false)
      url_safe = Base.url_encode64(secret, padding: false)

      assert standard =~ "+" and standard =~ "/"
      refute standard == url_safe

      for form <- [standard, url_safe] do
        assert form in SecretMasker.forms([secret])
        assert SecretMasker.mask("t: " <> form <> " .", [secret]) == "t: #{@redacted} ."
      end
    end

    test "a short secret has its raw form alone, and an unusable value none" do
      assert SecretMasker.forms(["abc"]) == ["abc"]
      assert SecretMasker.forms(["", nil, 123]) == []
      assert SecretMasker.forms(nil) == []
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
