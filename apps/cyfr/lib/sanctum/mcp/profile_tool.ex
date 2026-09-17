# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.ProfileTool do
  @moduledoc """
  Profile tool handlers for the Sanctum MCP provider — the consent walk
  over `Sanctum.Consent.{Plan,Commit}` plus thin list/revoke.

  Consent errors remain typed across this boundary. A key-authenticated
  commit loads its consent capability from the stored key row, never from
  caller input.
  """

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    alias Cyfr.Ops.{Arg, Operation}
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
           Arg.new("durable_storage", :boolean)
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
        "Grant, inspect and revoke profiles — the consent walk. plan stages the facts and candidates, preview renders exactly what would be granted and mints the proof, commit verifies the proof against a live recomputation and writes an immutable revision. Nothing is granted outside this walk.",
      title: "Profiles & Consent"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "plan", "ref" => ref} = args) do
    with {:ok, kind} <- kind(args) do
      params =
        %{ref: ref, kind: kind}
        |> Cyfr.MapUtil.put_present(:label, args["label"])

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
         {:ok, profiles} <- Source.impl().profiles(ctx, source_ref) do
      enriched =
        Enum.map(profiles, fn profile ->
          revision =
            case Source.impl().head_consent(ctx, profile.id) do
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

  def handle(%Context{} = ctx, %{"action" => "revoke", "profile_id" => profile_id}) do
    with {:ok, :interactive} <- Sanctum.Consent.Authz.authorize_interactive(ctx),
         :ok <- Arca.ProfileStorage.set_status(ctx.athanor_id, profile_id, "revoked") do
      {:ok, %{status: "revoked", profile_id: profile_id}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "revoke requires profile_id"}
  end

  def handle(_ctx, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("profile", action_enum())}
  end

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
         {:ok, tool_servers} <- decode_tool_servers(Map.get(raw, "tool_servers", [])) do
      decisions =
        %{
          ref: raw["ref"] || "",
          kind: kind,
          bindings: bindings,
          selections: selections,
          tool_servers: tool_servers
        }
        |> Cyfr.MapUtil.put_present(:label, raw["label"])
        |> Cyfr.MapUtil.put_present(:scope, scope)
        |> Cyfr.MapUtil.put_present(:invoke_mode, invoke_mode)
        |> Map.put(:override, raw["override"] == true)
        |> maybe_publish_passthrough(raw)

      {:ok, decisions}
    end
  end

  # Reject per-consent limits overrides. Runtime limits come from manifest
  # caps and defaults and are covered by the shape digest.
  defp refuse_limits(raw) do
    case Map.get(raw, "limits") do
      nil ->
        :ok

      _ ->
        {:error,
         "limits are not a consent decision — a component's limits come from its " <>
           "manifest caps, which shape_digest already covers"}
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
        |> Cyfr.MapUtil.put_present(:tool_patterns, grant["tool_patterns"])
      end)

    {:ok, decoded}
  end

  defp decode_tool_servers(_), do: {:error, "tool_servers must be a list"}

  # Preserve absent projection keys so Consent.Commit applies manifest
  # defaults. An explicit empty list means no narrowing (all fields);
  # it does not grant an empty set of fields.
  defp decode_bindings(list) when is_list(list) do
    decoded =
      Enum.map(list, fn binding ->
        %{
          need: Map.get(binding, "need", Cyfr.Authority.Blob.ingress_key()),
          entry_id: binding["entry_id"]
        }
        |> Cyfr.MapUtil.put_present(:fields, binding["fields"])
        |> Cyfr.MapUtil.put_present(:scopes, binding["scopes"])
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
        |> Cyfr.MapUtil.put_present(:from, selection["from"])
        |> Cyfr.MapUtil.put_present(:fields, selection["fields"])
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

      other ->
        {:error,
         "#{key} must be one of #{Enum.join(Map.keys(mapping), ", ")}, got: #{inspect(other)}"}
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
  defp fmt({tag, payload} = signal)
       when tag in [:setup_required, :consent_required, :consent_conflict, :restart_required] and
              is_map(payload),
       do: signal

  defp fmt({:plan_token, reason}),
    do: "plan_token_invalid: #{inspect(reason)} — re-run plan to stage fresh facts"

  defp fmt({:proof, reason}),
    do: "proof_invalid: #{inspect(reason)} — re-run preview to mint a fresh proof"

  # The consent-class vocabulary renders through its owner — one spelling
  # for this tool and the MCP dispatch gate alike.
  defp fmt({:surface_not_permitted, _} = refusal), do: Sanctum.Consent.Authz.message(refusal)

  defp fmt(refusal)
       when refusal in [
              :guest_plane,
              :not_authenticated,
              :anonymous,
              :no_capability,
              :capability_digest_mismatch,
              :capability_expired,
              :override_requires_interactive
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

  defp fmt(:grant_requires_owner_profile), do: "grant_requires_owner_profile"
  defp fmt(:profile_revoked), do: "profile_revoked"
  defp fmt({:component_not_found, _reason}), do: "component_not_found"
  defp fmt({:invalid_ref, reason}), do: "invalid_ref: #{reason}"
  defp fmt(reason), do: inspect(reason)

  defp action_enum, do: Cyfr.Ops.Provider.action_enum(definition())
end
