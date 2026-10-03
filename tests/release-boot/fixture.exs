# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the release proofs put in a running server, evaluated inside it by
# `bin/cyfr rpc` (`server_fixture` in tests/release-boot/release.sh). The
# file evaluates to a function of the argument list; each command prints
# nothing and answers one line, `FIXTURE=` and a JSON object.
#
#   person EMAIL SUB
#       The GitHub identity SUB with the verified EMAIL signed in as the
#       device flow signs one in, from the door on (`Sanctum.Door`,
#       `Sanctum.SignIn.admitted/2`, the membership read, the session):
#       everything but the identity provider, which the proofs cannot
#       reach. Answers the person, the athanor the session is focused on,
#       the route segment of that athanor and the session token.
#
#   tincture USER_ID DIR NAME public|private
#       The files under DIR written into the person's athanor as the local
#       tincture NAME at 1.0.0 and registered from the tree
#       (`Compendium.Registry.register_from_arca/3`), as a locally built
#       tincture is. `public` also writes the active public profile that
#       `profile.publish` leaves once its consent is committed, which is
#       what the `/t/` route asks of a public tincture; the consent flow
#       itself is a person's act in the console and is not what these
#       proofs are about.
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
#       writes one (the same payload, AAD, cipher and binding digest).
#       Entering a credential is a sensitive change a person confirms with
#       a fresh proof, which these proofs cannot give outside a browser, so
#       a proof that needs entries but is not about entering them seeds
#       them here. Answers the entry's id and name.
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

  case args do
    ["person", email, sub] ->
      identity = Sanctum.Auth.Identity.builtin_key(:github, sub)

      user_info = %{
        id: identity,
        provider: :github,
        email: email,
        verified: true,
        name: "Release proof"
      }

      {:ok, verdict} = Sanctum.Door.admit_identity(identity, user_info)
      {:ok, user} = Sanctum.SignIn.admitted(user_info, verdict)
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

      for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: false),
          File.regular?(file) do
        relative = Path.relative_to(file, dir)
        :ok = Arca.put(actor, unit ++ Path.split(relative), File.read!(file))
      end

      {:ok, component} = Compendium.Registry.register_from_arca(ctx, unit, force: true)

      ref = Prima.ComponentRef.build("tincture", "local", name)
      {:ok, profiles} = Arca.ConsentStorage.profiles(actor, ref)
      public? = Enum.any?(profiles, &(&1.kind == :public and &1.status == :active))

      if visibility == "public" and not public? do
        {:ok, _profile} =
          Arca.ProfileStorage.put(%{
            id: "prof_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
            athanor_id: ctx.athanor_id,
            source_ref: "tincture:local.#{name}",
            kind: "public",
            label: "public",
            status: "active"
          })
      end

      answer.(%{
        name: name,
        path: Prima.TinctureUrl.path(segment.(ctx.athanor_id), "local", name),
        component: is_map(component) and Map.get(component, :id)
      })

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

      binding = %{
        provider_hint: "",
        field_names: Jason.encode!([field]),
        oauth_endpoints: nil,
        oauth_scopes: nil
      }

      {:ok, digest} = Sanctum.VaultReader.binding_digest(binding)

      {:ok, entry} =
        Arca.VaultStorage.put(
          Sanctum.Context.actor(ctx),
          Map.merge(binding, %{
            id: id,
            name: name,
            kind: "api_key",
            provenance: "user",
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
