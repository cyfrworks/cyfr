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
#       proof", recorded on their row, the membership read, the session):
#       everything but the identity provider, which the proofs cannot
#       reach. An installation's first person is made by the setup
#       admission (`Sanctum.Newcomer.admit/2`, under a setup token the
#       fixture puts for the call and takes away after), and so is its
#       platform administrator; the command-line session setup mints is
#       ended at once. Every later person is made with the rows an open
#       admission writes (`Arca.Users.mint/4` under `open`, their keys,
#       their athanor), once the door's `*` admits newcomers, which the
#       proof opens as an administrator does (`door.allow`); a sign-in
#       method is never an admission, so the identity is linked to the
#       person made. Answers the person, the athanor the session is
#       focused on, the route segment of that athanor and the session
#       token.
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

  # The person's context as a session reaches it: its athanor filled from
  # the memberships the sign-in left.
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
    if athanor.kind == "person", do: "@" <> athanor.slug, else: athanor.slug
  end

  # The setup admission (`Sanctum.Newcomer.admit/2`) under a setup token
  # put for this call alone: the installation's configured token, if it
  # has one, is put back however the admission ends.
  setup = fn machine ->
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    configured = Application.fetch_env(:sanctum, :setup_token)
    Application.put_env(:sanctum, :setup_token, token)

    try do
      Sanctum.Newcomer.admit({:setup, token}, {:command_line, machine})
    after
      case configured do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end
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
          {:ok, %{person: person, readmitted: false, session_token: token}} ->
            :ok = Sanctum.Session.destroy(token)
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
                also: fn person ->
                  with :ok <- Sanctum.Person.mint_keys(person),
                       {:ok, _athanor} <- Sanctum.Provisioning.mint_personal(person, []),
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

  case args do
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
