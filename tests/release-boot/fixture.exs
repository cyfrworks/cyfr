# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the release proofs put in a running server, evaluated inside it by
# `bin/cyfr rpc` (`server_fixture` in tests/release-boot/release.sh). The
# file evaluates to a function of the argument list; each command prints
# nothing and answers one line, `FIXTURE=` and a JSON object.
#
#   person EMAIL SUB [NAME]
#       The person of the account SUB names, made the first time, then
#       signed in as an answer to a sign-in request signs one in: the door
#       asked about the person, the verified EMAIL and the name NAME,
#       default "Release proof", recorded on their row, their athanor's
#       fill started, and a session bound to the account's device key and
#       the head this CYFR caches. The account is built here, as the
#       account pages or `cyfr login --setup` make one: a genesis signed by
#       a recovery key SUB derives, at this deployment's directory
#       (`Sanctum.directory_url/0`), and one device key added, published
#       there as they publish one (the genesis registered and the key
#       appended, `Sanctum.Directory.Client`), and its head cached as a
#       first read leaves it, so the account refreshes from its directory
#       as any other does once the freshness bound has passed. Nothing is
#       written to cyfr.run, which holds real people's accounts: where the
#       deployment reads it, the account is cached alone, and its person
#       pauses past the bound on a public home. The same SUB is the same
#       account, so a person made once is signed in again, under the
#       device key their admission listed, the one this CYFR's cached head
#       of the account lists. An
#       installation's first person is made by the setup admission
#       (`Sanctum.Newcomer.admit/3` under a setup token the fixture puts
#       for the call and takes away after), and so is its platform
#       administrator, their device paired in the same admission as its
#       hello pairs one (`Sanctum.DeviceUnlock.pair/4`): a device-first
#       person, as a box's screen or `cyfr login --setup` makes one, named
#       `release-proof`. The device's key is an Ed25519 seed drawn here and
#       listed in the account's log. The seed is written to
#       `setup-device.json` in the server's working directory (a release
#       cell's own; an image's temporary directory where its working
#       directory is not the server's to write), with mode 0600, beside the
#       device's client, athanor, home and certificate, and is never
#       answered, taken as an argument or logged: `device_confirm` alone
#       reads it. A record already there is that device: a first person
#       made again where it is kept (an installation started over in the
#       same directory) is admitted with its seed and client, and the
#       record is written back with the new athanor and certificate; one
#       that does not read, or names another home, refuses the person.
#       Every later person is admitted by the open admission
#       (`Sanctum.Newcomer.admit/3` under `:open`, its caps counted before
#       the person's row), once the door's `*` admits newcomers, which the
#       proof opens as an administrator does (`door.allow`); their account's
#       device key SUB derives too. Answers the person, the athanor the
#       session is focused on, the route segment of that athanor and the
#       session token.
#
#   device_confirm REF [digest|ref|key]
#       The setup device confirming the pending confirmation REF, as its
#       own channel does (`Emissary.Web.DeviceChannel`): a `connect`
#       challenge for the certificate in `setup-device.json`, signed with
#       its seed and decided by `Sanctum.DeviceCerts.verify_connect/3` (a
#       certificate past its life renewed first, as the channel renews
#       one, `pairing.renew` through the gate, the replacement written
#       back), the record read through the gate as a device intent
#       (`confirmation.pending` with the `request`, which answers its
#       stored preview), this CYFR's `confirm` request for it
#       (`confirmation.request`, whose subject is the record's digest), and
#       the device's answer to it, Ed25519 over the request's digest, given
#       through the gate (`confirmation.confirm` with the `answer`). With
#       `digest`, `ref` or `key` the answer is made wrong on purpose: over
#       another digest, under another ref, or by another key; the home must
#       refuse it. Answers the record's operation and preview as the home
#       stored them and the digest its request names, and `ok` with the
#       confirmation's result or `error` with the refusal; no record of
#       that ref answers `error`.
#
#   tincture USER_ID DIR NAME public|private
#       The files under DIR committed into the person's athanor as the
#       local tincture NAME at 1.0.0, one unit, and registered from the tree
#       (`Compendium.Registry.register_from_arca/3`), as a locally built
#       tincture is, once the fill the person's sign-in started has let go
#       of their athanor. `public` also leaves the active public profile
#       the `/t/` route asks of a public tincture, unless one is there,
#       written by `Arca.Test.Writers.put_profile/1` loaded from the
#       checkout (the release refuses the consent walk that
#       `profile.publish` ends, see below); the fixture fails unless the
#       profile is there after and the route's own read
#       (`Sanctum.TinctureAccess.get_public/3`) finds the tincture.
#
#   grant SESSION_TOKEN NAME [VERSION]
#       The person's grant of their local tincture NAME as the consent walk
#       makes it (plan, preview, commit) under their session on the
#       interactive path, granting the whole ask, its flows among it: the
#       owner profile and head a frame of the tincture's VERSION (default
#       1.0.0) opens under, since a tincture's declaration is never its
#       grant. As the shell asks for a grant only for a version that does
#       not open, a VERSION that opens under the person's grant already is
#       left as it is. A plan the components projection cannot answer yet
#       is asked again, for up to ten seconds. The fixture fails unless the
#       frame open's own read (`Compendium.tincture_grant_revision/2`)
#       finds the grant for VERSION after. Answers the head's revision and
#       whether this walk committed it.
#
#   thread USER_ID TEXT
#       A thread in the person's athanor holding one message, TEXT.
#
#   console SESSION_TOKEN TOOL ARGUMENTS_JSON
#       TOOL called as the console calls it for the session's person
#       (`PrismWeb.Ops.call_tool/3`, through the gate): a proxied
#       `server:tool` among them, which `/mcp` does not dispatch. Answers
#       `ok` and the result, or `error` and the refusal.
#
#   vault SESSION_TOKEN NAME FIELD VALUE
#       An `api_key` entry NAME holding FIELD = VALUE in the athanor the
#       session is focused on, its row written sealed as `Sanctum.Vault`
#       writes one (the same payload, AAD, cipher and binding digest),
#       bound to the destination `fixture.test` and disclosed: a proof
#       hands its value to a backend's environment
#       (`tests/locus-backends-image/e2e.py`). Entering a credential is a
#       sensitive change a person confirms with a fresh proof, which these
#       proofs cannot give outside a browser, so a proof that needs entries
#       but is not about entering them seeds them here. Answers the entry's
#       id and name.
#
# A step that does not answer `{:ok, _}` raises, and the rpc exits non-zero
# naming it.

fn args ->
  answer = fn map -> "FIXTURE=" <> Jason.encode!(map) end

  # The person's context as a session reaches it: its athanor filled in as
  # the person's own.
  person_ctx = fn user_id ->
    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        email: user.email,
        provider: "device",
        athanor_id: nil,
        permissions: Sanctum.Context.person_permissions()
      )

    {:ok, ctx} = Sanctum.Tenancy.resolve_status(%{ctx | namespace: user.namespace}, force: true)
    ctx
  end

  segment = fn athanor_id ->
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(athanor_id)
    "@" <> athanor.slug
  end

  # The setup device's record: the seed its key is drawn from and what it
  # was certified as, readable by this user alone, in the
  # server's working directory, a release cell's own, or, where that is not
  # this user's to write (an image's /app), the server's temporary one.
  device_path =
    Enum.find_value([File.cwd!(), System.tmp_dir!()], fn dir ->
      path = Path.join(dir, "setup-device.json")
      if File.exists?(path), do: path
    end) ||
      Enum.find_value([File.cwd!(), System.tmp_dir!()], fn dir ->
        case File.stat(dir) do
          {:ok, %{access: access}} when access in [:write, :read_write] ->
            Path.join(dir, "setup-device.json")

          _other ->
            nil
        end
      end)

  write_device = fn device, create? ->
    modes = if create?, do: [:write, :exclusive], else: [:write]
    {:ok, file} = File.open(device_path, modes)
    :ok = File.chmod(device_path, 0o600)
    :ok = IO.binwrite(file, Jason.encode!(device))
    :ok = File.close(file)
  end

  # The device a record already kept names, to be made again: its seed
  # and client, for this home alone; nil where no record is kept.
  kept_device = fn ->
    if File.exists?(device_path) do
      with {:ok, text} <- File.read(device_path),
           {:ok, %{"seed" => seed, "client_id" => client_id} = kept} <- Jason.decode(text),
           {:ok, <<_::binary-size(32)>> = seed} <- Base.url_decode64(seed, padding: false),
           true <- kept["home"] == Sanctum.origin() do
        %{seed: seed, client_id: client_id}
      else
        _another ->
          raise "#{device_path} names no device of this home's setup; remove it to make a new one"
      end
    end
  end

  keep_device = fn user_id, client_id, seed, create? ->
    {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(user_id)
    actor = Prima.Actor.in_athanor(athanor_id)
    {:ok, row} = Arca.DeviceCertificates.current(actor, client_id)

    write_device.(
      %{
        seed: Base.url_encode64(seed, padding: false),
        client_id: client_id,
        athanor_id: athanor_id,
        home: Sanctum.origin(),
        certificate: Jason.decode!(row.certificate)
      },
      create?
    )
  end

  # The account SUB names, with the device key `device_pub` listed: a
  # genesis signed by the recovery key SUB derives, at this deployment's
  # directory, and the key added by it. The genesis is SUB's alone, so its
  # identifier is; the head is the device's.
  account = fn sub, device_pub ->
    alias Prima.Identity
    alias Prima.Identity.{Entry, Key}

    directory =
      Sanctum.directory_url() ||
        raise "this deployment names no directory (CYFR_DIRECTORY_URL): an account needs one"

    {recovery_pub, recovery} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, ["release-proof|", sub]))

    signer = Identity.recovery_signer(recovery_pub)
    at = 1_700_000_000_000

    {:ok, genesis} =
      Entry.new(
        kind: :genesis,
        seq: 0,
        at: at,
        signer: signer,
        directory: directory,
        recovery: [recovery_pub]
      )

    genesis = Identity.sign(genesis, recovery)
    {:ok, key} = Key.new(alg: :ed25519, kind: :device, pub: device_pub)

    {:ok, added} =
      Entry.new(
        kind: :add_key,
        prev: Identity.hash(genesis),
        seq: 1,
        at: at,
        signer: signer,
        key: key
      )

    added = Identity.sign(added, recovery)
    {:ok, state} = Identity.verify_chain([genesis, added])

    %{
      identifier: state.identifier,
      directory_url: directory,
      head_hash: state.head,
      key: key,
      genesis: Identity.canonical(genesis),
      added: Identity.canonical(added),
      state: state |> Identity.State.encode() |> Jason.encode!(),
      keys_added: Sanctum.IdentityFreshness.keys_added([genesis, added])
    }
  end

  # The account published at its directory, as the account pages publish
  # one: the genesis registered, then the key appended after it. Each
  # answers `:exists` for an entry already there, so an account published
  # once is found as written. Never at cyfr.run (the `person` command).
  published = fn account ->
    alias Sanctum.Directory.Client

    unless URI.parse(account.directory_url).host == "cyfr.run" do
      {:ok, _registered} = Client.register(account.genesis)
      {:ok, _appended} = Client.append(account.identifier, account.directory_url, account.added)
    end

    account
  end

  # The account's head cached here as a first read leaves it, before it is
  # admitted.
  cached = fn account ->
    {:ok, _head} =
      Arca.DirectoryHeads.put(
        Prima.Actor.system(),
        Map.take(account, [:identifier, :genesis, :directory_url, :head_hash, :state, :keys_added])
      )

    Map.take(account, [:identifier, :directory_url, :head_hash])
  end

  # The setup admission (`Sanctum.Newcomer.admit/3`) under a setup token
  # put for this call alone, the setup device paired in it as its hello
  # pairs one: the installation's configured token, if it has one, is put
  # back however the admission ends.
  setup = fn sub, name ->
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    configured = Application.fetch_env(:sanctum, :setup_token)
    Application.put_env(:sanctum, :setup_token, token)

    kept = kept_device.()
    seed = if kept, do: kept.seed, else: :crypto.strong_rand_bytes(32)
    {device_pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    client_id = if kept, do: kept.client_id, else: Prima.UUID7.generate_id("pcl")
    account = published.(account.(sub, device_pub))
    device = %{client_id: client_id, holder_kind: "software", display_name: name}

    try do
      with {:ok, %{person: person} = admitted} <-
             Sanctum.Newcomer.admit({:setup, token}, cached.(account),
               also: &Sanctum.DeviceUnlock.pair(&1, device, account.key, account.head_hash)
             ) do
        :ok = keep_device.(person.id, client_id, seed, is_nil(kept))
        {:ok, Map.put(admitted, :account, account)}
      end
    after
      case configured do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end
  end

  # The person of the account SUB names, made the first time (the `person`
  # command above), and the account's identifier, head and device key. The
  # setup admission makes the installation's first person
  # (`Arca.InstallationClaims.setup/1` says whether this is it), and the
  # open admission every later one, past a door whose `*` admits. A person
  # made before is the account as this CYFR caches it, and the one device
  # key it lists: the setup device's, or the key SUB derives.
  admitted = fn sub ->
    system = Prima.Actor.system()

    {device_pub, _} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, ["release-device|", sub]))

    known = account.(sub, device_pub)

    case Sanctum.Tenancy.Users.get_by_identifier(known.identifier) do
      {:ok, person} ->
        {:ok, head} = Arca.DirectoryHeads.get(system, known.identifier)
        {:ok, state} = head.state |> Jason.decode!() |> Prima.Identity.State.decode()
        [key] = Enum.filter(state.keys, &(&1.kind == :device))
        {person, %{identifier: known.identifier, head_hash: head.head_hash, key: key}}

      {:error, :not_found} ->
        case Arca.InstallationClaims.setup(system) do
          {:ok, :first} ->
            {:ok, %{person: person, account: account}} = setup.(sub, "release-proof")
            {:ok, _} = Arca.Users.set_namespace(system, person.id, "release-proof")
            {person, account}

          {:ok, :closed} ->
            unless Sanctum.Door.Store.wildcard() == {:ok, true},
              do: raise("the door's * admits no newcomer: allow * before a second person")

            {:ok, %{person: person}} = Sanctum.Newcomer.admit(:open, cached.(published.(known)))

            {person, known}
        end
    end
  end

  # Returns once no fill holds the context's athanor. The sign-in takes
  # the athanor's claim before it answers and fills it in the background,
  # copying the shipped units into `components/`; while a unit's move is
  # pending, every read of the components projection behind
  # `Compendium.ProjectionReconciler.await/2` answers
  # `:projection_unavailable`, and the `/t/` route answers 503. The fill
  # ends in a write to the athanor's row, which announces `:athanor_changed`
  # (`Sanctum.Provisioning.mark_filled/1`, `record_failure/4`), so the wait
  # is on that announcement, attached before the status is read, under one
  # deadline.
  fill_settled = fn ctx ->
    me = self()
    handler = {:release_boot_fill, make_ref()}
    athanor_id = ctx.athanor_id

    :telemetry.attach(
      handler,
      [:cyfr, :sanctum, :notify],
      fn _event, _measurements, %{athanor_id: id, kind: kind}, _config ->
        if id == athanor_id and kind == :athanor_changed, do: send(me, {handler, :changed})
      end,
      nil
    )

    deadline = System.monotonic_time(:millisecond) + 120_000

    settle = fn settle ->
      case Sanctum.Provisioning.status(ctx) do
        :filling ->
          receive do
            {^handler, :changed} -> settle.(settle)
          after
            max(deadline - System.monotonic_time(:millisecond), 0) ->
              raise "the fill of #{athanor_id} still holds it after 120 s"
          end

        :unavailable ->
          raise "the fill of #{athanor_id} could not be read"

        _ready_unfilled_or_failed ->
          :ok
      end
    end

    try do
      settle.(settle)
    after
      :telemetry.detach(handler)
    end
  end

  # The setup device's channel, as `Emissary.Web.DeviceChannel` holds one:
  # its context once its `connect` proof is decided, the certificate it
  # stands under renewed first when it is past its life.
  device_channel = fn ->
    alias Prima.DeviceCert
    alias Prima.DeviceCert.{Challenge, Proof}

    device = device_path |> File.read!() |> Jason.decode!()
    {:ok, seed} = Base.url_decode64(device["seed"], padding: false)
    {device_key, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, certificate} = DeviceCert.decode(device["certificate"])
    client_id = device["client_id"]

    base =
      Sanctum.Context.build(
        request_id: Prima.UUID7.request_id(),
        client_ip: "127.0.0.1",
        origin: :interactive
      )

    proven = fn purpose, certificate ->
      {:ok, challenge} =
        Challenge.new(
          purpose: purpose,
          home: certificate.audience,
          athanor: certificate.athanor,
          client_id: client_id,
          device_key: device_key,
          nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
          now: System.system_time(:millisecond)
        )

      proof = Proof.sign(challenge, seed)
      connection = %{client_id: client_id, certificate: certificate, source: base.client_ip}
      {Sanctum.DeviceCerts.verify_connect(connection, proof, challenge), proof}
    end

    carried = fn client ->
      %{
        client
        | request_id: base.request_id,
          client_ip: base.client_ip,
          call_id: Prima.UUID7.generate_id("call"),
          confirmation_id: nil,
          origin: :interactive
      }
    end

    case proven.(:connect, certificate) do
      {{:ok, client}, _proof} ->
        {carried.(client), certificate, {device_key, seed}}

      {{:error, :expired}, _proof} ->
        {{:ok, client}, proof} = proven.(:renew, certificate)
        ctx = carried.(client)

        {:ok, %{certificate: issued}} =
          Sanctum.Gate.call_external(
            "pairing",
            ctx,
            %{
              "action" => "renew",
              "client_id" => client_id,
              "device_key" => Prima.Identity.Encoding.b64(device_key),
              "proof" => Proof.encode(proof)
            },
            call_id: ctx.call_id,
            method: "device/renew"
          )

        {:ok, renewed} = DeviceCert.decode(issued)
        :ok = write_device.(Map.put(device, "certificate", issued), false)

        case proven.(:connect, renewed) do
          {{:ok, client}, _proof} ->
            {carried.(client), renewed, {device_key, seed}}

          {refused, _proof} ->
            raise "the renewed setup device did not connect: #{inspect(refused)}"
        end

      {refused, _proof} ->
        raise "the setup device did not connect: #{inspect(refused)}"
    end
  end

  # One intent on the device's channel, through the gate as the channel
  # dispatches it, under a call id of its own.
  device_intent = fn ctx, tool, args ->
    ctx = %{ctx | call_id: Prima.UUID7.generate_id("call")}
    Sanctum.Gate.call_external(tool, ctx, args, call_id: ctx.call_id, method: "device/intent")
  end

  case args do
    ["device_confirm", ref | tamper] when tamper in [[], ["digest"], ["ref"], ["key"]] ->
      alias Prima.SignIn.DeviceAnswer
      {ctx, _certificate, {device_key, seed}} = device_channel.()
      kid = Prima.Identity.Key.kid(device_key)

      with {:ok, %{confirmations: [%{ref: ^ref} = record]}} <-
             device_intent.(ctx, "confirmation", %{"action" => "pending", "request" => ref}),
           {:ok, %{request: encoded}} <-
             device_intent.(ctx, "confirmation", %{"action" => "request", "ref" => ref}) do
        {:ok, request} = Prima.SignIn.decode(encoded)
        sign = fn digest, key -> :crypto.sign(:eddsa, :none, digest, [key, :ed25519]) end

        {answer_ref, signed} =
          case tamper do
            [] ->
              {ref, DeviceAnswer.sign(request, kid, seed)}

            ["digest"] ->
              {ref,
               %DeviceAnswer{
                 challenge: request.challenge,
                 kid: kid,
                 sig: sign.(:crypto.hash(:sha256, "another digest"), seed)
               }}

            ["ref"] ->
              {"cnr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
               DeviceAnswer.sign(request, kid, seed)}

            ["key"] ->
              {ref,
               %DeviceAnswer{
                 challenge: request.challenge,
                 kid: kid,
                 sig: sign.(Prima.SignIn.digest(request), :crypto.strong_rand_bytes(32))
               }}
          end

        confirmed =
          device_intent.(ctx, "confirmation", %{
            "action" => "confirm",
            "ref" => answer_ref,
            "answer" => DeviceAnswer.encode(signed)
          })

        answer.(
          Map.merge(
            %{operation: record.operation, preview: record.preview, digest: request.subject},
            case confirmed do
              {:ok, result} -> %{ok: result}
              {:error, reason} -> %{error: inspect(reason)}
            end
          )
        )
      else
        {:ok, %{confirmations: records}} ->
          answer.(%{error: "no one open record of #{ref}: #{length(records)}"})

        {:error, reason} ->
          answer.(%{error: inspect(reason)})
      end

    ["person", email, sub | name] when length(name) <= 1 ->
      {person, account} = admitted.(sub)
      system = Prima.Actor.system()

      {:ok, _} =
        Arca.Users.update(system, person.id, %{
          email: email,
          email_verified: true,
          display_name: List.first(name, "Release proof")
        })

      {:ok, :allowed} = Sanctum.Door.sign_in(person)
      :ok = Sanctum.Provisioning.after_sign_in(person.id)
      ctx = person_ctx.(person.id)

      {:ok, session} =
        Sanctum.Session.create(ctx, kid: account.key.kid, head: account.head_hash)

      answer.(%{
        user_id: person.id,
        athanor_id: ctx.athanor_id,
        segment: segment.(ctx.athanor_id),
        token: session.token
      })

    ["tincture", user_id, dir, name, visibility] when visibility in ["public", "private"] ->
      ctx = person_ctx.(user_id)
      actor = Sanctum.Context.actor(ctx)
      unit = ["components", "tinctures", "local", name, "1.0.0"]
      :ok = fill_settled.(ctx)

      # One commit of the whole unit, its row and its revision, as a
      # local build lands one (`Arca.Overlay.commit_unit/4`): a plain write
      # under `components/` needs a unit already committed there.
      files =
        for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: false),
            File.regular?(file),
            do: {Path.split(Path.relative_to(file, dir)), File.read!(file)}

      {:ok, _written} = Arca.Overlay.commit_unit(actor, unit, {:files, files}, cap: :exempt)

      {:ok, component} = Compendium.Registry.register_from_arca(ctx, unit, force: true)

      ref = Prima.ComponentRef.build("tincture", "local", name)
      {:ok, profiles} = Arca.ConsentStorage.profiles(actor, ref)
      public? = Enum.any?(profiles, &(&1.kind == :public and &1.status == :active))

      # The release refuses the consent walk's first step here, the plan:
      # `{:unavailable, "Components"}`, because the components projection
      # is still behind the units the sign-in's seeding just copied
      # (`Compendium.ProjectionReconciler`'s read barrier answers
      # `:projection_unavailable` and never waits). So the profile the walk
      # would leave is written as the suite writes it: a release compiles
      # no test support, and the writer is loaded from the checkout, here
      # and nowhere else, so a copy of this file that runs the other
      # commands needs none of it.
      if visibility == "public" and not public? do
        Code.require_file(Path.expand("../../apps/arca/test/support/writers.ex", __DIR__))

        {:ok, _profile} =
          Arca.Test.Writers.put_profile(%{
            id: "prof_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
            athanor_id: ctx.athanor_id,
            source_ref: "tincture:local.#{name}",
            kind: "public",
            label: "public",
            status: "active"
          })
      end

      if visibility == "public" do
        {:ok, profiles} = Arca.ConsentStorage.profiles(actor, ref)

        unless Enum.any?(profiles, &(&1.kind == :public and &1.status == :active)),
          do: raise("tincture #{ref} holds no active public profile")

        # The `/t/` route's own read (`Emissary.Web.TinctureController`):
        # the address answers what this answers.
        {:ok, public_ctx} = Sanctum.TinctureAccess.public_context(segment.(ctx.athanor_id))

        case Sanctum.TinctureAccess.get_public(public_ctx, "local", name) do
          {:ok, _tincture} -> :ok
          other -> raise "tincture #{ref} is not served at its address: #{inspect(other)}"
        end
      end

      answer.(%{
        name: name,
        path: Prima.TinctureUrl.path(segment.(ctx.athanor_id), "local", name),
        component: is_map(component) and Map.get(component, :id)
      })

    ["grant", token, name | version] when length(version) <= 1 ->
      {:ok, console} = Sanctum.Caller.establish({:session, token})
      ctx = %{console | origin: :interactive}
      ref = "tincture:local." <> name
      pinned = ref <> ":" <> List.first(version, "1.0.0")

      # The components projection may still be behind the unit the proof
      # just wrote, which the plan and the open's read answer as unavailable
      # rather than waiting: each is asked again, for up to ten seconds.
      settled = fn ask ->
        Enum.reduce_while(1..100, nil, fn _try, _ ->
          case ask.() do
            {:error, :unavailable} ->
              Process.sleep(100)
              {:cont, nil}

            {:error, {:unavailable, _what}} ->
              Process.sleep(100)
              {:cont, nil}

            answered ->
              {:halt, answered}
          end
        end) || raise("#{ref} was unavailable for ten seconds")
      end

      opens = fn -> settled.(fn -> Compendium.tincture_grant_revision(ctx, pinned) end) end

      committed =
        case opens.() do
          {:ok, _revision} ->
            false

          {:error, :ungranted} ->
            decisions = %{ref: ref, origins: [:interactive]}
            {:ok, plan} = settled.(fn -> Sanctum.Consent.Plan.plan(ctx, %{ref: ref}) end)

            {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

            {:ok, _committed} =
              Sanctum.Consent.Commit.commit(ctx, %{
                decisions: decisions,
                plan_token: plan.plan_token,
                proof: preview.proof,
                commit_digest: preview.commit_digest,
                expected_consent_revision: plan.expected_consent_revision
              })

            true
        end

      case opens.() do
        {:ok, revision} -> answer.(%{revision: revision, committed: committed})
        other -> raise "#{pinned} opens under no grant after the walk: #{inspect(other)}"
      end

    ["console", token, tool, arguments] ->
      # What the console does when the person runs a tool: the session
      # established as a request establishes it, then the console's adapter
      # onto the operation catalog, through the one gate.
      {:ok, ctx} = Sanctum.Caller.establish({:session, token})

      case PrismWeb.Ops.call_tool(ctx, tool, Jason.decode!(arguments)) do
        {:ok, result} -> answer.(%{ok: result})
        {:error, reason} -> answer.(%{error: inspect(reason)})
      end

    ["vault", token, name, field, value] ->
      {:ok, ctx} = Sanctum.Caller.establish({:session, token})
      id = Prima.UUID7.generate_id("vlt")
      {:ok, json} = Sanctum.Vault.Payload.encode_material(%{field => value})
      aad = Sanctum.CipherAAD.vault_entry(Sanctum.Context.athanor!(ctx), id, "")
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

      # Every entry names where it may go. A proof hands this one's value
      # to a backend's environment, a disclosure, so it is disclosed.
      {:ok, destination} = Sanctum.Vault.destination_text(%{"hosts" => ["fixture.test"]})

      binding = %{
        provider_hint: "",
        field_names: Jason.encode!([field]),
        oauth_endpoints: nil,
        oauth_scopes: nil,
        destination: destination,
        attach_only: false
      }

      {:ok, digest} = Sanctum.VaultReader.binding_digest(binding)

      {:ok, entry} =
        Arca.VaultStorage.put(
          Sanctum.Context.actor(ctx),
          Map.merge(binding, %{
            id: id,
            name: name,
            kind: "api_key",
            status: "active",
            sealed_payload: sealed,
            binding_digest: digest
          })
        )

      answer.(%{id: entry.id, name: entry.name})

    ["thread", user_id, text] ->
      ctx = person_ctx.(user_id)
      actor = Sanctum.Context.actor(ctx)
      {:ok, thread} = Arca.ThreadStorage.create(actor)

      # The person's own message, sent as a person's send is.
      {:ok, _message} =
        Arca.ThreadStorage.append(actor, thread.id, %{
          author: user_id,
          sent_by: Aqua.Runner.Admission.person(),
          content: text
        })

      answer.(%{thread_id: thread.id, athanor_id: ctx.athanor_id})
  end
end
