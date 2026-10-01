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
#       The tincture under DIR written into the person's athanor as the
#       local tincture NAME at VERSION and registered from the tree, its
#       manifest as DIR has it but for its version and VARIANT: `base`
#       as it is, `background` asking to keep running when hidden, and
#       `reworded` that and its need's reason in other words.
#
#   head USER_ID REF
#       The head of the person's active owner profile of REF: its
#       revision, digests, admitted origins, and the hosts, storage paths
#       and background permission its policy grants.
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
    case Crucible.authority_for(ctx, :default, ref) do
      {:ok, authority} -> %{admitted: true, consent_id: authority.consent_id}
      {:error, {tag, _payload}} when is_atom(tag) -> %{admitted: false, refusal: tag}
      {:error, reason} -> %{admitted: false, refusal: inspect(reason)}
    end
  end

  case args do
    ["publish", user_id, dir, name, version, variant]
    when variant in ["base", "background", "reworded"] ->
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
        end
        |> Map.put("version", version)

      for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: false),
          File.regular?(file),
          Path.basename(file) != "cyfr-manifest.json" do
        :ok = Arca.put(actor, unit ++ Path.split(Path.relative_to(file, dir)), File.read!(file))
      end

      :ok = Arca.put(actor, unit ++ ["cyfr-manifest.json"], Jason.encode!(manifest))
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
            paths: Prima.Authority.Blob.Edge.paths(ingress)
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
  end
end
