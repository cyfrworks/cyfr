# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the release proofs put in a running server, evaluated inside it by
# `bin/cyfr rpc` (`server_fixture` in tests/release-boot/release.sh). The
# file evaluates to a function of the argument list; each command prints
# nothing and answers one line, `FIXTURE=` and a JSON object.
#
#   person SUB
#       The person of the account SUB names, made as the product makes a
#       device-first person, and signed in again by the same door. The
#       account is built here as `cyfr login --setup` builds one: a genesis
#       signed by a recovery key SUB derives, at this deployment's
#       directory (`Sanctum.directory_url/0`), and one device key added;
#       published there as it publishes one (`Sanctum.Directory.Client`:
#       the genesis registered, the key appended, each answering `:exists`
#       for an entry already there); and the name SUB claimed for it at
#       this deployment's registry (`handle.claim` signed by the recovery
#       key, the registry's policy accepted first when the registry asks,
#       `Compendium.Registry.Client.signed/2`). Then the device's hello,
#       as its channel takes one (`Sanctum.DeviceUnlock.hello/2` and
#       `admit/2`, the calls `Emissary.Web.DeviceChannel` makes, under a
#       client id reserved as it reserves one): the device signs the
#       sign-in request with its key, and the CYFR verifies the answer
#       against the account's log, admits the person, learns their name
#       from the registry, pairs the device and starts their athanor's
#       fill. An installation's first person, its platform administrator,
#       comes in under the setup token (one the fixture puts for the call
#       and takes away after); every later one through the door, once its
#       `*` admits newcomers, which the proof opens as an administrator
#       does (`door.allow`). A person made before comes in by the same
#       hello: the door admits them and their standing device is given a
#       new certificate. Nothing is sent to cyfr.run, which holds real
#       people's accounts: where the deployment's directory is cyfr.run, or
#       one its egress refuses (the compose proof's and the Locus image
#       tests' deployments name one, so that no read of theirs leaves the
#       machine), the account is cached here alone, as a first read leaves
#       it, and its person pauses past the bound on a public home; where its
#       registry is cyfr.run, or its directory holds no account, no name is
#       claimed.
#
#       The device's key is an Ed25519 seed: drawn here for the
#       installation's first person, and SUB's own for every later one, so
#       a later SUB is the same account at every cell that reads one
#       directory. Its record (the seed, the paired client, its athanor,
#       home and certificate) is written to `device-IDENTIFIER.json` in
#       the server's working directory (a release cell's own; an image's
#       temporary directory where its working directory is not the
#       server's to write), with mode 0600, and is never answered, taken as
#       an argument or logged: `device_confirm` and `confirmed` alone read
#       it. A record already there for the account is that device, whose
#       seed the hello uses again (an installation started over in the same
#       directory), and it is written back with the new client and
#       certificate; one that does not read, or names another home,
#       refuses the person.
#
#       The browser session is minted below the door, bound to the
#       account's device key and the head this CYFR holds
#       (`Sanctum.Session.create/2`): a device-first person's own browser
#       session is the device unlock's, which lives 60 s and which only the
#       device's open channel slides. Answers the person, the athanor the
#       session is focused on, the route segment of that athanor and the
#       session token.
#
#   device_confirm REF [digest|ref|key]
#       The confirmation REF given by the person's own device, as its
#       channel gives one (`Emissary.Web.DeviceChannel`): of the devices
#       this fixture paired at this home, the one whose person the record
#       is, found as each finds its own person's records. A `connect`
#       challenge for the certificate in its record, signed with its seed
#       and decided by `Sanctum.DeviceCerts.verify_connect/3` (a
#       certificate past its life renewed first, as the channel renews
#       one, `pairing.renew` through the gate, the replacement written
#       back; a device that no longer connects is passed over), the record
#       read through the gate as a device intent (`confirmation.pending`
#       with the `request`, which answers its stored preview), this CYFR's
#       `confirm` request for it (`confirmation.request`, whose subject is
#       the record's digest), and the device's answer to it, Ed25519 over
#       the request's digest, given through the gate
#       (`confirmation.confirm` with the `answer`). Each intent is checked
#       as the channel checks one first: its certificate and the client's
#       standing read now (`Sanctum.DeviceCerts.verify_request/2`). With
#       `digest`, `ref`, `key` or `other` the answer is made wrong on
#       purpose: over another digest (a changed record), under another ref,
#       by a key of no device, or by another person's device kept at this
#       home; the home must refuse it.
#       Answers the record's operation and preview as the home stored them
#       and the digest its request names, and `ok` with the confirmation's
#       result or `error` with the refusal; a ref no device here holds
#       answers `error`.
#
#   confirmed SESSION_TOKEN TOOL ARGUMENTS_JSON [refused]
#       TOOL called as `console` calls it, and, when the change asks for a
#       fresh confirmation, the confirmation given by the person's own
#       device (`device_confirm`) and the call made again under it, as the
#       console repeats a change once its record is confirmed. With
#       `refused`, the two wrong answers a person can meet are given first,
#       another person's device's (`device_confirm`'s `other`) and one over
#       a changed record (`digest`), each answering the home's refusal or
#       nothing where it was taken. Answers `ok` and the result, with
#       `refused` the two refusals, or `error` and the refusal.
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
#       session is focused on, bound to the destination `fixture.test` and
#       disclosed, entered as the person enters one (`vault.create`, the
#       sensitive change confirmed by their own device, `confirmed`): a
#       proof hands its value to a backend's environment
#       (`tests/locus-backends-image/e2e.py`). Answers the entry's id and
#       name.
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

  # Where this fixture keeps the devices it pairs: the server's working
  # directory, a release cell's own, or, where that is not this user's to
  # write (an image's /app), the server's temporary one. Each record is
  # readable by this user alone.
  device_dir =
    Enum.find([File.cwd!(), System.tmp_dir!()], fn dir ->
      match?({:ok, %{access: access}} when access in [:write, :read_write], File.stat(dir))
    end) || raise "neither the working nor the temporary directory is this server's to write"

  device_path = fn identifier -> Path.join(device_dir, "device-#{identifier}.json") end

  write_device = fn path, device ->
    {:ok, file} = File.open(path, [:write])
    :ok = File.chmod(path, 0o600)
    :ok = IO.binwrite(file, Jason.encode!(device))
    :ok = File.close(file)
  end

  # The seed of the device a record already kept for the account names,
  # to be used again, for this home alone; nil where no record is kept.
  kept_seed = fn identifier ->
    path = device_path.(identifier)

    if File.exists?(path) do
      with {:ok, text} <- File.read(path),
           {:ok, %{"seed" => seed} = kept} <- Jason.decode(text),
           {:ok, <<_::binary-size(32)>> = seed} <- Base.url_decode64(seed, padding: false),
           true <- kept["home"] == Sanctum.origin() do
        seed
      else
        _another ->
          raise "#{path} names no device of this home; remove it to make a new one"
      end
    end
  end

  keep_device = fn person, identifier, client_id, seed ->
    {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(person.id)
    actor = Prima.Actor.in_athanor(athanor_id)
    {:ok, row} = Arca.DeviceCertificates.current(actor, client_id)

    write_device.(device_path.(identifier), %{
      seed: Base.url_encode64(seed, padding: false),
      client_id: client_id,
      athanor_id: athanor_id,
      home: Sanctum.origin(),
      certificate: Jason.decode!(row.certificate)
    })
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
      signer: signer,
      recovery: recovery,
      genesis: Identity.canonical(genesis),
      added: Identity.canonical(added),
      state: state |> Identity.State.encode() |> Jason.encode!(),
      keys_added: Sanctum.IdentityFreshness.keys_added([genesis, added])
    }
  end

  # The account published at its directory, as the account pages publish
  # one: the genesis registered, then the key appended after it. Each
  # answers `:exists` for an entry already there, so an account published
  # once is found as written. At cyfr.run, which is never asked, and at a
  # directory this deployment's egress refuses, so that nothing leaves the
  # machine, the account's head is cached here alone, as a first read
  # leaves it. Answers the account with `published?`, whether its
  # directory holds it.
  published = fn account ->
    alias Sanctum.Directory.Client

    cache_alone = fn ->
      {:ok, _head} =
        Arca.DirectoryHeads.put(
          Prima.Actor.system(),
          Map.take(account, [
            :identifier,
            :genesis,
            :directory_url,
            :head_hash,
            :state,
            :keys_added
          ])
        )
    end

    published? =
      if URI.parse(account.directory_url).host == "cyfr.run" do
        cache_alone.()
        false
      else
        case Client.register(account.genesis) do
          {:ok, _registered} ->
            {:ok, _appended} =
              Client.append(account.identifier, account.directory_url, account.added)

            true

          {:error, :egress_refused} ->
            cache_alone.()
            false

          refused ->
            raise "#{account.directory_url} did not take #{account.identifier}: #{inspect(refused)}"
        end
      end

    Map.put(account, :published?, published?)
  end

  # The name SUB claimed for the account at this deployment's registry, as
  # an account's birth claims one: `handle.claim` signed by its recovery
  # key, after `policy.accept` of the version the registry asks for. An
  # account its directory does not hold has no name a registry would give
  # it, and a deployment that names cyfr.run gets no claim: its person has
  # no name.
  named = fn account, sub ->
    case {account.published?, Sanctum.registry_host()} do
      {true, host} when host != "cyfr.run" ->
        send_signed = fn operation, body ->
          {:ok, request} =
            Prima.RegistryRequest.new(
              registry: host,
              operation: operation,
              identifier: account.identifier,
              signer: account.signer,
              nonce: :crypto.strong_rand_bytes(Prima.RegistryRequest.nonce_bytes()),
              expires_at: System.system_time(:millisecond) + Prima.RegistryRequest.lifetime_ms(),
              body: body
            )

          {:ok, bytes} = Prima.RegistryRequest.sign(request, account.recovery)
          Compendium.Registry.Client.signed(operation, bytes)
        end

        claim = fn -> send_signed.("handle.claim", %{"handle" => sub}) end

        case claim.() do
          {:ok, _claimed} ->
            :ok

          {:error, {:policy_required, version}} when is_binary(version) ->
            {:ok, _accepted} = send_signed.("policy.accept", %{"policy_version" => version})
            {:ok, _claimed} = claim.()
            :ok

          refused ->
            raise "the registry gave #{account.identifier} no name #{sub}: #{inspect(refused)}"
        end

      _unnamed ->
        :ok
    end
  end

  # The device's hello on its channel's door, under a client id reserved
  # as the channel reserves one, answered with its key: the person
  # admitted (under `admission`, or by the door), their name learned, the
  # device paired. Answers the paired client's id.
  hello = fn account, seed, admission ->
    client_id = Prima.UUID7.generate_id("pcl")

    said = %{
      kid: account.key.kid,
      identifier: account.identifier,
      holder_kind: "software",
      display_name: "Release proof",
      admission: admission
    }

    with {:ok, request} <- Sanctum.DeviceUnlock.hello(client_id, said),
         answer = Prima.SignIn.DeviceAnswer.sign(request, account.key.kid, seed),
         {:ok, %{client_id: paired}} <- Sanctum.DeviceUnlock.admit(client_id, answer) do
      paired
    else
      {:error, {:door, reason}} ->
        raise "the door admitted no #{account.identifier} (#{inspect(reason)}): allow * before a second person"

      {:error, reason} ->
        raise "the hello of #{account.identifier}'s device was refused: #{inspect(reason)}"
    end
  end

  # The person of the account SUB names (the `person` command above), and
  # the account. The installation's first person
  # (`Arca.InstallationClaims.setup/1` says whether this is it) comes in
  # under a setup token put for this call alone, the installation's own,
  # if it has one, put back however the hello ends; every later one by
  # the door.
  admitted = fn sub ->
    system = Prima.Actor.system()

    {derived_pub, derived} =
      :crypto.generate_key(:eddsa, :ed25519, :crypto.hash(:sha256, ["release-device|", sub]))

    identifier = account.(sub, derived_pub).identifier
    first? = Arca.InstallationClaims.setup(system) == {:ok, :first}

    seed =
      kept_seed.(identifier) ||
        if(first?, do: :crypto.strong_rand_bytes(32), else: derived)

    {device_pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    account = published.(account.(sub, device_pub))
    :ok = named.(account, sub)

    client_id =
      if first? do
        token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        configured = Application.fetch_env(:sanctum, :setup_token)
        Application.put_env(:sanctum, :setup_token, token)

        try do
          hello.(account, seed, {:setup, token})
        after
          case configured do
            {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
            :error -> Application.delete_env(:sanctum, :setup_token)
          end
        end
      else
        hello.(account, seed, nil)
      end

    {:ok, person} = Sanctum.Tenancy.Users.get_by_identifier(identifier)
    :ok = keep_device.(person, identifier, client_id, seed)
    {:ok, head} = Arca.DirectoryHeads.get(system, identifier)
    {person, %{identifier: identifier, head_hash: head.head_hash, key: account.key}}
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

        :failed ->
          raise "the fill of #{athanor_id} failed"

        :unfilled ->
          raise "the fill of #{athanor_id} ended and left it unfilled"

        :ready ->
          :ok
      end
    end

    try do
      settle.(settle)
    after
      :telemetry.detach(handler)
    end
  end

  # A kept device's channel, as `Emissary.Web.DeviceChannel` holds one:
  # its context once its `connect` proof is decided, the certificate it
  # stands under renewed first when it is past its life; or the refusal
  # of a device that no longer connects.
  device_channel = fn path ->
    alias Prima.DeviceCert
    alias Prima.DeviceCert.{Challenge, Proof}

    device = path |> File.read!() |> Jason.decode!()
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
        {:ok, {carried.(client), certificate, {device_key, seed}}}

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
        :ok = write_device.(path, Map.put(device, "certificate", issued))

        case proven.(:connect, renewed) do
          {{:ok, client}, _proof} -> {:ok, {carried.(client), renewed, {device_key, seed}}}
          {refused, _proof} -> refused
        end

      {refused, _proof} ->
        refused
    end
  end

  # One intent on the device's channel, as the channel dispatches it: its
  # certificate and the client's standing read now
  # (`Sanctum.DeviceCerts.verify_request/2`), then through the gate under a
  # call id of its own.
  device_intent = fn ctx, certificate, tool, args ->
    with {:ok, client} <- Sanctum.DeviceCerts.verify_request(certificate, ctx) do
      client = %{
        client
        | request_id: ctx.request_id,
          client_ip: ctx.client_ip,
          call_id: Prima.UUID7.generate_id("call"),
          confirmation_id: nil,
          origin: :interactive
      }

      Sanctum.Gate.call_external(tool, client, args,
        call_id: client.call_id,
        method: "device/intent"
      )
    end
  end

  # A refusal as a proof compares it: a refusal's reason and the sentence
  # the person is shown, anything else as written.
  refusal = fn
    %Prima.Refusal{reason: reason, message: message} -> %{reason: reason, message: message}
    other -> inspect(other)
  end

  # The records of the devices this fixture kept for this home.
  kept_devices = fn ->
    device_dir
    |> Path.join("device-per_*.json")
    |> Path.wildcard()
    |> Enum.filter(
      &(&1 |> File.read!() |> Jason.decode!() |> Map.get("home") == Sanctum.origin())
    )
  end

  # The confirmation `ref` given by the device of the person whose record
  # it is (the `device_confirm` command above): each device this fixture
  # kept for this home connects and reads its own person's records, and
  # the one that finds the record answers it. Answers the command's map.
  confirm_ref = fn ref, tamper ->
    alias Prima.SignIn.DeviceAnswer

    holder =
      Enum.find_value(kept_devices.(), fn path ->
        with {:ok, {ctx, certificate, keys}} <- device_channel.(path),
             {:ok, %{confirmations: [%{ref: ^ref} = record]}} <-
               device_intent.(ctx, certificate, "confirmation", %{
                 "action" => "pending",
                 "request" => ref
               }) do
          {path, ctx, certificate, keys, record}
        else
          _not_its_own -> nil
        end
      end)

    case holder do
      nil ->
        %{error: "no device kept at this home holds #{ref}"}

      {path, ctx, certificate, {device_key, seed}, record} ->
        kid = Prima.Identity.Key.kid(device_key)

        case device_intent.(ctx, certificate, "confirmation", %{
               "action" => "request",
               "ref" => ref
             }) do
          {:ok, %{request: encoded}} ->
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

                ["other"] ->
                  other =
                    Enum.find(kept_devices.(), &(&1 != path)) ||
                      raise "no other person's device is kept at this home"

                  {:ok, other_seed} =
                    other
                    |> File.read!()
                    |> Jason.decode!()
                    |> Map.fetch!("seed")
                    |> Base.url_decode64(padding: false)

                  {other_key, ^other_seed} = :crypto.generate_key(:eddsa, :ed25519, other_seed)
                  {ref, DeviceAnswer.sign(request, Prima.Identity.Key.kid(other_key), other_seed)}
              end

            confirmed =
              device_intent.(ctx, certificate, "confirmation", %{
                "action" => "confirm",
                "ref" => answer_ref,
                "answer" => DeviceAnswer.encode(signed)
              })

            Map.merge(
              %{operation: record.operation, preview: record.preview, digest: request.subject},
              case confirmed do
                {:ok, result} -> %{ok: result}
                {:error, reason} -> %{error: refusal.(reason)}
              end
            )

          {:error, reason} ->
            %{error: inspect(reason)}
        end
    end
  end

  # TOOL called as the console calls it under the session (the `confirmed`
  # command above): a change that asks for a fresh confirmation confirmed
  # by the person's own device, then called again under it. With
  # `refused?`, the two wrong answers are given first and their refusals
  # kept: another person's device's, and one over a changed record.
  confirmed_call = fn token, tool, arguments, refused? ->
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})

    case PrismWeb.Ops.call_tool(ctx, tool, arguments) do
      {:error, {:confirmation_required, %{id: id}}} ->
        ref = Prima.Confirmation.ref(id)

        refusals =
          if refused?,
            do:
              Map.new([other: ["other"], changed: ["digest"]], fn {name, tamper} ->
                {name, confirm_ref.(ref, tamper)[:error]}
              end),
            else: %{}

        case confirm_ref.(ref, []) do
          %{ok: _confirmed} ->
            case PrismWeb.Ops.call_tool(ctx, tool, arguments, confirmation_id: id) do
              {:ok, result} when refused? -> %{ok: result, refused: refusals}
              {:ok, result} -> %{ok: result}
              {:error, reason} -> %{error: inspect(reason)}
            end

          unconfirmed ->
            %{error: inspect({:unconfirmed, unconfirmed[:error]}), refused: refusals}
        end

      {:ok, result} ->
        %{ok: result}

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  case args do
    ["device_confirm", ref | tamper]
    when tamper in [[], ["digest"], ["ref"], ["key"], ["other"]] ->
      answer.(confirm_ref.(ref, tamper))

    ["confirmed", token, tool, arguments | refused] when refused in [[], ["refused"]] ->
      answer.(confirmed_call.(token, tool, Jason.decode!(arguments), refused == ["refused"]))

    ["person", sub] ->
      {person, account} = admitted.(sub)
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
      # Disclosed, since a proof hands this entry's value to a backend's
      # environment.
      case confirmed_call.(
             token,
             "vault/create",
             %{
               "name" => name,
               "kind" => "api_key",
               "fields" => %{field => value},
               "destination" => %{"hosts" => ["fixture.test"]},
               "disclose" => true
             },
             false
           ) do
        %{ok: %{entry: entry}} -> answer.(%{id: entry.id, name: entry.name})
        refused -> raise "the vault entry #{name} was not entered: #{inspect(refused)}"
      end

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
