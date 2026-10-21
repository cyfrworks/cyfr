# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.CliSignInTest do
  @moduledoc """
  Signing a command line in by approving it in Prism (`Sanctum.CliSignIn`),
  through the gate as the wire reaches it.

  The command line, holding nothing, begins: it is answered a session
  token it keeps, a code and the link with the approval secret in its
  fragment, and polls by its token. A person, signed in, approves the
  link's secret under a fresh confirmation (`credential_issuance`, as an
  API key's issuance), and the token is then their session, listed as the
  command line's and revocable with the session alone. The command line's
  three calls are the only anonymous ones; every refusal is said: an
  unknown link, an expired one, one already used, one the command line
  withdrew, and a session revoked before the command line read it.
  """

  # The rate limiter's table is the node's.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.Identity.Encoding
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    seated!()
  end

  # A person seated in a group of their own, and the context their
  # browser's session establishes there.
  defp seated!(label \\ "cli") do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|#{label}-#{n}",
        provider: "github",
        email: "#{label}#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Command line #{n}")

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

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    %{user: user, athanor: athanor, session_ctx: session_ctx, browser_token: session.token}
  end

  # The command line as the anonymous surface builds its context: no
  # person, no athanor, no credential, and its address.
  defp command_line(ip \\ "198.51.100.61"),
    do: Context.build(%{authenticated: false, client_ip: ip})

  defp call(ctx, action, args),
    do: Sanctum.Gate.call_external("session", ctx, Map.put(args, "action", action))

  defp confirmed_approve(ctx, secret),
    do:
      Sanctum.TestContext.confirming(
        ctx,
        &call(&1, "cli_approve", %{"approval_secret" => secret})
      )

  defp refusal({:error, reason}), do: Sanctum.Refusals.classify(reason)

  defp begin!(machine \\ "laptop", ip \\ "198.51.100.61") do
    assert {:ok, begun} = call(command_line(ip), "cli_begin", %{"machine" => machine})
    secret = secret_of!(begun.approve_url)
    Map.put(begun, :secret, secret)
  end

  defp poll(token), do: call(command_line(), "cli_poll", %{"session_token" => token})

  defp status(token) do
    {:ok, %{status: status}} = poll(token)
    status
  end

  defp established(token), do: Sanctum.Caller.establish(token, refresh: false)

  defp sign_in_row!(token) do
    hash = Sanctum.Session.token_hash(token)
    Arca.Repo.one!(from(c in Arca.Schemas.CliSignIn, where: c.token_hash == ^hash))
  end

  defp expire!(token) do
    hash = Sanctum.Session.token_hash(token)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(from(c in Arca.Schemas.CliSignIn, where: c.token_hash == ^hash),
        set: [expires_at: past]
      )

    :ok
  end

  test "a command line holding nothing begins, a person approves under a fresh confirmation, and its token is their session",
       %{session_ctx: session_ctx, user: user, athanor: athanor} do
    begun = begin!()

    assert %{session_token: token, user_code: code, expires_in: 300, interval: 2} = begun
    assert {:ok, _token_bytes} = Encoding.unb64(token, 32)
    assert {:ok, _secret_bytes} = Encoding.unb64(begun.secret, 16)
    assert code =~ ~r/\A[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}\z/

    # Neither secret is stored, only their hashes.
    row = sign_in_row!(token)
    assert row.state == "pending" and row.machine == "laptop" and row.user_code == code
    refute inspect(row, limit: :infinity, printable_limit: :infinity) =~ token
    refute inspect(row, limit: :infinity, printable_limit: :infinity) =~ begun.secret

    assert status(token) == "pending"
    assert {:error, _not_yet} = established(token)

    # Approving is a sensitive change: the first call asks for the
    # confirmation, whose preview names the machine and the code, and
    # mints nothing.
    assert {:error, {:confirmation_required, %{id: id, operation: "session.cli_approve"}}} =
             call(session_ctx, "cli_approve", %{"approval_secret" => begun.secret})

    {:ok, %{confirmations: records}} =
      Sanctum.Gate.call_external("confirmation", session_ctx, %{"action" => "pending"})

    record = Enum.find(records, &(&1.ref == Prima.Confirmation.ref(id)))
    assert record.action == "credential_issuance"
    assert record.preview["resource"] == "the command line on laptop"
    assert record.preview["details"]["command_line"] == "on laptop, showing #{code}"
    refute inspect(record, limit: :infinity, printable_limit: :infinity) =~ begun.secret
    assert status(token) == "pending"

    assert {:ok, %{machine: "laptop", user_code: ^code}} =
             confirmed_approve(session_ctx, begun.secret)

    assert status(token) == "approved"
    assert sign_in_row!(token).state == "approved"

    # The token the command line held from its begin is now the person's
    # session in the athanor the approver had in focus, the command line's.
    assert {:ok, cli_ctx} = established(token)
    assert cli_ctx.user_id == user.id
    assert cli_ctx.athanor_id == athanor.id

    {:ok, stored} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))
    assert stored.cli_machine == "laptop"

    assert {:ok, %{sessions: [listed]}} = call(session_ctx, "cli_list", %{})
    assert %{machine: "laptop", current: false, session_id: "ses_" <> _} = listed

    # Listed from the command line itself, it is the current one.
    assert {:ok, %{sessions: [%{current: true}]}} = call(cli_ctx, "cli_list", %{})
  end

  test "the action table names the approval a credential issuance, as an API key's",
       %{session_ctx: session_ctx} do
    assert Sanctum.Pairing.sensitive?(:credential_issuance)

    # A session's own approval, with no proof, opens a confirmation and
    # nothing else, however often it is asked.
    begun = begin!()

    for _ <- 1..2 do
      assert {:error, {:confirmation_required, _signal}} =
               call(session_ctx, "cli_approve", %{"approval_secret" => begun.secret})
    end

    assert sign_in_row!(begun.session_token).state == "pending"
    assert {:error, _none} = established(begun.session_token)
  end

  describe "every refusal is said" do
    test "a link signs in once: a second approval is refused before any confirmation",
         %{session_ctx: session_ctx} do
      begun = begin!()
      assert {:ok, _approved} = confirmed_approve(session_ctx, begun.secret)

      refused = refusal(call(session_ctx, "cli_approve", %{"approval_secret" => begun.secret}))
      assert %Prima.Refusal{class: :conflict, reason: :cli_sign_in_used} = refused
      assert refused.message =~ "already approved"
    end

    test "an expired link is refused, and the command line reads it expired",
         %{session_ctx: session_ctx} do
      begun = begin!()
      expire!(begun.session_token)

      assert %Prima.Refusal{class: :conflict, reason: :cli_sign_in_expired} =
               refusal(confirmed_approve(session_ctx, begun.secret))

      assert status(begun.session_token) == "expired"
      assert {:error, _none} = established(begun.session_token)
    end

    test "a link the command line withdrew is refused, and it reads cancelled",
         %{session_ctx: session_ctx} do
      begun = begin!()

      assert {:ok, %{status: "cancelled"}} =
               call(command_line(), "cli_cancel", %{"session_token" => begun.session_token})

      assert %Prima.Refusal{class: :conflict, reason: :cli_sign_in_cancelled} =
               refusal(confirmed_approve(session_ctx, begun.secret))

      assert status(begun.session_token) == "cancelled"
      assert {:error, _none} = established(begun.session_token)
    end

    test "a secret no sign-in names, or no secret at all, is an unknown link",
         %{session_ctx: session_ctx} do
      for secret <- [Encoding.b64(:crypto.strong_rand_bytes(16)), "not-a-secret"] do
        assert %Prima.Refusal{class: :not_found, reason: :cli_sign_in_unknown} =
                 refusal(call(session_ctx, "cli_approve", %{"approval_secret" => secret}))
      end

      # A token no sign-in names reads as an expired one, whatever its shape.
      assert status(Encoding.b64(:crypto.strong_rand_bytes(32))) == "expired"
      assert status("not-a-token") == "expired"
    end

    test "not signed in, nothing approves: the approval is no anonymous action" do
      begun = begin!()

      assert %Prima.Refusal{class: class} =
               refusal(call(command_line(), "cli_approve", %{"approval_secret" => begun.secret}))

      assert class in [:unauthenticated, :forbidden]
      assert sign_in_row!(begun.session_token).state == "pending"
    end

    test "a session revoked before the command line read the approval reads revoked",
         %{session_ctx: session_ctx} do
      begun = begin!()
      assert {:ok, _approved} = confirmed_approve(session_ctx, begun.secret)
      {:ok, %{sessions: [%{session_id: session_id}]}} = call(session_ctx, "cli_list", %{})

      # Revoking needs the session alone: no confirmation is asked.
      assert {:ok, %{session_id: ^session_id, revoked: true}} =
               call(session_ctx, "cli_revoke", %{"session_id" => session_id})

      assert status(begun.session_token) == "revoked"
      assert {:error, _gone} = established(begun.session_token)
      assert {:ok, %{sessions: []}} = call(session_ctx, "cli_list", %{})
    end

    test "an approver whose own session ended meanwhile mints nothing",
         %{session_ctx: session_ctx, browser_token: browser_token} do
      begun = begin!()

      assert {:error, {:confirmation_required, %{id: id}}} =
               call(session_ctx, "cli_approve", %{"approval_secret" => begun.secret})

      Sanctum.TestContext.prove!(session_ctx, id)
      :ok = Sanctum.Session.destroy(browser_token)

      assert {:error, _refused} =
               call(%{session_ctx | confirmation_id: id}, "cli_approve", %{
                 "approval_secret" => begun.secret
               })

      assert sign_in_row!(begun.session_token).state == "pending"
      assert status(begun.session_token) == "pending"
      assert {:error, _none} = established(begun.session_token)
    end
  end

  test "a cancel that lands after the approval ends the session it minted",
       %{session_ctx: session_ctx} do
    begun = begin!()
    assert {:ok, _approved} = confirmed_approve(session_ctx, begun.secret)
    assert {:ok, _cli_ctx} = established(begun.session_token)

    assert {:ok, %{status: "cancelled"}} =
             call(command_line(), "cli_cancel", %{"session_token" => begun.session_token})

    assert {:error, _ended} = established(begun.session_token)
    assert status(begun.session_token) == "cancelled"
    assert {:ok, %{sessions: []}} = call(session_ctx, "cli_list", %{})
  end

  test "a person lists and revokes only their own command lines, never a browser's session",
       %{session_ctx: session_ctx} do
    mine = begin!("desk")
    assert {:ok, _} = confirmed_approve(session_ctx, mine.secret)

    %{session_ctx: other_ctx} = seated!("other")
    theirs = begin!("their-laptop")
    assert {:ok, _} = confirmed_approve(other_ctx, theirs.secret)

    assert {:ok, %{sessions: [%{machine: "desk"}]}} = call(session_ctx, "cli_list", %{})
    {:ok, %{sessions: [%{session_id: their_id}]}} = call(other_ctx, "cli_list", %{})

    {:ok, %{id: browser_id}} =
      Arca.SessionStorage.get_session(session_ctx.session_token_hash)

    for id <- [their_id, browser_id, "ses_nobody"] do
      assert %Prima.Refusal{class: :not_found} =
               refusal(call(session_ctx, "cli_revoke", %{"session_id" => id}))
    end

    assert {:ok, _theirs_stands} = established(theirs.session_token)

    assert {:ok, _browser_stands} =
             Arca.SessionStorage.get_session(session_ctx.session_token_hash)
  end

  test "a request the command line's session asks for names the command line on its machine",
       %{session_ctx: session_ctx} do
    begun = begin!()
    assert {:ok, _approved} = confirmed_approve(session_ctx, begun.secret)
    {:ok, cli_ctx} = established(begun.session_token)

    assert {:error, {:confirmation_required, %{id: id}}} =
             Sanctum.Gate.call_external("key", cli_ctx, %{"action" => "create", "name" => "ci"})

    {:ok, %{confirmations: records}} =
      Sanctum.Gate.call_external("confirmation", session_ctx, %{"action" => "pending"})

    record = Enum.find(records, &(&1.ref == Prima.Confirmation.ref(id)))
    assert %{"kind" => "command_line", "name" => "laptop", "since" => _} = record.asker
  end

  describe "the command line's machine and bounds" do
    test "a machine name is 1 to 64 printable ASCII characters" do
      for bad <- ["", "   ", "lap\ntop", "lap\u202Etop", "läptop", String.duplicate("x", 65)] do
        assert %Prima.Refusal{class: :invalid_argument} =
                 refusal(call(command_line(), "cli_begin", %{"machine" => bad}))
      end

      assert {:ok, _} = call(command_line(), "cli_begin", %{"machine" => "  build box 7  "})

      assert {:ok, _} =
               call(command_line(), "cli_begin", %{"machine" => String.duplicate("x", 64)})
    end

    test "a provider device-flow poll names its machine by the same rule" do
      assert {:error, {:invalid_argument, message}} =
               Sanctum.Providers.Session.handle(command_line(), %{
                 "action" => "device_poll",
                 "device_code" => "dc",
                 "machine" => "lap\ntop"
               })

      assert message =~ "printable ASCII"
    end

    test "an address begins at most 20 times a minute, and another address is not charged" do
      for _ <- 1..20, do: begin!("laptop", "198.51.100.70")

      assert {:error, {:rate_limited, retry_s}} =
               call(command_line("198.51.100.70"), "cli_begin", %{"machine" => "laptop"})

      assert retry_s > 0
      assert {:ok, _} = call(command_line("198.51.100.71"), "cli_begin", %{"machine" => "laptop"})
    end
  end

  test "the link's secret, the token and the link reach no log", %{session_ctx: session_ctx} do
    begun = begin!()
    assert {:ok, _} = confirmed_approve(session_ctx, begun.secret)
    _ = poll(begun.session_token)

    logged =
      Arca.Repo.all(from(l in Arca.Schemas.McpLog, select: {l.input, l.output, l.error})) ++
        Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, select: {d.reason, d.tool, d.action}))

    refute logged == []
    shown = inspect(logged, limit: :infinity, printable_limit: :infinity)
    refute shown =~ begun.secret
    refute shown =~ begun.session_token
    refute shown =~ begun.approve_url
  end

  test "the session sweep deletes a pending sign-in long past its expiry" do
    begun = begin!()
    hash = Sanctum.Session.token_hash(begun.session_token)
    long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)

    {1, _} =
      Arca.Repo.update_all(from(c in Arca.Schemas.CliSignIn, where: c.token_hash == ^hash),
        set: [expires_at: long_ago]
      )

    fresh = begin!()

    assert {:ok, swept} = Sanctum.Session.cleanup()
    assert swept >= 1
    assert {:error, :not_found} = Arca.CliSignIns.by_token(hash)

    assert {:ok, _kept} =
             Arca.CliSignIns.by_token(Sanctum.Session.token_hash(fresh.session_token))
  end

  # The approval secret the link carries in its fragment, the link being
  # this home's `/cli` page.
  defp secret_of!(link) do
    prefix = Sanctum.Person.home() <> "/cli#code="
    assert String.starts_with?(link, prefix), "#{link} is not this home's /cli link"
    String.replace_prefix(link, prefix, "")
  end
end
