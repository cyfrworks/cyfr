# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.ConfirmationTest do
  @moduledoc """
  The `confirmation` tool through the gate, as the wire reaches it, and a
  sensitive change met by each surface.

  A change a person asks for without a proof answers the
  `confirmation_required` signal naming one pending record, over MCP as
  over the gate; the person reads that record's preview under their own
  session (`pending`), proves it with a passkey assertion over its digest
  or with the one-time code emailed for it (`confirm`), and the change,
  repeated naming the record, goes ahead once. A plain OAuth sign-in is no
  proof. A code is bound to its record, used once, and five wrong ones
  cancel the record. The stream `confirmation.changes` is declared beside
  the operations. No secret, code or assertion reaches a log.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.Identity.Encoding
  alias Sanctum.Context
  alias Sanctum.TestContext
  alias Sanctum.TestContext.{Authenticator, MailSink}
  alias Sanctum.Tenancy.{Athanors, Users}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)
    seated!()
  end

  # A person with a verified email, seated in a group of their own, and the
  # context their session establishes there.
  defp seated!(opts \\ []) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|confirmation-#{n}",
        provider: "github",
        email: "confirmation#{n}@example.com",
        verified: Keyword.get(opts, :verified, true)
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Confirmation #{n}")
    %{user: user, athanor: athanor, session_ctx: session_ctx(user, athanor)}
  end

  defp session_ctx(user, athanor) do
    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    ctx
  end

  defp call(ctx, tool \\ "confirmation", action, args),
    do: Grimoire.call_external(tool, ctx, Map.put(args, "action", action))

  defp refusal({:error, reason}), do: Grimoire.Error.classify(reason)

  # A credential entry asked for through the gate, as a page asks for it.
  defp entry(name, secret \\ "sk-confirmation-secret"),
    do: %{"name" => name, "kind" => "api_key", "fields" => %{"KEY" => secret}}

  defp asked!(ctx, name \\ "prod-key") do
    assert {:error, {:confirmation_required, %{id: id, operation: "vault.create"}}} =
             call(ctx, "vault", "create", entry(name))

    id
  end

  defp pending!(ctx, id) do
    {:ok, %{confirmations: records}} = call(ctx, "pending", %{})
    Enum.find(records, &(&1.id == id)) || flunk("#{id} is not pending")
  end

  # ---------------------------------------------------------------------------
  # The stream
  # ---------------------------------------------------------------------------

  test "the stream is declared beside the operations, bound to its holder, projecting no preview" do
    assert {:ok, stream} = Prima.Provider.fetch_stream(Grimoire.streams(), "confirmation.changes")
    assert stream.topic == :confirmations
    assert stream.projection == ["id", "operation", "expires_at"]
    assert stream.bind == :holder
    assert Cyfr.Bus.grantable?(stream.topic, true)
  end

  # ---------------------------------------------------------------------------
  # The signal, the preview and a passkey's proof
  # ---------------------------------------------------------------------------

  describe "a change a session asks for with no proof" do
    test "answers the signal; pending reads the home's preview and the passkey's request options",
         %{session_ctx: session_ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)
      id = asked!(session_ctx)

      record = pending!(session_ctx, id)
      assert record.operation == "vault.create"
      assert record.action == "credential_entry"
      assert record.state == "pending"
      assert record.preview["resource"] == "prod-key"
      assert record.preview["operation"] == "vault.create"
      refute inspect(record) =~ "sk-confirmation-secret"

      webauthn = record.webauthn
      assert webauthn["userVerification"] == "required"
      assert webauthn["rpId"] == Sanctum.Passkeys.rp_id()

      assert webauthn["allowCredentials"] == [
               %{"type" => "public-key", "id" => Encoding.b64(authenticator.credential_id)}
             ]

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session_ctx), id)
      "sha256:" <> hex = row.digest
      assert Encoding.b64(Base.decode16!(hex, case: :lower)) == webauthn["challenge"]
    end

    test "a passkey's assertion over the wire proves it, and the repeat naming it goes ahead once",
         %{session_ctx: session_ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)
      id = asked!(session_ctx)

      challenge =
        Base.url_decode64!(pending!(session_ctx, id).webauthn["challenge"], padding: false)

      assertion = Authenticator.assertion(authenticator, challenge)

      log =
        capture_log(fn ->
          assert {:ok, %{id: ^id, state: "confirmed"}} =
                   call(session_ctx, "confirm", %{"id" => id, "assertion" => assertion})
        end)

      refute log =~ assertion["response"]["signature"]

      assert {:ok, %{entry: %{name: "prod-key"}}} =
               call(%{session_ctx | confirmation_id: id}, "vault", "create", entry("prod-key"))

      # The same record again is consumed: a new one is asked for.
      assert {:error, {:confirmation_required, %{id: again}}} =
               call(%{session_ctx | confirmation_id: id}, "vault", "create", entry("prod-key-2"))

      refute again == id
    end

    test "confirm takes exactly one proof, and a sign-in is none", %{session_ctx: session_ctx} do
      id = asked!(session_ctx)

      for args <- [%{"id" => id}, %{"id" => id, "assertion" => %{}, "code" => "123456"}] do
        assert %Prima.Refusal{class: :invalid_argument} =
                 refusal(call(session_ctx, "confirm", args))
      end

      # A plain OAuth sign-in declares it proves no freshness, and no
      # re-authentication method names one.
      refute Sanctum.Auth.OAuth.proves_freshness?()
      refute Sanctum.Auth.OIDC.proves_freshness?()

      assert {:error, _refused} =
               call(session_ctx, "reauth", %{"id" => id, "method" => "github"})

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session_ctx), id)
      assert row.state == "pending"
    end

    test "an MCP caller meeting a sensitive change receives the signal with its id, never a success",
         %{session_ctx: session_ctx} do
      name = "mcp-issuer-#{System.unique_integer([:positive])}"

      # An admin key, which may mint keys, minting one.
      opts = %{name: name, type: :admin}

      issuing =
        TestContext.confirmed(session_ctx, :credential_issuance, %{
          operation: "key.create",
          arguments: opts,
          resource: name
        })

      {:ok, %{api_key: raw}} = Sanctum.ApiKey.create(issuing, opts)
      {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw})

      message = %Prima.MCP.Message{
        type: :request,
        id: 9,
        method: "tools/call",
        params: %{"name" => "key", "arguments" => %{"action" => "create", "name" => "minted"}}
      }

      assert {:error, :confirmation_required, _message, data} =
               Emissary.MCP.Router.dispatch(key_ctx, message)

      assert %{"tag" => "confirmation_required", "payload" => %{"id" => id}} =
               data |> Jason.encode!() |> Jason.decode!()

      assert is_binary(id)
      {:ok, keys} = Sanctum.ApiKey.list(key_ctx)
      refute Enum.any?(keys, &(&1.name == "minted"))
    end
  end

  # ---------------------------------------------------------------------------
  # The emailed code
  # ---------------------------------------------------------------------------

  describe "an emailed one-time code" do
    test "is sent to the verified email for one record, and confirms it", %{
      session_ctx: session_ctx,
      user: user
    } do
      id = asked!(session_ctx)

      log =
        capture_log(fn ->
          assert {:ok, %{method: "email", expires_at: %DateTime{}}} =
                   call(session_ctx, "reauth", %{"id" => id, "method" => "email"})

          assert_receive {:confirmation_code_mail, %{to: to} = mail}
          assert to == user.email
          code = MailSink.code(mail)
          send(self(), {:code, code})

          assert {:ok, %{id: ^id, state: "confirmed"}} =
                   call(session_ctx, "confirm", %{"id" => id, "code" => code})
        end)

      assert_received {:code, code}
      refute log =~ code

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session_ctx), id)
      assert row.proof == "email_code"
      refute inspect(row) =~ code
    end

    test "is used once, and never for another record", %{session_ctx: session_ctx} do
      first = asked!(session_ctx, "first")
      second = asked!(session_ctx, "second")

      {:ok, _} = call(session_ctx, "reauth", %{"id" => first, "method" => "email"})
      assert_receive {:confirmation_code_mail, mail}
      code = MailSink.code(mail)

      {:ok, _} = call(session_ctx, "reauth", %{"id" => second, "method" => "email"})
      assert_receive {:confirmation_code_mail, _other}

      assert %Prima.Refusal{reason: :code_refused} =
               refusal(call(session_ctx, "confirm", %{"id" => second, "code" => code}))

      assert {:ok, _} = call(session_ctx, "confirm", %{"id" => first, "code" => code})

      assert %Prima.Refusal{reason: :not_pending} =
               refusal(call(session_ctx, "confirm", %{"id" => first, "code" => code}))
    end

    test "sending again invalidates the old code and keeps the record's expiry", %{
      session_ctx: session_ctx
    } do
      id = asked!(session_ctx)

      {:ok, %{expires_at: expires_at}} =
        call(session_ctx, "reauth", %{"id" => id, "method" => "email"})

      assert_receive {:confirmation_code_mail, first_mail}

      {:ok, %{expires_at: ^expires_at}} =
        call(session_ctx, "reauth", %{"id" => id, "method" => "email"})

      assert_receive {:confirmation_code_mail, second_mail}

      old = MailSink.code(first_mail)
      new = MailSink.code(second_mail)

      if old != new do
        assert %Prima.Refusal{reason: :code_refused} =
                 refusal(call(session_ctx, "confirm", %{"id" => id, "code" => old}))
      end

      assert {:ok, _} = call(session_ctx, "confirm", %{"id" => id, "code" => new})
    end

    test "five wrong codes cancel the record, and nothing confirms it after", %{
      session_ctx: session_ctx
    } do
      id = asked!(session_ctx)
      {:ok, _} = call(session_ctx, "reauth", %{"id" => id, "method" => "email"})
      assert_receive {:confirmation_code_mail, mail}
      code = MailSink.code(mail)
      wrong = if code == "000000", do: "111111", else: "000000"

      for _ <- 1..5 do
        assert %Prima.Refusal{reason: :code_refused} =
                 refusal(call(session_ctx, "confirm", %{"id" => id, "code" => wrong}))
      end

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session_ctx), id)
      assert row.state == "cancelled"

      assert {:error, _refused} = call(session_ctx, "confirm", %{"id" => id, "code" => code})
    end

    test "with no transport configured, the method is unavailable" do
      %{session_ctx: session_ctx} = seated!()
      id = asked!(session_ctx)
      transport = Application.get_env(:sanctum, :confirmation_code_transport)
      Application.delete_env(:sanctum, :confirmation_code_transport)
      on_exit(fn -> Application.put_env(:sanctum, :confirmation_code_transport, transport) end)

      assert %Prima.Refusal{class: :unavailable, reason: :email_unavailable} =
               refusal(call(session_ctx, "reauth", %{"id" => id, "method" => "email"}))

      refute_received {:confirmation_code_mail, _}
    end

    test "a person with no verified email is sent no code" do
      %{session_ctx: session_ctx} = seated!(verified: false)
      id = asked!(session_ctx)

      assert %Prima.Refusal{reason: :email_unavailable} =
               refusal(call(session_ctx, "reauth", %{"id" => id, "method" => "email"}))
    end
  end

  # ---------------------------------------------------------------------------
  # Cancelling, and another person's records
  # ---------------------------------------------------------------------------

  describe "cancel and another person" do
    test "cancel ends a record once", %{session_ctx: session_ctx} do
      id = asked!(session_ctx)
      assert {:ok, %{id: ^id, state: "cancelled"}} = call(session_ctx, "cancel", %{"id" => id})

      assert %Prima.Refusal{reason: :not_pending} =
               refusal(call(session_ctx, "cancel", %{"id" => id}))

      {:ok, %{confirmations: records}} = call(session_ctx, "pending", %{})
      refute Enum.any?(records, &(&1.id == id))
    end

    test "another member reads, proves and cancels none of a person's records", %{
      session_ctx: session_ctx,
      athanor: athanor
    } do
      id = asked!(session_ctx)
      %{user: other} = seated!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.id, scope: "athanor", athanor_id: athanor.id)

      other_ctx = session_ctx(other, athanor)
      other_authenticator = TestContext.passkey!(other.id)

      {:ok, %{confirmations: theirs}} = call(other_ctx, "pending", %{})
      refute Enum.any?(theirs, &(&1.id == id))

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session_ctx), id)
      "sha256:" <> hex = row.digest
      assertion = Authenticator.assertion(other_authenticator, Base.decode16!(hex, case: :lower))

      assert {:error, _} = call(other_ctx, "confirm", %{"id" => id, "assertion" => assertion})
      assert {:error, _} = call(other_ctx, "cancel", %{"id" => id})
      assert {:error, _} = call(other_ctx, "reauth", %{"id" => id, "method" => "email"})
      refute_received {:confirmation_code_mail, _}

      {:ok, row} = Arca.PendingConfirmations.get(Context.actor(session_ctx), id)
      assert row.state == "pending"
    end

    test "a re-authentication through an issuer this home does not sign in with is refused",
         %{session_ctx: session_ctx} do
      id = asked!(session_ctx)

      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(call(session_ctx, "reauth", %{"id" => id, "method" => "oidc"}))
    end
  end
end
