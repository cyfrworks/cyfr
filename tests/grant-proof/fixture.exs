# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The grant proof's part in the running server, evaluated inside it by
# `bin/cyfr rpc` (tests/grant-proof/run.sh `grant_fixture`). The file
# evaluates to a function of the argument list; each command answers one
# line, `GRANT=` and a JSON object. The person's grants are made in Prism
# and previewed from the command line by the proof itself; what is here
# publishes a version, reads what a grant holds and asks the loader for an
# admission, as a run started on Prism's path is admitted.
#
#   publish USER_ID DIR NAME VERSION VARIANT
#       The tincture under DIR committed into the person's athanor as the
#       local tincture NAME at VERSION, one unit, and registered from the
#       tree, its manifest as DIR has it but for its version and VARIANT:
#       `base` as it is, `background` asking to keep running when hidden,
#       `reworded` that and its need's reason in other words, and `flows`
#       that and a flow of outside material to the host it keeps.
#
#   head USER_ID REF
#       The head of the person's active owner profile of REF: its
#       revision, digests, admitted origins, and the hosts, storage paths,
#       flows and background permission its policy grants.
#
#   plan SESSION_TOKEN REF
#       The consent walk's plan for REF, as the console asks for it under
#       the session: the shape digest of what it asks now, and whether it
#       asks to run in the background.
#
#   file USER_ID PATH
#       A file at PATH in the person's athanor, so the grant prompt's
#       picker has a folder to offer inside the one the tincture asks for.
#
#   admit USER_ID REF
#       The loader's answer to a run of REF started on Prism's path, under
#       the person's interactive context: the consent it roots on, or the
#       refusal.
#
#   revoke USER_ID SESSION_TOKEN PROFILE_ID REF
#       The profile revoked as the person revokes it in the console
#       (`profile.revoke` through the gate, under the session), then the
#       admission asked again until it refuses: the milliseconds from the
#       revocation's answer to the first refusal, and how many admissions
#       were asked.
#
#   door SESSION_TOKEN
#       The door opened to newcomers by the person, the installation's
#       platform administrator (`door.allow` of `*` through the gate, under
#       the session), so a second person can sign in.
#
#   share OWNER_USER_ID DESTINATION_JSON
#       Seeds the owner's key and its share, the one thing this proof seeds
#       for its share step: an attach-only `api_key` entry of the provider
#       `grant.test` in the owner's athanor, holding the one field `TOKEN`
#       and bound to DESTINATION_JSON, sealed and stored as
#       `Sanctum.Vault.create/2` stores one (`Sanctum.Vault.Payload`, the
#       vault entry's AAD, `Sanctum.Cipher`, `Arca.VaultStorage.put/3`), and
#       shared with everyone with no cap (`Arca.Shares.create/3`). Making a
#       key and a share is the share proof's (`tests/share-proof/`), under
#       the confirmations it proves with a passkey; here it is the
#       recipient's grant that is proven. The key is random, made here, and
#       never leaves this function. Answers the entry's and the share's ids.
#
#   requested DESTINATION_JSON
#       What the owner's request implies the entry stores: the
#       destination's canonical text (`Prima.Destination.canonical/1`) and
#       the binding digest over it (`Sanctum.VaultReader.binding_digest/1`),
#       from the request alone.
#
#   clock
#       The database's time (`Arca.ServerMetaStorage.now!/0`): the start of
#       a window a stored time is held to.
#
#   shared USER_ID REF SHARE_ID
#       In one read, every row whole, every column as its schema reads it:
#       the binding rows of the head of the person's active owner profile
#       of REF (`consent_vault_refs`), the share SHARE_ID (`shares`) and
#       every use row of it (`share_usage`); then the database's time and
#       UTC date, the end of the window and the today a use row's day is.
#
#   attach SESSION_TOKEN REF OWNER_USER_ID ENTRY_ID URL METHOD
#       What the component's attached request of METHOD to URL carries:
#       the loader's admission of a run of REF under the context the
#       person's session establishes at Prism, the one a run started there
#       holds and its guest's calls run in, then the value `Opus.Host.AttachedFetch`
#       attaches, decided as it decides it (`Sanctum.Attach.resolve/5`,
#       handed the default vault resource of the admitted root's edge and
#       the facts an attempt of that root holds), rendered by the rule it
#       attaches by (`Prima.Manifest.Needs.render_attach/2`). The value is
#       compared here with the owner's entry ENTRY_ID unsealed as its owner
#       unseals it, and only the outcome leaves: whether the request
#       carries the owner's key, in which header, or the refusal.

require Ecto.Query

fn args ->
  answer = fn map -> "GRANT=" <> Jason.encode!(map) end

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
    # A person at Prism: the path a frame, a page and the console admit on.
    %{ctx | origin: :interactive}
  end

  # The one active owner profile of `ref`.
  owner = fn ctx, ref ->
    {:ok, profiles} = Sanctum.Consent.profiles(ctx, ref)
    Enum.find(profiles, &(&1.kind == :owner and &1.status == :active))
  end

  admit = fn ctx, ref ->
    case Opus.authority_for(ctx, :default, ref) do
      {:ok, authority} -> %{admitted: true, consent_id: authority.consent_id}
      {:error, {tag, _payload}} when is_atom(tag) -> %{admitted: false, refusal: tag}
      {:error, reason} -> %{admitted: false, refusal: inspect(reason)}
    end
  end

  # What a refusal is called on the wire: its tag.
  tag = fn
    {tag, _payload} when is_atom(tag) -> Atom.to_string(tag)
    tag when is_atom(tag) -> Atom.to_string(tag)
    other -> Prima.LoggerContext.shape(other)
  end

  # Every row of `query`, every column as its schema reads it.
  rows_of = fn query ->
    query |> Arca.Repo.all() |> Enum.map(&Map.delete(Map.from_struct(&1), :__meta__))
  end

  provider = "grant.test"
  field = "TOKEN"

  # The binding an attach-only entry of the provider holding the one field
  # and bound to `destination` stores, from the request alone.
  requested = fn destination ->
    {:ok, canonical} = Sanctum.Vault.destination_text(Jason.decode!(destination))

    binding = %{
      provider_hint: provider,
      field_names: Jason.encode!([field]),
      oauth_endpoints: nil,
      oauth_scopes: nil,
      destination: canonical,
      attach_only: true
    }

    {:ok, digest} = Sanctum.VaultReader.binding_digest(binding)
    {binding, digest}
  end

  case args do
    ["publish", user_id, dir, name, version, variant]
    when variant in ["base", "background", "reworded", "flows"] ->
      ctx = person_ctx.(user_id)
      actor = Sanctum.Context.actor(ctx)
      unit = ["components", "tinctures", "local", name, version]
      manifest = dir |> Path.join("cyfr-manifest.json") |> File.read!() |> Jason.decode!()

      manifest =
        case variant do
          "base" ->
            manifest

          "background" ->
            put_in(manifest, ["tincture", "frame"], %{"background" => true})

          "reworded" ->
            manifest
            |> put_in(["tincture", "frame"], %{"background" => true})
            |> put_in(["needs", "feed", "reason"], "so it can show you the feed it reads")

          "flows" ->
            manifest
            |> put_in(["tincture", "frame"], %{"background" => true})
            |> put_in(["needs", "feed", "reason"], "so it can show you the feed it reads")
            |> update_in(
              ["caps", "flows"],
              &(&1 ++ [%{"from" => "outside", "to" => "alpha.grant.test"}])
            )
        end
        |> Map.put("version", version)

      # One commit of the whole unit, its row and its revision, as a local
      # build lands one (`Arca.Overlay.commit_unit/4`): a plain write under
      # `components/` needs a unit already committed there.
      files =
        for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: false),
            File.regular?(file),
            Path.basename(file) != "cyfr-manifest.json",
            do: {Path.split(Path.relative_to(file, dir)), File.read!(file)}

      files = files ++ [{["cyfr-manifest.json"], Jason.encode!(manifest)}]
      {:ok, _written} = Arca.Overlay.commit_unit(actor, unit, {:files, files}, cap: :exempt)
      {:ok, component} = Compendium.Registry.register_from_arca(ctx, unit, force: true)
      answer.(%{name: name, version: version, component: Map.get(component, :id)})

    ["head", user_id, ref] ->
      ctx = person_ctx.(user_id)

      case owner.(ctx, ref) do
        nil ->
          answer.(%{profile_id: nil})

        profile ->
          {:ok, head} = Sanctum.Consent.head_consent(ctx, profile.id)
          {:ok, blob} = Prima.Authority.Blob.parse(head.resolved_policy)
          {:ok, ingress} = Prima.Authority.Blob.ingress(blob, ref)

          answer.(%{
            profile_id: profile.id,
            consent_id: head.id,
            revision: head.revision,
            commit_digest: head.commit_digest,
            shape_digest: head.shape_digest,
            admitted_origins: Prima.Origin.to_wire_list(head.admitted_origins),
            domains: (ingress.egress && ingress.egress.domains) || [],
            paths: Prima.Authority.Blob.Edge.paths(ingress),
            flows: Enum.map(ingress.flows, &"#{&1.from} to #{&1.to}")
          })
      end

    ["plan", token, ref] ->
      {:ok, console} = Sanctum.Caller.establish({:session, token})
      {:ok, plan} = Sanctum.Consent.Plan.plan(%{console | origin: :interactive}, %{ref: ref})

      background =
        Enum.any?(plan.rows, fn row ->
          row["kind"] == "frame" and get_in(row, ["values", "background"]) == true
        end)

      answer.(%{shape_digest: plan.shape_digest, background: background})

    ["file", user_id, path] ->
      ctx = person_ctx.(user_id)
      :ok = Arca.put(Sanctum.Context.actor(ctx), String.split(path, "/"), "the probe's notes")
      answer.(%{path: path})

    ["admit", user_id, ref] ->
      answer.(admit.(person_ctx.(user_id), ref))

    ["revoke", user_id, token, profile_id, ref] ->
      ctx = person_ctx.(user_id)
      {:ok, console} = Sanctum.Caller.establish({:session, token})
      console = %{console | origin: :interactive}
      before = admit.(ctx, ref)

      {:ok, %{status: "revoked"}} =
        PrismWeb.Ops.call_tool(console, "profile", %{
          "action" => "revoke",
          "profile_id" => profile_id
        })

      revoked_at = System.monotonic_time(:microsecond)

      {attempts, refused} =
        Enum.reduce_while(1..1_000, {0, nil}, fn n, _acc ->
          case admit.(ctx, ref) do
            %{admitted: false} = refused -> {:halt, {n, refused}}
            _admitted -> {:cont, {n, nil}}
          end
        end)

      answer.(%{
        before: before,
        refused: refused,
        attempts: attempts,
        refused_after_us: System.monotonic_time(:microsecond) - revoked_at
      })

    ["door", token] ->
      {:ok, console} = Sanctum.Caller.establish({:session, token})

      case PrismWeb.Ops.call_tool(%{console | origin: :interactive}, "door", %{
             "action" => "allow",
             "value" => "*"
           }) do
        {:ok, _entry} -> answer.(%{door: "*"})
        {:error, reason} -> answer.(%{door: nil, refusal: tag.(reason)})
      end

    ["share", owner_id, destination] ->
      ctx = person_ctx.(owner_id)
      actor = Sanctum.Context.actor(ctx)
      {binding, digest} = requested.(destination)
      key = "gp-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      {:ok, json} = Sanctum.Vault.Payload.encode_material(%{field => key}, nil)
      id = Prima.UUID7.generate_id("vlt")
      aad = Sanctum.CipherAAD.vault_entry(actor.athanor_id, id, provider)
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

      {:ok, entry} =
        Arca.VaultStorage.put(
          actor,
          Map.merge(binding, %{
            id: id,
            name: "Probe feed",
            kind: "api_key",
            status: "active",
            sealed_payload: sealed,
            binding_digest: digest
          })
        )

      {:ok, share} = Arca.Shares.create(actor, %{entry_id: entry.id, audience: "everyone"})
      answer.(%{entry_id: entry.id, share_id: share.id})

    ["requested", destination] ->
      {binding, digest} = requested.(destination)
      answer.(%{destination: binding.destination, binding_digest: digest})

    ["clock"] ->
      answer.(%{now: DateTime.to_iso8601(Arca.ServerMetaStorage.now!())})

    ["shared", user_id, ref, share_id] ->
      ctx = person_ctx.(user_id)

      bindings =
        case owner.(ctx, ref) do
          nil ->
            []

          profile ->
            {:ok, head} = Sanctum.Consent.head_consent(ctx, profile.id)

            rows_of.(
              Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef, where: r.consent_id == ^head.id)
            )
        end

      share = rows_of.(Ecto.Query.from(s in Arca.Schemas.Share, where: s.id == ^share_id))

      usage =
        rows_of.(Ecto.Query.from(u in Arca.Schemas.ShareUsage, where: u.share_id == ^share_id))

      now = Arca.ServerMetaStorage.now!()

      answer.(%{
        bindings: bindings,
        shares: share,
        usage: usage,
        now: DateTime.to_iso8601(now),
        today: Date.to_iso8601(DateTime.to_date(now))
      })

    ["attach", token, ref, owner_id, entry_id, url, method] ->
      {:ok, console} = Sanctum.Caller.establish({:session, token})
      ctx = %{console | origin: :interactive}

      # The owner's key, unsealed as its owner unseals it; compared here
      # and never answered.
      owner_key = fn ->
        athanor_id = person_ctx.(owner_id).athanor_id
        %{athanor_id: ^athanor_id} = entry = Arca.Repo.get(Arca.Schemas.VaultEntry, entry_id)
        aad = Sanctum.CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)
        {:ok, plaintext} = Sanctum.Cipher.decrypt(entry.sealed_payload, aad)
        {:ok, %{"fields" => %{^field => key}}} = Sanctum.Vault.Payload.decode(plaintext)
        key
      end

      case Opus.authority_for(ctx, :default, ref) do
        {:ok, authority} ->
          {:ok, vault} = Prima.Authority.Blob.vault_for(authority.resources, nil)

          facts = %{
            root_execution_id: Prima.UUID7.execution_id(),
            profile_id: authority.profile_id,
            consent_id: authority.consent_id
          }

          request = %{uri: URI.parse(url), method: method}

          case Sanctum.Attach.resolve(ctx, vault, "feed", request, facts) do
            {:ok, %{value: value, attach: rule}} ->
              key = owner_key.()

              answer.(%{
                admitted: true,
                consent_id: authority.consent_id,
                attached: true,
                in: rule.in,
                header: rule.name,
                owner_key:
                  value == key and
                    Prima.Manifest.Needs.render_attach(rule, value) ==
                      Prima.Manifest.Needs.render_attach(rule, key)
              })

            {:error, reason} ->
              answer.(%{
                admitted: true,
                consent_id: authority.consent_id,
                attached: false,
                refusal: tag.(reason)
              })
          end

        {:error, reason} ->
          answer.(%{admitted: false, refusal: tag.(reason)})
      end
  end
end
