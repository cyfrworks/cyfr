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
#   entries
#       Every living instance entry, by name, under the platform's actor:
#       its id, kind, provider, status, audience and members, policy, caps
#       and destination, and whether it holds sealed material. No value.
#
#   A person is named by SESSION_TOKEN, their sign-in's session, and acts
#   under the context it establishes as a request establishes it
#   (`Sanctum.Caller.establish/2`), at Prism (origin interactive).
#
#   binding SESSION_TOKEN ENTRY_ID
#       Once the person's athanor is filled (bounded), the head of their
#       owner profile of catalyst:local.openai as the first sign-in's
#       bootstrap committed it: its revision, and the instance binding
#       naming ENTRY_ID with its lifetime and whether its digest is the
#       entry's own.
#
#   admit SESSION_TOKEN
#       The real loader's answer for a run of catalyst:local.openai under
#       the person's context (`Crucible.authority_for/3`'s path), with no
#       run started: the consent it roots on, or the refusal.
#
#   claim SESSION_TOKEN ENTRY_ID COUNT URL METHOD
#       COUNT calls of `Sanctum.InstanceEntries.resolve/4` under the
#       person's context, for a request of METHOD to URL, with the node
#       facts of the root the loader admits for catalyst:local.openai:
#       each answers admitted, or the refusal with a cap's reset and
#       whether it is the database's next UTC midnight. Then the person's
#       count today. The material resolved is dropped here.
#
#   row_binding SESSION_TOKEN ENTRY_ID
#       The person's openai head's instance row naming ENTRY_ID, read live
#       by the loader (`Sanctum.Consent.row_binding/3`): offered or the
#       refusal.
#
#   standing USER_ID
#       The person's standing and how many instance-entry audiences list
#       them.
#
#   focus SESSION_TOKEN ATHANOR_ID
#       The session's person focused on ATHANOR_ID
#       (`Sanctum.Context.focus/2`) and refocused
#       (`Sanctum.Context.refocus/2`): the decision each answers.

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
    today = DateTime.to_date(Arca.ServerMetaStorage.now!())
    DateTime.new!(Date.add(today, 1), ~T[00:00:00.000000], "Etc/UTC")
  end

  case args do
    ["entries"] ->
      {:ok, entries} = Arca.InstanceEntries.list(Prima.Actor.system())

      answer.(%{
        entries:
          for entry <- entries do
            %{
              id: entry.id,
              name: entry.name,
              kind: entry.kind,
              provider_hint: entry.provider_hint,
              status: entry.status,
              audience: entry.audience,
              members: entry.members,
              component_policy: entry.component_policy,
              person_daily: entry.person_daily,
              total_daily: entry.total_daily,
              destination: Jason.decode!(entry.destination || "null"),
              sealed: is_binary(entry.sealed_payload) and entry.sealed_payload != ""
            }
          end
      })

    ["binding", token, entry_id] ->
      ctx = person_ctx.(token)

      case head.(ctx) do
        {profile, head} ->
          {:ok, entry} = Arca.InstanceEntries.get(Prima.Actor.system(), entry_id)
          row = instance_row.(head, entry_id)

          answer.(%{
            profile_id: profile.id,
            consent_id: head.id,
            revision: head.revision,
            bound: not is_nil(row),
            scope: row && row.scope,
            binding_key: row && row.binding_key,
            lifetime: row && Map.get(row, :lifetime_kind),
            digest_is_entry: not is_nil(row) and row.binding_digest == entry.binding_digest,
            instance_rows:
              Enum.count(head.vault_refs, &is_binary(Map.get(&1, :instance_entry_id)))
          })

        :timeout ->
          answer.(%{bound: false, error: "no openai profile was minted within 180 s"})
      end

    ["admit", token] ->
      case admitted.(person_ctx.(token)) do
        {:ok, authority, facts} ->
          answer.(%{
            admitted: true,
            consent_id: authority.consent_id,
            node_ref: facts.node_ref,
            node_digest: is_binary(facts.activation_digest)
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
                reset_at: DateTime.to_iso8601(reset_at),
                reset_is_next_utc_midnight: DateTime.compare(reset_at, next_midnight.()) == :eq
              }

            {:error, {:entry_unavailable, status}} ->
              %{admitted: false, refusal: "entry_unavailable", status: status}

            {:error, reason} ->
              %{admitted: false, refusal: tag.(reason)}
          end
        end

      {:ok, used} =
        Arca.InstanceEntryUsage.used_today(Prima.Actor.system(), entry_id, ctx.user_id)

      answer.(%{node_ref: facts.node_ref, results: results, used_today: used})

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

    ["standing", user_id] ->
      {:ok, user} = Sanctum.Tenancy.Users.get(user_id)
      {:ok, entries} = Arca.InstanceEntries.list(Prima.Actor.system())

      answer.(%{
        status: user.status,
        listed_in: Enum.count(entries, &(user_id in &1.members))
      })

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
