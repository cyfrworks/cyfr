# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The instance-entry proof's part in the running server, evaluated inside
# it by `bin/cyfr rpc` (tests/instance-entry-proof/run.sh `entry_fixture`).
# The file evaluates to a function of the argument list; each command
# answers one line, `ENTRY=` and a JSON object of bounded, non-secret
# facts. It seeds nothing an administrator does in the browser: it calls
# the real paths named below and reads back what they decided. Material
# an instance entry unseals is discarded here and never serialized.
#
#   clock
#       The database's time (`Arca.ServerMetaStorage.now!/0`): the start of
#       the run's window, which every stored time is held to.
#
#   state ANA_SESSION_TOKEN|- BEA_USER_ID|- PAYLOAD_DIGESTS_JSON
#       In one read, everything the proof's README names, every row whole,
#       every column as its schema reads it, for the proof to compare with
#       its own model after every step: every row of `instance_entries`
#       (tombstoned ones too), its sealed payload replaced by the outcome of
#       comparing it with the digest PAYLOAD_DIGESTS_JSON names for the
#       entry's id (`sealed_payload` below); every row of
#       `instance_entry_members` and of
#       `instance_entry_usage`; once Ana has signed in, every profile of
#       catalyst:local.openai in her athanor, every consent of those
#       profiles, every binding row of those consents, and the entries
#       offered to her (`Sanctum.InstanceEntries.offered/1`); once Bea has
#       signed in, her row (`users`); and, once every row is read, the
#       database's time and its UTC date, the end of the window and the
#       today a use row's day is held to. It picks no row out of a set and
#       leaves no column out.
#
#       An entry's sealed payload is unsealed here as its owner unseals it
#       (`Sanctum.InstanceEntries`' `unseal/1`, which is private: the same
#       AAD, `Sanctum.Cipher.decrypt/2` and `Sanctum.Vault.Payload.decode/1`),
#       its decoded document hashed in its canonical text (`Prima.JCS`), and
#       the hash compared with the proof's digest of the document its card
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
#   derived_head SESSION_TOKEN ENTRY_ID PROVIDER FIELD DESTINATION_JSON
#       What the first sign-in's bootstrap derives for the person's head of
#       catalyst:local.openai when it binds the instance entry ENTRY_ID that
#       an administrator requested with PROVIDER, the one field FIELD and
#       DESTINATION_JSON: the policy blob's text, its digest, the
#       activation's text, the shape digest and the commit digest, each
#       built by the owner's own public builders from the installed
#       catalyst and the request alone (as `Sanctum.Consent.Bootstrap`
#       builds them), never read from the stored head.
#
#   admit SESSION_TOKEN
#       The real loader's answer for a run of catalyst:local.openai under
#       the person's context (`Crucible.authority_for/3`'s path), with no
#       run started: the profile and consent it roots on and the node and
#       activation digest it verified for the catalyst, or the refusal.
#
#   claim SESSION_TOKEN ENTRY_ID COUNT URL METHOD
#       COUNT calls of `Sanctum.InstanceEntries.resolve/4` under the
#       person's context, for a request of METHOD to URL, with the node
#       facts of the root the loader admits for catalyst:local.openai:
#       each answers admitted, or the refusal with a cap's reset, and the
#       database's next UTC midnight, computed here from its clock. The
#       material resolved is dropped here.
#
#   row_binding SESSION_TOKEN ENTRY_ID
#       The person's openai head's instance row naming ENTRY_ID, read live
#       by the loader (`Sanctum.Consent.row_binding/3`): offered or the
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

  instance_row = fn head, entry_id ->
    Enum.find(head.vault_refs, &(Map.get(&1, :instance_entry_id) == entry_id))
  end

  today = fn -> DateTime.to_date(Arca.ServerMetaStorage.now!()) end

  # A row as its table holds it: every column, read by its schema.
  stored = fn schema, id ->
    case Arca.Repo.get(schema, id) do
      nil -> nil
      row -> Map.delete(Map.from_struct(row), :__meta__)
    end
  end

  # The root the loader admits for catalyst:local.openai, and the running
  # node's facts as an attempt holds them: its reference and the digest
  # the loader verified for it.
  admitted = fn ctx ->
    case Crucible.Admission.authority_and_stamp_for(ctx, :default, openai) do
      {:ok, %{authority: authority, stamp: stamp}} ->
        graph = (stamp && stamp.activation_graph) || %{}

        {node_ref, digest} =
          Enum.find(graph, {nil, stamp && stamp.activation_digest}, fn {ref, _digest} ->
            ref == openai or String.starts_with?(ref, openai <> ":")
          end)

        {:ok, authority, %{node_ref: node_ref, activation_digest: digest}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  next_midnight = fn ->
    DateTime.new!(Date.add(today.(), 1), ~T[00:00:00.000000], "Etc/UTC")
  end

  rows_of = fn query ->
    query |> Arca.Repo.all() |> Enum.map(&Map.delete(Map.from_struct(&1), :__meta__))
  end

  case args do
    ["clock"] ->
      answer.(%{now: DateTime.to_iso8601(Arca.ServerMetaStorage.now!())})

    ["state", ana_token, bea_id, payload_digests] ->
      # Every row of the instance's tables, whole, none picked out. The
      # owner's reads would drop rows or columns: `Arca.InstanceEntries.list/2`
      # leaves out tombstoned rows and reads members as ids, and
      # `Arca.InstanceEntryUsage.usage/3` leaves out `updated_at` and reads
      # every day from today on. The sealed payload is replaced here, before
      # anything is serialized, by the outcome of comparing it with what its
      # card typed.
      typed = Jason.decode!(payload_digests)

      # The stored payload against the digest of what its card typed: the
      # one fact that leaves here.
      payload = fn entry ->
        aad = Sanctum.CipherAAD.instance_entry(entry.id, entry.provider_hint)

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

      entries =
        for entry <- rows_of.(Arca.Schemas.InstanceEntry) do
          Map.put(entry, :sealed_payload, payload.(entry))
        end

      members = rows_of.(Arca.Schemas.InstanceEntryMember)
      usage = rows_of.(Arca.Schemas.InstanceEntryUsage)

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
            offered: Enum.map(offered, & &1.id)
          }
        end

      bea = if(bea_id == "-", do: nil, else: %{user: stored.(Arca.Schemas.User, bea_id)})

      # The database's time once every row is read: the end of the window a
      # stored time is held to, and the today a use row's day is.
      now = Arca.ServerMetaStorage.now!()

      answer.(%{
        now: DateTime.to_iso8601(now),
        today: Date.to_iso8601(DateTime.to_date(now)),
        entries: entries,
        members: members,
        usage: usage,
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

    ["derived_head", token, entry_id, provider, field, destination] ->
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

      # The binding the first sign-in commits for the requested entry.
      binding = %{
        need: need.name,
        entry_id: entry_id,
        binding_digest: digest,
        scope: "instance",
        destination: Prima.Destination.to_map(parsed),
        attach: Prima.Manifest.Needs.attach_to_map(need.attach),
        fields: need.fields,
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
      blob_digest = Prima.JCS.hash_binary(blob_json)
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
              instance_entry_id: entry_id,
              binding_digest: digest,
              fields: need.fields,
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

    ["claim", token, entry_id, count, url, method] ->
      ctx = person_ctx.(token)
      request = %{uri: URI.parse(url), method: method}

      facts =
        case admitted.(ctx) do
          {:ok, _authority, facts} -> facts
          {:error, _refused} -> %{node_ref: openai <> ":0.0.0", activation_digest: "unadmitted"}
        end

      results =
        for _ <- 1..String.to_integer(count) do
          case Sanctum.InstanceEntries.resolve(ctx, entry_id, request, facts) do
            # The material is dropped here, unread.
            {:ok, %{id: ^entry_id}, _material} ->
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

    ["row_binding", token, entry_id] ->
      ctx = person_ctx.(token)

      case head.(ctx) do
        {_profile, head} ->
          case instance_row.(head, entry_id) do
            nil ->
              answer.(%{row: false})

            row ->
              case Sanctum.Consent.row_binding(ctx, head, row) do
                {:instance, ^entry_id, {:ok, _view}} ->
                  answer.(%{row: true, offered: true})

                {:instance, ^entry_id, {:error, reason}} ->
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
