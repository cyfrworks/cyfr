# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault do
  @moduledoc """
  The operator's credential verbs: list, defaults, set_default, status,
  create, rename, rotate, rebind, revoke, delete.

  Two mutations are deliberately different classes:

    * **rotate** replaces the sealed *material* under a `payload_rev`
      compare-and-swap. Binding fields are untouched, so the derived
      binding digest is unchanged and no consent is disturbed.
    * **rebind** changes what the credential *talks to* (its field
      schema, its destination, whether it is disclosed). The derived
      binding digest moves, every profile whose head consent references
      the entry flips to `needs_consent`, and nothing runs against the new
      binding until a human re-consents. An OAuth entry's endpoints are
      not among them, being fixed when the entry is created, nor its
      scopes, which are the scopes its token was granted for and change
      only by re-authorization (`Sanctum.Vault.OAuthGrant`).

  Every entry names its **destination** (`Prima.Destination`): where its
  material may go, its hosts, scheme and port and, optionally, methods
  and paths. It is required when the entry is created and never
  defaulted. An entry is **attach-only** unless it is created or rebound
  with `disclose: true`: its material is never handed to a component, and
  only a disclosed entry's fields can be read by one
  (`Sanctum.VaultReader`). Both join the
  binding digest. An external MCP server definition is held to both
  before it is stored: a header names an entry whose destination covers
  the server's URL (`destination_matches?/3`), and a stdio backend's
  environment a disclosed entry (`disclosed?/2`).

  Every mutation requires the interactive consent class (`:oidc`
  surface, external plane) — no permission wildcard and no scoped key
  reaches these verbs. Entering and rotating material are sensitive
  changes (`credential_entry`), decided here by
  `Sanctum.Consent.Authz.confirm/3`; from a paired device, their write's
  own transaction holds the device's client and certificate
  (`Sanctum.Issuance.device_hold/1`), so a revocation that commits after
  the request was verified writes nothing and answers
  `{:error, :not_standing}`. Each announces the change by entry, verb and name
  (`Sanctum.Telemetry.vault_entry_changed/4`) so dependents (external MCP
  server processes holding resolved headers) reconcile immediately.

  What ships to callers is metadata only: names, kinds, field *names*,
  status. Material stays sealed; there is no read-back verb.

  The keyring, the AEAD and every plaintext stay here. Rows move through
  `Arca.VaultStorage`, which takes the caller's actor and answers plain
  maps of ciphertext and metadata — the tenant a read runs under is the
  actor's, and a row cannot name its own. Each verb decides everything a
  write will contain before asking for it, so the writes that must land
  together are one call and one transaction below, with nothing left for
  this module to abort.
  """

  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  require Logger

  @kinds ~w(api_key oauth bundle)
  @rebind_attempts 3

  # The status a profile takes when the binding under its head consent
  # moves. One word, written in one place: the operator's rebind and the
  # OAuth grant's rebind block dependents identically.
  @needs_consent "needs_consent"

  @type entry_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          status: String.t(),
          provenance: String.t(),
          field_names: [String.t()],
          oauth_scopes: [String.t()],
          destination: %{String.t() => term()} | nil,
          attach_only: boolean(),
          payload_rev: non_neg_integer(),
          last_used_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Read
  # ---------------------------------------------------------------------------

  @doc "Living entries in the caller's athanor, metadata only."
  @spec list(Context.t()) :: {:ok, [entry_view()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with {:ok, rows} <- Arca.VaultStorage.list(Context.actor(ctx)) do
      {:ok, Enum.map(rows, &view/1)}
    end
  end

  @typedoc """
  The caller's athanor's default entry per provider, keyed by provider
  hint: one of its own entries or an instance entry, named by id alone.
  """
  @type defaults_view :: %{
          String.t() => %{vault_entry_id: String.t()} | %{instance_entry_id: String.t()}
        }

  @doc """
  The caller's athanor's default entry per provider, as stored
  (`Arca.VaultDefaults`; `t:defaults_view/0`). A read, as `list/1` is,
  whose gate is its caller's (`vault/list`): an id per provider, never
  material or a field.
  """
  @spec defaults(Context.t()) :: {:ok, defaults_view()} | {:error, term()}
  def defaults(%Context{} = ctx) do
    with {:ok, rows} <- Arca.VaultDefaults.list(Context.actor(ctx)) do
      {:ok, Map.new(rows, &default_view/1)}
    end
  end

  @doc """
  Make an entry the caller's athanor's default for a provider
  (`params`: `:provider_hint`, and exactly one of `:entry_id`, an active
  entry of the athanor, and `:instance_entry_id`, an instance entry
  offered to the caller and active, `Sanctum.InstanceEntries.binding/2`).
  The entry must be of that provider (`{:error, {:provider_mismatch,
  hint}}`); an empty provider, or both ids or neither, is
  `{:error, {:invalid_argument, sentence}}`. One upsert
  (`Arca.VaultDefaults.set/3`): the provider's earlier default, if any,
  is replaced. A default only suggests: moving it moves no consent.
  Interactive consent class, the session alone. Answers
  `%{provider_hint: hint, vault_entry_id: id}` or
  `%{provider_hint: hint, instance_entry_id: id}`.
  """
  @spec set_default(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def set_default(%Context{} = ctx, params) when is_map(params) do
    hint = Map.get(params, :provider_hint)

    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         :ok <- default_provider(hint),
         {:ok, target} <- default_target(params),
         :ok <- default_of_provider(ctx, target, hint),
         {:ok, _default} <- Arca.VaultDefaults.set(Context.actor(ctx), hint, target) do
      {:ok, Map.put(target, :provider_hint, hint)}
    else
      {:error, :invalid_target} -> {:error, default_target_refusal()}
      {:error, _} = error -> error
    end
  end

  defp default_provider(hint) when is_binary(hint) and hint != "", do: :ok

  defp default_provider(_hint),
    do: {:error, {:invalid_argument, "A default names the provider it is the default of"}}

  defp default_target(params) do
    case {Map.get(params, :entry_id), Map.get(params, :instance_entry_id)} do
      {id, nil} when is_binary(id) and id != "" -> {:ok, %{vault_entry_id: id}}
      {nil, id} when is_binary(id) and id != "" -> {:ok, %{instance_entry_id: id}}
      _neither_or_both -> {:error, default_target_refusal()}
    end
  end

  defp default_target_refusal,
    do: {:invalid_argument, "A default names exactly one of entry_id and instance_entry_id"}

  # The entry is one the caller's athanor may use, and of the provider it
  # is made the default of.
  defp default_of_provider(ctx, %{vault_entry_id: id}, hint) do
    case Arca.VaultStorage.get(Context.actor(ctx), id) do
      {:ok, %{status: "active", provider_hint: ^hint}} -> :ok
      {:ok, %{status: "active"}} -> {:error, {:provider_mismatch, hint}}
      {:ok, %{status: status}} -> {:error, {:entry_unavailable, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_of_provider(ctx, %{instance_entry_id: id}, hint) do
    case Sanctum.InstanceEntries.binding(ctx, id) do
      {:ok, %{provider_hint: ^hint}} -> :ok
      {:ok, _other_provider} -> {:error, {:provider_mismatch, hint}}
      {:error, reason} -> {:error, reason}
    end
  end

  @typedoc """
  One living entry's standing: its id, name, kind and status, when it was
  created and last changed, and whether any consent's head revision binds
  it. Never material, and never a field's name or content.
  """
  @type status_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          status: String.t(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          bound: boolean()
        }

  @doc """
  The standing of every living entry in the caller's athanor
  (`t:status_view/0`), by name. A read: it needs no consent class.
  """
  @spec status(Context.t()) :: {:ok, [status_view()]} | {:error, term()}
  def status(%Context{} = ctx) do
    actor = Context.actor(ctx)

    with {:ok, rows} <- Arca.VaultStorage.list(actor),
         {:ok, referenced} <- Arca.ConsentStorage.head_referenced_entries(actor) do
      bound = MapSet.new(referenced)

      {:ok,
       Enum.map(rows, fn row ->
         %{
           id: row.id,
           name: row.name,
           kind: row.kind,
           status: row.status,
           created_at: row.inserted_at,
           updated_at: row.updated_at,
           bound: MapSet.member?(bound, row.id)
         }
       end)}
    end
  end

  @doc """
  Whether an external MCP server definition at `url` may name the entry
  `name` in a header: true only when the caller's athanor holds an active
  entry of that name whose destination admits a `POST` to `url`
  (`Prima.Destination.matches?/3`), the one method Streamable HTTP sends.
  A missing, inactive or unreadable entry is false. Metadata only:
  nothing is unsealed and no use is recorded.
  """
  @spec destination_matches?(Context.t(), String.t(), String.t()) :: boolean()
  def destination_matches?(%Context{} = ctx, name, url) when is_binary(name) and is_binary(url) do
    case active_by_name(ctx, name) do
      {:ok, entry} -> VaultReader.destination_admits?(entry, url)
      :error -> false
    end
  end

  @doc """
  Whether an external MCP server definition may name the entry `name` in a
  stdio backend's environment: true only when the caller's athanor holds
  an active entry of that name that is disclosed. A missing, inactive or
  unreadable entry is false. Metadata only: nothing is unsealed and no use
  is recorded.
  """
  @spec disclosed?(Context.t(), String.t()) :: boolean()
  def disclosed?(%Context{} = ctx, name) when is_binary(name) do
    match?({:ok, %{attach_only: false}}, active_by_name(ctx, name))
  end

  defp active_by_name(ctx, name) do
    case Arca.VaultStorage.get_by_name(Context.actor(ctx), name) do
      {:ok, %{status: "active"} = entry} -> {:ok, entry}
      _missing_inactive_or_unreadable -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @doc """
  Create an entry holding material (`Sanctum.Vault.Payload`). `params`:

    * `:name` (required) — athanor-unique label among living entries
    * `:kind` (required) — `"api_key" | "oauth" | "bundle"`
    * `:fields` — `%{name => value}` material map (default empty)
    * `:oauth` — token bundle map (see `Sanctum.Vault.Payload`)
    * `:provider_hint` — immutable; defaults `""`
    * `:oauth_endpoints` / `:oauth_scopes` — binding fields
    * `:destination` (required) — where the material may go, a
      `Prima.Destination` map (string or atom keys); absent is
      `:destination_required` and one outside the grammar
      `{:invalid_destination, reason}`, both before anything is asked
    * `:disclose` — `true` to let a component read the fields; `false`
      when absent, so the entry is attach-only unless it says otherwise

  An `oauth` entry names its provider (`:provider_required`), and its
  endpoints are fixed here and never change: a provider hint with a preset
  (`Sanctum.Vault.OAuth.preset/1`) takes the preset's, and naming
  endpoints beside it is refused `:endpoints_preset_conflict`; a provider
  with no preset needs them named (`:endpoints_required`), held to
  `Sanctum.Vault.OAuth.validate_endpoints/1`.
  """
  @spec create(Context.t(), map()) :: {:ok, entry_view()} | {:error, term()}
  def create(%Context{} = ctx, params) when is_map(params) do
    fields = Map.get(params, :fields, %{})

    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, name} <- required_name(params),
         {:ok, kind} <- required_kind(params),
         {:ok, endpoints} <- create_endpoints(kind, params),
         {:ok, destination} <- required_destination(params),
         {:ok, disclose} <- disclose_param(params),
         {:ok, hold} <- Sanctum.Issuance.device_hold(ctx),
         :ok <-
           Authz.confirm(ctx, :credential_entry, %{
             operation: "vault.create",
             arguments: params,
             resource: name
           }),
         :ok <- check_name_free(ctx, name),
         {:ok, json} <- Payload.encode_material(fields, Map.get(params, :oauth)),
         id = Prima.UUID7.generate_id("vlt"),
         hint = Map.get(params, :provider_hint, ""),
         aad = CipherAAD.vault_entry(Context.athanor!(ctx), id, hint),
         {:ok, sealed} <- seal(json, aad) do
      binding = %{
        provider_hint: hint,
        field_names: Jason.encode!(Enum.sort(Map.keys(fields))),
        oauth_endpoints: encode_optional_map(endpoints),
        oauth_scopes: encode_optional_list(Map.get(params, :oauth_scopes)),
        destination: destination,
        attach_only: not disclose
      }

      # The tenant is the caller's, never an attribute's: the facade stamps
      # the actor's athanor onto the row and refuses one supplied here.
      with {:ok, digest} <- VaultReader.binding_digest(binding),
           {:ok, entry} <-
             Arca.VaultStorage.put(
               Context.actor(ctx),
               Map.merge(binding, %{
                 id: id,
                 name: name,
                 kind: kind,
                 provenance: Map.get(params, :provenance, "user"),
                 status: "active",
                 sealed_payload: sealed,
                 binding_digest: digest
               }),
               hold
             ) do
        broadcast(ctx, id, :create, %{name: entry.name})
        {:ok, view(entry)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rename
  # ---------------------------------------------------------------------------

  @doc """
  Rename the mutable label. Identity, bindings and consents are untouched.

  It is announced like every other mutation even so. Consents bind an entry
  *id*, but an external MCP server's headers and backend env bind a
  `vault:<name>` reference that `Sanctum.VaultReader.unseal_for/3` and
  `unseal_disclosed/2` resolve at connect time — so moving a name from one
  entry to another changes what a running server dispenses without any
  entry's material changing. That is a resolution change, and the
  reconciler is what acts on those.
  """
  @spec rename(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def rename(%Context{} = ctx, id, new_name) when is_binary(new_name) and new_name != "" do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_living(ctx, id),
         :ok <- check_name_free(ctx, new_name),
         :ok <- Arca.VaultStorage.update_meta(Context.actor(ctx), id, %{name: new_name}) do
      # The signal carries the name being VACATED: header templates
      # reference entries by name, so the servers a rename breaks are the
      # ones still spelling the old one — a post-hoc read of the row can
      # only ever see the new name.
      broadcast(ctx, id, :rename, %{name: new_name, old_name: entry.name})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Rotate — material only, never a re-consent
  # ---------------------------------------------------------------------------

  @doc """
  Replace the secret material under CAS. The field schema must match the
  entry's `field_names` — changing the schema is a rebind, and silently
  accepting a different shape here would smuggle a binding change past
  re-consent.
  """
  @spec rotate(Context.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rotate(%Context{} = ctx, %{id: id, fields: fields, expected_payload_rev: expected} = params)
      when is_map(fields) and is_integer(expected) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_rotatable(ctx, id),
         {:ok, hold} <- Sanctum.Issuance.device_hold(ctx),
         :ok <-
           Authz.confirm(ctx, :credential_entry, %{
             operation: "vault.rotate",
             arguments: params,
             resource: entry.name
           }),
         :ok <- check_schema(entry, fields),
         {:ok, current} <- unseal(ctx, entry),
         {:ok, oauth} <- rotation_oauth(current, Map.get(params, :oauth)),
         {:ok, json} <- Payload.encode_material(fields, oauth),
         aad = CipherAAD.vault_entry(Context.athanor!(ctx), entry.id, entry.provider_hint),
         {:ok, sealed} <- seal(json, aad) do
      # The material and the reactivation that belongs to it are one
      # transaction, the same one an OAuth grant commits through: a rotate
      # that fails part-way leaves the entry at the version it was already
      # readable at, never at a payload its status has not caught up to.
      plan = %{
        expected_rev: expected,
        sealed_payload: sealed,
        status: if(entry.status == "needs_reauth", do: "active"),
        rebind: nil
      }

      case Arca.VaultStorage.commit_payload(Context.actor(ctx), id, plan, hold) do
        {:ok, %{payload_rev: rev}} ->
          broadcast(ctx, id, :rotate, %{name: entry.name})
          {:ok, rev}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rebind — a binding change, always a re-consent
  # ---------------------------------------------------------------------------

  @doc """
  Change the binding fields: `:field_names`, the material's field schema;
  `:destination`, where the material may go (held to the grammar as at
  `create/2`); and `:disclose`, whether a component may read the fields.
  `provider_hint` cannot change — it lives in the AAD — and neither can
  an entry's OAuth endpoints or scopes, each refused before the entry is
  read: a params map naming `:oauth_endpoints` is refused
  `:endpoints_immutable`, since a new endpoint is a new entry, and one
  naming `:oauth_scopes` `:scopes_need_reauthorization`, since an entry's
  scopes are the ones its token was granted for and change only with a
  newly granted token (`Sanctum.Vault.OAuthGrant`).

  Returns the new derived binding digest and the profiles now blocked at
  `needs_consent`.
  """
  @spec rebind(Context.t(), map()) ::
          {:ok, %{binding_digest: String.t(), affected: [String.t()]}} | {:error, term()}
  def rebind(%Context{} = ctx, %{id: id} = params) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         :ok <- endpoints_unnamed(params),
         :ok <- scopes_unnamed(params),
         {:ok, changes} <- rebind_changes(params),
         {:ok, entry} <- get_living(ctx, id) do
      if changes == %{} do
        {:error, :no_binding_changes}
      else
        with {:ok, rebound} <- rebind_entry(ctx, entry, changes, @rebind_attempts) do
          broadcast(ctx, id, :rebind, %{name: entry.name})
          {:ok, rebound}
        end
      end
    end
  end

  # A rebind that lost the race recomputes against what landed.
  defp rebind_entry(ctx, entry, changes, attempts) do
    case move_binding(ctx, entry, changes) do
      {:error, :binding_moved} when attempts > 1 ->
        with {:ok, fresh} <- get_living(ctx, entry.id),
             do: rebind_entry(ctx, fresh, changes, attempts - 1)

      result ->
        result
    end
  end

  # The new digest is derived here, from the entry as it was read merged
  # with the edit: a decision, made before any transaction opens. What
  # crosses into Arca is data — the digest the row must still read, the
  # columns to write, and the word a blocked profile takes. The binding
  # move and the invalidation of every profile that depended on it are one
  # transaction there, so no consent is ever left covering a binding it
  # did not approve, and a lost compare-and-set leaves neither behind.
  defp move_binding(%Context{} = ctx, entry, changes) when is_map(changes) do
    with {:ok, digest} <- VaultReader.binding_digest(Map.merge(entry, changes)),
         {:ok, affected} <-
           Arca.VaultStorage.move_binding(
             Context.actor(ctx),
             entry.id,
             entry.binding_digest,
             Map.put(changes, :binding_digest, digest),
             @needs_consent
           ) do
      {:ok, %{binding_digest: digest, affected: affected}}
    end
  end

  @doc false
  # What a profile's status becomes when the binding under its head consent
  # moves. `Sanctum.Vault.OAuthGrant` blocks dependents with the same word
  # and reads it from here rather than spelling it a second time.
  @spec blocked_profile_status() :: String.t()
  def blocked_profile_status, do: @needs_consent

  # ---------------------------------------------------------------------------
  # Revoke / delete
  # ---------------------------------------------------------------------------

  @doc """
  Stop the entry dispensing anything, effective at the next credential
  retrieval. Consents stay as history; the affected list is who loses
  access now.
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, %{affected: [String.t()]}} | {:error, term()}
  def revoke(%Context{} = ctx, id) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_living(ctx, id),
         :ok <- Arca.VaultStorage.set_status(Context.actor(ctx), id, "revoked"),
         {:ok, affected} <-
           Arca.ConsentStorage.head_profiles_referencing(Context.actor(ctx), id) do
      broadcast(ctx, id, :revoke, %{name: entry.name})
      {:ok, %{affected: Enum.sort(affected)}}
    end
  end

  @doc "Tombstone the entry and erase its sealed material. The name frees up."
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, id) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_any(ctx, id),
         :ok <- Arca.VaultStorage.tombstone(Context.actor(ctx), id) do
      broadcast(ctx, id, :delete, %{name: entry.name})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp view(entry) do
    %{
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      provider_hint: entry.provider_hint,
      status: entry.status,
      provenance: entry.provenance,
      field_names: decode_list(entry.field_names, "field_names"),
      oauth_scopes: decode_list(entry.oauth_scopes, "oauth_scopes"),
      destination: decode_destination(entry.destination),
      attach_only: entry.attach_only,
      payload_rev: entry.payload_rev,
      last_used_at: entry.last_used_at
    }
  end

  # A stored default names exactly one of the two entries.
  defp default_view(%{provider_hint: hint, vault_entry_id: id}) when is_binary(id),
    do: {hint, %{vault_entry_id: id}}

  defp default_view(%{provider_hint: hint, instance_entry_id: id}) when is_binary(id),
    do: {hint, %{instance_entry_id: id}}

  defp required_name(%{name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp required_name(_), do: {:error, :name_required}

  defp required_kind(%{kind: kind}) when kind in @kinds, do: {:ok, kind}
  defp required_kind(_), do: {:error, {:invalid_kind, @kinds}}

  # Where an entry's material may go: named by the caller, never defaulted,
  # and stored as the destination's canonical text, the bytes its binding
  # digest covers.
  defp required_destination(params) do
    case Map.fetch(params, :destination) do
      {:ok, destination} when not is_nil(destination) -> destination_text(destination)
      _absent -> {:error, :destination_required}
    end
  end

  @doc false
  # A destination as a caller names it, string or atom keys, held to
  # `Prima.Destination`'s athanor-entry grammar and answered as its
  # canonical text. `Sanctum.Vault.OAuthGrant` holds a new entry's to the
  # same rule.
  @spec destination_text(term()) :: {:ok, String.t()} | {:error, term()}
  def destination_text(%{} = destination) when not is_struct(destination) do
    with {:ok, parsed} <- Prima.Destination.from_map(string_keys(destination)) do
      {:ok, Prima.Destination.canonical(parsed)}
    end
  end

  def destination_text(_other), do: {:error, {:invalid_destination, :not_a_map}}

  defp string_keys(map),
    do:
      Map.new(map, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

  @doc false
  # Whether a create asks for disclosure: `false` when it says nothing, and
  # only a boolean otherwise.
  @spec disclose_param(map()) :: {:ok, boolean()} | {:error, :invalid_disclose}
  def disclose_param(params) do
    case Map.get(params, :disclose) do
      nil -> {:ok, false}
      disclose when is_boolean(disclose) -> {:ok, disclose}
      _other -> {:error, :invalid_disclose}
    end
  end

  # The binding columns a rebind names: the field schema, the destination
  # and the disclosure, each only when the caller named it.
  defp rebind_changes(params) do
    changes = put_change(%{}, :field_names, params, &encode_optional_list/1)

    with {:ok, changes} <- put_destination(changes, params) do
      case Map.fetch(params, :disclose) do
        {:ok, disclose} when is_boolean(disclose) ->
          {:ok, Map.put(changes, :attach_only, not disclose)}

        {:ok, _other} ->
          {:error, :invalid_disclose}

        :error ->
          {:ok, changes}
      end
    end
  end

  defp put_destination(changes, params) do
    case Map.fetch(params, :destination) do
      {:ok, destination} ->
        with {:ok, text} <- destination_text(destination),
             do: {:ok, Map.put(changes, :destination, text)}

      :error ->
        {:ok, changes}
    end
  end

  defp decode_destination(text) when is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, %{} = destination} -> destination
      _ -> nil
    end
  end

  defp decode_destination(_absent), do: nil

  # The endpoints an entry is created with. An `oauth` entry's come from its
  # provider's preset or are named for a provider with none, never both and
  # never neither; an empty map names none. Other kinds store what they are
  # given, as they always have.
  defp create_endpoints("oauth", params) do
    hint = Map.get(params, :provider_hint, "")
    given = Map.get(params, :oauth_endpoints)
    named? = not (is_nil(given) or given == %{})

    # An OAuth entry names the provider it dispenses for: the dispense
    # serves that provider alone, so an entry naming none could serve none.
    if hint in [nil, ""] do
      {:error, :provider_required}
    else
      case Sanctum.Vault.OAuth.preset(hint) do
        %{endpoints: _} when named? -> {:error, :endpoints_preset_conflict}
        %{endpoints: endpoints} -> {:ok, endpoints}
        nil when named? -> Sanctum.Vault.OAuth.validate_endpoints(given)
        nil -> {:error, :endpoints_required}
      end
    end
  end

  defp create_endpoints(_kind, params), do: {:ok, Map.get(params, :oauth_endpoints)}

  # An entry's OAuth endpoints are fixed when it is created: a rebind naming
  # them is refused whatever it names, before anything of the entry is read.
  defp endpoints_unnamed(params) do
    if Map.has_key?(params, :oauth_endpoints),
      do: {:error, :endpoints_immutable},
      else: :ok
  end

  # An entry's scopes are the ones its token was granted for. Moving the
  # column alone would make the old token stand for a grant it was never
  # issued under (fewer scopes, and it would be served as their whole
  # grant), so they move only with a token granted for them, by
  # re-authorization; a rebind naming them is refused before any read.
  defp scopes_unnamed(params) do
    if Map.has_key?(params, :oauth_scopes),
      do: {:error, :scopes_need_reauthorization},
      else: :ok
  end

  defp check_name_free(ctx, name) do
    case Arca.VaultStorage.get_by_name(Context.actor(ctx), name) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :name_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_any(ctx, id), do: Arca.VaultStorage.get(Context.actor(ctx), id)

  defp get_living(ctx, id) do
    case get_any(ctx, id) do
      {:ok, %{status: "tombstoned"}} -> {:error, :not_found}
      other -> other
    end
  end

  defp get_rotatable(ctx, id) do
    case get_any(ctx, id) do
      {:ok, %{status: status} = entry} when status in ["active", "needs_reauth"] ->
        {:ok, entry}

      {:ok, %{status: status}} ->
        {:error, {:entry_unavailable, status}}

      other ->
        other
    end
  end

  defp check_schema(entry, fields) do
    declared = decode_list(entry.field_names, "field_names")
    provided = Enum.sort(Map.keys(fields))

    if provided == declared do
      :ok
    else
      {:error, :schema_change_requires_rebind}
    end
  end

  # `Sanctum.Cipher.encrypt/2` raises rather than returning errors — boot
  # validates the keyring, so a raise here is a mid-flight misconfiguration
  # (a rotated-away label, a truncated key). The request path answers with
  # a typed refusal instead of a bare MatchError taking the caller down.
  defp seal(json, aad) do
    Sanctum.Cipher.encrypt(json, aad)
  rescue
    e ->
      Logger.error("[Sanctum.Vault] sealing failed: #{Exception.message(e)}")
      {:error, :seal_failed}
  end

  # The AAD's athanor is the CALLER's, not the row's. The facade has
  # already refused any row outside the caller's athanor, and binding the
  # ciphertext to the caller's tenant means a row that reached a foreign
  # context by any path fails to unseal rather than decrypting under the
  # tenant it brought with it.
  defp unseal(%Context{} = ctx, entry) do
    aad = CipherAAD.vault_entry(Context.athanor!(ctx), entry.id, entry.provider_hint)

    with sealed when is_binary(sealed) <- entry.sealed_payload,
         {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad) do
      Payload.decode(plaintext)
    else
      _ -> {:error, :unseal_failed}
    end
  end

  # What the rotated payload's oauth block becomes. A supplied bundle wins,
  # and with it go the tokens the old one held for narrower scope sets;
  # otherwise the current bundle is kept whole — rotating the secret fields
  # must not silently revoke a live grant.
  defp rotation_oauth(%{"v" => 3} = current, nil), do: {:ok, current["oauth"]}
  defp rotation_oauth(%{"v" => 3}, oauth) when is_map(oauth), do: {:ok, oauth}

  # Total, like every validator here: a non-map :oauth is a typed refusal,
  # not a FunctionClauseError out of a public API.
  defp rotation_oauth(%{"v" => 3}, _oauth),
    do: {:error, "oauth must be an object when supplied"}

  defp put_change(changes, key, params, encoder) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(changes, key, encoder.(value))
      :error -> changes
    end
  end

  defp encode_optional_map(nil), do: nil
  defp encode_optional_map(map) when is_map(map), do: Jason.encode!(map)
  defp encode_optional_map(json) when is_binary(json), do: json

  defp encode_optional_list(nil), do: nil
  defp encode_optional_list(list) when is_list(list), do: Jason.encode!(list)
  defp encode_optional_list(json) when is_binary(json), do: json

  defp decode_list(nil, _field), do: []

  defp decode_list(json, field) when is_binary(json) do
    case decode_stored(json, [], field) do
      list when is_list(list) -> Enum.sort(Enum.filter(list, &is_binary/1))
      _ -> []
    end
  end

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes. `decode_list/2`
  # answers nil itself.
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Sanctum.Vault] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  # One announcement, two topics: the athanor's own, and a deliberately
  # global one (the "sanctum:sessions" precedent) so singletons that
  # cannot know every tenant topic — the external-MCP reconciler — still
  # see every mutation. Both are the host bridge's to broadcast.
  defp broadcast(ctx, entry_id, verb, %{name: _} = meta),
    do: Sanctum.Telemetry.vault_entry_changed(Context.athanor!(ctx), entry_id, verb, meta)
end
