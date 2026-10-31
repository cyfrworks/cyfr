# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RecoveryTest.FillWatch do
  @moduledoc """
  The component-facts port as the suite installs it
  (`Sanctum.Test.Components`), telling the process `watch!/1` names of
  every fill asked for.
  """

  @behaviour Sanctum.Consent.Components

  @doc "Install this port for the test, telling `observer` of each fill."
  @spec watch!(pid()) :: :ok
  def watch!(observer) do
    real = Sanctum.Consent.Components.impl!()

    ExUnit.Callbacks.on_exit(fn ->
      Sanctum.Consent.Components.install!(real)
      :persistent_term.erase({__MODULE__, :observer})
    end)

    :persistent_term.put({__MODULE__, :observer}, observer)
    Sanctum.Consent.Components.install!(__MODULE__)
    :ok
  end

  for {name, arity} <- Sanctum.Consent.Components.behaviour_info(:callbacks), name != :fill do
    args = Macro.generate_arguments(arity, __MODULE__)
    @impl true
    def unquote(name)(unquote_splicing(args)),
      do: Sanctum.Test.Components.unquote(name)(unquote_splicing(args))
  end

  @impl true
  def fill(athanor, ctx, entry_kind) do
    send(:persistent_term.get({__MODULE__, :observer}), {:fill, athanor.id, entry_kind})
    Sanctum.Test.Components.fill(athanor, ctx, entry_kind)
  end
end

defmodule Sanctum.RecoveryTest do
  @moduledoc """
  Recovery material and restore, against a scripted directory that speaks
  HTTPS under a test authority on loopback (`Sanctum.Test.DirectoryServer`).

  Enrollment opens at admission, staged with the genesis over the
  person's keys at the pinned directory and sending nothing; `advance/2`
  registers the same genesis bytes however often its reply is lost, and
  the name it wants is replaced only until the person's name is recorded.
  The recovery code (`Prima.RecoveryCode`) is shown under a fresh proof
  until the person says it is saved, which erases the secret and is
  refused before their name is recorded. Another recovery code is a
  `recover` one the person holds signs,
  keeping the online keys and moving the head. A code that does not read
  is refused before anything is read, asked or sent.

  Restore checks the installation capability first, reads the code, holds
  it to the identity's current recovery set at the pinned directory before
  it claims anything, and walks its durable phases: a reply lost after
  acceptance resumes once, a later recovery supersedes it at any phase
  before its session, even one this home caches after the head's last
  read, a crash after the mint resumes at the mint, and the restored
  person stands at the door and may install their first method within the
  restore session's window, or by a reproof after it.
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
  alias Sanctum.Test.Newcomers
  alias Sanctum.TestContext.Authenticator

  @token String.duplicate("5a", 32)

  setup_all do
    %{tls: Directory.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
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
      Arca.Cache.delete_match({:established, :_, :_})
      Prima.Test.RateLimiter.reset!()
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

  defp holder_args(signer, added, id) do
    %{
      "recovery_code" => signer,
      "holder" => %{"recovery_secret" => b64(added)},
      "request_id" => id
    }
  end

  defp code(identifier, seed), do: Prima.RecoveryCode.encode(identifier, seed)

  # The restore ingress's body for `identifier`'s code over `seed`.
  defp body(identifier, seed), do: %{"recovery_code" => code(identifier, seed)}

  # Forgets the names the resolver was asked so far.
  defp forget_resolved do
    receive do
      {:resolved, _name} -> forget_resolved()
    after
      0 -> :ok
    end
  end

  # `code` with its last symbol changed: it reads, and its check fails.
  defp typo(code) do
    {kept, last} = String.split_at(code, -1)
    kept <> if(last == "0", do: "1", else: "0")
  end

  # Setup's mint of the installation's first person, which the guard
  # decides (`Arca.InstallationClaims`).
  defp setup_mint do
    now = DateTime.utc_now()

    Arca.Users.mint(
      system(),
      %{
        id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
        first_seen_at: now,
        last_seen_at: now,
        created_at: now,
        updated_at: now
      },
      nil,
      admission: "setup"
    )
  end

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
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
    {:ok, ctx} = Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{user: user, athanor: athanor, ctx: ctx}
  end

  defp confirmed(person, fun), do: TestContext.confirming(person.ctx, fun)

  # The enrollment the person's admission opens, as it opens it: at the
  # pinned directory, with a fresh identity, nothing sent.
  defp opened!(context, person \\ seated!()) do
    identity = Newcomers.identity()
    :ok = Recovery.open_at_admission(person.user.id, identity, context.directory.url)
    Map.merge(person, %{identity: identity, seed: identity.recovery_secret})
  end

  # An admitted person whose identity the directory accepted and whose
  # name is recorded, as `registry.register` leaves them.
  defp enrolled!(context) do
    person = opened!(context)
    {:ok, %{phase: "accepted"} = enrolled} = Recovery.advance(person.ctx, context.opts)
    named!(person)
    request_id = Arca.Repo.get!(IdentityAttempt, enrolled.attempt_id).request_id

    Map.merge(person, %{
      code: code(enrolled.identifier, person.seed),
      enrolled: Map.put(enrolled, :request_id, request_id)
    })
  end

  defp named!(person) do
    {:ok, user} = Users.get(person.user.id)
    {:ok, _named} = Users.set_namespace(user, person.identity.name)
    :ok
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

  # An identity held at another home: its online keys, one recovery code
  # and its genesis at the scripted directory. This node holds none of it.
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
      code: code(identifier, seed),
      body: body(identifier, seed)
    }
  end

  # This installation configured for restore, its first person reserved
  # for it.
  defp reserved! do
    Application.put_env(:sanctum, :restore_token, @token)
    InstallationClaims.install_mode!(:restore_reserved)
  end

  # A later recovery, made elsewhere with the same code: new online keys.
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

  # A restore stopped at `keys_active`: the directory accepted its
  # recovery, the reply was lost, and a resume read the head naming its
  # keys and stopped before the mint's transaction.
  defp stopped_at_keys_active!(context, identity) do
    Directory.next(context.directory.dir, identity.identifier, :drop)
    {:error, {:retry, "submitted", _}} = Recovery.restore(identity.body, @token, context.opts)
    [attempt] = attempts("restore")
    log = Directory.log(context.directory.dir, identity.identifier)

    {1, _} =
      Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^attempt.id),
        set: [
          phase: "keys_active",
          entry_hash: Identity.hash(List.last(log)),
          outcome: "accepted"
        ]
      )

    Arca.Repo.get!(IdentityAttempt, attempt.id)
  end

  # A completed restore taken back to the instant after its mint committed
  # and before its session was issued: the attempt at `minted`, its claim
  # pending, and the session it issued gone.
  defp stopped_at_minted!(restored) do
    [attempt] = attempts("restore")
    :ok = Sanctum.Session.destroy(restored.session_token)

    {1, _} =
      Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^attempt.id),
        set: [phase: "minted"]
      )

    {1, _} =
      Arca.Repo.update_all(
        from(c in InstallationClaim, where: c.request_id == ^attempt.request_id),
        set: [state: "pending", outcome: nil, ended_at: nil]
      )

    :ok
  end

  # The client options with a resolver that knows no scripted directory's
  # name: the directory cannot be reached.
  defp unreachable(opts), do: Keyword.put(opts, :resolver, Sanctum.Test.Resolver)

  defp sessions(user_id),
    do: Arca.Repo.aggregate(from(s in Arca.Schemas.Session, where: s.user_id == ^user_id), :count)

  # A handler on the repo's statements: the process that put `{test, point}`
  # under `:restore_hold` is held at the first statement `point` accepts,
  # until the test releases it.
  @doc false
  def hold(event, _measurements, metadata, _config) do
    with {test, point} <- Process.get(:restore_hold),
         true <- point.(event, metadata) do
      Process.delete(:restore_hold)
      send(test, {:restore_held, self()})

      receive do
        :release -> :ok
      end
    end

    :ok
  end

  # Once the restore's fresh read has cached the head it verified (inside
  # the cache's own transaction), at its next read of that cache outside a
  # transaction: the head it mints under is read, and the mint's
  # transaction has not begun.
  defp head_read_point(_event, %{source: "directory_heads"}) do
    cond do
      Arca.Repo.in_transaction?() ->
        Process.put(:head_cached, true)
        false

      Process.get(:head_cached, false) ->
        true

      true ->
        false
    end
  end

  defp head_read_point(_event, _metadata), do: false

  # Once the mint's transaction wrote the person, at the restore's next
  # read of the cached head outside a transaction, the `minted` phase's
  # fresh read: the person stands, and nothing of that phase has run.
  defp minted_point(_event, %{source: "users", query: "INSERT" <> _}) do
    if Arca.Repo.in_transaction?(), do: Process.put(:person_written, true)
    false
  end

  defp minted_point(_event, %{source: "directory_heads"}),
    do: Process.get(:person_written, false) and not Arca.Repo.in_transaction?()

  defp minted_point(_event, _metadata), do: false

  # Once the restore's session is issued (its insert committed), before
  # the attempt moves to `completed`.
  defp session_point([:cyfr, :sanctum, :session, :created], _metadata), do: true
  defp session_point(_event, _metadata), do: false

  # `request`, run by a task held at `point`, while the test runs `during`
  # before the task goes on. Answers `{request's answer, during's answer}`.
  defp held_at(point, request, during) do
    test = self()
    handler = "recovery-hold-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:arca, :repo, :query], [:cyfr, :sanctum, :session, :created]],
        &__MODULE__.hold/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        Process.put(:restore_hold, {test, point})
        request.()
      end)

    assert_receive {:restore_held, held}, 5_000
    meanwhile = during.()
    send(held, :release)
    answer = Task.await(task, 25_000)
    :telemetry.detach(handler)
    {answer, meanwhile}
  end

  defp restored!(context) do
    reserved!()
    identity = elsewhere!(context.directory)

    {:ok, %{status: "completed"} = restored} =
      Recovery.restore(identity.body, @token, context.opts)

    {:ok, session} = Sanctum.Session.load(restored.session_token)
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

  describe "enrollment at admission" do
    test "opens staged with the genesis over the person's keys at the pinned directory, asking and sending nothing",
         context do
      person = opened!(context)

      assert [attempt] = attempts("enrollment")

      assert %{
               phase: "staged",
               name: name,
               request_id: request_id,
               directory_url: directory,
               kit_seed_sealed: <<_::binary>>
             } = attempt

      assert name == person.identity.name
      assert request_id == person.identity.request_id
      assert directory == context.directory.url

      {:ok, genesis} =
        Sanctum.Person.sign_genesis(person.user.id, [public(person.seed)], directory)

      assert attempt.genesis == genesis.genesis
      assert attempt.identifier == genesis.identifier
      assert %{enrollment: "pending", identifier: nil} = row(person.user.id)
      assert confirmations(person.user.id) == []
      assert writes() == []
    end

    test "a staged attempt, left by a crash after the admission, is moved on by the next advance; an accepted one answers at once",
         context do
      person = opened!(context)
      assert [%{phase: "staged", id: attempt_id}] = attempts("enrollment")

      assert {:ok, answer} = Recovery.advance(person.ctx, context.opts)

      assert answer == %{
               attempt_id: attempt_id,
               identifier: answer.identifier,
               name: person.identity.name,
               phase: "accepted"
             }

      row = row(person.user.id)
      assert %{identifier: identifier, enrollment: "enrolled"} = row
      assert identifier == answer.identifier

      assert [genesis] = Directory.log(context.directory.dir, identifier)
      assert genesis.recovery_keys == [public(person.seed)]
      assert genesis.live_key == row.live_public_key
      assert genesis.directory == context.directory.url
      assert row.head_hash == Identity.hash(genesis)
      assert [_registered] = writes()

      # Accepted, it answers at once and sends nothing.
      assert {:ok, ^answer} = Recovery.advance(person.ctx, context.opts)
      assert writes() == []
    end

    test "a directory that refuses the genesis ends the attempt refused, and a repeat answers the same",
         context do
      person = opened!(context)
      [%{identifier: identifier}] = attempts("enrollment")
      Directory.next(context.directory.dir, identifier, :refuse)

      assert {:error, :directory_refused} = Recovery.advance(person.ctx, context.opts)
      assert %{identifier: nil, enrollment: "none"} = row(person.user.id)
      assert [%{phase: "refused", kit_seed_sealed: nil}] = attempts("enrollment")
      assert Directory.log(context.directory.dir, identifier) == nil
      _ = Directory.requests()

      assert {:error, :directory_refused} = Recovery.advance(person.ctx, context.opts)
      assert writes() == []
    end

    test "a lost reply leaves the attempt submitted, and a repeat registers the same genesis bytes",
         context do
      person = opened!(context)
      [%{identifier: identifier, genesis: bytes, id: attempt_id}] = attempts("enrollment")
      Directory.next(context.directory.dir, identifier, :drop)

      assert {:error, :directory_unavailable} = Recovery.advance(person.ctx, context.opts)
      assert [%{phase: "submitted", genesis: ^bytes}] = attempts("enrollment")
      _ = Directory.requests()

      assert {:ok, %{phase: "accepted", identifier: ^identifier, attempt_id: ^attempt_id}} =
               Recovery.advance(person.ctx, context.opts)

      assert [%{body: ^bytes}] = writes()
      assert length(attempts("enrollment")) == 1
      assert length(Directory.log(context.directory.dir, identifier)) == 1
    end

    test "a person with no enrollment has nothing to advance or rename", context do
      person = seated!()

      assert {:error, :no_attempt} = Recovery.advance(person.ctx, context.opts)
      assert {:error, :no_attempt} = Recovery.rename(person.ctx, "nova")
      assert writes() == []
    end

    test "the wanted name is replaced until the person's name is recorded, and never after",
         context do
      person = opened!(context)

      assert {:error, {:invalid_argument, _}} = Recovery.rename(person.ctx, "Not A Name")
      assert {:ok, %{name: "nova", phase: "staged"}} = Recovery.rename(person.ctx, "nova")
      assert [%{name: "nova"}] = attempts("enrollment")

      {:ok, %{phase: "accepted"}} = Recovery.advance(person.ctx, context.opts)
      assert {:ok, %{name: "luna", phase: "accepted"}} = Recovery.rename(person.ctx, "luna")

      named!(person)

      assert {:error, {:invalid_argument, "Your name is set and cannot be changed."}} =
               Recovery.rename(person.ctx, "stella")

      assert [%{name: "luna"}] = attempts("enrollment")
    end

    test "a refused enrollment takes no new name", context do
      person = opened!(context)
      [%{identifier: identifier}] = attempts("enrollment")
      Directory.next(context.directory.dir, identifier, :refuse)
      {:error, :directory_refused} = Recovery.advance(person.ctx, context.opts)

      assert {:error, :no_attempt} = Recovery.rename(person.ctx, "nova")
      assert [%{name: name}] = attempts("enrollment")
      assert name == person.identity.name
    end

    test "status answers the recorded name and the name the enrollment wants", context do
      person = opened!(context)

      assert {:ok, %{name: nil, kits: [kit]}} = Recovery.status(person.ctx)
      assert %{kind: "enrollment", phase: "staged", name: name, deliverable: false} = kit
      assert name == person.identity.name

      {:ok, _} = Recovery.advance(person.ctx, context.opts)
      named!(person)

      assert {:ok, %{name: ^name, kits: [%{phase: "accepted", deliverable: true}]}} =
               Recovery.status(person.ctx)
    end
  end

  describe "the recovery code" do
    test "is shown again only under a fresh proof, until saying it is saved erases it",
         context do
      person = enrolled!(context)
      attempt_id = person.enrolled.attempt_id

      assert {:error, {:confirmation_required, %{operation: "person.recovery_code"}}} =
               Recovery.recovery_code(person.ctx, attempt_id)

      assert {:ok, shown} = confirmed(person, &Recovery.recovery_code(&1, attempt_id))

      assert shown == %{
               attempt_id: attempt_id,
               code: code(person.enrolled.identifier, person.seed)
             }

      assert {:ok, %{attempt_id: ^attempt_id, phase: "completed"}} =
               Recovery.recovery_code_saved(person.ctx, attempt_id)

      assert Arca.Repo.get!(IdentityAttempt, attempt_id).kit_seed_sealed == nil

      # Gone for good: no proof brings it back, and a repeat restores nothing.
      assert {:error, :kit_acknowledged} = Recovery.recovery_code(person.ctx, attempt_id)
      assert {:ok, %{phase: "completed"}} = Recovery.recovery_code_saved(person.ctx, attempt_id)
      assert Arca.Repo.get!(IdentityAttempt, attempt_id).kit_seed_sealed == nil

      # The admission's answer holds no code once it is saved.
      assert {:ok, recovery} = Recovery.admission_recovery(person.user.id)
      refute Map.has_key?(recovery, :code)
      assert {:ok, %{phase: "completed"}} = Recovery.advance(person.ctx, context.opts)

      # Nobody else reaches it.
      other = seated!()

      assert {:error, {:not_found, "recovery_code", ^attempt_id}} =
               Recovery.recovery_code(other.ctx, attempt_id)

      assert {:error, {:not_found, "recovery_code", ^attempt_id}} =
               Recovery.recovery_code_saved(other.ctx, attempt_id)
    end

    test "said saved while its showing is inside its confirmation, it shows nothing",
         context do
      person = enrolled!(context)
      attempt_id = person.enrolled.attempt_id
      user_id = person.user.id
      test = self()
      handler = "recovery-code-saved-#{System.unique_integer([:positive])}"

      # The showing's confirmation is consumed, on the showing's own
      # process, and it has not opened the secret: the person says the
      # code is saved then.
      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :sanctum, :confirmation, :consumed],
          fn
            _event,
            _measurements,
            %{operation: "person.recovery_code", user_id: ^user_id},
            _config ->
              :telemetry.detach(handler)
              send(test, {:saved, Recovery.recovery_code_saved(person.ctx, attempt_id)})

            _event, _measurements, _metadata, _config ->
              :ok
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :kit_acknowledged} =
               confirmed(person, &Recovery.recovery_code(&1, attempt_id))

      assert_received {:saved, {:ok, %{phase: "completed"}}}
      assert Arca.Repo.get!(IdentityAttempt, attempt_id).kit_seed_sealed == nil
    end
  end

  describe "saying the recovery code is saved" do
    test "before the person's name is recorded is refused, and the code stays", context do
      person = opened!(context)
      {:ok, %{attempt_id: attempt_id}} = Recovery.advance(person.ctx, context.opts)

      assert {:error,
              {:conflict, "Your name is not recorded yet, so your recovery code cannot be saved."}} =
               Recovery.recovery_code_saved(person.ctx, attempt_id)

      assert %{phase: "accepted", kit_seed_sealed: <<_::binary>>} =
               Arca.Repo.get!(IdentityAttempt, attempt_id)

      named!(person)

      assert {:ok, %{attempt_id: ^attempt_id, phase: "completed"}} =
               Recovery.recovery_code_saved(person.ctx, attempt_id)
    end
  end

  describe "another recovery code" do
    test "is a recover a code the person holds signs, keeping the online keys, and moves the head",
         context do
      person = enrolled!(context)
      before = row(person.user.id)
      added = seed()
      args = holder_args(person.code, added, request_id())

      assert {:error, {:confirmation_required, %{operation: "person.recovery_code_add"}}} =
               Recovery.recovery_code_add(person.ctx, args, context.opts)

      assert attempts("holder") == []

      assert {:ok, %{phase: "accepted", code: added_code, key_epoch: epoch} = answer} =
               confirmed(person, &Recovery.recovery_code_add(&1, args, context.opts))

      assert added_code == code(before.identifier, added)
      assert answer.identifier == before.identifier

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

      # Its code is shown and saved as the first one's.
      [attempt] = attempts("holder")
      assert answer.attempt_id == attempt.id

      assert {:ok, %{code: ^added_code}} =
               confirmed(person, &Recovery.recovery_code(&1, attempt.id))

      assert {:ok, %{phase: "completed"}} = Recovery.recovery_code_saved(person.ctx, attempt.id)

      # A code the identity holds is not added twice, and the added one
      # signs the next.
      assert {:error, :already_a_holder} =
               Recovery.recovery_code_add(
                 person.ctx,
                 holder_args(person.code, added, request_id()),
                 context.opts
               )

      assert {:error, :already_a_holder} =
               Recovery.recovery_code_add(
                 person.ctx,
                 holder_args(added_code, person.seed, request_id()),
                 context.opts
               )
    end

    test "a secret that holds nothing and a holder twice are refused", context do
      person = enrolled!(context)
      added = seed()

      assert {:error, :not_a_holder} =
               Recovery.recovery_code_add(
                 person.ctx,
                 holder_args(code(person.enrolled.identifier, seed()), added, request_id()),
                 context.opts
               )

      # The code that signs is never the one added.
      assert {:error, {:invalid_argument, same}} =
               Recovery.recovery_code_add(
                 person.ctx,
                 holder_args(person.code, person.seed, request_id()),
                 context.opts
               )

      assert same == "The added code must be another than the one signing"

      assert {:error, {:invalid_argument, holder}} =
               Recovery.recovery_code_add(
                 person.ctx,
                 Map.put(holder_args(person.code, added, request_id()), "holder", %{}),
                 context.opts
               )

      assert holder =~ "holder.recovery_secret"
      assert attempts("holder") == []
    end

    test "a code of another identity is no holder, refused before the directory is read",
         context do
      person = enrolled!(context)
      elsewhere = elsewhere!(context.directory)
      _drained = Directory.requests()
      forget_resolved()

      # Another identity's own code, and one whose secret is the person's
      # own, so that only the identity it names differs.
      for signer <- [elsewhere.code, code(elsewhere.identifier, person.seed)] do
        assert {:error, :not_a_holder} =
                 Recovery.recovery_code_add(
                   person.ctx,
                   holder_args(signer, seed(), request_id()),
                   context.opts
                 )
      end

      assert Directory.requests() == []
      refute_received {:resolved, _}
      assert attempts("holder") == []

      assert [] =
               Enum.filter(
                 confirmations(person.user.id),
                 &(&1.action == "recovery_material" and &1.state == "pending")
               )
    end

    test "a signing code that does not read spends nothing: no request, no confirmation, no attempt",
         context do
      person = enrolled!(context)
      added = seed()
      id = request_id()
      args = holder_args(person.code, added, id)

      # The person proves the change first; the typed code then has a typo.
      assert {:error, {:confirmation_required, %{id: confirmation}}} =
               Recovery.recovery_code_add(person.ctx, args, context.opts)

      TestContext.prove!(person.ctx, confirmation)
      proved = confirmations(person.user.id)
      _drained = Directory.requests()
      forget_resolved()
      under_proof = %{person.ctx | confirmation_id: confirmation}

      for {signer, refusal} <- [
            {typo(person.code), :typo},
            {"CYFR-" <> String.duplicate("0", 8), :not_a_code},
            {nil, :not_a_code},
            {42, :not_a_code}
          ] do
        assert {:error, ^refusal} =
                 Recovery.recovery_code_add(
                   under_proof,
                   %{args | "recovery_code" => signer},
                   context.opts
                 )
      end

      assert {:error, :typo} =
               Recovery.recovery_code_add(
                 under_proof,
                 Map.delete(holder_args(typo(person.code), added, id), "holder"),
                 context.opts
               )

      assert Directory.requests() == []
      refute_received {:resolved, _}
      assert attempts("holder") == []
      assert confirmations(person.user.id) == proved

      # The proof was never spent: the code as saved adds under it.
      assert {:ok, %{phase: "accepted", code: added_code}} =
               Recovery.recovery_code_add(under_proof, args, context.opts)

      assert added_code == code(person.enrolled.identifier, added)
    end
  end

  # ---- restore -------------------------------------------------------------------

  describe "restore" do
    test "a code without this installation's token causes no row, no staging, no outbound call",
         context do
      identity = elsewhere!(context.directory)

      assert {:error, :restore_disabled} =
               Recovery.restore(identity.body, @token, context.opts)

      reserved!()
      assert {:error, :invalid_token} = Recovery.restore(identity.body, nil, context.opts)

      assert {:error, :invalid_token} =
               Recovery.restore(identity.body, String.duplicate("0", 64), context.opts)

      assert {:error, :invalid_token} =
               Recovery.restore(identity.body, "Bearer " <> @token, context.opts)

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
               Recovery.restore(identity.body, @token, context.opts)

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

      {:ok, session} = Sanctum.Session.load(token)
      assert session.user_id == user_id
      assert session.provider == "restore"

      # The restored person is the installation's first, so its platform
      # administrator; they hold no linked sign-in method yet, and the door
      # admits them as a local person, with no entry naming them.
      assert Sanctum.Door.Store.list() == []
      assert {:ok, :allowed} = Sanctum.Door.admit_person(%{id: user_id})
      assert {:ok, []} = Arca.Users.identities(system(), user_id)

      assert Arca.Repo.exists?(
               from(m in Arca.Schemas.Membership,
                 where: m.user_id == ^user_id and m.scope == "platform"
               )
             )

      # A plain retry issues no session.
      assert {:error, :restored} = Recovery.restore(identity.body, @token, context.opts)
    end

    test "a code that does not read spends nothing and reaches nothing", context do
      reserved!()
      identity = elsewhere!(context.directory)

      for {params, refusal} <- [
            {%{"recovery_code" => typo(identity.code)}, :typo},
            {%{"recovery_code" => String.replace(identity.code, "-", "", global: false) <> "0"},
             :not_a_code},
            {%{"recovery_code" => "CYFR"}, :not_a_code},
            {%{"recovery_code" => 7}, :not_a_code},
            {%{"identifier" => identity.identifier, "recovery_secret" => b64(identity.seed)},
             :not_a_code},
            {%{}, :not_a_code}
          ] do
        assert {:error, ^refusal} = Recovery.restore(params, @token, context.opts)
        assert {:error, ^refusal} = Recovery.reproof(params, @token, context.opts)
      end

      assert Directory.requests() == []
      refute_received {:resolved, _}
      assert count(IdentityAttempt) == 0
      assert count(InstallationClaim) == 0
      assert count(DirectoryHead) == 0
    end

    test "a code of no holder or of an unknown identity spends nothing, and the right one then restores",
         context do
      reserved!()
      identity = elsewhere!(context.directory)

      assert {:error, :not_a_holder} =
               Recovery.restore(body(identity.identifier, seed()), @token, context.opts)

      unknown = "per_" <> String.duplicate("0", 64)

      assert {:error, :unknown_identity} =
               Recovery.restore(body(unknown, identity.seed), @token, context.opts)

      assert count(IdentityAttempt) == 0
      assert count(InstallationClaim) == 0

      assert {:ok, %{status: "completed", identifier: identifier}} =
               Recovery.restore(identity.body, @token, context.opts)

      assert identifier == identity.identifier
    end

    test "with no directory pinned, nothing is read and nothing is restored", context do
      reserved!()
      identity = elsewhere!(context.directory)
      Prima.Test.Env.delete_app_env(:sanctum, :directory_url)

      # The capability is still checked first.
      assert {:error, :invalid_token} = Recovery.restore(identity.body, nil, context.opts)
      assert {:error, :no_directory} = Recovery.restore(identity.body, @token, context.opts)
      assert {:error, :no_directory} = Recovery.restore(%{}, @token, context.opts)

      assert Directory.requests() == []
      refute_received {:resolved, _}
      assert count(IdentityAttempt) == 0
      assert count(InstallationClaim) == 0
    end

    test "on a node with another person is refused before any write or outbound call", context do
      _person = seated!()
      reserved!()
      identity = elsewhere!(context.directory)

      assert {:error, :not_empty} = Recovery.restore(identity.body, @token, context.opts)
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
               Recovery.restore(identity.body, @token, context.opts)

      assert [%{phase: "submitted"} = staged] = attempts("restore")

      assert {:ok, %{status: "completed", user_id: user_id}} =
               Recovery.restore(identity.body, @token, context.opts)

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

      {:ok, %{user_id: user_id}} = Recovery.restore(identity.body, @token, context.opts)
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

      # Another identity's code under this token, or setup, wins nothing.
      other = elsewhere!(context.directory)
      assert {:error, :token_claimed} = Recovery.restore(other.body, @token, context.opts)
      assert {:error, :restore_reserved} = setup_mint()

      assert {:ok, %{status: "completed", user_id: ^user_id, session_token: _}} =
               Recovery.restore(identity.body, @token, context.opts)

      assert count(User) == 1
      assert {:ok, %{state: "ended"}} = InstallationClaims.get(system())

      # A completed restore leaves a node that holds a person.
      Application.put_env(:sanctum, :restore_token, String.duplicate("6b", 32))

      assert {:error, :not_empty} =
               Recovery.restore(other.body, String.duplicate("6b", 32), context.opts)
    end

    test "killed at staged, before its submission reached the directory, resumes and submits once",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      before = Directory.log(context.directory.dir, identity.identifier)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _}} =
               Recovery.restore(identity.body, @token, context.opts)

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

      # Another identity's code under this token wins nothing meanwhile.
      other = elsewhere!(context.directory)
      assert {:error, :token_claimed} = Recovery.restore(other.body, @token, context.opts)

      assert {:ok, %{status: "completed", user_id: user_id}} =
               Recovery.restore(identity.body, @token, context.opts)

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
               Recovery.restore(identity.body, @token, context.opts)

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
               Recovery.restore(identity.body, @token, context.opts)

      # Nothing was written to the directory on the way: the mint followed.
      assert writes() == []
      assert [%{phase: "completed"}] = attempts("restore")
      assert row(user_id).head_hash == entry_hash
      assert row(user_id).live_public_key == attempt.staged_live_public_key
      assert count(User) == 1
      assert {:ok, %{state: "ended", outcome: "completed"}} = InstallationClaims.get(system())
    end

    test "killed at keys_active and superseded while stopped, it mints nothing and ends superseded",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _}} =
               Recovery.restore(identity.body, @token, context.opts)

      [attempt] = attempts("restore")
      log = Directory.log(context.directory.dir, identity.identifier)
      entry_hash = Identity.hash(List.last(log))

      {1, _} =
        Arca.Repo.update_all(from(a in IdentityAttempt, where: a.id == ^attempt.id),
          set: [phase: "keys_active", entry_hash: entry_hash, outcome: "accepted"]
        )

      # A later recovery elsewhere, while the restore stood stopped.
      recovered_elsewhere!(context.directory, identity)
      assert count(User) == 0

      result = Recovery.restore(identity.body, @token, context.opts)

      assert result == {:error, :superseded},
             "superseded restore returned #{inspect(result)}; person rows: #{count(User)}"

      assert count(User) == 0
      assert count(PersonIdentity) == 0
      assert [%{phase: "superseded"} = ended] = attempts("restore")
      assert is_nil(ended.staged_live_key_sealed)
      assert is_nil(ended.staged_operational_key_sealed)
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())
      assert {:error, :superseded} = Recovery.restore(identity.body, @token, context.opts)
    end

    test "a later recovery this home caches between the head's read and the mint refuses the mint",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      _stopped = stopped_at_keys_active!(context, identity)

      {answer, _observed} =
        held_at(
          &head_read_point/2,
          fn -> Recovery.restore(identity.body, @token, context.opts) end,
          fn ->
            # The recovery lands at the directory, and this home reads it.
            recovered_elsewhere!(context.directory, identity)
            {:ok, _head} = Sanctum.IdentityFreshness.fresh!(identity.identifier, context.opts)
          end
        )

      assert answer == {:error, :superseded}
      assert count(User) == 0
      assert count(PersonIdentity) == 0
      assert [%{phase: "superseded"}] = attempts("restore")
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())
    end

    test "stopped at keys_active, a directory that cannot answer leaves it there, and a retry mints",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      stopped = stopped_at_keys_active!(context, identity)

      assert {:error, :unavailable} =
               Recovery.restore(identity.body, @token, unreachable(context.opts))

      assert [%{id: same, phase: "keys_active"} = standing] = attempts("restore")
      assert same == stopped.id
      assert standing.staged_live_key_sealed == stopped.staged_live_key_sealed
      assert count(User) == 0
      assert {:ok, %{state: "pending"}} = InstallationClaims.get(system())

      assert {:ok, %{status: "completed", user_id: user_id, session_token: _}} =
               Recovery.restore(identity.body, @token, context.opts)

      assert row(user_id).live_public_key == stopped.staged_live_public_key
      assert count(User) == 1
    end

    test "two requests under its token, one held after its head's read while the other completes, converge",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      _stopped = stopped_at_keys_active!(context, identity)

      {held, completed} =
        held_at(
          &head_read_point/2,
          fn -> Recovery.restore(identity.body, @token, context.opts) end,
          fn -> Recovery.restore(identity.body, @token, context.opts) end
        )

      assert {:ok, %{status: "completed", user_id: user_id}} = completed

      # The held request mints nothing more and issues no session.
      assert held == {:error, :restored}
      assert count(User) == 1
      assert sessions(user_id) == 1
      assert [%{phase: "completed", user_id: ^user_id}] = attempts("restore")
      assert {:ok, %{state: "ended", outcome: "completed"}} = InstallationClaims.get(system())
    end

    test "superseded after its mint and before its session, it provisions and issues nothing, and its person stays",
         context do
      :ok = Sanctum.RecoveryTest.FillWatch.watch!(self())
      reserved!()
      identity = elsewhere!(context.directory)
      _stopped = stopped_at_keys_active!(context, identity)

      # A later recovery lands at the directory once the person is minted,
      # before the `minted` phase reads the head.
      {answer, _published} =
        held_at(
          &minted_point/2,
          fn -> Recovery.restore(identity.body, @token, context.opts) end,
          fn -> recovered_elsewhere!(context.directory, identity) end
        )

      assert answer == {:error, :superseded}
      refute_received {:fill, _athanor_id, _entry_kind}
      assert [%{phase: "superseded", user_id: user_id}] = attempts("restore")
      assert is_binary(user_id)
      assert count(User) == 1
      assert sessions(user_id) == 0

      # The admission wrote the person's athanor and their grant with them;
      # superseded after it, the attempt asks for no fill and issues no
      # session.
      assert {:ok, _athanor} = Sanctum.Tenancy.Users.personal_athanor_id(user_id)
      assert Sanctum.Tenancy.platform_admin?(user_id)

      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())

      # It stays superseded, and no reproof reopens it.
      assert {:error, :superseded} = Recovery.restore(identity.body, @token, context.opts)
      assert {:error, :superseded} = Recovery.restore_challenge(@token)
    end

    test "superseded by a twin request after its session was issued, that session is deleted and never answered",
         context do
      reserved!()
      identity = elsewhere!(context.directory)

      {:ok, %{user_id: user_id} = restored} =
        Recovery.restore(identity.body, @token, context.opts)

      :ok = stopped_at_minted!(restored)

      # The held request read the head naming its keys and issued its
      # session; then a later recovery lands, and a twin request under the
      # same token reads it and supersedes the attempt.
      {held, twin} =
        held_at(
          &session_point/2,
          fn -> Recovery.restore(identity.body, @token, context.opts) end,
          fn ->
            recovered_elsewhere!(context.directory, identity)
            Recovery.restore(identity.body, @token, context.opts)
          end
        )

      assert twin == {:error, :superseded}
      assert held == {:error, :superseded}
      assert sessions(user_id) == 0
      assert [%{phase: "superseded", user_id: ^user_id}] = attempts("restore")
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())
    end

    test "stopped at minted, a directory that cannot answer leaves it there, and a retry issues the session",
         context do
      :ok = Sanctum.RecoveryTest.FillWatch.watch!(self())
      reserved!()
      identity = elsewhere!(context.directory)

      {:ok, %{user_id: user_id} = restored} =
        Recovery.restore(identity.body, @token, context.opts)

      # The fill is asked for once the head still names the restored keys.
      {:ok, athanor_id} = Sanctum.Tenancy.Users.personal_athanor_id(user_id)
      assert_received {:fill, ^athanor_id, "sign_in"}

      :ok = stopped_at_minted!(restored)

      assert {:error, :unavailable} =
               Recovery.restore(identity.body, @token, unreachable(context.opts))

      refute_received {:fill, _athanor_id, _entry_kind}
      assert [%{phase: "minted"}] = attempts("restore")
      assert sessions(user_id) == 0
      assert {:ok, %{state: "pending"}} = InstallationClaims.get(system())

      assert {:ok, %{status: "completed", user_id: ^user_id, session_token: token}} =
               Recovery.restore(identity.body, @token, context.opts)

      assert_received {:fill, ^athanor_id, "sign_in"}
      assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.get(token)
      assert [%{phase: "completed"}] = attempts("restore")
      assert count(User) == 1
    end

    test "accepted, its reply lost, superseded elsewhere, then resumed: it activates nothing",
         context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :drop)

      assert {:error, {:retry, "submitted", _}} =
               Recovery.restore(identity.body, @token, context.opts)

      recovered_elsewhere!(context.directory, identity)

      assert {:error, :superseded} = Recovery.restore(identity.body, @token, context.opts)
      assert [attempt] = attempts("restore")
      assert attempt.phase == "superseded"
      assert is_nil(attempt.staged_live_key_sealed)
      assert is_nil(attempt.staged_operational_key_sealed)
      assert count(User) == 0
      assert count(PersonIdentity) == 0
      assert {:ok, %{state: "ended", outcome: "superseded"}} = InstallationClaims.get(system())

      # It stays superseded, and its token restarts nothing.
      assert {:error, :superseded} = Recovery.restore(identity.body, @token, context.opts)
      assert {:error, :superseded} = Recovery.restore_challenge(@token)

      other = elsewhere!(context.directory)
      assert {:error, :token_spent} = Recovery.restore(other.body, @token, context.opts)
    end

    test "refused by the directory, the token is spent", context do
      reserved!()
      identity = elsewhere!(context.directory)
      Directory.next(context.directory.dir, identity.identifier, :refuse)

      assert {:error, :refused} = Recovery.restore(identity.body, @token, context.opts)
      assert [%{phase: "refused", staged_live_key_sealed: nil}] = attempts("restore")
      assert {:error, :refused} = Recovery.restore(identity.body, @token, context.opts)

      other = elsewhere!(context.directory)
      assert {:error, :token_spent} = Recovery.restore(other.body, @token, context.opts)
      assert count(User) == 0
    end

    test "racing setup, the restore alone holds the installation", context do
      reserved!()
      identity = elsewhere!(context.directory)

      assert {:error, :restore_reserved} = setup_mint()

      Directory.next(context.directory.dir, identity.identifier, :drop)
      {:error, {:retry, _, _}} = Recovery.restore(identity.body, @token, context.opts)

      # With the token unset, the claim made still reserves the node.
      InstallationClaims.install_mode!(:ordinary)
      assert {:error, :restore_reserved} = setup_mint()
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

    test "once the restore session ends, passkey sign-in admits them as a local person",
         context do
      restored = restored!(context)
      {{:ok, _active}, auth} = first_passkey(restored.ctx)
      :ok = Sanctum.Session.destroy(restored.session_token)

      held = Passkeys.sign_in_challenge()

      assert {:ok, %{session_token: token}} =
               Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

      assert {:ok, %{user_id: user_id}} = Sanctum.Session.get(token)
      assert user_id == restored.user_id

      # They are the installation's administrator, whom no deny names.
      assert {:error, :platform_admin} =
               Sanctum.Door.Store.deny("person", restored.user_id, "operator")

      held = Passkeys.sign_in_challenge()
      assert {:ok, _} = Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))
    end

    test "a closed window reopens only by the recovery code and the capability against a new challenge",
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

      {:ok, ctx} = Sanctum.Session.load(restored.session_token)
      assert {{:error, :reauth_required}, _auth} = first_passkey(ctx)

      body = restored.identity.body
      assert {:error, :invalid_token} = Recovery.restore_challenge(nil)
      assert {:ok, %{challenge: challenge}} = Recovery.restore_challenge(@token)

      assert {:error, :challenge_refused} =
               Recovery.reproof(Map.put(body, "challenge", b64(seed())), @token, context.opts)

      other = elsewhere!(context.directory)

      assert {:error, :token_spent} =
               Recovery.reproof(Map.put(other.body, "challenge", challenge), @token, context.opts)

      # The identity's own identifier under a secret that never signed this
      # restore is spent too, and a code with a typo is refused unread: the
      # challenge stays held for the code as saved.
      stranger = body(restored.identity.identifier, seed())

      assert {:error, :token_spent} =
               Recovery.reproof(Map.put(stranger, "challenge", challenge), @token, context.opts)

      mistyped = %{"recovery_code" => typo(restored.identity.code), "challenge" => challenge}
      assert {:error, :typo} = Recovery.reproof(mistyped, @token, context.opts)

      assert {:ok, %{status: "completed", session_token: fresh}} =
               Recovery.reproof(Map.put(body, "challenge", challenge), @token, context.opts)

      # Replayed, the challenge restarts nothing.
      assert {:error, :challenge_refused} =
               Recovery.reproof(Map.put(body, "challenge", challenge), @token, context.opts)

      {:ok, fresh_ctx} = Sanctum.Session.load(fresh)
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
                 Map.put(restored.identity.body, "challenge", challenge),
                 @token,
                 context.opts
               )
    end
  end
end
