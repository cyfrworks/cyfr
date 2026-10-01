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

  alias Sanctum.Consent.Commit
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
    bindings_arg =
      Arg.new(
        "bindings",
        {:array,
         Arg.new(
           nil,
           {:record,
            [
              Arg.new("need", :string),
              Arg.new("entry_id", :string, required: true),
              Arg.new("fields", {:array, Arg.new(nil, :string)}),
              Arg.new("scopes", {:array, Arg.new(nil, :string)})
            ]}
         )},
        description:
          "grant only: the credentials to bind, [{need:'@ingress', entry_id, fields, scopes}]"
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
                   Arg.new("label", :string),
                   Arg.new("from", :string),
                   Arg.new("fields", {:array, Arg.new(nil, :string)})
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
          "The operator's choices: ref, scope, invoke_mode, bindings [{need:'@ingress', entry_id, fields, scopes}], override"
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
        "Grant, inspect and revoke profiles — the consent walk. plan stages the facts and candidates, preview renders exactly what would be granted and mints the proof, commit verifies the proof against a live recomputation and writes an immutable revision; grants reads which grants reach a resource. Nothing is granted outside this walk.",
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
        {:error, reason} -> {:error, fmt(reason)}
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
        {:error, reason} -> {:error, fmt(reason)}
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
        {:error, reason} -> {:error, fmt(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "commit"}) do
    {:error,
     "commit requires decisions, plan_token, proof, commit_digest and expected_consent_revision"}
  end

  # The simple grant: a credential bound to an existing owner consent
  # whose shape has not moved, with the revision as the compare-and-set.
  def handle(%Context{} = ctx, %{"action" => "grant", "profile_id" => profile_id} = args) do
    with {:ok, bindings} <- decode_bindings(Map.get(args, "bindings", [])) do
      params = %{
        profile_id: profile_id,
        bindings: bindings,
        expected_consent_revision: args["expected_consent_revision"]
      }

      case Commit.grant(ctx, params) do
        {:ok, result} -> {:ok, Map.put(result, :status, "granted")}
        {:error, reason} -> {:error, fmt(reason)}
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
         {:ok, profiles} <- Arca.ConsentStorage.profiles(Context.actor(ctx), source_ref) do
      enriched =
        Enum.map(profiles, fn profile ->
          revision =
            case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id) do
              {:ok, consent} -> consent.revision
              _ -> nil
            end

          Map.put(profile, :head_revision, revision)
        end)

      {:ok, %{profiles: enriched}}
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

  # ---------------------------------------------------------------------------
  # The grant read — which grants reach one resource
  # ---------------------------------------------------------------------------

  # The head revision of every active profile of the caller's athanor, read
  # as the enforcement point would admit it, so no grant shows wider or
  # narrower than it runs. A revision is its built blob, narrowing already
  # applied, and one whose policy fails its digest or does not parse
  # reaches nothing, as the loader roots nothing on it. Every edge counts:
  #
  # - a domain, as egress pins a host (`Prima.Network.domain_allowed?/2`),
  #   on an edge that also allows a method and a scheme;
  # - a path, as the storage door reads a grant
  #   (`Prima.ComponentPath.path_granted?/2`) through each pattern as the
  #   door reaches through it (`door_pattern/1`), on an edge that allows
  #   an action;
  # - a vault entry, by its id among the revision's vault references, on
  #   the edges that bind it. A revision whose references and blob
  #   disagree reaches nothing through the entry: the loader refuses it.
  #
  # Only an active profile's head counts: the loader roots no other.
  defp grants_reaching(ctx, args) do
    with {:ok, resource} <- grants_resource(args),
         {:ok, heads} <- grant_heads(ctx, resource) do
      grants = Enum.flat_map(heads, &reaching_grant(&1, resource))

      {:ok, %{resource: resource_answer(resource), grants: grants, count: length(grants)}}
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
    if Arca.Storage.valid_guest_path?(path), do: active_heads(ctx), else: {:ok, []}
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
    case Arca.ConsentStorage.active_heads(Context.actor(ctx)) do
      {:ok, heads} -> {:ok, heads}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  defp reaching_grant(%{profile: profile, consent: consent}, resource) do
    case reaching_edges(consent, resource) do
      [] ->
        []

      edges ->
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
        ]
    end
  end

  defp reaching_edges(%{vault_refs: refs} = consent, {:entry_id, entry_id} = resource) do
    if Enum.any?(refs, &(&1.vault_entry_id == entry_id)),
      do: blob_edges(consent, resource),
      else: []
  end

  defp reaching_edges(consent, resource), do: blob_edges(consent, resource)

  defp blob_edges(consent, resource) do
    case verified_blob(consent) do
      {:ok, blob} ->
        for {node_ref, %Prima.Authority.Blob.Node{edges: edges}} <- Enum.sort(blob.nodes),
            {key, edge} <- Enum.sort(edges),
            %{} = reached <- [edge_reach(edge, resource)],
            do: Map.merge(%{node: node_ref, edge: key}, reached)

      :error ->
        []
    end
  end

  # The bytes the revision's digest names, parsed fail-closed, as the
  # loader reads them.
  defp verified_blob(%{blob_digest: digest, resolved_policy: policy})
       when is_binary(digest) and is_binary(policy) do
    with true <- Prima.JCS.hash_binary(policy) == digest,
         {:ok, blob} <- Prima.Authority.Blob.parse(policy) do
      {:ok, blob}
    else
      _unverified -> :error
    end
  end

  defp verified_blob(_consent), do: :error

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
    reached = Enum.flat_map(grant.paths, &door_pattern/1)

    if Prima.ComponentPath.path_granted?(path, reached) and grant.actions != [],
      do: %{storage: grant}
  end

  defp edge_reach(%{vault: %{entry_id: entry_id} = vault}, {:entry_id, entry_id}) do
    %{
      vault: %{
        entry_id: entry_id,
        binding_digest: vault.binding_digest,
        projection: vault.projection
      }
    }
  end

  defp edge_reach(_edge, _resource), do: nil

  # A grant pattern as the door reaches through it, for a read that names
  # the path trimmed. The door matches the guest's own spelling against the
  # pattern as written and then reaches the physical path with its empty
  # segments trimmed, so `data//secrets/` serves `data/secrets/key.txt`
  # through `data//secrets/key.txt`: the pattern reaches what its trimmed
  # spelling names (`Prima.ComponentPath.door_path/1`), `*` and a trailing
  # `/` kept. A pattern under which the door's path check refuses every
  # spelling (`Prima.PathSafety`: an unsafe segment, or an absolute path)
  # reaches nothing, and so does one that names no segment, which no read
  # can name either.
  defp door_pattern("*"), do: ["*"]

  defp door_pattern(pattern) do
    case Prima.ComponentPath.door_path(pattern) do
      nil -> []
      spelled -> [spelled]
    end
  end

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
        %{
          need: Map.get(binding, "need", Prima.Authority.Blob.ingress_key()),
          entry_id: binding["entry_id"]
        }
        |> Prima.MapUtil.put_present(:fields, binding["fields"])
        |> Prima.MapUtil.put_present(:scopes, binding["scopes"])
      end)

    {:ok, decoded}
  end

  defp decode_bindings(_), do: {:error, "bindings must be a list"}

  # A selection names a dependency edge of the closure and one of its
  # profiles by label (the default one when unnamed); `from` defaults to
  # the source at commit. The fields, when given, narrow what that
  # profile's entry lends.
  defp decode_selections(list) when is_list(list) do
    decoded =
      Enum.map(list, fn selection ->
        %{dep: selection["dep"], label: selection["label"] || "default"}
        |> Prima.MapUtil.put_present(:from, selection["from"])
        |> Prima.MapUtil.put_present(:fields, selection["fields"])
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
