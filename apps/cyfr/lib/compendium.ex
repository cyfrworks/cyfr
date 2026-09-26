# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium do
  @moduledoc """
  Component registry and lifecycle: publishing, resolution and activation of
  the four component kinds (catalyst, reagent, formula, tincture), local and
  OCI storage, manifests, dependency resolution, and the registry client for
  cyfr.run. Component references are parsed by `Prima.ComponentRef`.

  The functions below are the domain's door for callers outside it: the
  tincture rules (`Compendium.Tincture`); component inspection,
  resolution, activation and blobs for the execution domain; the
  component facts the assistant reads — its model catalysts, its agents,
  skills and agent sources and the estate's own formulas — with the path
  grammars of those trees; and the registry's sign-in probe and legal
  pages. Every fact is read under the caller's context and names nothing
  it did not read; running a catalyst is not here.
  """

  use Boundary,
    deps: [Grimoire, Cyfr, Sanctum, Arca],
    exports: [
      AquaPath,
      ComponentPath,
      ConsentFacts,
      Providers.Component,
      Supervisor
    ],
    check: [aliases: true]

  alias Compendium.{
    Activation,
    AgentIndex,
    AgentSource,
    AquaAgent,
    AquaPath,
    AquaSkills,
    Catalogue,
    Component,
    ComponentPath,
    Registry,
    Tincture
  }

  alias Compendium.Registry.Client
  alias Sanctum.Context

  # The most rows one listing of the estate's catalysts reads.
  @catalyst_limit 1000

  @typedoc """
  One installed catalyst release: its name-level `node_key`, its full
  `ref`, its `publisher`, `name` and `version` as the row holds them, and
  the `contracts` its manifest declares.
  """
  @type catalyst :: %{
          node_key: String.t(),
          ref: String.t(),
          publisher: String.t() | nil,
          name: String.t(),
          version: String.t() | nil,
          contracts: [String.t()]
        }

  @typedoc "One agent source: its ref, its name, and whether it is the soul."
  @type agent_source :: %{ref: String.t(), name: String.t(), soul?: boolean()}

  @doc "The entry a tincture serves. See `Compendium.Tincture.entry/1`."
  @spec tincture_entry(term()) :: {:ok, String.t()} | {:error, :no_entry | :invalid_entry}
  defdelegate tincture_entry(tincture), to: Tincture, as: :entry

  @doc "A tincture version's discovered media. See `Compendium.Tincture.media/2`."
  @spec tincture_media(Context.t(), [String.t()]) ::
          %{icon: String.t() | nil, previews: [String.t()]}
  defdelegate tincture_media(ctx, version_segs), to: Tincture, as: :media

  @doc "The immutable tincture asset rules. See `Compendium.Tincture.asset_rules/0`."
  @spec tincture_asset_rules() :: Tincture.asset_rules()
  defdelegate tincture_asset_rules(), to: Tincture, as: :asset_rules

  @doc "Whether a `tincture.connect` entry is a bare domain. See `Prima.Manifest`."
  @spec valid_tincture_connect_domain?(term()) :: boolean()
  defdelegate valid_tincture_connect_domain?(domain), to: Tincture, as: :valid_connect_domain?

  @doc """
  Every installed catalyst release in the caller's estate, each with the
  contracts its manifest declares — what the assistant's model listing
  chooses from. Nothing is run.

  The caller is an authenticated context focused on an estate that may
  read its components (`:component_read`); anything else is
  `{:error, :forbidden}`. A component index behind its tree, or a store
  that cannot answer, is `{:error, :unavailable}`. An estate nobody has
  opened starts filling here, as the component listing does, and answers
  the rows that exist.
  """
  @spec model_catalysts(Context.t()) :: {:ok, [catalyst()]} | {:error, :forbidden | :unavailable}
  def model_catalysts(%Context{} = ctx) do
    with :ok <- component_reader(ctx) do
      Sanctum.Provisioning.start_provisioning(ctx)

      case Registry.search(ctx, %{type: "catalyst", limit: @catalyst_limit}) do
        {:ok, %{components: rows}} -> {:ok, Enum.map(rows, &catalyst/1)}
        {:error, _behind_or_unreadable} -> {:error, :unavailable}
      end
    end
  end

  defp component_reader(
         %Context{authenticated: true, scope: :athanor, athanor_id: athanor_id} = ctx
       )
       when is_binary(athanor_id) and athanor_id != "" do
    case Context.require_permission(ctx, :component_read) do
      :ok -> :ok
      {:error, _} -> {:error, :forbidden}
    end
  end

  defp component_reader(%Context{}), do: {:error, :forbidden}

  defp catalyst(row) do
    %{
      node_key: Prima.ComponentRow.node_key(row),
      ref: row.component_ref,
      publisher: row.publisher,
      name: row.name,
      version: row.version,
      contracts: Prima.Manifest.contracts(Prima.Manifest.decode(row.manifest))
    }
  end

  @doc """
  The estate's indexed agents as consent sources, the soul first:
  `{:ok, [%{ref, name, soul?}]}`. An index behind its tree, or a store
  that cannot answer, is `{:error, :unavailable}`; a context that names
  no estate is `{:error, :forbidden}`.
  """
  @spec agent_source_refs(Context.t()) ::
          {:ok, [agent_source()]} | {:error, :unavailable | :forbidden}
  def agent_source_refs(%Context{} = ctx) do
    case AgentIndex.list(ctx) do
      {:ok, rows} ->
        soul = AquaAgent.soul_type()

        {:ok,
         Enum.map(
           rows,
           &%{ref: Prima.AgentRef.ref(&1.name), name: &1.name, soul?: &1.kind == soul}
         )}

      {:error, :no_athanor} ->
        {:error, :forbidden}

      {:error, _behind_or_unreadable} ->
        {:error, :unavailable}
    end
  end

  @doc """
  The estate's own formulas, as the name-level refs a fill consents:
  `{:ok, ["formula:local.<name>"]}`. A store that cannot answer is
  `{:error, :unavailable}`; a context that names no estate is
  `{:error, :forbidden}`.
  """
  @spec local_formula_refs(Context.t()) ::
          {:ok, [String.t()]} | {:error, :unavailable | :forbidden}
  def local_formula_refs(%Context{} = ctx) do
    case Arca.ComponentStorage.list_components(Context.actor(ctx),
           publisher: Prima.ComponentPath.default_publisher(),
           component_type: "formula",
           limit: :none
         ) do
      {:ok, rows} ->
        {:ok,
         rows
         |> Enum.map(
           &Prima.ComponentRef.build("formula", Prima.ComponentPath.default_publisher(), &1.name)
         )
         |> Enum.uniq()}

      {:error, :no_athanor} ->
        {:error, :forbidden}

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Components: inspection, resolution, activation and blobs
  # ---------------------------------------------------------------------------

  @doc "A component's manifest and metadata by reference (`Compendium.Component.inspect_component/2`)."
  @spec inspect_component(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate inspect_component(ctx, reference), to: Component

  @doc "The concrete reference a flexible one resolves to (`Compendium.Resolver.resolve/2`)."
  @spec resolve(Context.t(), String.t()) ::
          {:ok, String.t(), Compendium.Resolver.resolution_metadata()} | {:error, term()}
  defdelegate resolve(ctx, reference), to: Compendium.Resolver

  @doc "An activation graph's canonical encoding (`Compendium.Activation.encode_graph/1`)."
  @spec encode_activation_graph(Activation.graph()) ::
          {:ok, String.t()} | {:error, Activation.error()}
  defdelegate encode_activation_graph(graph), to: Activation, as: :encode_graph

  @doc "A component's activation over the current projection (`Compendium.Activation.resolve/2`)."
  @spec resolve_activation(Context.t(), map()) ::
          {:ok, Activation.t()} | {:error, Activation.error()}
  defdelegate resolve_activation(ctx, component), to: Activation, as: :resolve

  @doc "A component's activation with every node's integrity verified (`Compendium.Activation.resolve_verified/2`)."
  @spec resolve_verified_activation(Context.t(), map()) ::
          {:ok,
           %{
             digest: String.t(),
             graph: Activation.graph(),
             nodes: %{String.t() => Activation.verified_node()}
           }}
          | {:error, Activation.error()}
  defdelegate resolve_verified_activation(ctx, component), to: Activation, as: :resolve_verified

  @doc "A component blob's raw bytes by digest (`Compendium.Component.get_blob/2`)."
  @spec get_blob(Context.t(), String.t()) :: {:ok, binary()} | {:error, :blob_not_found | term()}
  defdelegate get_blob(ctx, digest), to: Component

  @doc "Every manifest path a component tree holds (`Compendium.AutoIndexer.discover/1`)."
  @spec discover_components(Context.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  defdelegate discover_components(ctx), to: Compendium.AutoIndexer, as: :discover

  @doc "Merged-search rows grouped one entry per component (`Compendium.Catalogue.group_search_results/1`)."
  @spec group_search_results([map()]) :: [map()]
  defdelegate group_search_results(rows), to: Catalogue

  @doc "Installed rows grouped by their name ref, newest first (`Compendium.Catalogue.group_by_component/1`)."
  @spec group_by_component([map()]) :: [map()]
  defdelegate group_by_component(rows), to: Catalogue

  @doc "The component a storage path names, or `:error` (`Compendium.ComponentPath.parse/1`)."
  @spec parse_component_path([String.t()]) ::
          {:ok,
           %{
             type: String.t(),
             publisher: String.t(),
             name: String.t(),
             version: String.t(),
             rest: [String.t()]
           }}
          | :error
  defdelegate parse_component_path(segments), to: ComponentPath, as: :parse

  @doc "Walked leaves filtered down to manifest files (`Compendium.ComponentPath.manifest_leaves/1`)."
  @spec manifest_leaves([[String.t()]]) :: [[String.t()]]
  defdelegate manifest_leaves(leaves), to: ComponentPath

  @doc """
  The projection epoch the estate's `root` has acknowledged, after its
  barrier unless `await: false` (`Compendium.ProjectionReconciler.acknowledged_epoch/3`).
  """
  @spec acknowledged_projection_epoch(Context.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate acknowledged_projection_epoch(ctx, root, opts \\ []),
    to: Compendium.ProjectionReconciler,
    as: :acknowledged_epoch

  @doc "Refresh every filled estate's seeded components (`Compendium.Provisioning.sync_seeds/0`)."
  @spec sync_seeds() :: :ok
  defdelegate sync_seeds(), to: Compendium.Provisioning

  # ---------------------------------------------------------------------------
  # The assistant's agents and skills
  # ---------------------------------------------------------------------------

  @doc "The estate's agents and the files that did not parse (`Compendium.AquaAgent.list/1`)."
  @spec agents(Context.t()) :: {:ok, [AquaAgent.t()], [{String.t(), term()}]} | {:error, term()}
  defdelegate agents(ctx), to: AquaAgent, as: :list

  @doc "One agent of the estate by name (`Compendium.AquaAgent.get/2`)."
  @spec agent(Context.t(), String.t()) :: {:ok, AquaAgent.t()} | {:error, term()}
  defdelegate agent(ctx, name), to: AquaAgent, as: :get

  @doc "An agent's type: the soul's or a role's (`Compendium.AquaAgent.type_of/1`)."
  @spec agent_type_of(AquaAgent.t()) :: String.t()
  defdelegate agent_type_of(agent), to: AquaAgent, as: :type_of

  @doc "The type a role agent carries (`Compendium.AquaAgent.role_type/0`)."
  @spec agent_role_type() :: String.t()
  defdelegate agent_role_type(), to: AquaAgent, as: :role_type

  @doc "The type the soul carries (`Compendium.AquaAgent.soul_type/0`)."
  @spec agent_soul_type() :: String.t()
  defdelegate agent_soul_type(), to: AquaAgent, as: :soul_type

  @doc "The digest of an agent's declared capabilities (`Compendium.AquaAgent.capability_digest/1`)."
  @spec agent_capability_digest(AquaAgent.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate agent_capability_digest(agent), to: AquaAgent, as: :capability_digest

  @doc "The policy glob a clone into `name` is granted by (`Compendium.AquaAgent.clone_glob/1`)."
  @spec agent_clone_glob(String.t()) :: String.t()
  defdelegate agent_clone_glob(name), to: AquaAgent, as: :clone_glob

  @doc "An agent parsed from its file's bytes (`Compendium.AquaAgent.parse/2`)."
  @spec parse_agent(String.t(), binary()) :: {:ok, AquaAgent.t()} | {:error, term()}
  defdelegate parse_agent(name, binary), to: AquaAgent, as: :parse

  @doc "An agent file's frontmatter and body (`Compendium.AquaAgent.parse_frontmatter/1`)."
  @spec parse_agent_frontmatter(binary()) :: {:ok, map(), String.t()} | {:error, term()}
  defdelegate parse_agent_frontmatter(binary), to: AquaAgent, as: :parse_frontmatter

  @doc """
  An agent as it stands now, with the revision it was read at and its
  capability digest (`Compendium.AgentIndex.snapshot/2`).
  """
  @spec agent_snapshot(Context.t(), String.t()) ::
          {:ok,
           %{
             agent: AquaAgent.t(),
             revision_digest: String.t(),
             capability_digest: String.t()
           }}
          | {:error, term()}
  defdelegate agent_snapshot(ctx, name), to: AgentIndex, as: :snapshot

  @doc "The consent row an agent projects under an enabled roster (`Compendium.AgentSource.row/2`)."
  @spec agent_row(AquaAgent.t(), MapSet.t(String.t())) :: map()
  defdelegate agent_row(agent, roster), to: AgentSource, as: :row

  @doc "The names of the estate's enabled agents (`Compendium.AgentSource.enabled_roster/1`)."
  @spec enabled_agent_roster(Context.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  defdelegate enabled_agent_roster(ctx), to: AgentSource, as: :enabled_roster

  @doc "The estate's skills, at most `limit` of them (`Compendium.AquaSkills.index/2`)."
  @spec skills_index(Context.t(), pos_integer() | :all) ::
          {:ok, %{entries: [AquaSkills.entry()], more: non_neg_integer()}} | {:error, term()}
  defdelegate skills_index(ctx, limit), to: AquaSkills, as: :index

  @doc "The most skills a prompt lists (`Compendium.AquaSkills.index_limit/0`)."
  @spec skills_index_limit() :: pos_integer()
  defdelegate skills_index_limit(), to: AquaSkills, as: :index_limit

  @doc "Whether a name is a valid agent or skill name (`Compendium.AquaPath.valid_name?/1`)."
  @spec valid_agent_name?(term()) :: boolean()
  defdelegate valid_agent_name?(name), to: AquaPath, as: :valid_name?

  @doc "The storage path of an agent's file (`Compendium.AquaPath.agent_file/1`)."
  @spec agent_file_path(String.t()) :: [String.t()]
  defdelegate agent_file_path(name), to: AquaPath, as: :agent_file

  @doc "The storage path of a skill's directory (`Compendium.AquaPath.skill_dir/1`)."
  @spec skill_dir(String.t()) :: [String.t()]
  defdelegate skill_dir(name), to: AquaPath

  @doc "Whether an agent name is the soul's (`Compendium.AquaPath.soul?/1`)."
  @spec soul_agent_file?(term()) :: boolean()
  defdelegate soul_agent_file?(name), to: AquaPath, as: :soul?

  # ---------------------------------------------------------------------------
  # The registry: sign-in and its legal pages
  # ---------------------------------------------------------------------------

  @doc """
  Probe the registry with the person's IdP `access_token` and absorb what
  it says; always `{:proceed, user, report}` (`Compendium.SignInSync.complete/4`).
  """
  @spec complete_sign_in(
          Context.t(),
          %{required(:id) => String.t(), optional(atom()) => term()},
          String.t() | atom(),
          String.t() | nil
        ) :: Sanctum.SignIn.outcome()
  defdelegate complete_sign_in(ctx, user, provider, access_token),
    to: Compendium.SignInSync,
    as: :complete

  @doc """
  Claim `username` as the person's personal namespace on the registry,
  proving their identity with the IdP `access_token`: `{:ok, %{slug,
  token}}` with the namespace claimed and its fresh push token, which
  nothing has stored yet (`store_push_token/3`). A refusal is the
  registry's, as `Compendium.Providers.Shared.refusal/1` renders it: a
  policy the person has not accepted is the reason
  `{:registry, :policy_acceptance_required}`, a spent IdP token
  `:invalid_access_token`.
  """
  @spec claim_personal_namespace(String.t(), atom() | String.t(), String.t()) ::
          {:ok, %{slug: String.t(), token: String.t() | nil}} | {:error, Prima.Refusal.t()}
  def claim_personal_namespace(username, provider, access_token) do
    case Client.claim_personal_namespace(username, provider, access_token) do
      {:ok, body} -> {:ok, %{slug: body["slug"] || username, token: body["token"]}}
      {:error, reason} -> {:error, Compendium.Providers.Shared.refusal(reason)}
    end
  end

  @doc """
  Store a personal namespace's push token as the caller's credential for
  this deployment's registry (`Compendium.Registry.CredentialStore.put_push_token/5`).
  """
  @spec store_push_token(Context.t(), String.t(), String.t() | nil) ::
          :ok | :skipped | {:error, :unavailable | :forbidden}
  def store_push_token(%Context{} = ctx, slug, token) do
    Registry.CredentialStore.put_push_token(
      ctx,
      Compendium.RegistryHost.canonical_host(),
      slug,
      token,
      "personal"
    )
  end

  @doc """
  The registry's current policy version and policies
  (`Compendium.Registry.Client.get_legal_version/0`); a failure is the
  registry's refusal, as `Compendium.Providers.Shared.refusal/1` renders it.
  """
  @spec registry_legal_version() :: {:ok, map()} | {:error, Prima.Refusal.t()}
  def registry_legal_version, do: registry_answer(Client.get_legal_version())

  @doc """
  One registry policy page (`Compendium.Registry.Client.get_legal_page/1`);
  a failure is the registry's refusal.
  """
  @spec registry_legal_page(String.t()) :: {:ok, map()} | {:error, Prima.Refusal.t()}
  def registry_legal_page(name), do: registry_answer(Client.get_legal_page(name))

  @doc """
  Record the person's acceptance of a policy version
  (`Compendium.Registry.Client.accept_policies/4`). A refusal is the
  registry's: a stale version is the reason
  `{:registry, :policy_version_mismatch, required_version}`, a refused
  identity `{:registry, :unauthorized}`, a spent IdP token
  `:invalid_access_token`.
  """
  @spec accept_registry_policies(
          atom() | String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t()
        ) :: {:ok, map()} | {:error, Prima.Refusal.t()}
  def accept_registry_policies(provider, access_token, id_token, policy_version) do
    registry_answer(Client.accept_policies(provider, access_token, id_token, policy_version))
  end

  @doc "The policy version a registry refusal requires, or nil."
  @spec registry_required_version(Prima.Refusal.t()) :: String.t() | nil
  def registry_required_version(%Prima.Refusal{
        reason: {:registry, :policy_version_mismatch, version}
      }),
      do: version

  def registry_required_version(%Prima.Refusal{}), do: nil

  defp registry_answer({:ok, _body} = ok), do: ok

  defp registry_answer({:error, reason}),
    do: {:error, Compendium.Providers.Shared.refusal(reason)}
end
