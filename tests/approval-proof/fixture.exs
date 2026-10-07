# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The approval proof's part in the running server, evaluated inside it by
# `bin/cyfr rpc` (tests/approval-proof/run.sh `approval_fixture`). The file
# evaluates to a function of the argument list; each command answers one
# line, `APPROVAL=` and a JSON object of bounded, non-secret facts. It
# grants nothing and binds nothing: the person does that in the browser.
# It calls the real paths named below and reads back what they decided.
# Material the use path resolves, and anything derived from a stored
# entry's sealed bytes but whether they match, is discarded here and never
# serialized.
#
# A person is named by SESSION_TOKEN, their sign-in's session, and acts
# under the context it establishes as a request establishes it
# (`Sanctum.Caller.establish/2`), at Prism (origin interactive). A command
# that takes more than its arguments reads it from ASK, the question file
# the proof wrote, by path, so nothing of it rides the command line.
#
#   clock
#       The database's time (`Arca.ServerMetaStorage.now!/0`).
#
#   publish SESSION_TOKEN DIR NAME VERSION
#       The tincture under DIR written into the person's athanor as the
#       local tincture NAME at VERSION and registered from the tree
#       (`Compendium.Registry.register_from_arca/3`), the release's own
#       install path, as tests/grant-proof/fixture.exs publishes its own.
#
#   state SESSION_TOKEN APP ASK
#       In one read, everything the proof's README names, every row whole,
#       every column as its schema reads it: every row of the athanor's
#       `vault_entries` (tombstoned ones too), each sealed payload replaced
#       by the outcome of comparing it with the digest ASK's `payloads`
#       names for the entry's id; every row of its `vault_defaults`; every
#       profile of APP in the athanor, every consent of those profiles and
#       every binding row of those consents; every row of the athanor's
#       `turns` and `executions`; and, once every row is read, the
#       database's time. It picks no row out of a set and leaves no column
#       out.
#
#       A sealed payload is unsealed here as its owner unseals it
#       (`Sanctum.VaultReader`'s private `unseal_material/2`: the same AAD,
#       `Sanctum.Cipher.decrypt/2` and `Sanctum.Vault.Payload.decode/1`),
#       its decoded document hashed in its canonical text (`Prima.JCS`), and
#       the hash compared with the proof's digest of the document the person
#       typed. The answer is one of `matches`, `differs`, `does_not_unseal`
#       or `absent`; the material and its hash never leave this function.
#
#   requested SESSION_TOKEN ASK
#       For each entry ASK's `entries` describes (provider, field and the
#       destination the person sent), what `vault/create` stores for it: the
#       destination's canonical text (`Prima.Destination.canonical/1`) and
#       the binding digest over the entry's binding fields
#       (`Sanctum.VaultReader.binding_digest/1`). What the request implies,
#       for the proof to compare with what is stored.
#
#   derived SESSION_TOKEN ASK
#       What a commit of the decisions ASK's `spec` names writes on the
#       consent row of APP's head: the policy blob's text, its digest, the
#       activation's text, the shape digest and the commit digest, each built
#       by the owner's own public builders from the installed components and
#       the decisions alone, as `Sanctum.Consent.Commit` builds them
#       (`Sanctum.Consent.BlobBuilder.build/5`, `vault_resource/1`,
#       `provided/3`, `encode/1`, `Sanctum.Consent.ShapeDerivation`,
#       `Sanctum.Consent.ShapeDigest`, `Sanctum.Consent.CommitDigest`), and
#       the source node's edges as the owner's parser reads that blob
#       (`Prima.Authority.Blob.parse/1`, `edge_to_map/1`). An entry is named
#       by its id and the request the person made for it (provider, field,
#       destination), never by its stored row; no consent row is read.
#
#   admit SESSION_TOKEN APP
#       The real loader's answer for a run of APP under the person's context
#       (`Crucible.authority_for/3`'s path), with no run started: the
#       profile and consent it roots on, the source node and the activation
#       digest it verified for it, and the source node's edges as the loaded
#       authority holds them; or the refusal.
#
#   use SESSION_TOKEN APP ASK
#       For each use ASK's `uses` names, the decision of the use path an
#       attached request takes (`Sanctum.Attach.resolve/5`): the binding the
#       loaded root's edge carries (the source's own calls, an account named
#       on them, or a dependency's edge), for a request of a method to a URL,
#       under the root execution id the proof names, with the profile and
#       consent the loader admitted. No request is sent and no execution
#       exists for the id: each answers, in the order asked, the request it
#       decides as the proof sent it (its edge, need, account, root, method
#       and URL) beside admitted or the refusal. The material an admission
#       resolves is dropped here, unread. The entries' last-use writes are
#       flushed before the answer (`Arca.RecordSink`).
#
#   thread SESSION_TOKEN
#       A thread of the person's, made through the `thread` operation's
#       `create` as a console makes one, holding no message.
#
#   announce SESSION_TOKEN APP THREAD_ID NAME
#       The resolution a launch of APP naming the account NAME takes
#       (`Sanctum.Consent.Accounts.resolve/4`); when it is the one a turn
#       ends on, `connection_not_granted`, the event the loop then announces
#       on the turn's thread (`Aqua.Loop.end_for_account/2`), announced on
#       THREAD_ID through `Aqua.Tape.announce/4`: `:consent_required` with
#       the app, the person, the account and its need (none, the app
#       declaring one) and no message. No turn exists.
#
#   account SESSION_TOKEN APP NAME
#       `Sanctum.Consent.Accounts.resolve/4` for NAME: the entry and the
#       stored name, or the refusal.

require Ecto.Query

fn args ->
  answer = fn map -> "APPROVAL=" <> Jason.encode!(map) end

  # The person as their session establishes them, at Prism.
  person_ctx = fn token ->
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})
    %{ctx | origin: :interactive}
  end

  asked = fn path -> path |> File.read!() |> Jason.decode!() end

  tag = fn
    {tag, _payload} when is_atom(tag) -> Atom.to_string(tag)
    {tag, _one, _two} when is_atom(tag) -> Atom.to_string(tag)
    tag when is_atom(tag) -> Atom.to_string(tag)
    %Prima.Refusal{reason: reason} when is_atom(reason) -> Atom.to_string(reason)
    other -> Prima.LoggerContext.shape(other)
  end

  # A refusal as the proof compares it: its tag, and an entry's status
  # where the refusal names one.
  refusal = fn
    {:entry_unavailable, status} when is_binary(status) ->
      %{refusal: "entry_unavailable", status: status}

    {:entry_unavailable, _id, status} when is_binary(status) ->
      %{refusal: "entry_unavailable", status: status}

    reason ->
      %{refusal: tag.(reason)}
  end

  rows_of = fn query ->
    query |> Arca.Repo.all() |> Enum.map(&Map.delete(Map.from_struct(&1), :__meta__))
  end

  # What `vault/create` stores for an attach-only entry of `provider`
  # holding the one field `field`, sent to `destination`: the canonical
  # destination text, its map as a binding carries it, and the binding
  # digest over the entry's binding fields.
  requested = fn %{"provider" => provider, "field" => field, "destination" => destination} ->
    {:ok, parsed} = Prima.Destination.from_map(destination)
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

    %{destination: canonical, map: Prima.Destination.to_map(parsed), binding_digest: digest}
  end

  # The loaded root of APP under the person's context and the source
  # node's edges by key.
  loaded = fn ctx, app ->
    case Crucible.Admission.authority_and_stamp_for(ctx, :default, app) do
      {:ok, %{authority: authority, stamp: stamp}} ->
        graph = (stamp && stamp.activation_graph) || %{}
        {:ok, node} = Prima.Authority.Blob.node(authority.policy, app)
        {:ok, authority, graph, node.edges}

      {:error, reason} ->
        {:error, reason}
    end
  end

  edge_maps = fn edges ->
    Map.new(edges, fn {key, edge} -> {key, Prima.Authority.Blob.edge_to_map(edge)} end)
  end

  case args do
    ["clock"] ->
      answer.(%{now: DateTime.to_iso8601(Arca.ServerMetaStorage.now!())})

    ["publish", token, dir, name, version] ->
      {:ok, ctx} = Sanctum.Caller.establish({:session, token})
      actor = Sanctum.Context.actor(ctx)
      unit = ["components", "tinctures", "local", name, version]

      for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: false), File.regular?(file) do
        :ok = Arca.put(actor, unit ++ Path.split(Path.relative_to(file, dir)), File.read!(file))
      end

      {:ok, component} = Compendium.Registry.register_from_arca(ctx, unit, force: true)
      answer.(%{name: name, version: version, component: Map.get(component, :id)})

    ["state", token, app, ask] ->
      typed = Map.get(asked.(ask), "payloads", %{})
      ctx = person_ctx.(token)
      athanor_id = ctx.athanor_id

      # The stored payload against the digest of what the person typed: the
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

      entries =
        for entry <-
              rows_of.(
                Ecto.Query.from(v in Arca.Schemas.VaultEntry, where: v.athanor_id == ^athanor_id)
              ) do
          Map.put(entry, :sealed_payload, payload.(entry))
        end

      defaults =
        rows_of.(
          Ecto.Query.from(d in Arca.Schemas.VaultDefault, where: d.athanor_id == ^athanor_id)
        )

      profiles =
        rows_of.(
          Ecto.Query.from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^athanor_id and p.source_ref == ^app
          )
        )

      profile_ids = Enum.map(profiles, & &1.id)

      consents =
        rows_of.(
          Ecto.Query.from(c in Arca.Schemas.Consent,
            where: c.athanor_id == ^athanor_id and c.profile_id in ^profile_ids
          )
        )

      consent_ids = Enum.map(consents, & &1.id)

      refs =
        rows_of.(
          Ecto.Query.from(r in Arca.Schemas.ConsentVaultRef,
            where: r.athanor_id == ^athanor_id and r.consent_id in ^consent_ids
          )
        )

      turns =
        rows_of.(Ecto.Query.from(t in Arca.Schemas.Turn, where: t.athanor_id == ^athanor_id))

      executions =
        rows_of.(Ecto.Query.from(e in Arca.Schemas.Execution, where: e.athanor_id == ^athanor_id))

      # The database's time once every row is read: the end of the window a
      # stored time is held to.
      now = Arca.ServerMetaStorage.now!()

      answer.(%{
        now: DateTime.to_iso8601(now),
        entries: entries,
        defaults: defaults,
        profiles: profiles,
        consents: consents,
        refs: refs,
        turns: turns,
        executions: executions
      })

    ["requested", _token, ask] ->
      implied =
        for entry <- Map.fetch!(asked.(ask), "entries") do
          Map.take(requested.(entry), [:destination, :binding_digest])
        end

      answer.(%{entries: implied})

    ["derived", token, ask] ->
      ctx = person_ctx.(token)
      spec = Map.fetch!(asked.(ask), "spec")
      app = Map.fetch!(spec, "app")

      {:ok, component} = Sanctum.Consent.Plan.fetch_component(ctx, app)
      {:ok, activation} = Sanctum.Consent.Components.resolve(ctx, component)
      graph = activation.graph
      {:ok, rows} = Sanctum.Consent.Plan.closure_rows(ctx, component, graph)

      manifest_of = fn key ->
        {:ok, manifest} =
          Prima.Manifest.decode_strict(Prima.ComponentRow.field(Map.fetch!(rows, key), :manifest))

        manifest
      end

      need_of = fn key, name ->
        key
        |> manifest_of.()
        |> Prima.Manifest.Needs.from_manifest()
        |> Enum.find(&(&1.name == name))
      end

      lifetime = fn
        %{"kind" => "until", "until" => until} ->
          {:ok, instant, 0} = DateTime.from_iso8601(until)
          %{kind: "until", until: DateTime.truncate(instant, :microsecond)}

        %{"kind" => kind} ->
          %{kind: kind, until: nil}
      end

      digest_lifetime = fn
        %{kind: "until", until: until} -> %{kind: "until", until: DateTime.to_iso8601(until)}
        %{kind: kind} -> %{kind: kind}
      end

      # One decided binding of an entry the person chose, as the commit
      # resolves it: the need's projection and attach rule, the entry's
      # scope and the destination and digest its request implies.
      bound = fn item, node ->
        need = need_of.(node, Map.fetch!(item, "need"))
        entry = Map.fetch!(item, "entry")
        implied = requested.(Map.put(entry, "field", hd(need.fields)))

        %{
          need: need.name,
          name: Map.get(item, "name"),
          entry_id: Map.fetch!(entry, "id"),
          binding_digest: implied.binding_digest,
          scope: "athanor",
          destination: implied.map,
          attach: Prima.Manifest.Needs.attach_to_map(need.attach),
          fields: need.fields,
          scopes: need.scopes,
          lifetime: lifetime.(Map.fetch!(item, "lifetime")),
          renew: Map.get(item, "renew", false)
        }
      end

      bindings = for item <- Map.get(spec, "bindings", []), do: bound.(item, app)

      selections =
        for item <- Map.get(spec, "selections", []) do
          item
          |> bound.(Map.fetch!(item, "dep"))
          |> Map.merge(%{from: Map.fetch!(item, "from"), dep: Map.fetch!(item, "dep")})
        end

      {:ok, subset} =
        Sanctum.Consent.Normalize.subset(
          %{subset: Map.get(spec, "subset", %{})},
          :subset,
          :invalid_decision
        )

      origins =
        for origin <- Map.fetch!(spec, "origins") do
          {:ok, origin} = Prima.Origin.from_wire(origin)
          origin
        end

      # The source's bindings ride its ingress as one resource: the default
      # with each named account beside it (`Commit`'s `source_resource/1`).
      source_vault =
        case Enum.split_with(bindings, &is_nil(&1.name)) do
          {[], []} ->
            nil

          {[default], named} ->
            Sanctum.Consent.BlobBuilder.vault_resource(
              Map.put(default, :named, Enum.sort_by(named, & &1.name))
            )
        end

      {defaults, named} = Enum.split_with(selections, &is_nil(&1.name))
      chosen = Map.new(defaults, &{{&1.from, &1.dep}, &1})
      named = Enum.group_by(named, &{&1.from, &1.dep})

      # What each node provides each of its dependencies, as the commit
      # reads it (`Commit`'s `provided_edges/3`).
      provided =
        for from <- graph |> Map.keys() |> Enum.sort(),
            manifest = manifest_of.(from),
            dep <- Sanctum.Consent.BlobBuilder.dep_edges(manifest, graph, from),
            %{covered: [{_need, resource}]} <- [
              Sanctum.Consent.BlobBuilder.provided(manifest, dep, manifest_of.(dep))
            ],
            into: %{},
            do: {{from, dep}, resource}

      vault_fn = fn node_key, _row, _manifest -> if node_key == app, do: source_vault end

      edge_vault_fn = fn from, dep, _row, _manifest, _provided ->
        case Map.fetch(chosen, {from, dep}) do
          {:ok, selection} ->
            Sanctum.Consent.BlobBuilder.vault_resource(
              Map.put(selection, :named, Enum.sort_by(Map.get(named, {from, dep}, []), & &1.name))
            )

          :error ->
            Map.get(provided, {from, dep})
        end
      end

      {:ok, nodes} =
        Sanctum.Consent.BlobBuilder.build(ctx, graph, app, vault_fn,
          rows: rows,
          edge_vault_fn: edge_vault_fn,
          subset: subset
        )

      {:ok, blob_json} = Sanctum.Consent.BlobBuilder.encode(nodes)
      blob_digest = Prima.JCS.hash_binary(blob_json)
      {:ok, activation_json} = Prima.JCS.encode(graph)
      {:ok, input} = Sanctum.Consent.ShapeDerivation.shape_input(ctx, app)
      {:ok, shape_digest} = Sanctum.Consent.ShapeDigest.compute(input)

      # The decisions as the commit digest reads them (`Commit`'s
      # `digest_binding/1` and `digest_selection/1`).
      digest_binding = fn binding ->
        binding
        |> Map.take([:need, :binding_digest, :fields, :scopes, :name, :renew])
        |> Map.put(:entry_id, binding.entry_id)
        |> Map.put(:lifetime, digest_lifetime.(binding.lifetime))
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
      end

      digest_selection = fn selection ->
        selection
        |> Map.take([:from, :dep, :need, :binding_digest, :fields, :renew])
        |> Map.put(:entry_id, selection.entry_id)
        |> Map.put(:lifetime, digest_lifetime.(selection.lifetime))
        |> Prima.MapUtil.put_present(:name, selection.name)
      end

      {:ok, commit_digest} =
        Sanctum.Consent.CommitDigest.compute(%{
          removed: Map.get(spec, "removed", []),
          shape_digest: shape_digest,
          blob_digest: blob_digest,
          label: "default",
          kind: :owner,
          invoke_mode: :open_inert,
          origins: origins,
          bindings: Enum.map(bindings, digest_binding),
          selections: Enum.map(selections, digest_selection),
          tool_servers: [],
          override: false,
          subset: subset
        })

      {:ok, blob} = Prima.Authority.Blob.parse(blob_json)
      {:ok, node} = Prima.Authority.Blob.node(blob, app)

      answer.(%{
        resolved_policy: blob_json,
        blob_digest: blob_digest,
        activation: activation_json,
        shape_digest: shape_digest,
        commit_digest: commit_digest,
        node_digest: Map.get(graph, app),
        edges: edge_maps.(node.edges)
      })

    ["admit", token, app] ->
      case loaded.(person_ctx.(token), app) do
        {:ok, authority, graph, edges} ->
          answer.(%{
            admitted: true,
            profile_id: authority.profile_id,
            consent_id: authority.consent_id,
            node_ref: app,
            node_digest: Map.get(graph, app),
            edges: edge_maps.(edges)
          })

        {:error, reason} ->
          answer.(Map.put(refusal.(reason), :admitted, false))
      end

    ["use", token, app, ask] ->
      ctx = person_ctx.(token)
      uses = Map.fetch!(asked.(ask), "uses")

      case loaded.(ctx, app) do
        {:ok, authority, graph, edges} ->
          results =
            for use <- uses do
              target = Map.fetch!(use, "edge")

              found =
                if target == Prima.Authority.Blob.ingress_key() do
                  Map.fetch(edges, target)
                else
                  case Enum.find(edges, fn {key, _edge} ->
                         Prima.Authority.Blob.edge_target(key) == {:ok, target}
                       end) do
                    {_key, edge} -> {:ok, edge}
                    nil -> :error
                  end
                end

              node_ref = if target == Prima.Authority.Blob.ingress_key(), do: app, else: target

              facts = %{
                node_ref: node_ref,
                activation_digest: Map.get(graph, node_ref),
                root_execution_id: Map.fetch!(use, "root"),
                profile_id: authority.profile_id,
                consent_id: authority.consent_id
              }

              request = %{
                uri: URI.parse(Map.fetch!(use, "url")),
                method: Map.fetch!(use, "method")
              }

              decision =
                with {:ok, edge} <- found,
                     {:ok, vault} <-
                       Prima.Authority.Blob.vault_for(edge, Map.get(use, "account")) do
                  case Sanctum.Attach.resolve(ctx, vault, Map.fetch!(use, "need"), request, facts) do
                    # The material is dropped here, unread.
                    {:ok, _material} -> %{admitted: true}
                    {:error, reason} -> Map.put(refusal.(reason), :admitted, false)
                  end
                else
                  :error -> %{admitted: false, refusal: "no_edge"}
                  {:error, reason} -> Map.put(refusal.(reason), :admitted, false)
                end

              # The request this answers, as the proof sent it.
              Map.put(decision, :request, Map.take(use, ~w(edge need account root method url)))
            end

          :ok = Arca.RecordSink.flush()
          answer.(%{admitted: true, results: results})

        {:error, reason} ->
          answer.(Map.put(refusal.(reason), :admitted, false))
      end

    ["thread", token] ->
      {:ok, ctx} = Sanctum.Caller.establish({:session, token})
      {:ok, thread} = PrismWeb.Ops.call_tool(ctx, "thread", %{"action" => "create"})
      answer.(%{thread_id: Map.get(thread, :id) || Map.get(thread, "id")})

    ["announce", token, app, thread_id, name] ->
      ctx = person_ctx.(token)

      case Sanctum.Consent.Accounts.resolve(ctx, :default, app, name) do
        {:error, :connection_not_granted} ->
          # What `Aqua.Loop.end_for_account/2` announces when a launch names
          # an account its app does not bind; the app declares one need.
          :ok =
            Aqua.Tape.announce(ctx, thread_id, :consent_required, %{
              ref: app,
              user_id: ctx.user_id,
              account: %{name: name, need: nil},
              message_id: nil
            })

          answer.(%{resolution: "connection_not_granted", announced: true})

        {:ok, _bound} ->
          answer.(%{resolution: "bound", announced: false})

        {:error, reason} ->
          answer.(%{resolution: tag.(reason), announced: false})
      end

    ["account", token, app, name] ->
      case Sanctum.Consent.Accounts.resolve(person_ctx.(token), :default, app, name) do
        {:ok, %{entry_id: id, name: stored}} ->
          answer.(%{resolved: true, entry_id: id, name: stored})

        {:error, reason} ->
          answer.(Map.put(refusal.(reason), :resolved, false))
      end
  end
end
