# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RecoveryTest do
  @moduledoc """
  Recovery material and restore, against a scripted directory that speaks
  HTTPS under a test authority on loopback (`Sanctum.Test.DirectoryServer`).

  Enrollment is asked for its `recovery_material` proof before anything is
  opened, consumes it with its one durable attempt, registers the same
  genesis bytes however often its reply is lost, and answers the kit until
  its acknowledgment erases the seed. One the directory has not accepted
  is abandoned, and a retry under its request id then registers nothing;
  an accepted one is not. Another kit is a `recover` an
  existing kit signs, keeping the online keys and moving the head.

  Restore checks the installation capability first, holds the kit to the
  identity's current recovery set before it claims anything, and walks
  its durable phases: a reply lost after acceptance resumes once, a later
  recovery supersedes it, a crash after the mint resumes at the mint, and
  the restored person stands at the door and may install their first
  method within the restore session's window, or by a reproof after it.
  """

  # The directory and restore settings, the installation mode, the
  # private-egress listing, the resolver's observer and the rate counters
  # are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.InstallationClaims
  alias Arca.Schemas.{DirectoryHead, IdentityAttempt, InstallationClaim, PersonIdentity, User}
  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, RecoverRequest}
  alias Sanctum.{Caller, Context, Passkeys, Recovery, SignIn, TestContext}
  alias Sanctum.Tenancy.{Athanors, Members, Users}
  alias Sanctum.Test.DirectoryServer, as: Directory
  alias Sanctum.TestContext.Authenticator

  @token String.duplicate("5a", 32)

  setup_all do
    %{tls: Directory.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.RateLimiter.reset()
    Directory.listen!()
    env = Map.new([:directory_url, :restore_token], &{&1, Application.fetch_env(:sanctum, &1)})
    mode = if InstallationClaims.installed?(), do: InstallationClaims.mode()

    on_exit(fn ->
      for {key, value} <- env do
        case value do
          {:ok, value} -> Application.put_env(:sanctum, key, value)
          :error -> Application.delete_env(:sanctum, key)
        end
      end

      if mode, do: InstallationClaims.install_mode!(mode), else: InstallationClaims.reset()
      Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      Arca.Cache.delete_match({:established, :_, :_, :_})
      Prima.RateLimiter.reset()
    end)

    InstallationClaims.install_mode!(:ordinary)
    Application.delete_env(:sanctum, :restore_token)
    directory = Directory.start!(tls)
    Application.put_env(:sanctum, :directory_url, directory.url)
    %{directory: directory, opts: Directory.opts(tls)}
  end

  # ---- fixtures ------------------------------------------------------------------

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)
  defp seed, do: :crypto.strong_rand_bytes(32)
  defp b64(bytes), do: Encoding.b64(bytes)
  defp request_id, do: "req_#{System.unique_integer([:positive])}"
  defp system, do: Prima.Actor.system()

  defp public(seed) do
    {:ok, {public, _private}} = Identity.derive_recovery_key(seed)
    public
  end

  defp args(seed, id), do: %{"recovery_secret" => b64(seed), "request_id" => id}

  defp holder_args(signer, added, id) do
    %{
      "recovery_secret" => b64(signer),
      "holder" => %{"kind" => "kit", "recovery_secret" => b64(added)},
      "request_id" => id
    }
  end

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|recovery-#{n}",
        provider: "github",
        email: "recovery#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Recovery #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)

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
    {:ok, ctx} = Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
    %{user: user, athanor: athanor, ctx: ctx}
  end

  defp confirmed(person, fun), do: TestContext.confirming(person.ctx, fun)

  defp enrolled!(context) do
    person = seated!()
    seed = seed()
    args = args(seed, request_id())

    {:ok, %{phase: "accepted"} = enrolled} =
      confirmed(person, &Recovery.enroll(&1, args, context.opts))

    Map.merge(person, %{seed: seed, enrolled: enrolled})
  end

  defp row(user_id), do: Arca.Repo.get_by!(PersonIdentity, user_id: user_id)

  defp attempts(kind),
    do: Arca.Repo.all(from(a in IdentityAttempt, where: a.kind == ^kind, order_by: a.inserted_at))

  defp confirmations(user_id) do
    Arca.Repo.all(
      from(c in "pending_confirmations",
        where: c.user_id == ^user_id,
        select: %{action: c.action, state: c.state, preview: c.preview}
      )
    )
  end

  defp count(schema), do: Arca.Repo.aggregate(schema, :count)

  defp writes do
    Enum.filter(Directory.requests(), &(&1.method == "POST"))
  end

  # An identity held at another home: its online keys, one printed kit and
  # its genesis at the scripted directory. This node holds none of it.
  defp elsewhere!(directory) do
    {live, _} = keypair()
    {operational, operational_private} = keypair()
    seed = seed()

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: operational,
        recovery_keys: [public(seed)],
        directory: directory.url
      )

    genesis = Identity.sign(genesis, operational_private)
    identifier = Identity.identifier(genesis)
    Directory.publish(directory.dir, identifier, [genesis])

    %{
      identifier: identifier,
      genesis: genesis,
      seed: seed,
      kit: kit(identifier, directory.url, seed)
    }
  end

  defp kit(identifier, url, seed),
    do: %{"identifier" => identifier, "directory_url" => url, "recovery_secret" => b64(seed)}

  # This installation configured for restore, its first person reserved
  # for it.
  defp reserved! do
    Application.put_env(:sanctum, :restore_token, @token)
    InstallationClaims.install_mode!(:restore_reserved)
  end

  # A later recovery, made elsewhere with the same kit: new online keys.
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
        request_id: request_id()
      )

    {:ok, {_public, private}} = Identity.derive_recovery_key(identity.seed)
    {:ok, entry} = Entry.recover(state.head, Identity.sign(request, private))
    Directory.publish(directory.dir, identity.identifier, log ++ [entry])
    entry
  end

  defp restored!(context) do
    reserved!()
    identity = elsewhere!(context.directory)

    {:ok, %{status: "completed"} = restored} =
      Recovery.restore(identity.kit, @token, context.opts)

    {:ok, session} = Sanctum.Session.load(restored.session_token, surface: :console)
    Map.merge(restored, %{identity: identity, ctx: session})
  end

  # The person's first passkey here, registered through the context's own
  # session; answers the registration's result and the authenticator.
  defp first_passkey(ctx) do
    auth = Authenticator.for_person(ctx.user_id)
    {:ok, options} = Passkeys.register(ctx, %{})

    {Passkeys.register(ctx, %{credential: Authenticator.registration(auth, options)}), auth}
  end

  # ---- enrollment ----------------------------------------------------------------

  describe "enrollment" do
    test "with no seed, or a malformed one, is refused, and nothing is opened or sent", context do
      person = seated!()

      assert {:error, {:invalid_argument, message}} =
               Recovery.enroll(person.ctx, %{"request_id" => request_id()}, context.opts)

      assert message =~ "recovery_secret"

      assert {:error, {:invalid_argument, _}} =
               Recovery.enroll(
                 person.ctx,
                 %{"recovery_secret" => "short", "request_id" => request_id()},
                 context.opts
               )

      assert attempts("enrollment") == []
      assert writes() == []
      assert row(person.user.id).identifier == nil
    end

    test "a session alone is asked for the exact set, directory and genesis, and registers nothing",
         context do
      person = seated!()
      seed = seed()

      assert {:error, {:confirmation_required, %{operation: "person.enroll"}}} =
               Recovery.enroll(person.ctx, args(seed, request_id()), context.opts)

      assert attempts("enrollment") == []
      assert writes() == []
      assert row(person.user.id).identifier == nil

      assert [%{action: "recovery_material", state: "pending", preview: preview}] =
               confirmations(person.user.id)

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      details = Jason.decode!(preview)["details"]
      assert details["recovery_key"] == b64(public(seed))
      assert details["directory"] == context.directory.url
      assert details["genesis"] == genesis.genesis_hash
      refute preview =~ b64(seed)
    end

    test "under its proof registers the genesis at the pinned directory and answers the kit",
         context do
      person = seated!()
      seed = seed()
      args = args(seed, request_id())

      assert {:ok, %{phase: "accepted", identifier: identifier, kit: kit}} =
               confirmed(person, &Recovery.enroll(&1, args, context.opts))

      assert kit == %{
               identifier: identifier,
               directory_url: context.directory.url,
               recovery_secret: b64(seed)
             }

      row = row(person.user.id)
      assert row.identifier == identifier
      assert row.enrollment == "enrolled"

      assert [genesis] = Directory.log(context.directory.dir, identifier)
      assert Identity.identifier(genesis) == identifier
      assert genesis.recovery_keys == [public(seed)]
      assert genesis.live_key == row.live_public_key
      assert genesis.operational_key == row.operational_public_key
      assert genesis.directory == context.directory.url
      assert row.head_hash == Identity.hash(genesis)

      # The proof was consumed with the attempt it opened.
      assert [%{action: "recovery_material", state: "consumed"}] = confirmations(person.user.id)
    end

    test "a directory that refuses the genesis leaves the attempt refused and no identifier",
         context do
      person = seated!()
      seed = seed()

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      Directory.next(context.directory.dir, genesis.identifier, :refuse)
      args = args(seed, request_id())

      assert {:error, :enrollment_refused} =
               confirmed(person, &Recovery.enroll(&1, args, context.opts))

      assert %{identifier: nil, enrollment: "none"} = row(person.user.id)
      assert [%{phase: "refused", kit_seed_sealed: nil}] = attempts("enrollment")
      assert Directory.log(context.directory.dir, genesis.identifier) == nil
      assert {:error, :not_found} = Recovery.abandon_enrollment(person.ctx)
    end

    test "a lost reply resumes the one attempt, registering the same genesis bytes", context do
      person = seated!()
      seed = seed()
      id = request_id()

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      Directory.next(context.directory.dir, genesis.identifier, :drop)

      assert {:error, :directory_unavailable} =
               confirmed(person, &Recovery.enroll(&1, args(seed, id), context.opts))

      assert [%{phase: "submitted", genesis: bytes} = attempt] = attempts("enrollment")
      assert bytes == genesis.genesis
      _ = Directory.requests()

      # The retry needs no second proof and registers the same bytes.
      assert {:ok, %{phase: "accepted", identifier: identifier, attempt_id: attempt_id}} =
               Recovery.enroll(person.ctx, args(seed, id), context.opts)

      assert identifier == genesis.identifier
      assert attempt_id == attempt.id
      assert [%{body: body}] = writes()
      assert body == genesis.genesis
      assert length(attempts("enrollment")) == 1
      assert length(Directory.log(context.directory.dir, identifier)) == 1

      # The request id is this request's; another enrollment is not opened.
      assert {:error, :request_id_reused} =
               Recovery.enroll(person.ctx, args(seed(), id), context.opts)

      assert {:error, :already_enrolled} =
               Recovery.enroll(person.ctx, args(seed(), request_id()), context.opts)
    end

    test "a second enrollment in flight is named, and with no directory pinned none begins",
         context do
      person = seated!()
      seed = seed()
      id = request_id()

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      Directory.next(context.directory.dir, genesis.identifier, :drop)

      {:error, :directory_unavailable} =
        confirmed(person, &Recovery.enroll(&1, args(seed, id), context.opts))

      assert {:error, {:attempt_in_progress, ^id}} =
               Recovery.enroll(person.ctx, args(seed(), request_id()), context.opts)

      Application.delete_env(:sanctum, :directory_url)
      other = seated!()

      assert {:error, :no_directory} =
               Recovery.enroll(other.ctx, args(seed(), request_id()), context.opts)
    end
  end

  describe "an unfinished enrollment" do
    test "abandoned at submitted, a retry under its request id registers nothing, and a new kit enrolls anew",
         context do
      person = seated!()
      seed = seed()
      id = request_id()

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      # The directory registers the genesis and its answer is lost.
      Directory.next(context.directory.dir, genesis.identifier, :drop)

      assert {:error, :directory_unavailable} =
               confirmed(person, &Recovery.enroll(&1, args(seed, id), context.opts))

      assert %{enrollment: "pending"} = row(person.user.id)
      _ = Directory.requests()

      assert {:ok, %{request_id: ^id, phase: "superseded"}} =
               Recovery.abandon_enrollment(person.ctx)

      assert %{identifier: nil, enrollment: "none"} = row(person.user.id)
      assert [%{phase: "superseded", kit_seed_sealed: nil}] = attempts("enrollment")

      # The browser that still held the seed retries: it is told the
      # enrollment was abandoned, and nothing reaches the directory.
      assert {:error, :enrollment_abandoned} =
               Recovery.enroll(person.ctx, args(seed, id), context.opts)

      assert writes() == []
      assert %{identifier: nil, enrollment: "none"} = row(person.user.id)
      assert {:error, :not_found} = Recovery.abandon_enrollment(person.ctx)

      # The genesis the directory registered stays there, unused.
      assert [_genesis] = Directory.log(context.directory.dir, genesis.identifier)

      # A new kit enrolls anew, under a new identifier.
      anew = args(seed(), request_id())

      assert {:ok, %{phase: "accepted", identifier: identifier}} =
               confirmed(person, &Recovery.enroll(&1, anew, context.opts))

      assert identifier != genesis.identifier
      assert %{identifier: ^identifier, enrollment: "enrolled"} = row(person.user.id)
    end

    test "abandoned after the directory registered it and before its acceptance moved, it answers abandoned",
         context do
      person = seated!()
      seed = seed()
      id = request_id()
      args = args(seed, id)
      test = self()
      handler = "recovery-abandon-between-#{System.unique_integer([:positive])}"

      # The registration's answer has arrived, on the request's own process,
      # and the attempt has not moved: the person abandons it then.
      :ok =
        :telemetry.attach(
          handler,
          [:finch, :request, :stop],
          fn _event, _measurements, %{request: request}, _config ->
            if request.method == "POST" and String.ends_with?(request.path, "/genesis") do
              :telemetry.detach(handler)
              send(test, {:abandoned, Recovery.abandon_enrollment(person.ctx)})
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :enrollment_abandoned} =
               confirmed(person, &Recovery.enroll(&1, args, context.opts))

      assert_received {:abandoned, {:ok, %{request_id: ^id, phase: "superseded"}}}

      # The acceptance wrote nothing: the person is unenrolled, and the
      # genesis the directory registered stays there unused.
      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      assert %{identifier: nil, enrollment: "none"} = row(person.user.id)
      assert [%{phase: "superseded", kit_seed_sealed: nil}] = attempts("enrollment")
      assert [_registered] = Directory.log(context.directory.dir, genesis.identifier)
    end

    test "abandoned at staged, killed before its submission, ends with nothing sent", context do
      person = seated!()
      assert {:error, :not_found} = Recovery.abandon_enrollment(person.ctx)

      seed = seed()
      id = request_id()

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(seed)], context.directory.url)

      # Opened, and killed before its move to submitted.
      {:ok, _staged} =
        Arca.IdentityAttempts.open(Context.actor(person.ctx), %{
          kind: "enrollment",
          request_id: id,
          user_id: person.user.id,
          identifier: genesis.identifier,
          directory_url: context.directory.url,
          genesis: genesis.genesis,
          request_digest: genesis.genesis_hash,
          kit_seed_sealed: "sealed-kit-seed"
        })

      assert %{enrollment: "pending"} = row(person.user.id)

      assert {:error, {:attempt_in_progress, ^id}} =
               Recovery.enroll(person.ctx, args(seed(), request_id()), context.opts)

      assert {:ok, %{request_id: ^id, phase: "superseded"}} =
               Recovery.abandon_enrollment(person.ctx)

      assert [%{phase: "superseded", kit_seed_sealed: nil}] = attempts("enrollment")
      assert %{identifier: nil, enrollment: "none"} = row(person.user.id)
      assert writes() == []
      assert Directory.log(context.directory.dir, genesis.identifier) == nil
    end

    test "an accepted one is registered: not abandoned, its kit still delivered", context do
      person = enrolled!(context)
      attempt_id = person.enrolled.attempt_id

      assert {:error, :registered} = Recovery.abandon_enrollment(person.ctx)
      assert %{enrollment: "enrolled", identifier: identifier} = row(person.user.id)
      assert identifier == person.enrolled.identifier

      assert {:ok, %{kit: kit}} = confirmed(person, &Recovery.kit(&1, attempt_id))
      assert kit.recovery_secret == b64(person.seed)

      # Saved, it is no longer in progress: nothing is left to abandon.
      assert {:ok, %{phase: "completed"}} = Recovery.kit_ack(person.ctx, attempt_id)
      assert {:error, :not_found} = Recovery.abandon_enrollment(person.ctx)
      assert %{enrollment: "enrolled", identifier: ^identifier} = row(person.user.id)
    end
  end

  describe "the kit" do
    test "is delivered again only under a fresh proof, until its acknowledgment erases it",
         context do
      person = enrolled!(context)
      attempt_id = person.enrolled.attempt_id

      assert {:error, {:confirmation_required, %{operation: "person.kit"}}} =
               Recovery.kit(person.ctx, attempt_id)

      assert {:ok, %{kit: kit}} = confirmed(person, &Recovery.kit(&1, attempt_id))
      assert kit.recovery_secret == b64(person.seed)

      assert {:ok, %{phase: "completed"}} = Recovery.kit_ack(person.ctx, attempt_id)
      assert Arca.Repo.get!(IdentityAttempt, attempt_id).kit_seed_sealed == nil

      # Gone for good: no proof brings it back, and a repeat restores nothing.
      assert {:error, :kit_acknowledged} = Recovery.kit(person.ctx, attempt_id)
      assert {:ok, %{phase: "completed"}} = Recovery.kit_ack(person.ctx, attempt_id)
      assert Arca.Repo.get!(IdentityAttempt, attempt_id).kit_seed_sealed == nil

      assert {:ok, enrolled} =
               Recovery.enroll(
                 person.ctx,
                 args(person.seed, person.enrolled.request_id),
                 context.opts
               )

      refute Map.has_key?(enrolled, :kit)

      # Nobody else reaches it.
      other = seated!()
      assert {:error, {:not_found, "kit", ^attempt_id}} = Recovery.kit(other.ctx, attempt_id)
      assert {:error, {:not_found, "kit", ^attempt_id}} = Recovery.kit_ack(other.ctx, attempt_id)
    end
  end

  describe "another printed kit" do
    test "is a recover an existing kit signs, keeping the online keys, and moves the head",
         context do
      person = enrolled!(context)
      before = row(person.user.id)
      added = seed()
      args = holder_args(person.seed, added, request_id())

      assert {:error, {:confirmation_required, %{operation: "person.enroll_holder"}}} =
               Recovery.enroll_holder(person.ctx, args, context.opts)

      assert attempts("holder") == []

      assert {:ok, %{phase: "accepted", kit: kit, key_epoch: epoch}} =
               confirmed(person, &Recovery.enroll_holder(&1, args, context.opts))

      assert kit.recovery_secret == b64(added)

      after_it = row(person.user.id)
      assert after_it.head_hash == epoch
      assert after_it.live_public_key == before.live_public_key
      assert after_it.operational_public_key == before.operational_public_key
      assert after_it.live_key_sealed == before.live_key_sealed

      log = Directory.log(context.directory.dir, before.identifier)
      assert %Entry{kind: :recover, request: request} = recover = List.last(log)
      assert request.recovery_keys == [public(person.seed), public(added)]
      assert request.live_key == before.live_public_key
      assert Identity.hash(recover) == epoch
      assert {:ok, %{key_epoch: ^epoch, revision: 1}} = Identity.verify_chain(log)

      # Its kit is acknowledged as the first one's.
      [attempt] = attempts("holder")
      assert {:ok, %{phase: "completed"}} = Recovery.kit_ack(person.ctx, attempt.id)

      # A kit the identity holds is not added twice.
      assert {:error, :already_a_holder} =
               Recovery.enroll_holder(
                 person.ctx,
                 holder_args(person.seed, added, request_id()),
                 context.opts
               )
    end

    test "a device as holder, a seed that holds nothing and a holder twice are refused",
         context do
      person = enrolled!(context)
      added = seed()

      device = %{
        holder_args(person.seed, added, request_id())
        | "holder" => %{"kind" => "device", "recovery_secret" => b64(added)}
      }

      assert {:error, {:invalid_argument, message}} =
               Recovery.enroll_holder(person.ctx, device, context.opts)

      assert message =~ "device"

      assert {:error, :not_a_holder} =
               Recovery.enroll_holder(
                 person.ctx,
                 holder_args(seed(), added, request_id()),
                 context.opts
               )

      # The kit that signs is never the one added.
      assert {:error, {:invalid_argument, same}} =
               Recovery.enroll_holder(
                 person.ctx,
                 holder_args(person.seed, person.seed, request_id()),
                 context.opts
               )

      assert same =~ "another kit"
      assert attempts("holder") == []
    end
  end

  # ---- restore -------------------------------------------------------------------

  describe "restore" do
    test "a kit without this installation's token causes no row, no staging, no outbound call",
         context do
      identity = elsewhere!(context.directory)

      assert {:error, :restore_disabled} =
               Recovery.restore(identity.kit, @token, context.opts)

      reserved!()
      assert {:error, :invalid_token} = Recovery.restore(identity.kit, nil, context.opts)

      assert {:error, :invalid_token} =
               Recovery.restore(identity.kit, String.duplicate("0", 64), context.opts)

      assert {:error, :invalid_token} =
               Recovery.restore(identity.kit, "Bearer " <> @token, context.opts)

      assert {:error, :invalid_token} = Recovery.restore_challenge("")

      assert Directory.requests() == []
      refute_received {:resolved, _}
      assert count(IdentityAttempt) == 0
      assert count(InstallationClaim) == 0
      assert count(DirectoryHead) == 0
    end

    test "stages, submits, activates the current keys and mints the person with a session",
         context do
      reserved!()
      identity = elsewhere!(context.directory)

      assert {:ok, %{status: "completed", user_id: user_id, session_token: token} = restored} =
               Recovery.restore(identity.kit, @token, context.opts)

      assert restored.identifier == identity.identifier

      assert [attempt] = attempts("restore")
      assert attempt.phase == "completed"
      assert attempt.user_id == user_id
      assert is_nil(attempt.staged_live_key_sealed)
      assert is_nil(attempt.staged_operational_key_sealed)

      row = row(user_id)
      assert row.provenance == "local"
      assert row.enrollment == "enrolled"
      assert row.identifier == identity.identifier
      assert row.live_public_key == attempt.staged_live_public_key
      assert row.operational_public_key == attempt.staged_operational_public_key
      assert row.head_hash == attempt.entry_hash
      assert row.genesis_hash == Identity.hash(identity.genesis)

      {:ok, state} =
        Identity.verify_chain(Directory.log(context.directory.dir, identity.identifier))

      assert state.key_epoch == row.head_hash
      assert state.live_key == row.live_public_key

      # The keys open in the person's own frame: the live key signs.
      {:ok, %{personal_athanor_id: athanor_id}} = Users.get(user_id)
      {device_key, _} = keypair()

      assert {:ok, %Prima.DeviceCert{}} =
               Sanctum.Person.issue_device_cert(user_id, device_key, "pcl_restored", %{
                 subject: :local,
                 audience: Sanctum.Person.home(),
                 athanor: athanor_id
               })

      # The person rotates from the genesis their identity rests on.
      assert {:ok, %{genesis: genesis}} = Arca.IdentityAttempts.genesis(system(), user_id)
      assert genesis == Identity.canonical(identity.genesis)

      assert {:ok, %{state: "ended", outcome: "completed"}} = InstallationClaims.get(system())

      {:ok, session} = Sanctum.Session.load(token, surface: :console)
      assert session.user_id == user_id
      assert session.provider == "restore"

      # The door names the restored person, who holds no door yet and no
      # platform administration.
      assert {:ok, true} = Sanctum.Door.Store.allowed("user_id", user_id)
      assert {:ok, []} = Arca.Users.identities(system(), user_id)

      refute Arca.Repo.exists?(
               from(m in Arca.Schemas.Membership,
                 where: m.user_id == ^user_id and m.scope == "platform"
               )
             )

      # A plain retry issues no session.
      assert {:error, :restored} = Recovery.restore(identity.kit, @token, context.opts)
    end

    test "a mistyped kit spends nothing, and the right one then restores", context do
      reserved!()
      identity = elsewhere!(context.directory)

      assert {:error, :not_a_holder} =
               Recovery.restore(
                 %{identity.kit | "recovery_secret" => b64(seed())},
                 @token,
                 context.opts
               )

      unknown = "per_" <> String.duplicate("0", 64)

      assert {:error, :unknown_identity} =
               Recovery.restore(%{identity.kit | "identifier" => unknown}, @token, context.opts)

      assert {:error, :invalid_kit} =
               Recovery.restore(
                 %{identity.kit | "directory_url" => "http://dir-a.test"},
                 @token,
                 context.opts
               )

      assert {:error, :invalid_kit} = Recovery.restore(%{}, @token, context.opts)

      assert count(IdentityAttempt) == 0
      assert count(InstallationClaim) == 0

      assert {:ok, %{status: "completed"}} = Recovery.restore(identity.kit, @token, context.opts)
    end

    test "on a node with another person is refused before any write or outbound call", context do
      _person = seated!()
      reserved!()
      identity = elsewhere!(context.directory)

      assert {:error, :not_empty} = Recovery.restore(identity.kit, @token, context.opts)
      assert Directory.requests() == []
      assert count(IdentityAttempt) == 0
      assert count(InstallationClaim) == 0
    end

    test "killed after the directory accepted, resumes and activates the staged keys once",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _seconds}} =
               Recovery.restore(identity.kit, @token, context.opts)

      assert [%{phase: "submitted"} = staged] = attempts("restore")

      assert {:ok, %{status: "completed", user_id: user_id}} =
               Recovery.restore(identity.kit, @token, context.opts)

      assert [done] = attempts("restore")
      assert done.id == staged.id
      assert row(user_id).live_public_key == staged.staged_live_public_key
      assert row(user_id).operational_public_key == staged.staged_operational_public_key

      # The resubmission answered its recorded outcome: one recovery.
      log = Directory.log(context.directory.dir, identity.identifier)
      assert Enum.count(log, &(&1.kind == :recover)) == 1
    end

    test "killed after the mint, resumes at that phase on a node otherwise refused", context do
      reserved!()
      identity = elsewhere!(context.directory)

      {:ok, %{user_id: user_id}} = Recovery.restore(identity.kit, @token, context.opts)
      [attempt] = attempts("restore")

      # The instant after the mint's transaction committed and before the
      # completion was recorded.
      {1, _} =
        Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^attempt.id),
          set: [phase: "minted"]
        )

      {1, _} =
        Arca.Repo.update_all(
          from(c in InstallationClaim, where: c.request_id == ^attempt.request_id),
          set: [state: "pending", outcome: nil, ended_at: nil]
        )

      # Another kit under this token, or a first door, wins nothing.
      other = elsewhere!(context.directory)
      assert {:error, :token_claimed} = Recovery.restore(other.kit, @token, context.opts)

      assert {:error, :restore_reserved} =
               Sanctum.SignIn.admitted(
                 %{id: "github|https://github.com|late", provider: :github, verified: true},
                 :allowed
               )

      assert {:ok, %{status: "completed", user_id: ^user_id, session_token: _}} =
               Recovery.restore(identity.kit, @token, context.opts)

      assert count(User) == 1
      assert {:ok, %{state: "ended"}} = InstallationClaims.get(system())

      # A completed restore leaves a node that holds a person.
      Application.put_env(:sanctum, :restore_token, String.duplicate("6b", 32))

      assert {:error, :not_empty} =
               Recovery.restore(other.kit, String.duplicate("6b", 32), context.opts)
    end

    test "killed at staged, before its submission reached the directory, resumes and submits once",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      before = Directory.log(context.directory.dir, identity.identifier)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _}} =
               Recovery.restore(identity.kit, @token, context.opts)

      [attempt] = attempts("restore")

      # The instant after the attempt opened with its claim, and before its
      # submission was recorded or reached the directory: the directory
      # holds neither the recovery nor its outcome.
      Directory.publish(context.directory.dir, identity.identifier, before)
      Agent.update(context.directory.dir, &%{&1 | recorded: %{}})

      {1, _} =
        Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^attempt.id),
          set: [phase: "staged"]
        )

      # Another kit under this token wins nothing meanwhile.
      other = elsewhere!(context.directory)
      assert {:error, :token_claimed} = Recovery.restore(other.kit, @token, context.opts)

      assert {:ok, %{status: "completed", user_id: user_id}} =
               Recovery.restore(identity.kit, @token, context.opts)

      assert [%{id: same, phase: "completed"}] = attempts("restore")
      assert same == attempt.id
      assert row(user_id).live_public_key == attempt.staged_live_public_key
      assert row(user_id).operational_public_key == attempt.staged_operational_public_key

      log = Directory.log(context.directory.dir, identity.identifier)
      assert [%{request: %{request_id: request_id}}] = Enum.filter(log, &(&1.kind == :recover))
      assert request_id == attempt.request_id
      assert count(User) == 1
    end

    test "killed at keys_active, before the mint, resumes into the mint without a directory write",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _}} =
               Recovery.restore(identity.kit, @token, context.opts)

      [attempt] = attempts("restore")
      log = Directory.log(context.directory.dir, identity.identifier)
      entry_hash = Identity.hash(List.last(log))

      # The instant after the head was read again and named this attempt's
      # keys, and before the mint's transaction: no person yet.
      {1, _} =
        Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^attempt.id),
          set: [phase: "keys_active", entry_hash: entry_hash, outcome: "accepted"]
        )

      assert count(User) == 0
      _drained = Directory.requests()

      assert {:ok, %{status: "completed", user_id: user_id, session_token: _}} =
               Recovery.restore(identity.kit, @token, context.opts)

      # Nothing was written to the directory on the way: the mint followed.
      assert writes() == []
      assert [%{phase: "completed"}] = attempts("restore")
      assert row(user_id).head_hash == entry_hash
      assert row(user_id).live_public_key == attempt.staged_live_public_key
      assert count(User) == 1
      assert {:ok, %{state: "ended", outcome: "completed"}} = InstallationClaims.get(system())
    end

    test "accepted, its reply lost, superseded elsewhere, then resumed: it activates nothing",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _}} =
               Recovery.restore(identity.kit, @token, context.opts)

      recovered_elsewhere!(context.directory, identity)

      assert {:error, :superseded} = Recovery.restore(identity.kit, @token, context.opts)
      assert [attempt] = attempts("restore")
      assert attempt.phase == "superseded"
      assert is_nil(attempt.staged_live_key_sealed)
      assert is_nil(attempt.staged_operational_key_sealed)
      assert count(User) == 0
      assert count(PersonIdentity) == 0
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())

      # It stays superseded, and its token restarts nothing.
      assert {:error, :superseded} = Recovery.restore(identity.kit, @token, context.opts)
      assert {:error, :superseded} = Recovery.restore_challenge(@token)

      other = elsewhere!(context.directory)
      assert {:error, :token_spent} = Recovery.restore(other.kit, @token, context.opts)
    end

    test "refused by the directory, the token is spent", context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :refuse)

      assert {:error, :refused} = Recovery.restore(identity.kit, @token, context.opts)
      assert [%{phase: "refused", staged_live_key_sealed: nil}] = attempts("restore")
      assert {:error, :refused} = Recovery.restore(identity.kit, @token, context.opts)

      other = elsewhere!(context.directory)
      assert {:error, :token_spent} = Recovery.restore(other.kit, @token, context.opts)
      assert count(User) == 0
    end

    test "racing a first sign-in, the restore alone holds the installation", context do
      reserved!()
      identity = elsewhere!(context.directory)
      first = %{id: "github|https://github.com|first", provider: :github, verified: true}

      assert {:error, :restore_reserved} = Sanctum.SignIn.admitted(first, :admin)

      Directory.next(context.directory.dir, identity.identifier, :drop)
      {:error, {:retry, _, _}} = Recovery.restore(identity.kit, @token, context.opts)

      # With the token unset, the claim made still reserves the node.
      InstallationClaims.install_mode!(:ordinary)
      assert {:error, :restore_reserved} = Sanctum.SignIn.admitted(first, :admin)
      assert count(User) == 0
    end
  end

  # ---- the restored person's first method --------------------------------------

  describe "after restore" do
    test "the first local passkey, then a freshly confirmed door link", context do
      restored = restored!(context)
      assert {{:ok, %{status: "active"}}, auth} = first_passkey(restored.ctx)

      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")
      key = "oidcc|https://idp.test|restored-#{System.unique_integer([:positive])}"

      {:ok, ticket} =
        SignIn.link_ticket(restored.ctx, %{
          key: key,
          provider: "oidcc",
          email: "restored@example.com",
          verified: true
        })

      assert {:error, {:confirmation_required, %{id: id}}} =
               SignIn.link_door(restored.ctx, "oidcc", ticket)

      TestContext.prove!(restored.ctx, id, auth)

      assert {:ok, %{linked: true, door: %{key: ^key}}} =
               SignIn.link_door(%{restored.ctx | confirmation_id: id}, "oidcc", ticket)

      assert {:ok, %{id: user_id}} = Users.get_by_identity(key)
      assert user_id == restored.user_id
    end

    test "once the restore session ends, passkey sign-in admits them by their door entry",
         context do
      restored = restored!(context)
      {{:ok, _active}, auth} = first_passkey(restored.ctx)
      :ok = Sanctum.Session.destroy(restored.session_token)

      held = Passkeys.sign_in_challenge()

      assert {:ok, %{session_token: token}} =
               Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      assert {:ok, %{user_id: user_id}} = Sanctum.Session.get(token)
      assert user_id == restored.user_id

      # The operator can still deny them.
      {:ok, _} = Sanctum.Door.Store.deny("user_id", restored.user_id, "operator")
      held = Passkeys.sign_in_challenge()

      assert {:error, {:door, :denied}} =
               Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))
    end

    test "a closed window reopens only by the kit and the capability against a new challenge",
         context do
      restored = restored!(context)
      {:ok, seconds} = Sanctum.Consent.Authz.seconds_setting("reauth_seconds")
      aged = DateTime.add(DateTime.utc_now(), -(seconds + 60), :second)

      {1, _} =
        Arca.Repo.update_all(
          from(s in Arca.Schemas.Session,
            where: s.token_hash == ^:crypto.hash(:sha256, restored.session_token)
          ),
          set: [inserted_at: aged]
        )

      {:ok, ctx} = Sanctum.Session.load(restored.session_token, surface: :console)
      assert {{:error, :reauth_required}, _auth} = first_passkey(ctx)

      kit = restored.identity.kit
      assert {:error, :invalid_token} = Recovery.restore_challenge(nil)
      assert {:ok, %{challenge: challenge}} = Recovery.restore_challenge(@token)

      assert {:error, :challenge_refused} =
               Recovery.reproof(Map.put(kit, "challenge", b64(seed())), @token, context.opts)

      other = elsewhere!(context.directory)

      assert {:error, :token_spent} =
               Recovery.reproof(Map.put(other.kit, "challenge", challenge), @token, context.opts)

      assert {:ok, %{status: "completed", session_token: fresh}} =
               Recovery.reproof(Map.put(kit, "challenge", challenge), @token, context.opts)

      # Replayed, the challenge restarts nothing.
      assert {:error, :challenge_refused} =
               Recovery.reproof(Map.put(kit, "challenge", challenge), @token, context.opts)

      {:ok, fresh_ctx} = Sanctum.Session.load(fresh, surface: :console)
      assert fresh_ctx.provider == "restore"
      assert {{:ok, %{status: "active"}}, _auth} = first_passkey(fresh_ctx)

      # A first method closes the route; neither rotated a key nor restored again.
      assert {:error, :closed} = Recovery.restore_challenge(@token)
      assert length(attempts("restore")) == 1
      assert row(restored.user_id).head_hash == hd(attempts("restore")).entry_hash
    end

    test "a later recovery elsewhere refuses the reproof as superseded", context do
      restored = restored!(context)
      recovered_elsewhere!(context.directory, restored.identity)

      assert {:ok, %{challenge: challenge}} = Recovery.restore_challenge(@token)

      assert {:error, :superseded} =
               Recovery.reproof(
                 Map.put(restored.identity.kit, "challenge", challenge),
                 @token,
                 context.opts
               )
    end
  end
end
