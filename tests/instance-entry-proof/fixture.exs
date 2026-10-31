# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The instance-entry proof's part in the running server, evaluated inside
# it by `bin/cyfr rpc` (tests/instance-entry-proof/run.sh `entry_fixture`).
# The file evaluates to a function of the argument list; each command
# answers one line, `ENTRY=` and a JSON object of bounded, non-secret
# facts. It calls the real paths named below and reads back what they
# decided, and seeds one thing, a group of the administrator's holding
# Bea (`group`), which the narrowing names. The administrator's keys and
# their shares are made on the Vault page, in the browser. Material a
# share unseals is discarded here and never serialized.
#
#   clock
#       The database's time (`Arca.ServerMetaStorage.now!/0`): the start of
#       the run's window, which every stored time is held to.
#
#   state ANA_SESSION_TOKEN|- BEA_USER_ID|- PAYLOAD_DIGESTS_JSON
#       In one read, everything the proof's README names, every row whole,
#       every column as its schema reads it, for the proof to compare with
#       its own model after every step: every row of `vault_entries`
#       (tombstoned ones too), its sealed payload replaced by the outcome of
#       comparing it with the digest PAYLOAD_DIGESTS_JSON names for the
#       entry's id (`sealed_payload` below); every row of
#       `instance_entries`, `instance_entry_members` and
#       `instance_entry_usage`, which nothing here makes; every row of
#       `shares` and of `share_usage`; once Ana has signed in, every
#       profile of catalyst:local.openai in her athanor, every consent of
#       those profiles, every binding row of those consents, the instance
#       entries offered to her (`Sanctum.InstanceEntries.offered/1`) and the
#       shares (`Sanctum.Shares.offered/1`); once Bea has signed in, her row
#       (`users`) and the shares offered to her under the context she held
#       (`held_claim` below), or the refusal; and, once every row is read, the database's time and its
#       UTC date, the end of the window and the today a use row's day is
#       held to. It picks no row out of a set and leaves no column out.
#
#       An entry's sealed payload is unsealed here as its owner unseals it
#       (`Sanctum.VaultReader`: the vault entry's AAD,
#       `Sanctum.Cipher.decrypt/2` and `Sanctum.Vault.Payload.decode/1`),
#       its decoded document hashed in its canonical text (`Prima.JCS`), and
#       the hash compared with the proof's digest of the document its form
#       typed. The answer is one of `matches`, `differs`, `does_not_unseal`
#       or `absent`; the material and its hash never leave this function.
#
#   requested_digest PROVIDER FIELD DESTINATION_JSON
#       What an entry of PROVIDER holding the one field FIELD and bound to
#       DESTINATION_JSON stores, as its owner computes it when it is
#       created: the destination's canonical text
#       (`Prima.Destination.canonical/1`), the bytes the store holds, and the
#       binding digest over it (`Sanctum.VaultReader.binding_digest/1`).
#       What the administrator's request implies, for the proof to compare
#       with what is stored.
#
#   A person is named by SESSION_TOKEN, their sign-in's session, and acts
#   under the context it establishes as a request establishes it
#   (`Sanctum.Caller.establish/2`), at Prism (origin interactive).
#
#   group SESSION_TOKEN MEMBER_USER_ID NAME
#       The administrator, by their session, makes the group NAME
#       (`Sanctum.Tenancy.Athanors.create_group/3`, which seats them) and
#       seats the person MEMBER_USER_ID in it
#       (`Sanctum.Tenancy.Members.ensure/2`). Answers the group's id.
#
#   derived_head SESSION_TOKEN SHARE_ID PROVIDER FIELD DESTINATION_JSON
#       What the first sign-in's bootstrap derives for the person's head of
#       catalyst:local.openai when it binds the administrator's share
#       SHARE_ID of a key with PROVIDER, the one field FIELD and
#       DESTINATION_JSON: the policy blob's text, its digest, the
#       activation's text, the shape digest and the commit digest, each
#       built by the owner's own public builders from the installed
#       catalyst and the request alone (as `Sanctum.Consent.Bootstrap`
#       builds them), never read from the stored head.
#
#   admit SESSION_TOKEN
#       The real loader's answer for a run of catalyst:local.openai under
#       the person's context (`Opus.authority_for/3`'s path), with no
#       run started: the profile and consent it roots on and the node and
#       activation digest it verified for the catalyst, or the refusal.
#       The loader is asked once the person's athanor is filled, as a turn
#       is admitted only then (`Sanctum.Provisioning.ready/1`): a sign-in
#       answers before the fill that follows it, and that fill mints the
#       consent bootstrap before it marks the athanor filled. An athanor
#       not filled within the bound answers the refusal `not_provisioned`.
#
#   claim SESSION_TOKEN SOURCE ID COUNT URL METHOD DIGEST FIELD
#       COUNT claims of the share ID under the person's context, through
#       `Sanctum.Shares.resolve/5`, for a request of METHOD to URL: for
#       SOURCE `share`, held to the digest and the field the person's
#       openai head binds it at, as `Sanctum.Attach` holds a request
#       (DIGEST and FIELD are `-`); for SOURCE `granted`, a share no head of
#       theirs binds, held to DIGEST, the digest its source's request
#       implies, and its one field FIELD, as a grant of it would bind it.
#       Each answers
#       admitted, or the refusal with a cap's reset, and the database's
#       next UTC midnight, computed here from its clock. The material
#       resolved is dropped here.
#
#   held_claim USER_ID SHARE_ID COUNT URL METHOD DIGEST FIELD
#       `claim`'s `granted` claims under the person's context as a request
#       established it and still holds it, built from their row (their own
#       athanor, at Prism) rather than from their session, which a deny
#       ends: the share's own checks, not the session's, are what a request
#       already in flight meets.
#
#   row_binding SESSION_TOKEN SHARE_ID
#       The person's openai head's share row naming SHARE_ID, read live by
#       the loader (`Sanctum.Consent.row_binding/3`): offered or the
#       refusal.
#
#   focus SESSION_TOKEN ATHANOR_ID
#       The session's person focused on ATHANOR_ID
#       (`Sanctum.Context.focus/2`) and refocused
#       (`Sanctum.Context.refocus/2`): the decision each answers.

require Ecto.Query

fn args ->
  answer = fn map -> "ENTRY=" <> Jason.encode!(map) end
  openai = "catalyst:local.openai"

  # The person as their session establishes them, focused where it is.
  person_ctx = fn token ->
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})
    %{ctx | origin: :interactive}
  end

  tag = fn
    {tag, _payload} when is_atom(tag) -> Atom.to_string(tag)
    tag when is_atom(tag) -> Atom.to_string(tag)
    %Prima.Refusal{reason: reason} when is_atom(reason) -> Atom.to_string(reason)
    other -> Prima.LoggerContext.shape(other)
  end

  # The person's active owner profile of catalyst:local.openai and its
  # head, once the fill that follows a first sign-in has minted it.
  head = fn ctx ->
    deadline = System.monotonic_time(:millisecond) + 180_000

    Stream.repeatedly(fn ->
      with {:ok, profiles} <- Sanctum.Consent.profiles(ctx, openai),
           %{} = profile <- Enum.find(profiles, &(&1.kind == :owner and &1.status == :active)),
           {:ok, head} <- Sanctum.Consent.head_consent(ctx, profile.id) do
        {profile, head}
      else
        _not_yet ->
          if System.monotonic_time(:millisecond) > deadline,
            do: :timeout,
            else: Process.sleep(500)
      end
    end)
    |> Enum.find(&(&1 != :ok))
  end

  share_row = fn head, share_id ->
    Enum.find(head.vault_refs, &(Map.get(&1, :share_id) == share_id))
  end

  # The digest and the field the person's openai head binds the share
  # `share_id` at, as `Sanctum.Attach` reads them from the head's blob: the
  # approved digest and the need's one field mapped to the source's.
  bound_share = fn head, share_id ->
    with {:ok, blob} <- Prima.Authority.Blob.parse(head.resolved_policy),
         {:ok, %{vault: %{scope: "share", entry_id: ^share_id} = vault}} <-
           Prima.Authority.Blob.ingress(blob, openai),
         [{need_field, entry_field}] <- Map.to_list(vault.projection.fields) do
      {:ok, vault.binding_digest, {:field, need_field, entry_field}}
    else
      _unbound -> {:error, :not_bound}
    end
  end

  today = fn -> DateTime.to_date(Arca.ServerMetaStorage.now!()) end

  # A row as its table holds it: every column, read by its schema.
  stored = fn schema, id ->
    case Arca.Repo.get(schema, id) do
      nil -> nil
      row -> Map.delete(Map.from_struct(row), :__meta__)
    end
  end

  # The person's athanor ready to run a turn, as a turn's admission asks
  # before anything reaches the loader (`Sanctum.Provisioning.ready/1`),
  # bounded as the head's read is: `:filled`, or `:timeout`.
  filled = fn ctx ->
    deadline = System.monotonic_time(:millisecond) + 180_000

    Stream.repeatedly(fn ->
      cond do
        Sanctum.Provisioning.ready(ctx) == :ok -> :filled
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(500)
      end
    end)
    |> Enum.find(&(&1 != :ok))
  end

  # The root the loader admits for catalyst:local.openai once the athanor
  # is filled, and the running node's facts as an attempt holds them: its
  # reference and the digest the loader verified for it.
  admitted = fn ctx ->
    with :filled <- filled.(ctx),
         {:ok, %{authority: authority, stamp: stamp}} <-
           Opus.Admission.authority_and_stamp_for(ctx, :default, openai) do
      graph = (stamp && stamp.activation_graph) || %{}

      {node_ref, digest} =
        Enum.find(graph, {nil, stamp && stamp.activation_digest}, fn {ref, _digest} ->
          ref == openai or String.starts_with?(ref, openai <> ":")
        end)

      {:ok, authority, %{node_ref: node_ref, activation_digest: digest}}
    else
      :timeout -> {:error, :not_provisioned}
      {:error, reason} -> {:error, reason}
    end
  end

  next_midnight = fn ->
    DateTime.new!(Date.add(today.(), 1), ~T[00:00:00.000000], "Etc/UTC")
  end

  rows_of = fn query ->
    query |> Arca.Repo.all() |> Enum.map(&Map.delete(Map.from_struct(&1), :__meta__))
  end

  # A person's context as a request established it and still holds it,
  # built from their row (their own athanor, at Prism) rather than from
  # their session: a deny ends the session, and the share's own checks, not
  # the session's, are what a request already in flight meets.
  held_ctx = fn user_id ->
    {:ok, user} = Sanctum.Tenancy.Users.get(user_id)

    ctx =
      Sanctum.Context.build(
        user_id: user_id,
        athanor_id: user.personal_athanor_id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    %{ctx | origin: :interactive}
  end

  # The shares offered to the person `ctx` names, by id, or the refusal.
  shared_with = fn ctx ->
    case Sanctum.Shares.offered(ctx) do
      {:ok, shared} -> Enum.map(shared, & &1.id)
      {:error, reason} -> %{refused: tag.(reason)}
    end
  end

  claim_for = fn ctx, source, id, count, url, method, digest, field ->
    request = %{uri: URI.parse(url), method: method}

    # One claim of the source, its material dropped here, unread.
    resolve =
      case source do
        "granted" ->
          fn ->
            with {:ok, _value} <-
                   Sanctum.Shares.resolve(ctx, id, digest, request, {:field, field, field}),
                 do: :admitted
          end

        "share" ->
          bound =
            case head.(ctx) do
              {_profile, head} -> bound_share.(head, id)
              :timeout -> {:error, :not_bound}
            end

          fn ->
            with {:ok, approved, take} <- bound,
                 {:ok, _value} <- Sanctum.Shares.resolve(ctx, id, approved, request, take),
                 do: :admitted
          end
      end

    results =
      for _ <- 1..String.to_integer(count) do
        case resolve.() do
          :admitted ->
            %{admitted: true}

          {:error, {:connection_cap, %DateTime{} = reset_at}} ->
            %{
              admitted: false,
              refusal: "connection_cap",
              reset_at: DateTime.to_iso8601(reset_at)
            }

          {:error, {:entry_unavailable, status}} ->
            %{admitted: false, refusal: "entry_unavailable", status: status}

          {:error, reason} ->
            %{admitted: false, refusal: tag.(reason)}
        end
      end

    answer.(%{
      results: results,
      next_utc_midnight: DateTime.to_iso8601(next_midnight.())
    })
  end

  case args do
    ["clock"] ->
      answer.(%{now: DateTime.to_iso8601(Arca.ServerMetaStorage.now!())})

    ["state", ana_token, bea_id, payload_digests] ->
      # Every row of each table, whole, none picked out. The owner's reads
      # would drop rows or columns: `Arca.VaultStorage.list/1` leaves out
      # tombstoned rows, and `Arca.ShareUsage.usage/3` leaves out
      # `updated_at`. The sealed payload is replaced here, before anything
      # is serialized, by the outcome of comparing it with what its form
      # typed.
      typed = Jason.decode!(payload_digests)

      # The stored payload against the digest of what its form typed: the
      # one fact that leaves here.
      payload = fn entry ->
        aad = Sanctum.CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

        with sealed when is_binary(sealed) and sealed != "" <- entry.sealed_payload,
             {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad),
             {:ok, document} <- Sanctum.Vault.Payload.decode(plaintext),
             {:ok, text} <- Prima.JCS.encode(document) do
          digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
          if digest == Map.get(typed, entry.id), do: "matches", else: "differs"
        else
          absent when absent in [nil, ""] -> "absent"
          _unsealed_none -> "does_not_unseal"
        end
      end

      vault_entries =
        for entry <- rows_of.(Arca.Schemas.VaultEntry) do
          Map.put(entry, :sealed_payload, payload.(entry))
        end

      # No instance entry is made here; one that is would be read whole but
      # for its sealed payload, which only says whether it holds one.
      entries =
        for entry <- rows_of.(Arca.Schemas.InstanceEntry) do
          held = if entry.sealed_payload in [nil, ""], do: "absent", else: "present"
          Map.put(entry, :sealed_payload, held)
        end

      members = rows_of.(Arca.Schemas.InstanceEntryMember)
      usage = rows_of.(Arca.Schemas.InstanceEntryUsage)
      shares = rows_of.(Arca.Schemas.Share)
      share_usage = rows_of.(Arca.Schemas.ShareUsage)

      ana =
        if ana_token == "-" do
          nil
        else
          ctx = person_ctx.(ana_token)
          # The fill that follows her first sign-in mints her profile; the
          # read waits for it, bounded, then reads every row whole.
          _minted = head.(ctx)
          athanor_id = ctx.athanor_id

          profiles =
            rows_of.(
              Ecto.Query.from(p in Arca.Schemas.Profile,
                where: p.athanor_id == ^athanor_id and p.source_ref == ^openai
              )
            )

          profile_ids = Enum.map(profiles, & &1.id)

          consents =
            rows_of.(
              Ecto.Query.from(c in Arca.Schemas.Consent, where: c.profile_id in ^profile_ids)
            )

          consent_ids = Enum.map(consents, & &1.id)

          rows =
            rows_of.(
              Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
                where: r.consent_id in ^consent_ids
              )
            )

          {:ok, offered} = Sanctum.InstanceEntries.offered(ctx)

          %{
            profiles: profiles,
            consents: consents,
            rows: rows,
            offered: Enum.map(offered, & &1.id),
            shared: shared_with.(ctx)
          }
        end

      bea =
        if bea_id == "-",
          do: nil,
          else: %{
            user: stored.(Arca.Schemas.User, bea_id),
            shared: shared_with.(held_ctx.(bea_id))
          }

      # The database's time once every row is read: the end of the window a
      # stored time is held to, and the today a use row's day is.
      now = Arca.ServerMetaStorage.now!()

      answer.(%{
        now: DateTime.to_iso8601(now),
        today: Date.to_iso8601(DateTime.to_date(now)),
        vault_entries: vault_entries,
        entries: entries,
        members: members,
        usage: usage,
        shares: shares,
        share_usage: share_usage,
        ana: ana,
        bea: bea
      })

    ["requested_digest", provider, field, destination] ->
      {:ok, parsed} = Prima.Destination.new(Jason.decode!(destination), true)
      canonical = Prima.Destination.canonical(parsed)

      {:ok, digest} =
        Sanctum.VaultReader.binding_digest(%{
          provider_hint: provider,
          field_names: Jason.encode!([field]),
          oauth_endpoints: nil,
          oauth_scopes: nil,
          destination: canonical,
          attach_only: true
        })

      answer.(%{destination: canonical, binding_digest: digest})

    ["group", token, member_id, name] ->
      admin = person_ctx.(token)
      {:ok, group} = Sanctum.Tenancy.Athanors.create_group(admin.user_id, name)

      {:ok, _seat} =
        Sanctum.Tenancy.Members.ensure(member_id, scope: "athanor", athanor_id: group.id)

      answer.(%{group_id: group.id})

    ["derived_head", token, share_id, provider, field, destination] ->
      ctx = person_ctx.(token)
      {:ok, parsed} = Prima.Destination.new(Jason.decode!(destination), true)

      {:ok, digest} =
        Sanctum.VaultReader.binding_digest(%{
          provider_hint: provider,
          field_names: Jason.encode!([field]),
          oauth_endpoints: nil,
          oauth_scopes: nil,
          destination: Prima.Destination.canonical(parsed),
          attach_only: true
        })

      {:ok, component} = Sanctum.Consent.Components.get_latest(ctx, "openai", "local", "catalyst")
      {:ok, activation} = Sanctum.Consent.Components.resolve(ctx, component)
      {:ok, manifest} = Prima.Manifest.decode_strict(Map.get(component, :manifest))

      # The catalyst's one attach-only credential need, as the bootstrap
      # picks it.
      [need] =
        manifest
        |> Prima.Manifest.Needs.from_manifest()
        |> Enum.filter(fn need ->
          need.kind in ~w(api_key oauth bundle) and is_map(need.attach) and need.disclose != true
        end)

      # The binding the first sign-in commits for the administrator's share,
      # under the automatic map of the need over its source's one field, as
      # provisioning takes it: the share's id is the binding's entry.
      fields = Sanctum.Consent.Plan.field_map(need, [field])

      binding = %{
        need: need.name,
        entry_id: share_id,
        binding_digest: digest,
        scope: "share",
        destination: Prima.Destination.to_map(parsed),
        attach: Prima.Manifest.Needs.attach_to_map(need.attach),
        fields: fields,
        scopes: need.scopes,
        lifetime: %{kind: "standing", until: nil},
        renew: false
      }

      vault_fn = fn node_key, _row, _manifest ->
        if node_key == openai, do: Sanctum.Consent.BlobBuilder.vault_resource(binding)
      end

      {:ok, nodes} =
        Sanctum.Consent.BlobBuilder.build(ctx, activation.graph, openai, vault_fn,
          source_row: component
        )

      {:ok, blob_json} = Sanctum.Consent.BlobBuilder.encode(nodes)
      blob_digest = Prima.Digest.sha256(blob_json)
      {:ok, activation_json} = Prima.JCS.encode(activation.graph)
      {:ok, input} = Sanctum.Consent.ShapeDerivation.shape_input(ctx, openai)
      {:ok, shape_digest} = Sanctum.Consent.ShapeDigest.compute(input)

      {:ok, commit_digest} =
        Sanctum.Consent.CommitDigest.compute(%{
          shape_digest: shape_digest,
          blob_digest: blob_digest,
          label: "default",
          kind: :owner,
          invoke_mode: :open_inert,
          origins: [:interactive, :programmatic],
          bindings: [
            %{
              need: need.name,
              share_id: share_id,
              binding_digest: digest,
              fields: fields,
              scopes: need.scopes,
              lifetime: %{kind: "standing"},
              renew: false
            }
          ]
        })

      answer.(%{
        resolved_policy: blob_json,
        blob_digest: blob_digest,
        activation: activation_json,
        shape_digest: shape_digest,
        commit_digest: commit_digest
      })

    ["admit", token] ->
      case admitted.(person_ctx.(token)) do
        {:ok, authority, facts} ->
          answer.(%{
            admitted: true,
            profile_id: authority.profile_id,
            consent_id: authority.consent_id,
            node_ref: facts.node_ref,
            node_digest: facts.activation_digest
          })

        {:error, reason} ->
          answer.(%{admitted: false, refusal: tag.(reason)})
      end

    ["claim", token, source, id, count, url, method, digest, field] ->
      claim_for.(person_ctx.(token), source, id, count, url, method, digest, field)

    ["held_claim", user_id, id, count, url, method, digest, field] ->
      claim_for.(held_ctx.(user_id), "granted", id, count, url, method, digest, field)

    ["row_binding", token, share_id] ->
      ctx = person_ctx.(token)

      case head.(ctx) do
        {_profile, head} ->
          case share_row.(head, share_id) do
            nil ->
              answer.(%{row: false})

            row ->
              case Sanctum.Consent.row_binding(ctx, head, row) do
                {:share, ^share_id, {:ok, _view}} ->
                  answer.(%{row: true, offered: true})

                {:share, ^share_id, {:error, reason}} ->
                  answer.(%{row: true, offered: false, refusal: tag.(reason)})

                other ->
                  answer.(%{row: true, offered: false, refusal: tag.(other)})
              end
          end

        :timeout ->
          answer.(%{row: false, error: "no openai profile"})
      end

    ["focus", token, athanor_id] ->
      {:ok, admin} = Sanctum.Caller.establish({:session, token})

      decision = fn
        {:ok, _focused} -> "admitted"
        {:error, reason} -> tag.(reason)
      end

      answer.(%{
        platform_admin: admin.platform_admin,
        in_focus: admin.athanor_id,
        focus: decision.(Sanctum.Context.focus(admin, athanor_id)),
        refocus: decision.(Sanctum.Context.refocus(admin, athanor_id))
      })
  end
end
