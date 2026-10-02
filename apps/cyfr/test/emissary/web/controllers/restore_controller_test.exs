# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.RestoreControllerTest do
  @moduledoc """
  The restore ingress, through the endpoint: the installation capability
  in the authorization header and nowhere else, the kit in a body bounded
  before it is decoded, each refusal on the wire as its own code (absent
  capability, wrong token, claimed or spent token, non-empty node,
  superseded attempt, a completed one), a restore standing at a phase
  answered as retryable, a completed restore handing its session to the
  holder of the capability in the cookie alone, and a reproof challenge
  refused once the database's clock passes its five minutes.

  The restore's phases against a directory are `Sanctum.RecoveryTest`'s;
  here an attempt is seeded at the phase a case needs, as the restore
  leaves it, against a scripted directory (`Sanctum.Test.DirectoryServer`)
  that serves what the seeded phase has seen, since a restore reads the
  head again before it mints and before it issues its session.
  """

  # The restore token, the installation mode, the directory client's seam,
  # the private-egress listing and the rate counters are process-wide.
  use CyfrWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Arca.InstallationClaims
  alias Arca.Schemas.{IdentityAttempt, InstallationClaim, User}
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, RecoverRequest}
  alias Sanctum.CipherAAD
  alias Sanctum.Test.DirectoryServer, as: Directory

  @token String.duplicate("7c", 32)

  setup_all do
    %{tls: Directory.tls()}
  end

  setup %{tls: tls} do
    token = Application.fetch_env(:sanctum, :restore_token)
    mode = if InstallationClaims.installed?(), do: InstallationClaims.mode()
    Prima.RateLimiter.reset()

    on_exit(fn ->
      case token do
        {:ok, value} -> Application.put_env(:sanctum, :restore_token, value)
        :error -> Application.delete_env(:sanctum, :restore_token)
      end

      if mode, do: InstallationClaims.install_mode!(mode), else: InstallationClaims.reset()
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      Prima.RateLimiter.reset()
    end)

    # The route passes the directory client no options: the seam points it
    # at the scripted directory.
    Directory.listen!()
    directory = Directory.start!(tls)
    Directory.seam!(tls)

    # An empty installation configured for restore.
    Arca.Repo.delete_all(User)
    Application.put_env(:sanctum, :restore_token, @token)
    InstallationClaims.install_mode!(:restore_reserved)
    %{directory: directory}
  end

  # ---- fixtures ----------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp system, do: Prima.Actor.system()

  # An identity held elsewhere, its genesis at the scripted directory, and
  # its printed kit.
  defp identity(directory) do
    seed = :crypto.strong_rand_bytes(32)
    {:ok, {recovery, recovery_private}} = Identity.derive_recovery_key(seed)
    {live, _} = keypair()
    {operational, operational_private} = keypair()

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: operational,
        recovery_keys: [recovery],
        directory: directory.url
      )

    genesis = Identity.sign(genesis, operational_private)
    identifier = Identity.identifier(genesis)
    Directory.publish(directory.dir, identifier, [genesis])

    %{
      identifier: identifier,
      genesis: genesis,
      recovery_private: recovery_private,
      kit: %{
        "identifier" => identifier,
        "directory_url" => directory.url,
        "recovery_secret" => Encoding.b64(seed)
      }
    }
  end

  # The restore attempt this token opened for `identity`, moved through
  # `phases` as the restore moves it: its keys staged in its own frame, its
  # recover signed by the kit, and from `accepted` on, that recover
  # committed at the directory as the head the acceptance names.
  defp attempt!(directory, identity, phases, token \\ @token) do
    request_id = Prima.UUID7.generate_id("rst")
    frame = "restore:" <> request_id
    {live, live_private} = keypair()
    {operational, operational_private} = keypair()
    {:ok, live_sealed} = Sanctum.Cipher.encrypt(live_private, CipherAAD.person_key(frame, :live))

    {:ok, operational_sealed} =
      Sanctum.Cipher.encrypt(operational_private, CipherAAD.person_key(frame, :operational))

    {:ok, request} =
      RecoverRequest.new(
        identifier: identity.identifier,
        directory: directory.url,
        live_key: live,
        operational_key: operational,
        expected_revision: 0,
        request_id: request_id
      )

    request = Identity.sign(request, identity.recovery_private)

    {:ok, attempt} =
      Arca.IdentityAttempts.open(system(), %{
        kind: "restore",
        request_id: request_id,
        identifier: identity.identifier,
        directory_url: directory.url,
        genesis: Identity.canonical(identity.genesis),
        entry: Identity.canonical(request),
        request_digest: Identity.request_digest(request),
        expected_revision: 0,
        token_digest: Prima.Digest.sha256(token),
        staged_live_public_key: live,
        staged_operational_public_key: operational,
        staged_live_key_sealed: live_sealed,
        staged_operational_key_sealed: operational_sealed
      })

    Enum.reduce(phases, attempt, fn to, attempt ->
      attrs =
        if to == "accepted",
          do: %{entry_hash: committed!(directory, identity, request)},
          else: %{}

      {:ok, moved} = Arca.IdentityAttempts.advance(system(), attempt.id, attempt.phase, to, attrs)
      moved
    end)
  end

  # `request` committed at the directory after `identity`'s genesis: the
  # hash of the entry it is, which the directory serves as the head.
  defp committed!(directory, identity, request) do
    {:ok, entry} = Entry.recover(Identity.hash(identity.genesis), request)
    Directory.publish(directory.dir, identity.identifier, [identity.genesis, entry])
    Identity.hash(entry)
  end

  # A later recovery, made elsewhere with the same kit: new online keys
  # after whatever the directory serves.
  defp recovered_elsewhere!(directory, identity) do
    log = Directory.log(directory.dir, identity.identifier)
    {:ok, state} = Identity.verify_chain(log)
    {live, _} = keypair()
    {operational, _} = keypair()

    {:ok, request} =
      RecoverRequest.new(
        identifier: identity.identifier,
        directory: state.directory,
        live_key: live,
        operational_key: operational,
        expected_revision: state.revision,
        request_id: Prima.UUID7.generate_id("rst")
      )

    {:ok, entry} = Entry.recover(state.head, Identity.sign(request, identity.recovery_private))
    Directory.publish(directory.dir, identity.identifier, log ++ [entry])
  end

  # The directory client's seam with a resolver that knows no scripted
  # directory's name: from here on, this node cannot reach the directory.
  defp unreachable!(tls) do
    Application.put_env(
      :sanctum,
      :directory_client,
      Keyword.put(Directory.opts(tls), :resolver, Sanctum.Test.Resolver)
    )
  end

  defp restore(conn, body, token \\ @token) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    end)
    |> post("/restore", Jason.encode!(body))
  end

  defp counts do
    %{
      attempts: Arca.Repo.aggregate(IdentityAttempt, :count),
      claims: Arca.Repo.aggregate(InstallationClaim, :count),
      people: Arca.Repo.aggregate(User, :count)
    }
  end

  @nothing %{attempts: 0, claims: 0, people: 0}

  # ---- the capability -----------------------------------------------------------

  describe "the installation capability" do
    test "with none configured, restore is disabled", %{conn: conn, directory: directory} do
      Application.delete_env(:sanctum, :restore_token)
      conn = restore(conn, identity(directory).kit)
      assert json_response(conn, 404) == %{"error" => "restore_disabled"}
      assert counts() == @nothing
    end

    test "a kit without this installation's token writes nothing and calls nowhere", %{
      conn: conn,
      directory: directory
    } do
      kit = identity(directory).kit

      assert json_response(restore(conn, kit, nil), 401) == %{"error" => "invalid_token"}

      assert json_response(restore(build_conn(), kit, String.duplicate("0", 64)), 401) ==
               %{"error" => "invalid_token"}

      # The token is the header's alone: not a query, not a body field.
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/restore?token=" <> @token, Jason.encode!(Map.put(kit, "token", @token)))

      assert json_response(conn, 401) == %{"error" => "invalid_token"}
      assert counts() == @nothing
    end

    test "a malformed kit is refused before anything is read", %{
      conn: conn,
      directory: directory
    } do
      kit = identity(directory).kit

      assert json_response(restore(conn, %{kit | "recovery_secret" => "short"}), 422) ==
               %{"error" => "invalid_kit"}

      assert json_response(restore(build_conn(), %{kit | "directory_url" => "http://x"}), 422) ==
               %{"error" => "invalid_kit"}

      assert counts() == @nothing
    end

    test "a body past 16 KiB is refused before it is decoded", %{
      conn: conn,
      directory: directory
    } do
      body = Map.put(identity(directory).kit, "padding", String.duplicate("x", 17_000))

      assert_error_sent 413, fn -> restore(conn, body) end
      assert counts() == @nothing
    end
  end

  # ---- the node and the token ----------------------------------------------------

  describe "the node and the token" do
    test "a node holding a person is refused before any write", %{
      conn: conn,
      directory: directory
    } do
      InstallationClaims.install_mode!(:ordinary)

      {:ok, _} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|resident",
          provider: "github"
        })

      InstallationClaims.install_mode!(:restore_reserved)

      assert json_response(restore(conn, identity(directory).kit), 409) ==
               %{"error" => "not_empty"}

      assert %{attempts: 0, claims: 0} = counts()
    end

    test "a token bound to another kit's running restore is claimed; once ended, spent", %{
      conn: conn,
      directory: directory
    } do
      attempt = attempt!(directory, identity(directory), ["submitted"])

      assert json_response(restore(conn, identity(directory).kit), 409) ==
               %{"error" => "token_claimed"}

      {:ok, _} = Arca.IdentityAttempts.advance(system(), attempt.id, "submitted", "refused")

      assert json_response(restore(build_conn(), identity(directory).kit), 409) ==
               %{"error" => "token_spent"}
    end

    test "a superseded restore is answered as one, and so is a completed one", %{
      conn: conn,
      directory: directory
    } do
      identity = identity(directory)
      attempt!(directory, identity, ["submitted", "accepted", "superseded"])
      assert json_response(restore(conn, identity.kit), 409) == %{"error" => "superseded"}

      assert json_response(
               build_conn()
               |> put_req_header("authorization", "Bearer " <> @token)
               |> post("/restore/challenge"),
               409
             ) == %{"error" => "superseded"}
    end

    test "a restore standing at a phase is retryable, with the phase it stands at", %{
      conn: conn,
      directory: directory,
      tls: tls
    } do
      identity = identity(directory)
      attempt!(directory, identity, ["submitted", "accepted"])

      # Its directory cannot be read to check the head the acceptance names.
      unreachable!(tls)
      {conn, _log} = with_log(fn -> restore(conn, identity.kit) end)
      assert %{"status" => "accepted", "retry_after" => seconds} = json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]
      assert counts().people == 0
    end

    test "a restore stopped before its mint and superseded since mints nothing", %{
      conn: conn,
      directory: directory
    } do
      identity = identity(directory)
      attempt = attempt!(directory, identity, ["submitted", "accepted", "keys_active"])
      recovered_elsewhere!(directory, identity)

      conn = restore(conn, identity.kit)
      assert json_response(conn, 409) == %{"error" => "superseded"}
      refute get_session(conn, CyfrWeb.SignInResponse.session_key())
      assert counts().people == 0
      assert %{phase: "superseded"} = Arca.Repo.get!(IdentityAttempt, attempt.id)
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())
    end
  end

  # ---- completion ----------------------------------------------------------------

  describe "completion" do
    test "the bound kit mints the person and the cookie, alone, carries the session", %{
      conn: conn,
      directory: directory
    } do
      identity = identity(directory)
      attempt = attempt!(directory, identity, ["submitted", "accepted", "keys_active"])

      conn = restore(conn, identity.kit)

      assert json_response(conn, 200) == %{
               "status" => "completed",
               "identifier" => identity.identifier
             }

      refute conn.resp_body =~ @token
      token = get_session(conn, CyfrWeb.SignInResponse.session_key())
      assert is_binary(token)
      refute conn.resp_body =~ token

      {:ok, session} = Sanctum.Session.load(token, surface: :console)
      assert session.provider == "restore"

      assert %{phase: "completed", user_id: user_id} =
               Arca.Repo.get!(IdentityAttempt, attempt.id)

      assert user_id == session.user_id
      assert {:ok, %{state: "ended", outcome: "completed"}} = InstallationClaims.get(system())

      # A plain retry issues no session.
      retried = restore(build_conn(), identity.kit)
      assert json_response(retried, 409) == %{"error" => "restored"}
      refute get_session(retried, CyfrWeb.SignInResponse.session_key())

      # A completed restore's first-method reproof challenge is the
      # capability's to ask for.
      challenged =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> @token)
        |> post("/restore/challenge")

      assert %{"challenge" => challenge, "expires_at" => _} = json_response(challenged, 200)
      assert {:ok, _} = Encoding.unb64(challenge, 32)

      assert json_response(build_conn() |> post("/restore/challenge"), 401) ==
               %{"error" => "invalid_token"}

      # A kit this restore did not restore reproves nothing.
      reproof =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> @token)
        |> post(
          "/restore/reproof",
          Jason.encode!(Map.put(identity(directory).kit, "challenge", challenge))
        )

      assert json_response(reproof, 409) == %{"error" => "token_spent"}
    end

    test "a reproof challenge lives five minutes on the database's clock, and past them is refused",
         %{conn: conn, directory: directory, tls: tls} do
      identity = identity(directory)
      attempt = attempt!(directory, identity, ["submitted", "accepted", "keys_active"])
      assert %{"status" => "completed"} = json_response(restore(conn, identity.kit), 200)

      issued = Arca.ServerMetaStorage.now!()

      challenged =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> @token)
        |> post("/restore/challenge")

      answered = Arca.ServerMetaStorage.now!()

      assert %{"challenge" => challenge, "expires_at" => expires_at} =
               json_response(challenged, 200)

      {:ok, expires_at, 0} = DateTime.from_iso8601(expires_at)

      # Five minutes from the database's clock, as the row holds it.
      assert DateTime.compare(expires_at, DateTime.add(issued, 300_000, :millisecond)) != :lt
      assert DateTime.compare(expires_at, DateTime.add(answered, 300_000, :millisecond)) != :gt
      held = Arca.Repo.get!(IdentityAttempt, attempt.id)
      assert DateTime.compare(held.reproof_expires_at, expires_at) == :eq

      reprove = fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> @token)
        |> post("/restore/reproof", Jason.encode!(Map.put(identity.kit, "challenge", challenge)))
      end

      # Alive, it passes to the directory, which this node cannot reach.
      unreachable!(tls)
      {alive, _log} = with_log(reprove)
      assert %{"status" => "completed", "retry_after" => _} = json_response(alive, 503)

      # The five minutes pass: the database's clock is past the expiry.
      held
      |> Ecto.Changeset.change(
        reproof_expires_at: DateTime.add(held.reproof_expires_at, -300_001, :millisecond)
      )
      |> Arca.Repo.update!()

      assert json_response(reprove.(), 409) == %{"error" => "challenge_refused"}
      refute get_session(reprove.(), CyfrWeb.SignInResponse.session_key())
    end

    test "a challenge before any restore completed is no reproof", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> post("/restore/challenge")

      assert json_response(conn, 409) == %{"error" => "not_restored"}
    end
  end

  describe "the restore attempt's rows" do
    test "a node mid-restore refuses a first door", %{directory: directory} do
      attempt!(directory, identity(directory), ["submitted"])

      assert {:error, :restore_reserved} =
               Sanctum.SignIn.admitted(
                 %{id: "github|https://github.com|early", provider: :github, verified: true},
                 :admin
               )

      assert Arca.Repo.aggregate(User, :count) == 0
    end
  end
end
