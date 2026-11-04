# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the release proofs put in a running server, evaluated inside it by
# `bin/cyfr rpc` (`server_fixture` in tests/release-boot/release.sh). The
# file evaluates to a function of the argument list; each command prints
# nothing and answers one line, `FIXTURE=` and a JSON object.
#
#   person EMAIL SUB [NAME]
#       The person the GitHub identity SUB is linked to, made the first
#       time, then signed in with it as the device flow signs one in, from
#       the unlock on (`Sanctum.SignIn.unlock/1`: the door asked about the
#       person, the verified EMAIL and the name NAME, default "Release
#       proof", recorded on their row, the athanor read, the session):
#       everything but the identity provider, which the proofs cannot
#       reach. An installation's first person is made by the setup
#       admission (`Sanctum.Newcomer.admit/2`, with a protected device's
#       enrollment `{:device, enrollment, identity}` under a setup token
#       the fixture puts for the call and takes away after, the identity
#       drawn as a device draws it, named `release-proof`), and so is its
#       platform administrator: a device-first person, as a box's screen or
#       `cyfr login --setup` makes one. The device's key is an Ed25519 seed
#       drawn here; its public key is the one enrolled, and the device, its
#       certificate and the first-method mark the enrollment set all stand.
#       The seed is written to `setup-device.json` in the server's working
#       directory (a release cell's own; an image's temporary directory
#       where its working directory is not the server's to write), created
#       once with mode 0600, beside the
#       device's client, athanor, home and certificate, and is never
#       answered, taken as an argument or logged: `device_confirm` alone
#       reads it. Their enrollment is then finished through Arca with no
#       network: accepted as the directory's answer is recorded, its
#       recovery code saved and its name recorded on their row, so every
#       proof gets a finished person, and their first passkey is one the
#       setup device confirms. Every later person is made with the rows an open
#       admission writes (`Arca.Users.mint/4` under `open`, its caps
#       counted before the person's row, their keys, their athanor), once
#       the door's `*` admits newcomers, which the proof opens as an administrator does (`door.allow`); a sign-in
#       method is never an admission, so the identity is linked to the
#       person made. Answers the person, the athanor the session is
#       focused on, the route segment of that athanor and the session
#       token.
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
#       stored preview and the `confirm` challenge) and the proof over that
#       challenge given through the gate (`confirmation.confirm` with
#       `device_proof`). With `digest`, `ref` or `key` the proof is made
#       wrong on purpose: over another digest, over another ref, or by
#       another key; the home must refuse it. Answers the record's
#       operation, preview and digest as the home stored them, and `ok`
#       with the confirmation's result or `error` with the refusal; no
#       record of that ref answers `error`.
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
        provider: "github",
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
  # was certified as, created once and readable by this user alone, in the
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

  keep_device = fn enrollment, seed ->
    actor = Prima.Actor.in_athanor(enrollment.athanor_id)
    {:ok, row} = Arca.DeviceCertificates.current(actor, enrollment.client_id)

    write_device.(
      %{
        seed: Base.url_encode64(seed, padding: false),
        client_id: enrollment.client_id,
        athanor_id: enrollment.athanor_id,
        home: Sanctum.Person.home(),
        certificate: Jason.decode!(row.certificate)
      },
      true
    )
  end

  # The setup admission (`Sanctum.Newcomer.admit/2`) under a setup token
  # put for this call alone, with a protected device's enrollment, as
  # `Sanctum.DeviceUnlock` hands it to the admission once its proof
  # verified, and the identity a device draws: the installation's
  # configured token, if it has one, is put back however the admission
  # ends.
  setup = fn name ->
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    configured = Application.fetch_env(:sanctum, :setup_token)
    Application.put_env(:sanctum, :setup_token, token)

    identity = %{
      name: "release-proof",
      recovery_secret: :crypto.strong_rand_bytes(32),
      request_id: "req_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }

    seed = :crypto.strong_rand_bytes(32)
    {device_key, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

    enrollment = %{
      athanor_id: Prima.UUID7.generate_id("ath"),
      client_id: Prima.UUID7.generate_id("pcl"),
      device_key: device_key,
      request_id: identity.request_id,
      holder_kind: "software",
      display_name: name,
      user_id: nil
    }

    try do
      with {:ok, admitted} <-
             Sanctum.Newcomer.admit({:setup, token}, {:device, enrollment, identity}) do
        :ok = keep_device.(enrollment, seed)
        {:ok, admitted}
      end
    after
      case configured do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end
  end

  # The enrollment the setup admission opened, finished with no network:
  # accepted as the directory's answer is recorded, its recovery code
  # saved and its name recorded on the person's row.
  finished = fn user_id, %{attempt_id: attempt_id, name: name} ->
    system = Prima.Actor.system()
    {:ok, _} = Arca.IdentityAttempts.advance(system, attempt_id, "staged", "submitted")

    {:ok, _} =
      Arca.IdentityAttempts.advance(system, attempt_id, "submitted", "accepted", %{
        outcome: "accepted"
      })

    {:ok, %{phase: "completed"}} = Arca.IdentityAttempts.acknowledge_kit(system, attempt_id)
    {:ok, _} = Arca.Users.set_namespace(system, user_id, name)
    :ok
  end

  # The person the identity `key` is linked to, made the first time (the
  # `person` command above). The setup admission makes the installation's
  # first person and refuses every later one (`:setup_closed`), which an
  # open admission's rows then make, past a door whose `*` admits.
  admitted = fn key ->
    system = Prima.Actor.system()

    {:ok, %{provider: provider, issuer: issuer, subject: subject}} =
      Sanctum.Auth.Identity.parse(key)

    link = %{key: key, provider: provider, issuer: issuer, subject: subject}

    case Sanctum.Tenancy.Users.get_by_identity(key) do
      {:ok, _person} ->
        :ok

      {:error, :not_found} ->
        case setup.("release-proof") do
          {:ok, %{person: person, readmitted: false, recovery: recovery}} ->
            :ok = finished.(person.id, recovery)
            {:ok, %{linked: true}} = Arca.Users.link_identity(system, person.id, link)
            :ok

          {:error, :setup_closed} ->
            unless Sanctum.Door.Store.wildcard() == {:ok, true},
              do: raise("the door's * admits no newcomer: allow * before a second person")

            now = DateTime.utc_now()

            person = %{
              id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
              prefs: Jason.encode!(%{}),
              first_seen_at: now,
              last_seen_at: now,
              created_at: now,
              updated_at: now
            }

            {:ok, _person} =
              Arca.Users.mint(
                system,
                person,
                Map.merge(link, %{first_seen_at: now, last_seen_at: now}),
                admission: "open",
                verify: &Sanctum.Provisioning.personal_admissible/0,
                also: fn person ->
                  with :ok <- Sanctum.Person.mint_keys(person),
                       {:ok, _athanor} <- Sanctum.Provisioning.mint_personal(person),
                       do: :ok
                end
              )

            :ok
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
          device_key: certificate.device_key,
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
        {carried.(client), certificate, seed}

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
              "device_key" => Prima.Identity.Encoding.b64(certificate.device_key),
              "proof" => Proof.encode(proof)
            },
            call_id: ctx.call_id,
            method: "device/renew"
          )

        {:ok, renewed} = DeviceCert.decode(issued)
        :ok = write_device.(Map.put(device, "certificate", issued), false)

        case proven.(:connect, renewed) do
          {{:ok, client}, _proof} ->
            {carried.(client), renewed, seed}

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
      alias Prima.DeviceCert.{Challenge, Proof}
      {ctx, _certificate, seed} = device_channel.()

      case device_intent.(ctx, "confirmation", %{"action" => "pending", "request" => ref}) do
        {:ok, %{confirmations: [%{ref: ^ref} = record]}} ->
          {:ok, challenge} = Challenge.decode(record.challenge)
          stored = challenge.digest

          {challenge, key} =
            case tamper do
              [] ->
                {challenge, seed}

              ["digest"] ->
                {%{challenge | digest: "sha256:" <> String.duplicate("0", 64)}, seed}

              ["ref"] ->
                {%{
                   challenge
                   | ref:
                       "cnr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
                 }, seed}

              ["key"] ->
                {challenge, :crypto.strong_rand_bytes(32)}
            end

          proof = Proof.encode(Proof.sign(challenge, key))

          confirmed =
            device_intent.(ctx, "confirmation", %{
              "action" => "confirm",
              "ref" => ref,
              "device_proof" => proof
            })

          answer.(
            Map.merge(
              %{operation: record.operation, preview: record.preview, digest: stored},
              case confirmed do
                {:ok, result} -> %{ok: result}
                {:error, reason} -> %{error: inspect(reason)}
              end
            )
          )

        {:ok, %{confirmations: records}} ->
          answer.(%{error: "no one open record of #{ref}: #{length(records)}"})

        {:error, reason} ->
          answer.(%{error: inspect(reason)})
      end

    ["person", email, sub | name] when length(name) <= 1 ->
      identity = Sanctum.Auth.Identity.builtin_key(:github, sub)

      method = %{
        id: identity,
        provider: :github,
        email: email,
        verified: true,
        name: List.first(name, "Release proof")
      }

      :ok = admitted.(identity)
      {:ok, user} = Sanctum.SignIn.unlock(method)
      ctx = person_ctx.(user.id)
      {:ok, session} = Sanctum.Session.create(ctx)

      answer.(%{
        user_id: user.id,
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

      {:ok, _message} =
        Arca.ThreadStorage.append(actor, thread.id, %{author: user_id, content: text})

      answer.(%{thread_id: thread.id, athanor_id: ctx.athanor_id})
  end
end
