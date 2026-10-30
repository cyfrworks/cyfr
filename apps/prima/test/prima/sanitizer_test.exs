# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A struct defined here rather than borrowed from the app: the property under
# test is the sanitizer's, independent of which production struct carries a
# credential field.
defmodule Prima.SanitizerTest.Credentialed do
  @moduledoc false
  defstruct [:id, :sanctum_token]
end

# A struct with no sensitive field name: only the value layer reaches it.
defmodule Prima.SanitizerTest.Note do
  @moduledoc false
  defstruct [:text]
end

defmodule Prima.SanitizerTest do
  use ExUnit.Case, async: true

  alias Prima.Sanitizer
  alias Prima.SanitizerTest.Credentialed

  describe "matching grammar" do
    test "preserves token, normalized substring, exact and raw-key rules" do
      sensitive = [
        "x.auth",
        "tokenValue",
        "TOKEN_VALUE",
        "privateKeyId",
        "API--KEY",
        "prefix-api_key-suffix",
        "confirmationId",
        "cyfr/confirmationId",
        "confirmation-id",
        "INVITATION_URL",
        "invitationUrl",
        "FRAG-MENT",
        "_T",
        "_SESSION",
        "recovery_code",
        "recoveryCode",
        "recovery-code",
        :confirmation_id,
        :master_key
      ]

      readable = [
        "authentication",
        "tokenizer",
        "secretary",
        "offer_id",
        "sender_user_id",
        "recipient_user_id",
        "filename",
        "idempotency_key",
        "partition_key",
        "connection_state",
        "field_names",
        "fragment_id",
        "invitation_url_label",
        "recovery_phase",
        "recovery",
        "confirmation.id",
        "confirmation id",
        "private.key",
        "api key",
        "session",
        "t",
        "session_object",
        "",
        :offer_id,
        :session,
        nil,
        42,
        {"token", "value"}
      ]

      for key <- sensitive do
        assert Sanitizer.sensitive_key?(key), "expected sensitive key #{inspect(key)}"
      end

      for key <- readable do
        refute Sanitizer.sensitive_key?(key), "expected readable key #{inspect(key)}"
      end
    end

    test "redacts through nested credential-bearing terms while preserving identity and values" do
      data = %{
        "offer_id" => "ofr_readable",
        "detail" => [
          {:error,
           %{
             "confirmationId" => "pending-secret",
             "headers" => [{"x-api-key", "header-secret"}, {"content-type", "application/json"}],
             "session" => %Credentialed{id: "sess_readable", sanctum_token: "struct-secret"},
             "calendar" => [
               ~D[2026-10-07],
               ~T[08:00:00],
               ~N[2026-10-07 08:00:00],
               ~U[2026-10-07 08:00:00Z]
             ]
           }},
          {"_session", "query-secret"},
          {"field_names", ["password", "token"]}
        ]
      }

      assert Sanitizer.sanitize(data) == %{
               "offer_id" => "ofr_readable",
               "detail" => [
                 {:error,
                  %{
                    "confirmationId" => "[REDACTED]",
                    "headers" => [
                      {"x-api-key", "[REDACTED]"},
                      {"content-type", "application/json"}
                    ],
                    "session" => %Credentialed{id: "sess_readable", sanctum_token: "[REDACTED]"},
                    "calendar" => [
                      ~D[2026-10-07],
                      ~T[08:00:00],
                      ~N[2026-10-07 08:00:00],
                      ~U[2026-10-07 08:00:00Z]
                    ]
                  }},
                 {"_session", "[REDACTED]"},
                 {"field_names", ["password", "token"]}
               ]
             }
    end
  end

  describe "sanitize/1" do
    test "redacts password keys" do
      assert %{"password" => "[REDACTED]", "name" => "test"} ==
               Sanitizer.sanitize(%{"password" => "s3cret", "name" => "test"})
    end

    test "redacts nested sensitive keys" do
      result = Sanitizer.sanitize(%{"nested" => %{"api_key" => "abc123", "data" => "ok"}})
      assert result["nested"]["api_key"] == "[REDACTED]"
      assert result["nested"]["data"] == "ok"
    end

    test "redacts keys in lists" do
      result = Sanitizer.sanitize([%{"token" => "abc"}, %{"name" => "safe"}])
      assert [%{"token" => "[REDACTED]"}, %{"name" => "safe"}] == result
    end

    test "passes through non-sensitive data" do
      data = %{"user" => "alice", "action" => "login"}
      assert data == Sanitizer.sanitize(data)
    end

    test "passes through scalar values" do
      assert "hello" == Sanitizer.sanitize("hello")
      assert 42 == Sanitizer.sanitize(42)
      assert nil == Sanitizer.sanitize(nil)
    end

    test "redacts sensitive fields inside a struct instead of passing it through" do
      result =
        Sanitizer.sanitize(%Credentialed{id: "sess_abc", sanctum_token: "cyfr_live_token_value"})

      assert %Credentialed{} = result
      assert result.sanctum_token == "[REDACTED]"
      assert result.id == "sess_abc"
      refute inspect(result) =~ "cyfr_live_token_value"
    end

    test "round-trips calendar value structs unchanged" do
      dt = ~U[2026-08-10 12:00:00Z]
      assert dt == Sanitizer.sanitize(dt)

      nested = %{"when" => dt, "token" => "abc"}
      result = Sanitizer.sanitize(nested)
      assert result["when"] == dt
      assert result["token"] == "[REDACTED]"
    end
  end

  # Sanitization must redact credentials in nested structs and error tuples.
  describe "credentials nested in error terms" do
    test "a struct's credential is redacted inside an error tuple" do
      term = {:error, %{session: %Credentialed{id: "sess_abc", sanctum_token: "cyfr_live_token"}}}

      result = Sanitizer.sanitize(term)

      refute inspect(result) =~ "cyfr_live_token"
      assert inspect(result) =~ "sess_abc"
    end

    test "redaction reaches through lists and nested maps" do
      term = %{"attempts" => [%{"detail" => %Credentialed{sanctum_token: "cyfr_live_token"}}]}

      refute inspect(Sanitizer.sanitize(term)) =~ "cyfr_live_token"
    end
  end

  describe "sensitive_key?/1 — original keys" do
    test "detects standard sensitive keys" do
      for key <- ~w(password secret token api_key authorization bearer credentials jwt) do
        assert Sanitizer.sensitive_key?(key), "expected #{key} to be sensitive"
      end
    end

    test "detects case-insensitive" do
      assert Sanitizer.sensitive_key?("API_KEY")
      assert Sanitizer.sensitive_key?("Authorization")
      assert Sanitizer.sensitive_key?("X-Api-Key")
    end

    test "detects atom keys" do
      assert Sanitizer.sensitive_key?(:password)
      assert Sanitizer.sensitive_key?(:api_key)
    end

    test "rejects non-sensitive keys" do
      refute Sanitizer.sensitive_key?("username")
      refute Sanitizer.sensitive_key?("email")
      refute Sanitizer.sensitive_key?("action")
    end
  end

  describe "sensitive_key?/1 — stripe and basic_auth" do
    test "detects stripe keys" do
      assert Sanitizer.sensitive_key?("stripe")
      assert Sanitizer.sensitive_key?("stripe_key")
      assert Sanitizer.sensitive_key?("stripe_secret")
      assert Sanitizer.sensitive_key?("STRIPE_API_KEY")
    end

    test "detects basic_auth keys" do
      assert Sanitizer.sensitive_key?("basic_auth")
      assert Sanitizer.sensitive_key?("basic-auth")
      assert Sanitizer.sensitive_key?("basic_auth_password")
      assert Sanitizer.sensitive_key?("BASIC_AUTH_TOKEN")
    end
  end

  describe "sensitive_key?/1 — word-boundary matching" do
    test "redacts real secret keys (sensitive word is a whole token)" do
      keys = ~w(
        auth auth_token authToken access_token refresh_token client_secret
        password password_hash my_password secret_key x-api-key apiKey
        session_token private_key signing_key device_code
      )

      for key <- keys do
        assert Sanitizer.sensitive_key?(key), "expected #{key} to be sensitive"
      end
    end

    test "does NOT redact compound words that merely contain a sensitive substring" do
      keys = ~w(
        authentication authentication_method is_authenticated
        secretary tokenizer author
      )

      for key <- keys do
        refute Sanitizer.sensitive_key?(key), "expected #{key} to NOT be sensitive"
      end
    end
  end

  describe "credentials that arrive as a header pair" do
    test "a header list is redacted by name, not passed through" do
      headers = [
        {"authorization", "Bearer cyfr_live_abc"},
        {"cookie", "_cyfr_key=deadbeef"},
        {"x-cyfr-signature", "sha256=abcd"},
        {"content-type", "application/json"}
      ]

      assert Prima.Sanitizer.sanitize(headers) == [
               {"authorization", "[REDACTED]"},
               {"cookie", "[REDACTED]"},
               {"x-cyfr-signature", "[REDACTED]"},
               {"content-type", "application/json"}
             ]
    end

    test "the ordinary tagged-tuple shapes traverse" do
      assert Prima.Sanitizer.sanitize({:error, %{"password" => "hunter2", "id" => "x"}}) ==
               {:error, %{"password" => "[REDACTED]", "id" => "x"}}

      assert Prima.Sanitizer.sanitize({:ok, "fine"}) == {:ok, "fine"}
    end
  end

  describe "keys sensitive only in full" do
    test "an OAuth authorization code is redacted" do
      assert Prima.Sanitizer.sanitize(%{"code" => "4/0Adeu5"}) == %{"code" => "[REDACTED]"}
      assert Prima.Sanitizer.sensitive_key?(:code)
      assert Prima.Sanitizer.sensitive_key?("code_verifier")
    end

    test "codes that are not credentials stay readable" do
      refute Prima.Sanitizer.sensitive_key?("error_code")
      refute Prima.Sanitizer.sensitive_key?("status_code")

      # The PKCE challenge is the hash the verifier is checked against; it is
      # public by design, and a log that hides it hides the useful half.
      refute Prima.Sanitizer.sensitive_key?("code_challenge")
    end

    test "a vault entry's material is redacted whatever its field names are" do
      assert Prima.Sanitizer.sanitize(%{
               "action" => "create",
               "kind" => "api_key",
               "fields" => %{"value" => "vault-material"}
             }) == %{"action" => "create", "kind" => "api_key", "fields" => "[REDACTED]"}

      refute Prima.Sanitizer.sensitive_key?("field_names")
    end

    test "set-cookie and webhook signatures are covered" do
      assert Prima.Sanitizer.sensitive_key?("set-cookie")
      assert Prima.Sanitizer.sensitive_key?("x-hub-signature-256")
    end

    test "a pairing link is redacted as a whole key, and a plain url stays readable" do
      link = "https://home.example/pair#code=q2mTb0yU7aKpXv1ZcR4n8w"

      assert Prima.Sanitizer.sanitize(%{
               "invitation_url" => link,
               "client_id" => "pcl_1",
               "url" => "https://home.example/"
             }) == %{
               "invitation_url" => "[REDACTED]",
               "client_id" => "pcl_1",
               "url" => "https://home.example/"
             }

      assert Prima.Sanitizer.sanitize(%{invitation_url: link}) == %{invitation_url: "[REDACTED]"}
      assert Prima.Sanitizer.sensitive_key?("invitationUrl")
      refute Prima.Sanitizer.sensitive_key?("url")
      refute Prima.Sanitizer.sensitive_key?("invitation_url_label")
    end

    # A command line's sign-in (`Sanctum.CliSignIn`): the link its begin
    # answers carries the approval secret in its fragment, the token it
    # holds is the session, and the approval names the secret again.
    test "a command line's sign-in link, token and approval secret are redacted, and its code is not" do
      link = "https://home.example/cli#code=q2mTb0yU7aKpXv1ZcR4n8w"

      assert Prima.Sanitizer.sanitize(%{
               "approve_url" => link,
               "session_token" => "c2Vzc2lvbiB0b2tlbiBvZiB0aGlydHktdHdvIGJ5dGVz",
               "user_code" => "K7QM-3XRD",
               "machine" => "laptop"
             }) == %{
               "approve_url" => "[REDACTED]",
               "session_token" => "[REDACTED]",
               "user_code" => "K7QM-3XRD",
               "machine" => "laptop"
             }

      assert Prima.Sanitizer.sanitize(%{"approval_secret" => "q2mTb0yU7aKpXv1ZcR4n8w"}) ==
               %{"approval_secret" => "[REDACTED]"}

      assert Prima.Sanitizer.sensitive_key?("approveUrl")
      refute Prima.Sanitizer.sensitive_key?("approve_url_label")
    end

    # A sign-in carry's fragment, as a page hands it to its LiveView
    # (`cyfr_carry`, `cyfr_assertion`, `carry_challenge`, `carry_return`) and
    # as the sign-in page posts an assertion to its callback.
    test "a sign-in carry's fragment is redacted as a whole key, and longer names stay readable" do
      carried = "eyJhc3NlcnRpb24iOnsiYXVkaWVuY2UiOiJodHRwczovL2h1Yi5leGFtcGxlIn19"

      assert Prima.Sanitizer.sanitize(%{
               "fragment" => carried,
               "expected_source" => "https://a.example",
               "fragment_id" => "f1"
             }) == %{
               "fragment" => "[REDACTED]",
               "expected_source" => "https://a.example",
               "fragment_id" => "f1"
             }

      assert Prima.Sanitizer.sensitive_key?(:fragment)
      refute Prima.Sanitizer.sensitive_key?("fragments_seen")

      # Phoenix's request and LiveView event logs filter by substring.
      assert Enum.any?(Prima.Sanitizer.filter_parameters(), &String.contains?("fragment", &1))
    end
  end

  # A person's recovery code (`Prima.RecoveryCode`), the one line that
  # restores them, under the names it travels by.
  describe "a person's recovery code" do
    test "is redacted under every spelling of its key, at the top level and nested" do
      code =
        Prima.RecoveryCode.encode("per_" <> String.duplicate("5", 64), :binary.copy(<<7>>, 32))

      assert String.length(code) == 130

      assert Prima.Sanitizer.sanitize(%{
               "recovery_code" => code,
               "holder" => %{"recoveryCode" => code, "recovery-code" => code},
               "recovery_phase" => "saved",
               "error_code" => "typo"
             }) == %{
               "recovery_code" => "[REDACTED]",
               "holder" => %{"recoveryCode" => "[REDACTED]", "recovery-code" => "[REDACTED]"},
               "recovery_phase" => "saved",
               "error_code" => "typo"
             }

      assert Prima.Sanitizer.sensitive_key?(:recovery_code)

      # Phoenix's request and LiveView event logs filter by substring.
      assert Enum.any?(
               Prima.Sanitizer.filter_parameters(),
               &String.contains?("recovery_code", &1)
             )
    end
  end

  # A pending confirmation's secret travels as a context's `confirmation_id`
  # and as the MCP request metadata key `cyfr/confirmationId`.
  describe "a pending confirmation's secret" do
    @secret "cnf_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    test "is redacted under either spelling" do
      version = "io.modelcontextprotocol/protocolVersion"

      assert Prima.Sanitizer.sanitize(%{
               "confirmation_id" => @secret,
               "_meta" => %{"cyfr/confirmationId" => @secret, version => "2026-07-28"}
             }) == %{
               "confirmation_id" => "[REDACTED]",
               "_meta" => %{"cyfr/confirmationId" => "[REDACTED]", version => "2026-07-28"}
             }

      assert Prima.Sanitizer.sensitive_key?(:confirmation_id)
    end

    # Phoenix filters a parameter whose key contains a listed term, compared
    # case-sensitively.
    test "is reachable by Phoenix's substring match under either spelling" do
      for key <- ["cyfr/confirmationId", "confirmation_id"] do
        assert Enum.any?(Prima.Sanitizer.filter_parameters(), &String.contains?(key, &1)),
               "#{key} must be reachable by Phoenix's substring match"
      end
    end
  end

  # The second layer: a credential recognised by its value, under any key.
  describe "a credential by its shape" do
    alias Prima.CredentialShape

    test "each shape is replaced under an innocent key, whole or embedded, at any depth" do
      for {kind, credential} <- credentials() do
        data = %{
          "note" => credential,
          "nested" => %{
            "deeper" => [%{"text" => "use #{credential} to call"}, {"pair", "(#{credential})"}],
            "twice" => "#{credential},#{credential}"
          },
          "struct" => %Prima.SanitizerTest.Note{text: "/files/#{credential}"},
          "count" => 3
        }

        assert Sanitizer.sanitize(data) == %{
                 "note" => "[REDACTED]",
                 "nested" => %{
                   "deeper" => [%{"text" => "use [REDACTED] to call"}, {"pair", "([REDACTED])"}],
                   "twice" => "[REDACTED],[REDACTED]"
                 },
                 "struct" => %Prima.SanitizerTest.Note{text: "/files/[REDACTED]"},
                 "count" => 3
               },
               "#{inspect(kind)} was not replaced"
      end
    end

    test "a run without its prefix, of another length or alphabet, stays readable" do
      header = CredentialShape.signed_token_header()
      signature = CredentialShape.signed_token_signature_length()

      prefixed =
        for {_kind, prefix, length} <- CredentialShape.prefixed(),
            text <- [
              prefix <> run(length - 1),
              prefix <> run(length + 1),
              # A longer malformed run is not its valid-length head.
              prefix <> run(length) <> "-tail",
              prefix <> run(length - 1) <> "+",
              prefix <> "!" <> run(length - 1),
              String.upcase(prefix) <> run(length),
              run(length),
              "the #{prefix} prefix, named in prose"
            ],
            do: text

      signed = [
        signed(48, signature - 1),
        signed(48, signature + 1),
        signed(48, signature) <> "x",
        header <> ".." <> run(signature),
        String.downcase(header) <> "." <> run(48) <> "." <> run(signature),
        run(43),
        run(32)
      ]

      ordinary = [
        "internationalization_configuration_value",
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, "x"), case: :lower),
        Base.url_encode64(:crypto.hash(:sha256, "x"), padding: false),
        "frm_" <> run(20),
        "https://example.com/hooks/wh_" <> run(24)
      ]

      for text <- prefixed ++ signed ++ ordinary do
        assert Sanitizer.sanitize(%{"note" => [text]}) == %{"note" => [text]},
               "#{inspect(text)} was redacted"
      end
    end

    test "a key is never rewritten, so no two keys collapse into one" do
      [{_kind, credential} | _] = credentials()

      assert Sanitizer.sanitize(%{credential => "value", "other" => credential}) ==
               %{credential => "value", "other" => "[REDACTED]"}
    end

    # Every candidate reads a bounded span after its prefix, so text dense
    # with candidates costs work in proportion to its length. Twice the
    # text may cost at most three times the reductions (linear is two; a
    # rescan of the rest of the text per candidate is four).
    test "recognition is linear in the text, however dense its candidates" do
      header = CredentialShape.signed_token_header()

      units =
        Enum.map(CredentialShape.prefixed(), &elem(&1, 1)) ++
          [header <> ".", header <> "." <> String.duplicate("A", 900) <> "."]

      for unit <- units do
        cost = fn bytes ->
          text = String.duplicate(unit, div(bytes, byte_size(unit)))
          Sanitizer.sanitize(%{"note" => text})
          reductions(fn -> Sanitizer.sanitize(%{"note" => text}) end)
        end

        small = cost.(16_384)
        large = cost.(32_768)

        assert large < 3 * small,
               "#{inspect(binary_part(unit, 0, min(byte_size(unit), 12)))}: " <>
                 "#{small} reductions for 16 KiB, #{large} for 32 KiB"
      end
    end

    test "the placeholder is the key-name layer's" do
      assert Sanitizer.placeholder() == "[REDACTED]"
      assert Sanitizer.sanitize(%{"password" => "x"}) == %{"password" => Sanitizer.placeholder()}
    end

    # One credential of every shape: each prefixed kind as its minter draws
    # it, and a signed token of the declared form.
    defp credentials do
      minted =
        for {kind, _prefix, _length} <- CredentialShape.prefixed(),
            do: {kind, CredentialShape.mint(kind)}

      [{:signed_token, signed(48, CredentialShape.signed_token_signature_length())} | minted]
    end

    defp signed(payload, signature),
      do: CredentialShape.signed_token_header() <> "." <> run(payload) <> "." <> run(signature)

    defp reductions(fun) do
      {:reductions, before} = :erlang.process_info(self(), :reductions)
      fun.()
      {:reductions, now} = :erlang.process_info(self(), :reductions)
      now - before
    end

    # `length` base64url characters.
    defp run(length) do
      bytes = :crypto.strong_rand_bytes(length)
      binary_part(Base.url_encode64(bytes, padding: false), 0, length)
    end
  end
end
