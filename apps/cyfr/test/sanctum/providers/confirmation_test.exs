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
  (`pending`), asks this CYFR for the record's `confirm` request
  (`request`), and proves the record by its ref with the answer a passkey
  of the person's account signed for that request at the account pages
  (`confirm`); the change, repeated under the secret, goes ahead once. An
  answer confirms only under the session its request was bound to, once,
  for the record that request names, by a key of the record's own person.
  The ref never repeats a change, and no tool takes the secret as an
  argument, so no request-log row, decision or log line keeps it. The
  stream `confirmation.changes` is declared beside the operations,
  projecting the ref and what happened to the record.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.Identity.Encoding
  alias Sanctum.Context
  alias Sanctum.TestContext
  alias Sanctum.TestContext.Authenticator

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    signed_in!()
  end

  # A person with their own athanor and an account whose passkey answers
  # here (`Sanctum.TestContext.account!/1`), and the context their session
  # establishes there.
  defp signed_in! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|confirmation-#{n}",
        provider: "github",
        email: "confirmation#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)
    _account = TestContext.account!(user.id)
    %{user: user, athanor: athanor, session_ctx: session_ctx(user, athanor)}
  end

  defp session_ctx(user, athanor) do
    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "passkey",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    ctx
  end

  defp call(ctx, tool \\ "confirmation", action, args),
    do: Sanctum.Gate.call_external(tool, ctx, Map.put(args, "action", action))

  defp refusal({:error, reason}), do: Sanctum.Refusals.classify(reason)

  defp ref(id), do: Prima.Confirmation.ref(id)

  # A credential entry asked for through the gate, as a page asks for it.
  defp entry(name, secret \\ "sk-confirmation-secret"),
    do: %{
      "name" => name,
      "kind" => "api_key",
      "fields" => %{"KEY" => secret},
      "destination" => %{"hosts" => ["api.example.com"]}
    }

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

  # This CYFR's `confirm` request for the record, as `request` answers it
  # to the session in `ctx`.
  defp requested!(ctx, id) do
    assert {:ok, %{request: encoded, url: url}} = call(ctx, "request", %{"ref" => ref(id)})
    {:ok, request} = Prima.SignIn.decode(encoded)
    %{request: request, url: url}
  end

  # The account pages' answer to `request` by the passkey of `user_id`'s
  # account, as the fragment they return.
  defp answered(request, user_id) do
    account = TestContext.account!(user_id)

    account.authenticator
    |> Authenticator.answer(request, account.identifier)
    |> Prima.SignIn.fragment()
  end

  # The record proven by the person's passkey through the gate.
  defp proven!(ctx, id) do
    %{request: request} = requested!(ctx, id)

    assert {:ok, %{state: "confirmed"}} =
             call(ctx, "confirm", %{"ref" => ref(id), "answer" => answered(request, ctx.user_id)})
  end

  # A record asked for and cancelled by its ref, and another asked for,
  # proven by its ref and repeated under its secret, as Prism repeats a
  # change (`PrismWeb.Ops`'s `confirmation_id:`). Answers both secrets.
  defp asked_and_repeated!(session_ctx) do
    cancelled = asked!(session_ctx, "cancelled-key")

    assert {:ok, %{ref: cancelled_ref, state: "cancelled"}} =
             call(session_ctx, "cancel", %{"ref" => ref(cancelled)})

    assert cancelled_ref == ref(cancelled)

    repeated = asked!(session_ctx, "repeated-key")
    proven!(session_ctx, repeated)

    assert {:ok, %{entry: %{name: "repeated-key"}}} =
             PrismWeb.Ops.call_tool(
               session_ctx,
               "vault/create",
               entry("repeated-key"),
               confirmation_id: repeated
             )

    [cancelled, repeated]
  end

  # ---------------------------------------------------------------------------
  # The stream
  # ---------------------------------------------------------------------------

  test "the stream is declared beside the operations, bound to its holder, projecting the ref, its kind and no preview" do
    assert {:ok, stream} =
             Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), "confirmation.changes")

    assert stream.topic == :confirmations
    assert stream.projection == ["ref", "kind", "operation", "expires_at"]
    assert stream.bind == :holder
    assert Cyfr.Bus.grantable?(stream.topic, true)
  end

  test "a fact of the stream says what happened to the record, and carries nothing else", %{
    session_ctx: session_ctx
  } do
    {:ok, stream} = Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), "confirmation.changes")
    {:ok, grant} = Sanctum.Gate.open_stream(session_ctx, "confirmation.changes")
    actor = Context.actor(session_ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.granted_topic(actor, grant))

    id = asked!(session_ctx)
    {:ok, %{state: "cancelled"}} = call(session_ctx, "cancel", %{"ref" => ref(id)})

    for kind <- [:opened, :cancelled] do
      assert_receive %Cyfr.Bus.Confirmation{kind: ^kind} = fact, 2_000
      projected = Prima.StreamGrant.project(grant, Map.from_struct(fact))
      assert Map.keys(projected) |> Enum.sort() == Enum.sort(stream.projection)
      assert projected["ref"] == ref(id)
      assert projected["kind"] == kind
      refute inspect(projected) =~ id
    end
  end

  test "request, confirm and cancel take the ref alone: the secret is never an argument" do
    %{operations: operations} = Sanctum.Providers.Confirmation.definition()

    assert Enum.map(operations, & &1.action) == ~w(request confirm pending cancel)

    for operation <- operations, operation.action in ~w(request confirm cancel) do
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
         %{session_ctx: session_ctx} do
      # Every log line, down to debug, is read for the secret.
      {secrets, log} =
        Prima.Test.Env.with_logger([level: :debug], fn ->
          with_log([level: :debug], fn -> asked_and_repeated!(session_ctx) end)
        end)

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
         %{session_ctx: session_ctx} do
      id = asked!(session_ctx)
      listed = pending!(session_ctx, id).ref
      assert listed == ref(id)
      proven!(session_ctx, id)

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
            {"request", %{"id" => id}},
            {"confirm", %{"id" => id, "answer" => "x"}},
            {"cancel", %{"id" => id}}
          ] do
        assert {:error, _refused} = call(session_ctx, action, args)
      end

      # Named by the secret where a ref belongs, the record is not found.
      assert {:error, _not_found} = call(session_ctx, "cancel", %{"ref" => id})
      assert {:error, _not_found} = call(session_ctx, "request", %{"ref" => id})
      assert row!(session_ctx, id).state == "pending"
    end
  end

  # ---------------------------------------------------------------------------
  # The signal, the preview and the account's proof
  # ---------------------------------------------------------------------------

  describe "a change a session asks for with no proof" do
    test "answers the signal; pending reads the CYFR's preview, the asker and the proof this client gives",
         %{session_ctx: session_ctx} do
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

      # The client that asked: this session, by how it signed in and when
      # it was created.
      assert %{"kind" => "session", "name" => "passkey", "since" => since} = record.asker
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(since)

      # A person's browser proves it by a passkey of their account.
      assert record.methods == ["passkey"]
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

    test "a passkey of the person's account confirms it by its ref, and the repeat under the secret goes ahead once",
         %{session_ctx: session_ctx, user: user} do
      id = asked!(session_ctx)
      %{request: request, url: url} = requested!(session_ctx, id)

      # The request is this CYFR's, to confirm, sent to the account pages'
      # sign page with the request in the fragment.
      assert request.purpose == :confirm
      assert url == directory_origin() <> "/account/sign#" <> Prima.SignIn.fragment(request)

      fragment = answered(request, user.id)

      log =
        capture_log(fn ->
          assert {:ok, %{ref: confirmed_ref, state: "confirmed"} = answer} =
                   call(session_ctx, "confirm", %{"ref" => ref(id), "answer" => fragment})

          assert confirmed_ref == ref(id)
          refute Map.has_key?(answer, :id)
        end)

      refute log =~ fragment

      # The record names the key that confirmed it and the head it was
      # verified under.
      account = TestContext.account!(user.id)
      confirmed = row!(session_ctx, id)
      assert confirmed.state == "confirmed"
      assert confirmed.head == account.head

      assert {:ok, %{entry: %{name: "prod-key"}}} =
               call(%{session_ctx | confirmation_id: id}, "vault", "create", entry("prod-key"))

      # The same record again is consumed: a new one is asked for.
      assert {:error, {:confirmation_required, %{id: again}}} =
               call(%{session_ctx | confirmation_id: id}, "vault", "create", entry("prod-key-2"))

      refute again == id
    end

    test "an answer confirms once, only its own record, only under the session it was bound to",
         %{session_ctx: session_ctx, user: user, athanor: athanor} do
      id = asked!(session_ctx)
      other = asked!(session_ctx, "other-key")

      # No answer is no proof.
      assert %Prima.Refusal{class: :invalid_argument} =
               refusal(call(session_ctx, "confirm", %{"ref" => ref(id)}))

      # An answer to another record's request confirms neither.
      %{request: others} = requested!(session_ctx, other)

      assert %Prima.Refusal{reason: :answer_refused} =
               refusal(
                 call(session_ctx, "confirm", %{
                   "ref" => ref(id),
                   "answer" => answered(others, user.id)
                 })
               )

      # Delivered by another session of the same person, it is refused, and
      # the request it answered is spent.
      %{request: request} = requested!(session_ctx, id)
      fragment = answered(request, user.id)
      elsewhere = session_ctx(user, athanor)

      assert %Prima.Refusal{reason: :answer_refused} =
               refusal(call(elsewhere, "confirm", %{"ref" => ref(id), "answer" => fragment}))

      assert %Prima.Refusal{reason: :answer_refused} =
               refusal(call(session_ctx, "confirm", %{"ref" => ref(id), "answer" => fragment}))

      assert row!(session_ctx, id).state == "pending"
      assert row!(session_ctx, other).state == "pending"

      # A fresh request, answered under its session, confirms; the same
      # answer again confirms nothing more.
      %{request: request} = requested!(session_ctx, id)
      fragment = answered(request, user.id)

      assert {:ok, %{state: "confirmed"}} =
               call(session_ctx, "confirm", %{"ref" => ref(id), "answer" => fragment})

      assert {:error, _replayed} =
               call(session_ctx, "confirm", %{"ref" => ref(id), "answer" => fragment})
    end

    test "an answer by another person's account confirms nothing", %{session_ctx: session_ctx} do
      id = asked!(session_ctx)
      %{user: someone} = signed_in!()
      %{request: request} = requested!(session_ctx, id)

      assert %Prima.Refusal{reason: :answer_refused} =
               refusal(
                 call(session_ctx, "confirm", %{
                   "ref" => ref(id),
                   "answer" => answered(request, someone.id)
                 })
               )

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
  # Cancel and another person
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

    test "another person reads, asks for, proves and cancels none of a person's records", %{
      session_ctx: session_ctx
    } do
      id = asked!(session_ctx)
      named = ref(id)
      %{user: other, session_ctx: other_ctx} = signed_in!()

      {:ok, %{confirmations: theirs}} = call(other_ctx, "pending", %{})
      refute Enum.any?(theirs, &(&1.ref == named))

      assert {:error, _} = call(other_ctx, "request", %{"ref" => named})

      %{request: request} = requested!(session_ctx, id)

      assert {:error, _} =
               call(other_ctx, "confirm", %{
                 "ref" => named,
                 "answer" => answered(request, other.id)
               })

      assert {:error, _} = call(other_ctx, "cancel", %{"ref" => named})
      assert row!(session_ctx, id).state == "pending"
    end

    test "a ref that names no record is refused", %{session_ctx: session_ctx} do
      id = asked!(session_ctx)

      # A ref that names no record, here or anywhere.
      unknown = ref("cnf_" <> Encoding.b64(:crypto.strong_rand_bytes(32)))

      for action <- ~w(request cancel) do
        assert %Prima.Refusal{class: :not_found} =
                 refusal(call(session_ctx, action, %{"ref" => unknown}))
      end

      assert row!(session_ctx, id).state == "pending"
    end
  end

  # The deployment's directory, whose account pages a browser is sent to.
  defp directory_origin do
    {origin, _path} = Encoding.directory_origin(Sanctum.directory_url())
    origin
  end
end
