# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Profile do
  @moduledoc """
  Profile tool handlers for the Sanctum MCP provider — the consent walk
  over `Sanctum.Consent.{Plan,Commit}` plus thin list/revoke, and the
  read of which grants reach a resource (`grants`).

  Consent errors remain typed across this boundary. A key-authenticated
  commit loads its consent capability from the stored key row, never from
  caller input.
  """

  require Prima.Refusal

  alias Prima.Authority.Blob
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.Plan
  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}
    # Dispatch applies the coarse consent class; the domain applies
    # the exact one (commit's digest-pinned key-capability arm lives
    # in Sanctum.Consent.Commit and stays there).
    lifetime_arg =
      Arg.new(
        "lifetime",
        {:record,
         [
           Arg.new("kind", :string,
             required: true,
             enum: ["standing", "until", "once"],
             description: "standing until revoked, until a time, or once (one root run)"
           ),
           Arg.new("until", :string,
             description:
               "until only: an RFC 3339 instant in UTC, after now and at most 24 hours away"
           )
         ]},
        description: "How long the binding lives; standing when absent"
      )

    renew_arg =
      Arg.new("renew", :boolean,
        description: "true makes a consumed once binding consumable again; false by default"
      )

    bindings_arg =
      Arg.new(
        "bindings",
        {:array,
         Arg.new(
           nil,
           {:record,
            [
              Arg.new("need", :string),
              Arg.new("entry_id", :string,
                description:
                  "An entry of the athanor (vlt_…); exactly one of entry_id and instance_entry_id"
              ),
              Arg.new("instance_entry_id", :string,
                description:
                  "An instance entry offered to you (ine_…); exactly one of entry_id and " <>
                    "instance_entry_id"
              ),
              Arg.new("name", :string,
                description:
                  "The account name of a named binding beside the need's default; absent " <>
                    "for the default"
              ),
              lifetime_arg,
              renew_arg,
              Arg.new("fields", {:array, Arg.new(nil, :string)}),
              Arg.new("scopes", {:array, Arg.new(nil, :string)})
            ]}
         )},
        description:
          "The credentials to bind, one need's: [{need:'@ingress', entry_id | " <>
            "instance_entry_id, name, lifetime, renew, fields, scopes}]"
      )

    decisions_arg =
      Arg.new(
        "decisions",
        {:record,
         [
           Arg.new("ref", :string),
           Arg.new("kind", :string, enum: ["owner", "public"]),
           Arg.new("label", :string),
           Arg.new("scope", :string, enum: ["versionless", "pinned"]),
           Arg.new("invoke_mode", :string, enum: ["open_inert", "edge_only"]),
           bindings_arg,
           Arg.new(
             "selections",
             {:array,
              Arg.new(
                nil,
                {:record,
                 [
                   Arg.new("dep", :string, required: true),
                   Arg.new("label", :string,
                     description:
                       "The dependency's profile that lends its key; at most one of label, " <>
                         "entry_id and instance_entry_id, label 'default' when none"
                   ),
                   Arg.new("entry_id", :string,
                     description: "An entry of the athanor bound on the dependency's edge"
                   ),
                   Arg.new("instance_entry_id", :string,
                     description: "An instance entry offered to you, bound on the edge"
                   ),
                   Arg.new("need", :string,
                     description:
                       "The dependency's credential need the entry is for; required when it " <>
                         "declares several, never with a label"
                   ),
                   Arg.new("name", :string,
                     description:
                       "The account name of a named selection beside the edge's default " <>
                         "entry; it names an entry, never a label; absent for the default"
                   ),
                   Arg.new("from", :string),
                   Arg.new("fields", {:array, Arg.new(nil, :string)}),
                   lifetime_arg,
                   renew_arg
                 ]}
              )}
           ),
           Arg.new(
             "tool_servers",
             {:array,
              Arg.new(
                nil,
                {:record,
                 [
                   Arg.new("server_name", :string, required: true),
                   Arg.new("tool_patterns", {:array, Arg.new(nil, :string)})
                 ]}
              )}
           ),
           Arg.new("override", :boolean),
           Arg.new("publish_from", :string),
           Arg.new("need_ids", {:array, Arg.new(nil, :string)}),
           Arg.new("durable_storage", :boolean),
           Arg.new("origins", {:array, Arg.new(nil, :string, enum: Prima.Origin.spellings())},
             min: 1,
             description: "The origins the grant admits; absent, interactive alone"
           ),
           Arg.new("subset", {:map, subset_node_arg()},
             description:
               "Per consent-graph node, the part of the ask granted; a missing kind or field keeps its ask, an empty set grants none"
           )
         ]},
        required: true,
        description:
          "The operator's choices: ref, scope, invoke_mode, bindings [{need:'@ingress', " <>
            "entry_id | instance_entry_id, name, lifetime, renew, fields, scopes}], selections, " <>
            "override"
      )

    Operation.tool(
      [
        Operation.new(
          "profile",
          "plan",
          "Plan profile",
          [
            Arg.new("ref", :string,
              required: true,
              description: "Component reference to grant (name-level or versioned)"
            ),
            Arg.new("kind", :string, enum: ["owner", "public"]),
            Arg.new("label", :string, description: "Profile label (default 'default')")
          ],
          kind: :write,
          planes: [:external],
          consent: :staging
        ),
        Operation.new("profile", "preview", "Preview profile", [decisions_arg],
          kind: :write,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "profile",
          "commit",
          "Commit profile",
          [
            decisions_arg,
            Arg.new("plan_token", :string, required: true, description: "From plan"),
            Arg.new("proof", :string, required: true, description: "From preview"),
            Arg.new("commit_digest", :string,
              required: true,
              description: "The digest preview rendered — what is being approved"
            ),
            Arg.new("expected_consent_revision", :integer,
              required: true,
              nullable: true,
              description: "The revision plan reported"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "profile",
          "grant",
          "Grant profile",
          [
            Arg.new("profile_id", :string,
              required: true,
              description: "Profile id (grant/list/revoke)"
            ),
            bindings_arg,
            Arg.new("expected_consent_revision", :integer,
              required: true,
              nullable: true,
              description: "The revision plan reported"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "profile",
          "publish",
          "Publish profile",
          [
            Arg.new("profile_id", :string,
              required: true,
              description: "Profile id (grant/list/revoke)"
            ),
            Arg.new("need_ids", {:array, Arg.new(nil, :string)},
              description:
                "publish only: edge keys whose credentials the public profile keeps (default none — expose without credentials)"
            ),
            Arg.new("durable_storage", :boolean,
              description:
                "publish only: allow durable writes (default false — read-only storage)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "profile",
          "list",
          "List profile",
          [
            Arg.new("ref", :string,
              required: true,
              description: "Component reference to grant (name-level or versioned)"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "profile",
          "grants",
          "Grants reaching a resource",
          [
            Arg.new("domain", :string,
              description: "grants: an egress domain; name exactly one of domain, path, entry_id"
            ),
            Arg.new("path", :string,
              description: "grants: a storage path; name exactly one of domain, path, entry_id"
            ),
            Arg.new("entry_id", :string,
              description:
                "grants: a vault entry (vlt_…); name exactly one of domain, path, entry_id"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "profile",
          "revoke",
          "Revoke profile",
          [
            Arg.new("profile_id", :string,
              required: true,
              description: "Profile id (grant/list/revoke)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Grant, inspect and revoke profiles — the consent walk. plan stages the facts and candidates: each need, and each need of a dependency, answers its candidates (own or instance entries of its kind and provider), the one it has suggested, whether a choice_required, and its source (own, instance, or provided by the app); preview renders exactly what would be granted and mints the proof, commit verifies the proof against a live recomputation and writes an immutable revision; list answers each profile's head_state — present, missing, damaged, or unavailable when the store could not answer — beside head_revision, which is set only when the head is present, and lists a profile row that is damaged as status corrupt with head_state damaged, its head not read; grants reads which grants reach a resource: it is refused unavailable when the stored heads, or a profile a grant borrows a key from, cannot be read, and corrupt when a head the store returns fails its digest, does not parse or disagrees with its stored references, or when a profile a grant borrows a key from is damaged; a head row that does not decode is not listed by the store, so grants does not read it. plan is refused unavailable when the components, the consent profiles, the vault or the instance entries offered to the person cannot be read, not_found when its component is not installed, and corrupt when its stored manifest is damaged or its profile's head row does not decode, fails its digest or does not parse. plan, preview, commit and grant are refused unavailable when the components, or a profile that would lend a dependency its key, cannot be read (for plan, or the entry that profile binds), and corrupt when that profile is damaged or when the head row of the profile they would revise does not decode; preview, commit and grant are refused corrupt when a dependency's stored manifest is damaged, which plan answers as a closure unresolved with reason corrupt_manifest, so nothing is granted over it. Nothing is granted outside this walk.",
      title: "Profiles & Consent"
    )
  end

  # One consent-graph node's narrowing: a closed record per resource kind
  # its enforcement point can check, and nothing for a credential, a
  # tincture or arbitrary JSON.
  defp subset_node_arg do
    alias Prima.Arg

    strings = fn name -> Arg.new(name, {:array, Arg.new(nil, :string)}) end

    Arg.new(
      nil,
      {:record,
       [
         Arg.new(
           "egress",
           {:record,
            [
              strings.("domains"),
              strings.("methods"),
              strings.("schemes"),
              strings.("private_ips")
            ]}
         ),
         Arg.new("storage", {:record, [strings.("paths"), strings.("actions")]}),
         strings.("tools"),
         Arg.new("limits", {:record, limits_subset_fields()})
       ]}
    )
  end

  # The limits vocabulary (`Prima.Limits.fields/0`): the four integer
  # limits, the two duration strings and the rate limit's record.
  defp limits_subset_fields do
    alias Prima.Arg

    for field <- Prima.Limits.fields() do
      name = Atom.to_string(field)

      case field do
        :rate_limit ->
          Arg.new(
            name,
            {:record, [Arg.new("requests", :integer), Arg.new("window", :string)]}
          )

        duration when duration in [:timeout, :batch_timeout] ->
          Arg.new(name, :string)

        _integer ->
          Arg.new(name, :integer)
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "plan", "ref" => ref} = args) do
    with {:ok, kind} <- kind(args) do
      params =
        %{ref: ref, kind: kind}
        |> Prima.MapUtil.put_present(:label, args["label"])

      case Plan.plan(ctx, params) do
        {:ok, plan} -> {:ok, plan}
        {:error, reason} -> {:error, walk_refusal(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "plan"}) do
    {:error, "plan requires ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "preview", "decisions" => decisions})
      when is_map(decisions) do
    with {:ok, decoded} <- decode_decisions(decisions) do
      case Commit.preview(ctx, decoded) do
        {:ok, preview} -> {:ok, preview}
        {:error, reason} -> {:error, walk_refusal(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "preview"}) do
    {:error, "preview requires decisions"}
  end

  def handle(%Context{} = ctx, %{"action" => "commit", "decisions" => decisions} = args)
      when is_map(decisions) do
    with {:ok, decoded} <- decode_decisions(decisions),
         {:ok, capability} <- key_capability(ctx) do
      params = %{
        decisions: decoded,
        plan_token: args["plan_token"] || "",
        proof: args["proof"] || "",
        commit_digest: args["commit_digest"] || "",
        expected_consent_revision: args["expected_consent_revision"]
      }

      case Commit.commit(ctx, params, key_capability: capability) do
        {:ok, result} -> {:ok, Map.put(result, :status, "committed")}
        {:error, reason} -> {:error, walk_refusal(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "commit"}) do
    {:error,
     "commit requires decisions, plan_token, proof, commit_digest and expected_consent_revision"}
  end

  # The simple grant: a credential bound to an existing owner consent
  # whose shape has not moved, with the revision as the compare-and-set.
  # No preview stands before it, so it answers the head's bindings it
  # removed (`removed`, as a preview of it lists them) beside the revision.
  def handle(%Context{} = ctx, %{"action" => "grant", "profile_id" => profile_id} = args) do
    with {:ok, bindings} <- decode_bindings(Map.get(args, "bindings", [])) do
      params = %{
        profile_id: profile_id,
        bindings: bindings,
        expected_consent_revision: args["expected_consent_revision"]
      }

      case Commit.grant(ctx, params) do
        {:ok, result} -> {:ok, Map.put(result, :status, "granted")}
        {:error, reason} -> {:error, walk_refusal(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "grant"}) do
    {:error,
     {:invalid_argument, "grant requires profile_id, bindings and expected_consent_revision"}}
  end

  def handle(%Context{} = ctx, %{"action" => "publish", "profile_id" => profile_id} = args) do
    params = %{
      profile_id: profile_id,
      need_ids: Map.get(args, "need_ids", []),
      durable_storage: args["durable_storage"] == true
    }

    case Commit.stage_publish(ctx, params) do
      {:ok, staged} -> {:ok, staged}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "publish"}) do
    {:error, "publish requires profile_id (the owner profile to publish from)"}
  end

  def handle(%Context{} = ctx, %{"action" => "list", "ref" => ref}) do
    # The registry gate already applies the annotation's consent class —
    # this arm and revoke's are deliberate defense in depth for direct
    # callers of the handler.
    with :ok <- Sanctum.Consent.Authz.authorize_staging(ctx),
         {:ok, source_ref} <- Plan.name_ref(ref),
         {:ok, entries} <- Arca.ConsentStorage.profile_entries(Context.actor(ctx), source_ref) do
      {:ok, %{profiles: Enum.map(entries, &listed_profile(ctx, &1))}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "list"}) do
    {:error, "list requires ref"}
  end

  # Which grants of the caller's athanor reach one resource
  # (`grants_reaching/2`). The same defense in depth as list's.
  def handle(%Context{} = ctx, %{"action" => "grants"} = args) do
    case Sanctum.Consent.Authz.authorize_staging(ctx) do
      :ok -> grants_reaching(ctx, args)
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "profile_id" => profile_id}) do
    with {:ok, :interactive} <- Sanctum.Consent.Authz.authorize_interactive(ctx),
         :ok <- Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), profile_id, "revoked") do
      {:ok, %{status: "revoked", profile_id: profile_id}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "revoke requires profile_id"}
  end

  def handle(_ctx, _args) do
    {:error, Prima.Provider.invalid_action("profile", action_enum())}
  end

  # A profile as `list` answers it. A row whose kind or status is outside
  # the closed vocabulary is listed, never dropped, as damaged: its head is
  # not read, since nothing it holds can be trusted.
  defp listed_profile(_ctx, %{id: id, status: :corrupt}),
    do: %{id: id, status: :corrupt, head_state: "damaged", head_revision: nil}

  defp listed_profile(ctx, profile) do
    {state, revision} = head_state(ctx, profile.id)
    Map.merge(profile, %{head_state: state, head_revision: revision})
  end

  # A profile's head as `list` answers it, read three ways, never one: a
  # head absent, one stored outside the closed vocabulary and one the
  # store could not answer each say so, so an outage never reads as "no
  # consent". The revision is the head's only when it was read.
  defp head_state(ctx, profile_id) do
    case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile_id) do
      {:ok, consent} -> {"present", consent.revision}
      {:error, absent} when absent in [:not_found, :no_head] -> {"missing", nil}
      {:error, {:invalid_stored_value, _value}} -> {"damaged", nil}
      {:error, _unanswered} -> {"unavailable", nil}
    end
  end

  # ---------------------------------------------------------------------------
  # The grant read — which grants reach one resource
  # ---------------------------------------------------------------------------

  # The head revision of each active profile of the caller's athanor, read
  # as the loader carries it (`Sanctum.Consent.Loader.admitted_blob/3`), so
  # no grant shows wider or narrower than it runs: its built blob,
  # narrowing already applied, with every selection the loader resolves
  # resolved. The heads themselves come from
  # `Arca.ConsentStorage.active_heads/2`, never through the loader's head
  # read: a store that cannot answer them refuses the whole read, and a
  # head row that does not decode is not among them (`active_heads/2`
  # drops it). A head the loader cannot trust (its validity, digest,
  # parse, blob/refs equality or binding digests) refuses the whole read
  # as that damage, in the loader's one reading of it
  # (`Sanctum.Consent.Loader.damage_refusal/3`, the damaged head
  # `{:head_corrupt, profile_id}`); a head asked again under the canonical
  # spelling of its storage paths reaches nothing. A lender the store
  # could not answer, or whose profile row or head does not decode, or
  # whose head's bytes fail their digest or do not parse, refuses the
  # whole read with that reason (`Sanctum.Unauthorized`'s sentence): an
  # answer short of that head's grants would read as "reaches nothing". A
  # lender admits a borrower's load only under an origin the lender's own
  # revision names, so a head is loaded under each origin its revision
  # admits and reaches a resource when any of those loads carries it.
  # Every edge counts:
  #
  # - a domain, as egress pins a host (`Prima.Network.domain_allowed?/2`),
  #   on an edge that also allows a method and a scheme;
  # - a path, as the storage door reads a grant
  #   (`Prima.ComponentPath.path_granted?/2`), on an edge that allows an
  #   action. A loaded head spells every pattern as the door reaches it, so
  #   a pattern is matched as written;
  # - a vault entry, on every edge the load binds to it: the revision's own
  #   references, and a selection (`via`) resolved to a lender's bound
  #   entry, which names the label it selected and the lender's profile.
  #
  # Only an active profile's head counts: the loader roots no other. At
  # most `@grants_heads_cap` heads are read, in profile-id order, and the
  # answer says when the athanor holds more (`truncated`).
  @grants_heads_cap 1_000

  defp grants_reaching(ctx, args) do
    with {:ok, resource} <- grants_resource(args),
         {:ok, heads, truncated?} <- grant_heads(ctx, resource),
         {:ok, grants} <- reaching_grants(ctx, heads, resource) do
      {:ok,
       %{
         resource: resource_answer(resource),
         grants: grants,
         count: length(grants),
         truncated: truncated?
       }}
    end
  end

  @grant_resources ~w(domain path entry_id)

  defp grants_resource(args) do
    case Enum.reject(@grant_resources, &is_nil(args[&1])) do
      [key] -> grant_resource(key, args[key])
      _none_or_several -> grants_refusal("grants names exactly one of domain, path, entry_id")
    end
  end

  defp grant_resource(key, value) when not is_binary(value) or value == "",
    do: grants_refusal("grants: #{key} must be a non-empty string")

  # A wildcard is a pattern a grant may hold, never a host a request names.
  defp grant_resource("domain", domain) do
    if String.contains?(domain, "*"),
      do: grants_refusal("grants: domain names one host, never a pattern"),
      else: {:ok, {:domain, domain}}
  end

  # Read as the storage doors read a path: relative to the athanor root,
  # with its empty segments trimmed, and refused whole when a segment is
  # unsafe.
  defp grant_resource("path", path) do
    segments = String.split(path, "/", trim: true)

    case segments != [] && Prima.PathSafety.validate_segments(segments) do
      :ok -> {:ok, {:path, Enum.join(segments, "/")}}
      false -> grants_refusal("grants: path names no file or folder")
      {:error, {_reason, message}} -> grants_refusal("grants: path is refused: #{message}")
    end
  end

  defp grant_resource("entry_id", entry_id), do: {:ok, {:entry_id, entry_id}}

  defp grants_refusal(message), do: {:error, {:invalid_argument, message}}

  # A path outside every guest scope is one no grant can reach, and an
  # entry that is not the caller's athanor's is refused as unknown, the
  # same answer whether it exists elsewhere or nowhere.
  defp grant_heads(ctx, {:path, path}) do
    if Arca.Storage.valid_guest_path?(path), do: active_heads(ctx), else: {:ok, [], false}
  end

  defp grant_heads(ctx, {:entry_id, entry_id}) do
    case Arca.VaultStorage.get(Context.actor(ctx), entry_id) do
      {:ok, _entry} -> active_heads(ctx)
      {:error, :not_found} -> {:error, {:not_found, "Vault entry", entry_id}}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  defp grant_heads(ctx, {:domain, _domain}), do: active_heads(ctx)

  defp active_heads(ctx) do
    case Arca.ConsentStorage.active_heads(Context.actor(ctx), limit: @grants_heads_cap) do
      {:ok, heads, truncated?} -> {:ok, heads, truncated?}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  # Each head's grant in head order, or the first refusal a head's load
  # answers that is no grant reaching nothing.
  defp reaching_grants(ctx, heads, resource) do
    heads
    |> Enum.reduce_while({:ok, []}, fn head, {:ok, reached} ->
      case reaching_grant(ctx, head, resource) do
        {:ok, grants} -> {:cont, {:ok, [grants | reached]}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, reached} -> {:ok, reached |> Enum.reverse() |> Enum.concat()}
      {:error, _} = refused -> refused
    end
  end

  defp reaching_grant(ctx, %{profile: profile, consent: consent}, resource) do
    case reaching_edges(ctx, profile, consent, resource) do
      {:ok, []} ->
        {:ok, []}

      {:ok, edges} ->
        {:ok,
         [
           %{
             profile_id: profile.id,
             source_ref: profile.source_ref,
             kind: Atom.to_string(profile.kind),
             label: profile.label,
             consent_id: consent.id,
             revision: consent.revision,
             admitted_origins: Prima.Origin.to_wire_list(consent.admitted_origins),
             edges: edges
           }
         ]}

      {:error, _} = refused ->
        refused
    end
  end

  # The edges of the first load, among the origins the revision admits,
  # that carries the resource; none when no such load does. A lender that
  # could not be read or does not decode refuses the read. The app's own
  # head the loader cannot trust refuses it as that damage, in the
  # loader's one reading of it (`Loader.damage?/1`, `damage_refusal/3`):
  # read as reaching nothing, a grant that exists would read as none. Any
  # other refusal, a revision asked again under the canonical spelling of
  # its paths or a lender that does not admit the origin, reaches nothing
  # under that origin.
  defp reaching_edges(ctx, profile, consent, resource) do
    Enum.reduce_while(consent.admitted_origins, {:ok, []}, fn origin, none ->
      case Loader.admitted_blob(%{ctx | origin: origin}, profile, consent) do
        {:ok, blob} ->
          case loaded_edges(blob, consent, resource) do
            [] -> {:cont, none}
            edges -> {:halt, {:ok, edges}}
          end

        {:error, {:lender_unavailable, _target}} = refused ->
          {:halt, refused}

        {:error, {:lender_corrupt, _target, _profile_id}} = refused ->
          {:halt, refused}

        {:error, reason} ->
          case own_head_refusal(reason, profile) do
            nil -> {:cont, none}
            refusal -> {:halt, {:error, refusal}}
          end
      end
    end)
  end

  # The app's own head refused: its damage as the loader names it, and,
  # defensively, an answer the consent vocabulary classes unavailable as
  # that head unanswered. `admitted_blob/3` reads no store for the app's
  # own head today (the heads and their references arrive read, and a
  # store that cannot answer them refuses the whole read first), so no
  # such answer reaches here; one that did would be an outage, never a
  # grant reaching nothing.
  defp own_head_refusal(reason, profile) do
    cond do
      Loader.damage?(reason) ->
        Loader.damage_refusal(reason, profile.id, profile.source_ref)

      Sanctum.Unauthorized.reason?(reason) and Sanctum.Unauthorized.class(reason) == :unavailable ->
        {:head_unavailable, profile.id}

      true ->
        nil
    end
  end

  defp loaded_edges(blob, consent, resource) do
    edges =
      for {node_ref, %Blob.Node{edges: edges}} <- Enum.sort(blob.nodes),
          {key, edge} <- Enum.sort(edges),
          %{} = reached <- [edge_reach(edge, resource)],
          do: Map.merge(%{node: node_ref, edge: key}, reached)

    if Enum.any?(edges, &match?(%{vault: %{lender: _}}, &1)),
      do: name_lenders(edges, consent),
      else: edges
  end

  # A borrowed entry names the label its selection asked for, read from the
  # revision as granted, since the load replaces the selection with the
  # lender's bound entry. An edge granted bound is the revision's own
  # reference, whatever its stored form says of a lender.
  defp name_lenders(edges, consent) do
    case Blob.parse(consent.resolved_policy) do
      {:ok, %Blob{nodes: granted}} -> Enum.map(edges, &name_lender(&1, granted))
      {:error, _unparsed} -> []
    end
  end

  defp name_lender(
         %{node: node_ref, edge: key, vault: %{lender: lender} = vault} = reached,
         granted
       ) do
    case granted do
      %{^node_ref => %Blob.Node{edges: %{^key => %Blob.Edge{vault: %{via: %{label: label}}}}}} ->
        %{reached | vault: %{vault | lender: %{label: label, profile_id: lender.profile_id}}}

      _granted_bound ->
        %{reached | vault: Map.delete(vault, :lender)}
    end
  end

  defp name_lender(reached, _granted), do: reached

  defp edge_reach(%{egress: %{} = egress}, {:domain, domain}) do
    grant = %{
      domains: Map.get(egress, :domains, []),
      methods: Map.get(egress, :methods, []),
      schemes: Map.get(egress, :schemes, []),
      private_ips: Map.get(egress, :private_ips, [])
    }

    if Prima.Network.domain_allowed?(domain, grant.domains) and grant.methods != [] and
         grant.schemes != [],
       do: %{egress: grant}
  end

  defp edge_reach(%{storage: %{} = storage}, {:path, path}) do
    grant = %{paths: Map.get(storage, :paths, []), actions: Map.get(storage, :actions, [])}

    if Prima.ComponentPath.path_granted?(path, grant.paths) and grant.actions != [],
      do: %{storage: grant}
  end

  defp edge_reach(%{vault: %{entry_id: entry_id} = vault}, {:entry_id, entry_id}) do
    %{vault: Map.take(vault, [:entry_id, :binding_digest, :projection, :lender])}
  end

  defp edge_reach(_edge, _resource), do: nil

  defp resource_answer({kind, value}), do: %{kind: Atom.to_string(kind), value: value}

  # ---------------------------------------------------------------------------
  # Decisions decoding — string-keyed wire shape → the Commit vocabulary
  # ---------------------------------------------------------------------------

  defp decode_decisions(raw) do
    with :ok <- refuse_limits(raw),
         {:ok, kind} <- kind(raw),
         {:ok, scope} <- enum(raw, "scope", %{"versionless" => :versionless, "pinned" => :pinned}),
         {:ok, invoke_mode} <-
           enum(raw, "invoke_mode", %{"open_inert" => :open_inert, "edge_only" => :edge_only}),
         {:ok, bindings} <- decode_bindings(Map.get(raw, "bindings", [])),
         {:ok, selections} <- decode_selections(Map.get(raw, "selections", [])),
         {:ok, tool_servers} <- decode_tool_servers(Map.get(raw, "tool_servers", [])),
         {:ok, origins} <- decode_origins(raw),
         {:ok, subset} <- decode_subset(raw) do
      decisions =
        %{
          ref: raw["ref"] || "",
          kind: kind,
          bindings: bindings,
          selections: selections,
          tool_servers: tool_servers
        }
        |> Prima.MapUtil.put_present(:label, raw["label"])
        |> Prima.MapUtil.put_present(:scope, scope)
        |> Prima.MapUtil.put_present(:invoke_mode, invoke_mode)
        |> Prima.MapUtil.put_present(:origins, origins)
        |> Prima.MapUtil.put_present(:subset, subset)
        |> Map.put(:override, raw["override"] == true)
        |> maybe_publish_passthrough(raw)

      {:ok, decisions}
    end
  end

  # The origins the grant admits, from their wire spellings; absent, the
  # commit admits interactive alone.
  defp decode_origins(raw) do
    case Map.fetch(raw, "origins") do
      :error ->
        {:ok, nil}

      {:ok, spellings} ->
        case Prima.Origin.parse_list(spellings) do
          {:ok, origins} ->
            {:ok, origins}

          {:error, :empty_origins} ->
            {:error, {:invalid_argument, "origins must name at least one origin"}}

          {:error, :duplicate_origin} ->
            {:error, {:invalid_argument, "origins names an origin twice"}}

          {:error, {:unknown_origin, _spelling}} ->
            {:error,
             {:invalid_argument,
              "origins must name only #{Enum.join(Prima.Origin.spellings(), ", ")}"}}
        end
    end
  end

  # The narrowing in its wire form, which the commit validates against the
  # ask and the ceiling.
  defp decode_subset(raw) do
    case Map.fetch(raw, "subset") do
      :error -> {:ok, nil}
      {:ok, subset} when is_map(subset) -> {:ok, subset}
      {:ok, _other} -> {:error, {:invalid_argument, "subset must be a map of node references"}}
    end
  end

  # Reject a top-level limits override. Runtime limits come from manifest
  # caps and defaults and are covered by the shape digest; a decision may
  # only narrow them, per node, under `subset`.
  defp refuse_limits(raw) do
    case Map.get(raw, "limits") do
      nil ->
        :ok

      _ ->
        {:error,
         "limits are not a consent decision — a component's limits come from its " <>
           "manifest caps, which shape_digest already covers; a decision narrows " <>
           "them per node under subset.<node>.limits"}
    end
  end

  # A staged publish round-trips its decisions through the same wire shape.
  defp maybe_publish_passthrough(decisions, raw) do
    case raw["publish_from"] do
      profile_id when is_binary(profile_id) and profile_id != "" ->
        decisions
        |> Map.put(:publish_from, profile_id)
        |> Map.put(:need_ids, List.wrap(raw["need_ids"]))
        |> Map.put(:durable_storage, raw["durable_storage"] == true)

      _ ->
        decisions
    end
  end

  defp decode_tool_servers(list) when is_list(list) do
    decoded =
      Enum.map(list, fn grant ->
        %{server_name: grant["server_name"]}
        |> Prima.MapUtil.put_present(:tool_patterns, grant["tool_patterns"])
      end)

    {:ok, decoded}
  end

  defp decode_tool_servers(_), do: {:error, "tool_servers must be a list"}

  # Preserve absent projection keys so Consent.Commit applies the need's
  # declared fields and scopes. An explicit list is passed as given, and
  # Consent.Commit refuses an empty one: a projection names what it reads.
  defp decode_bindings(list) when is_list(list) do
    decoded =
      Enum.map(list, fn binding ->
        %{need: Map.get(binding, "need", Prima.Authority.Blob.ingress_key())}
        |> Prima.MapUtil.put_present(:entry_id, binding["entry_id"])
        |> Prima.MapUtil.put_present(:instance_entry_id, binding["instance_entry_id"])
        |> Prima.MapUtil.put_present(:name, binding["name"])
        |> Prima.MapUtil.put_present(:lifetime, decode_lifetime(binding["lifetime"]))
        |> put_given(:renew, binding, "renew")
        |> Prima.MapUtil.put_present(:fields, binding["fields"])
        |> Prima.MapUtil.put_present(:scopes, binding["scopes"])
      end)

    {:ok, decoded}
  end

  defp decode_bindings(_), do: {:error, "bindings must be a list"}

  # A lifetime record in the commit's vocabulary; a member it does not
  # name stays as it came, so the commit refuses it rather than reading
  # less than was sent.
  defp decode_lifetime(%{} = lifetime) do
    Map.new(lifetime, fn
      {"kind", kind} -> {:kind, kind}
      {"until", until} -> {:until, until}
      {other, value} -> {other, value}
    end)
  end

  defp decode_lifetime(other), do: other

  # A member the caller sent, false included, reaches the commit.
  defp put_given(decoded, key, raw, wire_key) do
    case Map.fetch(raw, wire_key) do
      {:ok, value} -> Map.put(decoded, key, value)
      :error -> decoded
    end
  end

  # A selection names a dependency edge of the closure and what fills it:
  # one of its profiles by label (the default one when it names nothing),
  # or an entry or instance entry for one of its needs, under an account
  # name beside the edge's default when it names one. `from` defaults to
  # the source at commit. The fields, when given, narrow what is lent.
  defp decode_selections(list) when is_list(list) do
    decoded =
      Enum.map(list, fn selection ->
        %{dep: selection["dep"]}
        |> Prima.MapUtil.put_present(:label, selection["label"])
        |> Prima.MapUtil.put_present(:entry_id, selection["entry_id"])
        |> Prima.MapUtil.put_present(:instance_entry_id, selection["instance_entry_id"])
        |> Prima.MapUtil.put_present(:need, selection["need"])
        |> Prima.MapUtil.put_present(:name, selection["name"])
        |> Prima.MapUtil.put_present(:from, selection["from"])
        |> Prima.MapUtil.put_present(:fields, selection["fields"])
        |> Prima.MapUtil.put_present(:lifetime, decode_lifetime(selection["lifetime"]))
        |> put_given(:renew, selection, "renew")
      end)

    {:ok, decoded}
  end

  defp decode_selections(_), do: {:error, {:invalid_argument, "selections must be a list"}}

  defp kind(args) do
    enum(args, "kind", %{"owner" => :owner, "public" => :public})
    |> case do
      {:ok, nil} -> {:ok, :owner}
      other -> other
    end
  end

  defp enum(args, key, mapping) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_map_key(mapping, value) ->
        {:ok, Map.fetch!(mapping, value)}

      _other ->
        {:error, "#{key} must be one of #{Enum.join(Map.keys(mapping), ", ")}"}
    end
  end

  # A key-authenticated caller's capability comes from its own key row —
  # never from the request.
  defp key_capability(%Context{auth_method: :api_key} = ctx) do
    Sanctum.ApiKey.consent_capability(ctx, ctx.api_key_id)
  end

  defp key_capability(_ctx), do: {:ok, nil}

  # Error rendering

  # A refusal of `plan`, `preview`, `commit` or `grant`. A lender that
  # could not be read, or whose profile row or head does not decode, or
  # whose head's bytes fail their digest or do not parse
  # (`Sanctum.Consent.Plan.plan/2`, `Sanctum.Consent.Commit.preview/2`,
  # `commit/3` and `grant/3`), is answered typed, as `grants` answers it:
  # the gate classes it `unavailable` or `corrupt` through
  # `Sanctum.Unauthorized`, whose sentence it reads as, and a client
  # branches on that class. So, in `Prima.Refusal`'s rows, are the
  # profile's own head that cannot be trusted, its row not decoding or its
  # stored policy failing its digest or not parsing, whose narrowing a
  # re-grant would keep (`Sanctum.Consent.Plan.head_narrowing/4`), the
  # corrupt profile; a component the athanor no longer holds; a store the
  # walk could not read (`{:unavailable, store}`: the components at every
  # verb, as the source's row is read, `Sanctum.Consent.Plan.fetch_component/2`,
  # and as its closure is resolved and walked, and the plan's other
  # stores); and a stored manifest that does not decode, the source's or a
  # dependency's the closure reads (`Sanctum.Consent.Plan.closure_rows/3`).
  # Every other refusal is rendered here.
  defp walk_refusal({:lender_unavailable, _dep} = unread), do: unread
  defp walk_refusal({:lender_corrupt, _dep, _profile_id} = damaged), do: damaged
  defp walk_refusal({:corrupt, {:profile, _profile_id}} = damaged), do: damaged
  defp walk_refusal({:not_found, {:component, _ref}} = absent), do: absent
  defp walk_refusal({:unavailable, store} = unread) when is_binary(store), do: unread
  defp walk_refusal({:corrupt, {:manifest, _ref}} = damaged), do: damaged

  defp walk_refusal({:activation_unresolvable, {:corrupt, {:manifest, _ref}} = damaged}),
    do: damaged

  defp walk_refusal(reason), do: fmt(reason)

  # Preserve typed consent signals for wire and console rendering.
  defp fmt({tag, payload} = signal) when Prima.Refusal.is_consent_signal(tag, payload),
    do: signal

  defp fmt({:plan_token, _reason}),
    do: "plan_token_invalid — re-run plan to stage fresh facts"

  defp fmt({:proof, _reason}),
    do: "proof_invalid — re-run preview to mint a fresh proof"

  # The consent vocabulary renders through its owner — one spelling for
  # this tool and the MCP dispatch gate alike.
  defp fmt({:surface_not_permitted, _} = refusal), do: Sanctum.Consent.Authz.message(refusal)

  defp fmt(refusal)
       when refusal in [
              :guest_plane,
              :not_authenticated,
              :anonymous,
              :no_capability,
              :capability_digest_mismatch,
              :capability_expired,
              :override_requires_interactive,
              :not_standing,
              :unavailable
            ],
       do: Sanctum.Consent.Authz.message(refusal)

  defp fmt({:unknown_need, need}),
    do: "unknown_need: #{inspect(need)} — this component declares no such need"

  defp fmt({:selection_target_unknown, dep}),
    do: "selection_target_unknown: #{inspect(dep)} is not a dependency of this component"

  defp fmt({:selection_profile_unavailable, dep, label}),
    do:
      "selection_profile_unavailable: #{dep} has no active owner profile labelled #{inspect(label)}"

  defp fmt({:selection_unbound, dep, label}),
    do:
      "selection_unbound: the '#{label}' profile of #{dep} binds no usable entry — connect a key there first"

  defp fmt({:selection_fields_unavailable, dep, fields}),
    do: "selection_fields_unavailable: #{dep}'s profile does not lend #{Enum.join(fields, ", ")}"

  defp fmt({:entry_unavailable, id, status}),
    do: "entry_unavailable: #{id} is #{inspect(status)}"

  # The revision's own lock found an entry it binds changed since it was
  # read (`Arca.ConsentStorage`): which one, the store does not say.
  defp fmt({:entry_unavailable, status}) when is_binary(status),
    do: "entry_unavailable: an entry this consent binds is now #{inspect(status)}"

  # A binding's refusals name the need and never the entry's material.
  defp fmt({:provider_mismatch, need}) when is_binary(need),
    do: "provider_mismatch: #{inspect(need)} takes an entry of its own kind and provider"

  defp fmt({:disclosure_refused, need}) when is_binary(need),
    do:
      "disclosure_refused: the component reads #{inspect(need)} itself, so it takes a " <>
        "disclosed entry of the athanor"

  defp fmt({:component_not_admitted, need}) when is_binary(need),
    do:
      "component_not_admitted: the instance entry for #{inspect(need)} admits no such " <>
        "component under its component policy"

  defp fmt({:not_offered, need}) when is_binary(need),
    do: "not_offered: the instance entry for #{inspect(need)} is not offered to you"

  defp fmt(:shape_moved),
    do:
      "shape_moved: the component's shape changed since this revision — plan, preview and commit again"

  defp fmt(:grant_requires_full_commit),
    do:
      "grant_requires_full_commit: this profile grants external tool servers, which a grant cannot carry — plan, preview and commit"

  defp fmt({:preview_unrepresentable, _reason}),
    do:
      "preview_unrepresentable: what this grant would give cannot be shown as preview rows, " <>
        "so it is not offered"

  # The closure the grant would cover does not resolve: the refusal names
  # what is missing, so the person knows what to install first.
  defp fmt({:activation_unresolvable, {:incomplete, {:unresolvable_dependency, ref}}})
       when is_binary(ref),
       do:
         "activation_unresolvable: #{ref} cannot be resolved — it is not installed, or its " <>
           "dependencies cannot be read; install it, then plan again"

  defp fmt({:activation_unresolvable, {:incomplete, {:missing_release_digest, ref}}})
       when is_binary(ref),
       do:
         "activation_unresolvable: #{ref} has no release digest — publish it again, " <>
           "then plan again"

  defp fmt({:activation_unresolvable, {:activation_moved, ref}}) when is_binary(ref),
    do: "activation_unresolvable: #{ref} changed while this grant was read — plan again"

  defp fmt({:activation_unresolvable, _reason}),
    do:
      "activation_unresolvable: this component's dependencies cannot be resolved, " <>
        "so nothing can be granted"

  defp fmt(:grant_requires_owner_profile), do: "grant_requires_owner_profile"
  defp fmt(:profile_revoked), do: "profile_revoked"
  defp fmt({:component_not_found, _reason}), do: "component_not_found"
  defp fmt({:invalid_ref, reason}), do: "invalid_ref: #{reason}"

  defp fmt(reason) do
    if Sanctum.Unauthorized.reason?(reason),
      do: Sanctum.Unauthorized.message(reason),
      else: Prima.Refusal.message(reason)
  end

  defp action_enum, do: Prima.Provider.action_enum(definition())
end
