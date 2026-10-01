# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.ConfirmationTest do
  @moduledoc """
  The `confirmation` tool through the gate, as the wire reaches it, and a
  sensitive change met by each surface.

  A change a person asks for without a proof answers the
  `confirmation_required` signal with a secret, its `id`, over MCP as over
  the gate, to that request alone; every client of the person reads the
  record under its public ref, with its preview and the client that asked
  (`pending`), proves it by that ref with a passkey assertion over its
  digest or with the one-time code emailed for it (`confirm`), and the
  change, repeated under the secret, goes ahead once. The ref never
  repeats a change, and no tool takes the secret as an argument, so no
  request-log row, decision or log line keeps it. A plain OAuth sign-in is
  no proof. A code is bound to its record, used once, and five wrong ones
  cancel the record. The stream `confirmation.changes` is declared beside
  the operations, projecting the ref. No secret, code or assertion reaches
  a log.
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

  defp ref(id), do: Prima.Confirmation.ref(id)

  # A credential entry asked for through the gate, as a page asks for it.
  defp entry(name, secret \\ "sk-confirmation-secret"),
    do: %{"name" => name, "kind" => "api_key", "fields" => %{"KEY" => secret}}

  # The entry asked for with no proof: answers the signal's secret.
  defp asked!(ctx, name \\ "prod-key") do
    assert {:error, {:confirmation_required, %{id: id, operation: "vault.create"}}} =
             call(ctx, "vault", "create", entry(name))

    id
  end

  # The record the secret `id` names, as `pending` lists it by its ref.
  defp pending!(ctx, id) do
    {:ok, %{confirmations: records}} = call(ctx, "pending", %{})
    Enum.find(records, &(&1.ref == ref(id))) || flunk("#{ref(id)} is not pending")
  end

  defp row!(ctx, id) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref(id))
    row
  end

  defp assertion!(authenticator, row) do
    "sha256:" <> hex = row.digest
    Authenticator.assertion(authenticator, Base.decode16!(hex, case: :lower))
  end

  # ---------------------------------------------------------------------------
  # The stream
  # ---------------------------------------------------------------------------

  test "the stream is declared beside the operations, bound to its holder, projecting the ref and no preview" do
    assert {:ok, stream} = Prima.Provider.fetch_stream(Grimoire.streams(), "confirmation.changes")
    assert stream.topic == :confirmations
    assert stream.projection == ["ref", "operation", "expires_at"]
    assert stream.bind == :holder
    assert Cyfr.Bus.grantable?(stream.topic, true)
  end

  test "confirm, reauth and cancel take the ref alone: the secret is never an argument" do
    %{operations: operations} = Sanctum.Providers.Confirmation.definition()

    for operation <- operations, operation.action in ~w(confirm reauth cancel) do
      names = Enum.map(operation.args, & &1.name)
      assert "ref" in names, operation.action
      refute "id" in names, operation.action
    end
  end

  # ---------------------------------------------------------------------------
  # The secret, the ref and the request log
  # ---------------------------------------------------------------------------

  describe "the asking request's secret" do
    test "appears in no request-log row, decision or log line after cancel, confirm or repeat",
         %{session_ctx: session_ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)

      # Every log line, down to debug, is read for the secret.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {secrets, log} =
        with_log([level: :debug], fn ->
          # Asked, then cancelled by its ref.
          cancelled = asked!(session_ctx, "cancelled-key")

          assert {:ok, %{ref: cancelled_ref, state: "cancelled"}} =
                   call(session_ctx, "cancel", %{"ref" => ref(cancelled)})

          assert cancelled_ref == ref(cancelled)

          # Asked, proven by its ref, and repeated under its secret, as
          # Prism repeats a change (`PrismWeb.Ops`'s `confirmation_id:`).
          repeated = asked!(session_ctx, "repeated-key")
          assertion = assertion!(authenticator, row!(session_ctx, repeated))

          assert {:ok, %{ref: _, state: "confirmed"}} =
                   call(session_ctx, "confirm", %{
                     "ref" => ref(repeated),
                     "assertion" => assertion
                   })

          assert {:ok, %{entry: %{name: "repeated-key"}}} =
                   PrismWeb.Ops.call_tool(
                     session_ctx,
                     "vault/create",
                     entry("repeated-key"),
                     confirmation_id: repeated
                   )

          [cancelled, repeated]
        end)

      Logger.configure(level: previous)
      assert {:ok, %{logs: rows}} = call(session_ctx, "mcp_log", "list", %{"limit" => 100})

      assert {:ok, %{decisions: decisions}} =
               call(session_ctx, "decision", "list", %{"limit" => 100})

      stored = inspect({rows, decisions}, limit: :infinity, printable_limit: :infinity)

      # The rows are this test's: the cancel and the confirm name their refs.
      for secret <- secrets, do: assert(stored =~ ref(secret))
      assert Enum.any?(rows, &(&1.tool == "vault" and &1.status == "success"))

      for secret <- secrets do
        refute stored =~ secret
        refute log =~ secret
      end
    end

    test "a client that learned the ref from the stream or the list cannot repeat with it",
         %{session_ctx: session_ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)
      id = asked!(session_ctx)
      listed = pending!(session_ctx, id).ref
      assert listed == ref(id)

      assert {:ok, _} =
               call(session_ctx, "confirm", %{
                 "ref" => listed,
                 "assertion" => assertion!(authenticator, row!(session_ctx, id))
               })

      # Presented as the secret, the ref names no record: the change is
      # asked for again, and nothing is stored.
      assert {:error, {:confirmation_required, %{id: fresh}}} =
               call(
                 %{session_ctx | confirmation_id: listed},
                 "vault",
                 "create",
                 entry("prod-key")
               )

      refute fresh == id
      assert {:ok, entries} = Sanctum.Vault.list(session_ctx)
      refute Enum.any?(entries, &(&1.name == "prod-key"))
      assert row!(session_ctx, id).state == "confirmed"

      # The secret repeats it.
      assert {:ok, %{entry: %{name: "prod-key"}}} =
               call(%{session_ctx | confirmation_id: id}, "vault", "create", entry("prod-key"))
    end

    test "the secret as an argument is refused, never a record's name", %{
      session_ctx: session_ctx
    } do
      id = asked!(session_ctx)

      for {action, args} <- [
            {"confirm", %{"id" => id, "code" => "123456"}},
            {"reauth", %{"id" => id, "method" => "email"}},
            {"cancel", %{"id" => id}}
          ] do
        assert {:error, _refused} = call(session_ctx, action, args)
      end

      # Named by the secret where a ref belongs, the record is not found.
      assert {:error, _not_found} = call(session_ctx, "cancel", %{"ref" => id})
      assert row!(session_ctx, id).state == "pending"
    end
  end

  # ---------------------------------------------------------------------------
  # The signal, the preview and a passkey's proof
  # ---------------------------------------------------------------------------

  describe "a change a session asks for with no proof" do
    test "answers the signal; pending reads the home's preview, the asker and the passkey's request options",
         %{session_ctx: session_ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)
      id = asked!(session_ctx)

      record = pending!(session_ctx, id)
      refute Map.has_key?(record, :id)
      assert record.operation == "vault.create"
      assert record.action == "credential_entry"
      assert record.state == "pending"
      assert record.preview["resource"] == "prod-key"
      assert record.preview["operation"] == "vault.create"
      refute inspect(record) =~ "sk-confirmation-secret"
      refute inspect(record, limit: :infinity, printable_limit: :infinity) =~ id

      # The client that asked: this session, by its sign-in provider and
      # when it was created.
      assert %{"kind" => "session", "name" => "github", "since" => since} = record.asker
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(since)

      webauthn = record.webauthn
      assert webauthn["userVerification"] == "required"
      assert webauthn["rpId"] == Sanctum.Passkeys.rp_id()

      assert webauthn["allowCredentials"] == [
               %{"type" => "public-key", "id" => Encoding.b64(authenticator.credential_id)}
             ]

      "sha256:" <> hex = row!(session_ctx, id).digest
      assert Encoding.b64(Base.decode16!(hex, case: :lower)) == webauthn["challenge"]
    end

    test "two identical requests open two records, each listed with its own ref",
         %{session_ctx: session_ctx} do
      first = asked!(session_ctx)
      second = asked!(session_ctx)
      refute first == second

      {:ok, %{confirmations: records}} = call(session_ctx, "pending", %{})
      refs = Enum.map(records, & &1.ref)
      assert ref(first) in refs and ref(second) in refs
    end

    test "a passkey's assertion over the wire proves it by its ref, and the repeat under the secret goes ahead once",
         %{session_ctx: session_ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)
      id = asked!(session_ctx)
      listed = pending!(session_ctx, id)

      challenge = Base.url_decode64!(listed.webauthn["challenge"], padding: false)
      assertion = Authenticator.assertion(authenticator, challenge)

      log =
        capture_log(fn ->
          assert {:ok, %{ref: ref, state: "confirmed"} = answer} =
                   call(session_ctx, "confirm", %{"ref" => listed.ref, "assertion" => assertion})

          assert ref == listed.ref
          refute Map.has_key?(answer, :id)
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

      for args <- [
            %{"ref" => ref(id)},
            %{"ref" => ref(id), "assertion" => %{}, "code" => "123456"}
          ] do
        assert %Prima.Refusal{class: :invalid_argument} =
                 refusal(call(session_ctx, "confirm", args))
      end

      # A plain OAuth sign-in declares it proves no freshness, and no
      # re-authentication method names one.
      refute Sanctum.Auth.OAuth.proves_freshness?()
      refute Sanctum.Auth.OIDC.proves_freshness?()

      assert {:error, _refused} =
               call(session_ctx, "reauth", %{"ref" => ref(id), "method" => "github"})

      assert row!(session_ctx, id).state == "pending"
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

      assert {:error, :confirmation_required, sentence, data} =
               Emissary.MCP.Router.dispatch(key_ctx, message)

      assert %{"tag" => "confirmation_required", "payload" => %{"id" => id}} =
               data |> Jason.encode!() |> Jason.decode!()

      # The secret rides the signal's data alone, never its sentence, and
      # the person's other clients read the record by its ref, naming the
      # key that asked.
      assert is_binary(id)
      refute sentence =~ id
      assert pending!(session_ctx, id).asker == %{"kind" => "key", "name" => name}

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
                   call(session_ctx, "reauth", %{"ref" => ref(id), "method" => "email"})

          assert_receive {:confirmation_code_mail, %{to: to} = mail}
          assert to == user.email
          refute mail.text =~ id
          code = MailSink.code(mail)
          send(self(), {:code, code})

          assert {:ok, %{ref: confirmed, state: "confirmed"}} =
                   call(session_ctx, "confirm", %{"ref" => ref(id), "code" => code})

          assert confirmed == ref(id)
        end)

      assert_received {:code, code}
      refute log =~ code

      row = row!(session_ctx, id)
      assert row.proof == "email_code"
      refute inspect(row) =~ code
    end

    test "is used once, and never for another record", %{session_ctx: session_ctx} do
      first = ref(asked!(session_ctx, "first"))
      second = ref(asked!(session_ctx, "second"))

      {:ok, _} = call(session_ctx, "reauth", %{"ref" => first, "method" => "email"})
      assert_receive {:confirmation_code_mail, mail}
      code = MailSink.code(mail)

      {:ok, _} = call(session_ctx, "reauth", %{"ref" => second, "method" => "email"})
      assert_receive {:confirmation_code_mail, _other}

      assert %Prima.Refusal{reason: :code_refused} =
               refusal(call(session_ctx, "confirm", %{"ref" => second, "code" => code}))

      assert {:ok, _} = call(session_ctx, "confirm", %{"ref" => first, "code" => code})

      assert %Prima.Refusal{reason: :not_pending} =
               refusal(call(session_ctx, "confirm", %{"ref" => first, "code" => code}))
    end

    test "sending again invalidates the old code and keeps the record's expiry", %{
      session_ctx: session_ctx
    } do
      named = ref(asked!(session_ctx))

      {:ok, %{expires_at: expires_at}} =
        call(session_ctx, "reauth", %{"ref" => named, "method" => "email"})

      assert_receive {:confirmation_code_mail, first_mail}

      {:ok, %{expires_at: ^expires_at}} =
        call(session_ctx, "reauth", %{"ref" => named, "method" => "email"})

      assert_receive {:confirmation_code_mail, second_mail}

      old = MailSink.code(first_mail)
      new = MailSink.code(second_mail)

      if old != new do
        assert %Prima.Refusal{reason: :code_refused} =
                 refusal(call(session_ctx, "confirm", %{"ref" => named, "code" => old}))
      end

      assert {:ok, _} = call(session_ctx, "confirm", %{"ref" => named, "code" => new})
    end

    test "five wrong codes cancel the record, and nothing confirms it after", %{
      session_ctx: session_ctx
    } do
      id = asked!(session_ctx)
      {:ok, _} = call(session_ctx, "reauth", %{"ref" => ref(id), "method" => "email"})
      assert_receive {:confirmation_code_mail, mail}
      code = MailSink.code(mail)
      wrong = if code == "000000", do: "111111", else: "000000"

      for _ <- 1..5 do
        assert %Prima.Refusal{reason: :code_refused} =
                 refusal(call(session_ctx, "confirm", %{"ref" => ref(id), "code" => wrong}))
      end

      assert row!(session_ctx, id).state == "cancelled"

      assert {:error, _refused} =
               call(session_ctx, "confirm", %{"ref" => ref(id), "code" => code})
    end

    test "with no transport configured, the method is unavailable" do
      %{session_ctx: session_ctx} = seated!()
      id = asked!(session_ctx)
      transport = Application.get_env(:sanctum, :confirmation_code_transport)
      Application.delete_env(:sanctum, :confirmation_code_transport)
      on_exit(fn -> Application.put_env(:sanctum, :confirmation_code_transport, transport) end)

      assert %Prima.Refusal{class: :unavailable, reason: :email_unavailable} =
               refusal(call(session_ctx, "reauth", %{"ref" => ref(id), "method" => "email"}))

      refute_received {:confirmation_code_mail, _}
    end

    test "a person with no verified email is sent no code" do
      %{session_ctx: session_ctx} = seated!(verified: false)
      id = asked!(session_ctx)

      assert %Prima.Refusal{reason: :email_unavailable} =
               refusal(call(session_ctx, "reauth", %{"ref" => ref(id), "method" => "email"}))
    end
  end

  # ---------------------------------------------------------------------------
  # Cancelling, and another person's records
  # ---------------------------------------------------------------------------

  describe "cancel and another person" do
    test "cancel ends a record once, by its ref", %{session_ctx: session_ctx} do
      id = asked!(session_ctx)
      named = ref(id)

      assert {:ok, %{ref: ^named, state: "cancelled"} = answer} =
               call(session_ctx, "cancel", %{"ref" => named})

      refute Map.has_key?(answer, :id)

      assert %Prima.Refusal{reason: :not_pending} =
               refusal(call(session_ctx, "cancel", %{"ref" => named}))

      {:ok, %{confirmations: records}} = call(session_ctx, "pending", %{})
      refute Enum.any?(records, &(&1.ref == named))
    end

    test "another member reads, proves and cancels none of a person's records", %{
      session_ctx: session_ctx,
      athanor: athanor
    } do
      id = asked!(session_ctx)
      named = ref(id)
      %{user: other} = seated!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.id, scope: "athanor", athanor_id: athanor.id)

      other_ctx = session_ctx(other, athanor)
      other_authenticator = TestContext.passkey!(other.id)

      {:ok, %{confirmations: theirs}} = call(other_ctx, "pending", %{})
      refute Enum.any?(theirs, &(&1.ref == named))

      assertion = assertion!(other_authenticator, row!(session_ctx, id))

      assert {:error, _} = call(other_ctx, "confirm", %{"ref" => named, "assertion" => assertion})
      assert {:error, _} = call(other_ctx, "cancel", %{"ref" => named})
      assert {:error, _} = call(other_ctx, "reauth", %{"ref" => named, "method" => "email"})
      refute_received {:confirmation_code_mail, _}

      assert row!(session_ctx, id).state == "pending"
    end

    test "a ref names one record in one athanor of one person; any other ref is refused", %{
      session_ctx: session_ctx,
      user: user
    } do
      authenticator = TestContext.passkey!(user.id)
      id = asked!(session_ctx)
      named = ref(id)
      assertion = assertion!(authenticator, row!(session_ctx, id))

      # The same person, working in another athanor of theirs: the ref
      # names nothing there.
      {:ok, elsewhere} = Athanors.create_group(user.id, "Elsewhere #{System.unique_integer()}")
      elsewhere_ctx = session_ctx(user, elsewhere)

      {:ok, %{confirmations: there}} = call(elsewhere_ctx, "pending", %{})
      refute Enum.any?(there, &(&1.ref == named))

      for {action, args} <- [
            {"confirm", %{"ref" => named, "assertion" => assertion}},
            {"cancel", %{"ref" => named}},
            {"reauth", %{"ref" => named, "method" => "email"}}
          ] do
        assert %Prima.Refusal{class: :not_found} = refusal(call(elsewhere_ctx, action, args)),
               action
      end

      # A ref that names no record, here or anywhere.
      unknown = ref("cnf_" <> Encoding.b64(:crypto.strong_rand_bytes(32)))

      assert %Prima.Refusal{class: :not_found} =
               refusal(call(session_ctx, "cancel", %{"ref" => unknown}))

      refute_received {:confirmation_code_mail, _}
      assert row!(session_ctx, id).state == "pending"
    end

    test "a re-authentication through an issuer this home does not sign in with is refused",
         %{session_ctx: session_ctx} do
      id = asked!(session_ctx)

      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(call(session_ctx, "reauth", %{"ref" => ref(id), "method" => "oidc"}))
    end
  end
end
