# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Refusal do
  @moduledoc """
  The closed refusal table: every reason a call can be refused for, the
  class it belongs to and the public sentence it reads as.

  A producer returns its own reason term; `classify/1` turns it into
  `%Prima.Refusal{class, reason, message}`, the normalized form every edge
  reads — the wire, the console, stored rows, bus payloads. The class is
  one of sixteen (`classes/0`) and decides status and code at each
  surface; the message is a sentence with no internal field name, no
  Elixir syntax and no `inspect/1` of a term.

  `confirmation_required` is a class of its own: the change stands and
  waits for the person's fresh confirmation, so it is neither a denial
  (`forbidden`) nor a consent to give (`consent_required`).

  The authorization vocabulary is `Sanctum.Unauthorized`'s, which
  classifies its own reasons; `Sanctum.Refusals.classify/1` tries it first
  and comes here for everything else. A reason this table does not know —
  a Sanctum term included, since the contracts do not name Sanctum — is
  `internal`, reads "The outcome could not be confirmed." and is
  logged by its shape (`Prima.LoggerContext.unexpected/3`), never its
  value.

  A refusal's `stage` says where it was made. The gate's own refusals —
  of the plane, the caller's authorization, the arguments, the chain's
  authority, an unknown tool or action — are made before any handler
  runs and carry `:admission`; everything a handler or the call's own
  ending answers is `:execution`, the default. A surface that answers the
  two differently (a JSON-RPC error for an admission refusal, a failed
  tool result for an execution one) reads the stage, never the reason.
  """

  @enforce_keys [:class, :reason, :message]
  defstruct [:class, :reason, :message, stage: :execution]

  @type class ::
          :unauthenticated
          | :forbidden
          | :consent_required
          | :confirmation_required
          | :setup_required
          | :invalid_argument
          | :not_found
          | :conflict
          | :rate_limited
          | :not_owner
          | :unavailable
          | :corrupt
          | :timeout
          | :cancelled
          | :uncertain
          | :internal

  @type stage :: :admission | :execution

  @type t :: %__MODULE__{
          class: class(),
          reason: term(),
          message: String.t(),
          stage: stage()
        }

  @classes [
    :unauthenticated,
    :forbidden,
    :consent_required,
    :confirmation_required,
    :setup_required,
    :invalid_argument,
    :not_found,
    :conflict,
    :rate_limited,
    :not_owner,
    :unavailable,
    :corrupt,
    :timeout,
    :cancelled,
    :uncertain,
    :internal
  ]

  @unconfirmed "The outcome could not be confirmed."

  # The consent signals' tags and shape, read from their owner rather
  # than spelled: this table, `is_consent_signal/2` and every surface that
  # keeps a signal typed through it recognise the same signals.
  require Prima.ConsentSignal

  @signal_tags Prima.ConsentSignal.tags()

  @doc """
  Whether `{tag, payload}` is a consent signal (`Prima.ConsentSignal`):
  a tag of `signal_tags/0` with a map payload, and for
  `confirmation_required` a payload naming its confirmation's `id`.
  Usable in guards.
  """
  defguard is_consent_signal(tag, payload) when Prima.ConsentSignal.is_signal(tag, payload)

  # The class a guest error's `type` reads as on the worker wire.
  @guest_error_classes %{
    "invalid_request" => :invalid_argument,
    "invalid_json" => :invalid_argument,
    "tool_denied" => :forbidden,
    "action_denied" => :forbidden,
    "storage_path_denied" => :forbidden,
    "resource_limit" => :rate_limited,
    "storage_quota_exceeded" => :rate_limited,
    "storage_unavailable" => :unavailable,
    "not_found" => :not_found,
    "setup_required" => :setup_required,
    "uncertain" => :uncertain,
    "timeout" => :timeout,
    "storage_error" => :internal,
    "encoding_error" => :internal,
    "spawn_failed" => :internal,
    "dispatch_error" => :internal,
    "unknown" => :internal,
    "task_failed" => :internal,
    "cancel_failed" => :internal,
    # A credential's refusals, by the reason a host call's guest error
    # names (`credential_reasons/0`).
    "destination_mismatch" => :forbidden,
    "scope_not_attenuable" => :forbidden,
    "disclosure_refused" => :forbidden,
    "not_offered" => :forbidden,
    "component_not_admitted" => :forbidden,
    "provider_mismatch" => :invalid_argument,
    "credential_header_refused" => :invalid_argument,
    "endpoints_immutable" => :invalid_argument,
    "connection_not_granted" => :setup_required,
    "connection_cap" => :rate_limited,
    "grant_expired" => :consent_required,
    # An attached request's egress refusals, by the type a guest's own
    # fetch is refused with, and the rate and size it is charged against.
    "method_blocked" => :forbidden,
    "scheme_blocked" => :forbidden,
    "domain_blocked" => :forbidden,
    "private_ip_blocked" => :forbidden,
    "dns_error" => :unavailable,
    "rate_limited" => :rate_limited,
    "request_too_large" => :invalid_argument
  }

  # The credential refusals, each with its class and its fixed sentence:
  # the condition in words, never the entry, its value or its address.
  @credential %{
    destination_mismatch:
      {:forbidden, "The request goes outside the destination its credential is bound to."},
    scope_not_attenuable: {:forbidden, "This entry's scopes are granted whole or not at all."},
    disclosure_refused:
      {:forbidden, "This credential is attached by CYFR and never disclosed to a component."},
    not_offered: {:forbidden, "This instance entry is not offered to you."},
    component_not_admitted:
      {:forbidden, "This instance entry requires an unmodified shipped component."},
    provider_mismatch: {:invalid_argument, "The entry is for another provider than this need."},
    credential_header_refused:
      {:invalid_argument, "A request that names a connection carries no credential header."},
    endpoints_immutable:
      {:invalid_argument, "An OAuth entry's endpoints are fixed when it is created."},
    connection_not_granted:
      {:setup_required, "This account is not granted to the component; grant it first."},
    connection_cap: {:rate_limited, "This instance entry's request cap for today is reached."},
    grant_expired: {:consent_required, "The grant for this account has expired; grant it again."}
  }

  # A turn or a runner refused a transition the caller asked for: the
  # state moved on, and reading it again is what to do.
  @turn_conflicts [
    :superseded,
    :not_open,
    :not_running,
    :not_suspended,
    :recovery_exhausted,
    :held,
    :not_accepted,
    :not_paused,
    :attempt_not_paused,
    :already_finished,
    :steer_pending,
    :clone,
    :no_root,
    :turn_over,
    :turn_exists,
    :stale,
    :catalyst_pinned,
    :not_proposed,
    :not_dispatched,
    :proposal_digest_required,
    :parent_not_running,
    :clone_depth,
    :not_a_clone,
    :consent_moved,
    :agent_changed,
    :no_pin,
    :turn_superseded
  ]

  # A run's own record refused the write it was handed — no fence, a lost
  # sequence race, or a transition its rows do not allow: an internal
  # fault of the writer, never something the caller can change.
  @turn_internal [:fence_required, :seq_conflict, :illegal_transition]

  @turn_not_found [
    :approval_not_found,
    :catalyst_not_found,
    :step_not_found,
    :thread_not_found,
    :turn_not_found
  ]

  # An execution barrier refused a child: the parent moved on.
  @barrier_conflicts [:hold_expired, :step_superseded, :parent_ended, :occurrence_not_claimed]

  # The MCP transport's own refusals of a request it could not read.
  @transport_invalid [
    :header_mismatch,
    :unsupported_protocol_version,
    :parse_error,
    :invalid_request
  ]

  # The bootstrap's refusals of a member's boot, by sub-reason.
  # How the home is reached: the boot's and the access engine's refusals
  # that carry nothing but their code.
  @access %{
    access_missing:
      {:setup_required,
       "CYFR_ACCESS is not set in .env, so CYFR does not know how it is reached. " <>
         "Nothing started. Run `cyfr init` for a new CYFR, or `cyfr access " <>
         "local|tailnet|public` for this one."},
    access_assertion_from_file:
      {:forbidden,
       "CYFR_LOCAL_INGRESS_ASSERTED is the compose file's assertion and cannot come from " <>
         ".env. Remove it from .env."},
    access_request_reused:
      {:conflict,
       "This request names a different change than the one first sent under its id. " <>
         "Nothing was changed. Send it again under a new id."},
    tailnet_not_joined:
      {:setup_required,
       "This machine has not joined your tailnet. Nothing was changed. Run `cyfr access " <>
         "tailnet` and approve the machine with the link it prints."},
    tailnet_join_expired:
      {:timeout,
       "The approval link expired before the machine was approved. How CYFR is " <>
         "reached was not changed. Run `cyfr access tailnet` for a new link."},
    tailnet_join_cancelled:
      {:cancelled, "Joining your tailnet was cancelled. How CYFR is reached was not changed."},
    tailnet_join_ended:
      {:unauthenticated,
       "Tailscale did not accept this machine's join: the auth key may be wrong, already " <>
         "used or expired, or the join ended before the machine was approved. How CYFR " <>
         "is reached was not changed. Check the key if you gave one, then run `cyfr access " <>
         "tailnet` again."},
    tailnet_join_not_current:
      {:conflict, "That join attempt is no longer the one in progress. Nothing was changed."}
  }

  # The form an access setting's value must take, by the setting.
  @access_setting_forms %{
    "CYFR_PORT" => "a port from 1 to 65535",
    "CYFR_PROXY_PORT" => "a port from 1 to 65535",
    "CYFR_BIND_ADDRESS" => "an IPv4 or IPv6 address",
    "CYFR_PROXY_BIND_ADDRESS" => "an IPv4 or IPv6 address",
    "CYFR_LOCAL_INGRESS_ASSERTED" => "true, the one value the compose file asserts",
    "CYFR_TRUSTED_PROXY_HOPS" => "a whole number of proxy hops from 0 to 16",
    "CYFR_TRUSTED_PROXY_CIDRS" => "a comma-separated list of IP addresses and CIDRs",
    "CYFR_LOCUS_BUILDS_URL" =>
      "an http or https URL with a host, an optional port and no path, query or credentials"
  }

  # What a `cyfr access` input was meant to be.
  @access_input_kinds %{
    "domain" => "domain",
    "tailnet_name" => "tailnet machine name",
    "email" => "email address"
  }

  # Why a home put back after a failed change answers on this machine only,
  # and the step that serves it on the tailnet again.
  @rolled_back_local %{
    "tailnet_node_mismatch" =>
      {"this machine's tailnet identity is not the one .env names",
       "run `cyfr access tailnet`, which offers to move CYFR to the machine's tailnet name"},
    "tailnet_not_joined" =>
      {"this machine has not joined your tailnet",
       "run `cyfr access tailnet` and approve the machine with the link it prints"},
    "tailnet_https_off" =>
      {"your tailnet has HTTPS certificates turned off",
       "turn on HTTPS on the DNS page of the Tailscale admin console, then run `cyfr access tailnet`"}
  }

  @doc "The sixteen refusal classes."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  The credential refusals' reasons, each a typed reason of this table and
  a guest error `type` a host call may answer: where a credential may go,
  how it is disclosed, which provider and account it is for, and how an
  instance entry is offered and capped.
  """
  @spec credential_reasons() :: [atom()]
  def credential_reasons, do: @credential |> Map.keys() |> Enum.sort()

  @doc """
  The normalized refusal for `reason`. A `%Prima.Refusal{}` classifies as
  itself; a reason the table does not know is `internal`, with the fixed
  sentence, and is logged by its shape.
  """
  @spec classify(term()) :: t()
  def classify(%__MODULE__{} = refusal), do: refusal

  def classify(reason) do
    case row(reason) do
      {class, message} ->
        %__MODULE__{class: class, reason: reason, message: message}

      nil ->
        Prima.LoggerContext.unexpected(__MODULE__, reason)
        %__MODULE__{class: :internal, reason: reason, message: @unconfirmed}
    end
  end

  @doc "The tags of the consent signals, the roster `is_consent_signal/2` reads."
  @spec signal_tags() :: [Prima.ConsentSignal.tag()]
  def signal_tags, do: @signal_tags

  @doc "The sentence an unknown reason reads as."
  @spec unconfirmed() :: String.t()
  def unconfirmed, do: @unconfirmed

  @doc """
  Whether `reason` is a typed reason this table knows. A bare binary is a
  producer's sentence, which the table renders but which is no typed
  reason.
  """
  @spec reason?(term()) :: boolean()
  def reason?(%__MODULE__{}), do: true
  def reason?(reason) when is_binary(reason), do: false
  def reason?(reason), do: row(reason) != nil

  @doc "The public sentence for `reason` (`classify/1`'s message)."
  @spec message(term()) :: String.t()
  def message(reason), do: classify(reason).message

  @doc """
  The JSON-RPC code name a row answers with in place of its class's code,
  or `nil`. The presented-credential refusals keep the `auth_invalid` code
  they have always carried.
  """
  @spec code_override(t() | term()) :: atom() | nil
  def code_override(%__MODULE__{reason: reason}), do: code_override(reason)

  def code_override(reason) when reason in [:invalid_bearer, :invalid_api_key, :api_key_revoked],
    do: :auth_invalid

  def code_override(_reason), do: nil

  # ---------------------------------------------------------------------------
  # The table: one clause per rostered reason, `{class, sentence}` or nil.
  # ---------------------------------------------------------------------------

  # Named resources, arguments and conflicts carry the caller's own words.
  defp row({:not_found, resource, id}) when is_binary(resource) and is_binary(id),
    do: {:not_found, "#{resource} not found: #{id}"}

  defp row({:not_found, {:component, ref}}) when is_binary(ref),
    do: {:not_found, "Component not found: #{ref}"}

  # The registry row names bytes the store no longer holds.
  defp row({:not_found, {:blob, digest}}) when is_binary(digest),
    do: {:not_found, "The component's bytes were not found (#{digest})"}

  # A reference the grammar refuses, in `Prima.ComponentRef`'s own words
  # about the caller's string.
  defp row({:invalid_reference, reason}) when is_binary(reason),
    do: {:invalid_argument, "Invalid reference: #{reason}"}

  defp row({:invalid_reference, _reason}), do: {:invalid_argument, "Invalid reference"}

  defp row({:invalid_argument, message}) when is_binary(message),
    do: {:invalid_argument, message}

  defp row({:conflict, message}) when is_binary(message), do: {:conflict, message}

  defp row({:unavailable, what}) when is_binary(what),
    do: {:unavailable, "#{what} is unavailable — retry shortly"}

  # A stored registry credential that no longer opens: minting the
  # person's tokens again replaces it.
  defp row({:corrupt, :registry_credential}),
    do:
      {:corrupt,
       "The stored registry credential is damaged; run `cyfr registry sync` to replace it."}

  # A registry operation the person signs (`Prima.RegistryRequest`), refused
  # before it is sent: the person has no identifier to sign under, their
  # keys are held by another CYFR, or this deployment names no registry.
  defp row(:not_enrolled),
    do: {:setup_required, "This needs your identity: enroll it in Settings, then try again."}

  defp row(:remote),
    do: {:forbidden, "Your keys are held by your own CYFR; do this there."}

  defp row(:no_registry),
    do: {:setup_required, "No registry is configured on this server (CYFR_REGISTRY_URL=none)."}

  defp row(:registry_unavailable),
    do: {:unavailable, "The registry could not be reached just now; try again shortly."}

  # A push for a namespace this server holds no usable token for, or whose
  # token the registry no longer accepts: the stale token is removed, and a
  # sync mints the person's tokens again.
  defp row(:registry_token_missing),
    do:
      {:unauthenticated,
       "There is no valid push token for this namespace; run `cyfr registry sync`, then " <>
         "push again."}

  # The registry's own refusals of a signed request that CYFR passes on
  # (`Prima.RegistryRequest.refusals/0` names each one's code); the last
  # two are the directory's too, as a recovery meets them.
  defp row(:malformed_answer),
    do: {:unavailable, "The registry's answer could not be read; try again shortly."}

  defp row(:handle_taken), do: {:conflict, "That handle is already taken; pick another."}

  defp row(:has_other_handle),
    do: {:conflict, "Your identity already holds another handle at the registry."}

  defp row(:handle_invalid), do: {:invalid_argument, "The registry does not accept that handle."}
  defp row(:handle_reserved), do: {:invalid_argument, "That handle is reserved; pick another."}

  defp row(:no_handle),
    do: {:setup_required, "Claim a handle at the registry first: run `cyfr registry claim`."}

  defp row(:namespace_reserved),
    do: {:forbidden, "That namespace is reserved at the registry."}

  defp row(:claim_not_pending),
    do: {:conflict, "No pending claim of yours names that namespace; claim it first."}

  defp row(:dns_unverified),
    do: {:conflict, "The registry did not find the DNS record the claim asked for yet."}

  defp row(:dns_timeout),
    do: {:unavailable, "The registry's DNS lookup timed out; try again shortly."}

  defp row({:policy_required, version}) when is_binary(version),
    do: {:conflict, "Accept the registry's policy version #{version} first."}

  defp row({:policy_required, nil}),
    do: {:conflict, "Accept the registry's current policy first."}

  defp row(:banned), do: {:forbidden, "The registry has banned this identity."}

  defp row(:not_appellant), do: {:forbidden, "This action is not yours to appeal."}

  defp row(:action_not_found), do: {:not_found, "The registry has no such action to appeal."}

  defp row(:appeal_too_early),
    do: {:forbidden, "This ban's cool-off has not passed; appeal once it has."}

  defp row(:namespace_unowned),
    do:
      {:forbidden,
       "That namespace has no owner at the registry, so its operator handles this appeal by hand."}

  defp row(:wrong_directory),
    do:
      {:forbidden,
       "The registry accepts only identities its own directory orders; this one names another."}

  defp row(:unknown_identity), do: {:not_found, "The directory does not know this identity."}

  defp row(:directory_unavailable),
    do: {:unavailable, "The identity's directory could not be read just now; try again shortly."}

  # Stored bytes that no longer match the digest their row recorded: an
  # integrity refusal, not an outage — a retry will not help, and the
  # bytes are not served under the digest a caller would trust.
  defp row({:corrupt, {:digest, what}}) when is_binary(what),
    do: {:corrupt, "#{what} does not match its recorded digest and was not served"}

  # A stored row that no longer decodes: nothing is served from it, and
  # nothing but writing it again repairs it.
  defp row({:corrupt, {:profile, _id}}),
    do: {:corrupt, "The stored profile is damaged and cannot be used."}

  defp row({:corrupt, {:manifest, _ref}}), do: {:corrupt, "The stored manifest is damaged."}

  # A dependency whose stored manifest or dependency block does not read:
  # its subtree is unknown, which is damage, never an empty one.
  defp row({:dependency_unreadable, ref, _reason}) when is_binary(ref),
    do:
      {:corrupt, "A dependency's stored manifest is damaged, so its dependencies cannot be read."}

  # A person's identity row is minted with their person row; one missing
  # is damage, never a local person who has not enrolled.
  defp row({:corrupt, :person_identity}),
    do: {:corrupt, "This person's identity record is missing, so it cannot be used."}

  defp row({:corrupt, {:execution, _id}}),
    do: {:corrupt, "The stored execution record is damaged."}

  # A run's component graph whose stored rows do not hash, so the consent
  # cannot be judged against it. The ref rides in the reason; the sentence
  # names the damaged thing, never a grant to make.
  defp row({:corrupt, {:component_graph, _ref}}),
    do: {:corrupt, "The component graph this run needs is stored damaged and cannot be used."}

  defp row({:corrupt, {:settings, :retention}}),
    do: {:corrupt, "The stored retention settings are damaged."}

  # A supervised call's own ending, already a client-safe sentence.
  defp row({:crashed, message}) when is_binary(message), do: {:internal, message}
  defp row({:exit, message}) when is_binary(message), do: {:internal, message}
  defp row({:cancelled, message}) when is_binary(message), do: {:cancelled, message}
  defp row({:timeout, message}) when is_binary(message), do: {:timeout, message}

  # A child asked for after its parent's subtree deadline passed.
  defp row({:timeout, :parent_deadline}),
    do: {:timeout, "The parent execution's deadline has passed"}

  defp row(:action_missing), do: {:invalid_argument, "Missing required argument: action"}

  # A send whose run read a class its grant declares no flow of to the
  # exit (`Prima.Flow`): the classes and the exit, by its host, a need and
  # its host, or a server name.
  defp row({:flow_not_declared, [_ | _] = classes, exit}) when is_binary(exit) do
    if Enum.all?(classes, &(&1 in Prima.Source.classes())),
      do: {:forbidden, Prima.Flow.sentence(classes, exit)}
  end

  defp row({:unknown_action, name_action}) when is_binary(name_action),
    do: {:invalid_argument, "Unknown action: #{name_action}"}

  # A lost control-plane lease blocks admission until ownership is restored.
  defp row(:control_plane_lost),
    do:
      {:not_owner,
       "This server does not currently own its database's control plane — retry shortly"}

  defp row(:not_owner),
    do: {:not_owner, "This server does not currently own its control plane — retry shortly"}

  defp row(:slot_not_held),
    do: {:not_owner, "This server does not hold its slot in the cluster — retry shortly"}

  # The component index has not caught up with the tree it projects: an
  # answer from it would be stale, so none is given.
  defp row(:projection_unavailable),
    do: {:unavailable, "The component index is catching up with its files — retry shortly"}

  # The athanor exists and is being filled. A turn waits for that; reads of
  # the tree answer meanwhile.
  defp row(:not_provisioned),
    do: {:unavailable, "This athanor is still being prepared — retry shortly"}

  # The runner's queue is full: the one `:busy`. A live peer holding the
  # thread is `:held_elsewhere`.
  defp row(:busy),
    do: {:rate_limited, "The turn queue is full — send again after the current turn"}

  defp row(:held_elsewhere),
    do: {:conflict, "Another server is running this thread — send again once it finishes"}

  defp row({:held_elsewhere, turn_id}) when is_binary(turn_id),
    do: {:conflict, "Another turn holds this thread — send again once it finishes"}

  defp row(:not_member), do: {:forbidden, "Only a member of the athanor can act in its threads"}
  defp row(:archived), do: {:forbidden, "This athanor is archived — nothing runs in it"}

  defp row(:no_agent),
    do: {:setup_required, "This athanor has no assistant to address — reset its AQUA tree"}

  defp row(:execution_unavailable),
    do: {:unavailable, "The execution engine is unavailable — retry shortly"}

  defp row(:no_worker_for_target),
    do: {:unavailable, "No worker serves this webhook's target; try again when one does."}

  defp row(:message_too_long),
    do: {:invalid_argument, "The message is longer than the 32 KiB bound"}

  defp row(:client_id_reused),
    do:
      {:conflict,
       "That client id already names a different send — offer the same send, or a new client id"}

  defp row(:message_id_reused), do: {:conflict, "That message id already names another message"}

  # An effect that may have happened with no result to show for it; one
  # that happened whose result could not be kept; one whose record of
  # ending could not be written.
  defp row({:uncertain, message}) when is_binary(message), do: {:uncertain, message}
  defp row({:result_lost, message}) when is_binary(message), do: {:uncertain, message}
  defp row({:not_recorded, message}) when is_binary(message), do: {:uncertain, message}

  # What a unit commit refused, and what the caller does about it. A
  # writer that died holding a unit's draft blocks the unit until the
  # draft expires (`Arca.StorageUnits.draft_ttl_ms/0`, fifteen minutes),
  # so the sentence says how long rather than "retry shortly".
  defp row(:stale_writer),
    do:
      {:conflict,
       "Another write to this unit holds it — retry once its draft expires (up to fifteen minutes)"}

  defp row(:stale_revision),
    do: {:conflict, "Another write to this unit landed first — read it again and retry"}

  defp row(:missing_unit), do: {:not_found, "This unit was removed while it was being written"}

  # A plain write inside a unit no committed row names: nothing lands
  # inside a unit before the unit exists, and a component exists by its
  # own verbs.
  defp row(:no_unit),
    do:
      {:not_found,
       "Nothing is here to write into yet: a component is created by scaffold, pull, fork " <>
         "or publish, and a role, the soul or a scroll by writing its own file first"}

  # A plain write, edit or delete in a shaped folder's `.staging/`, where
  # every unit's revisions are kept and served from: only the server's own
  # commits, repairs and collector change it, and a unit is changed or
  # removed at its own path.
  defp row({:reserved_path, path}) when is_list(path),
    do:
      {:invalid_argument,
       "This folder holds the server's stored unit revisions and only the server changes " <>
         "it — edit or remove a unit at its own path, one unit at a time"}

  defp row(:invalid_objects),
    do:
      {:corrupt, "What was staged for this unit is not what was written — nothing was published"}

  # A call whose store could not say what it did: the sentence asks the
  # caller to look rather than to retry, because retrying an effect that
  # may have happened is the dangerous mistake.
  defp row(:outcome_unknown),
    do:
      {:uncertain,
       "Unavailable — what was asked may or may not have been done; check before asking again"}

  # A store or a check that could not answer, where nothing was done.
  defp row(:unavailable), do: {:unavailable, "The service could not answer — retry shortly"}

  # A host call CYFR could not answer at all.
  defp row(:lost),
    do:
      {:uncertain,
       "The call was lost — what was asked may or may not have been done; check before asking again"}

  # What a runner's wire carries: a guest error already rendered on the
  # other side, a failure sentence, a setup signal.
  defp row({:guest_error, type, message}) when is_binary(type) and is_binary(message),
    do: {Map.get(@guest_error_classes, type, :internal), message}

  defp row({:guest_error, type, message, %{}}) when is_binary(type) and is_binary(message),
    do: {Map.get(@guest_error_classes, type, :internal), message}

  defp row({:failed, message}) when is_binary(message), do: {:internal, message}

  # A credential's refusals. Two carry a detail beside the reason — the
  # provider the need asked for, the instant a cap resets — which the
  # reason keeps and the sentence never names.
  defp row(reason) when is_map_key(@credential, reason), do: Map.fetch!(@credential, reason)

  defp row({:provider_mismatch, _provider}), do: Map.fetch!(@credential, :provider_mismatch)
  defp row({:connection_cap, _reset_at}), do: Map.fetch!(@credential, :connection_cap)

  # A component whose registry row carries no type: registering it again
  # writes one.
  defp row({:setup_required, :registry_binding}),
    do: {:setup_required, "The component has no registry binding; register it again."}

  # A caller's asserted component type that is not the registry's: the
  # registry decides, since the type selects the runtime's capabilities.
  # The two types ride in the reason, not the sentence.
  defp row({:component_type_mismatch, asserted, registered})
       when is_atom(asserted) and is_atom(registered),
       do:
         {:invalid_argument, "The requested type does not match the component's registered type."}

  # A component type outside the executable roster, from a caller or a row.
  defp row(:invalid_component_type),
    do:
      {:invalid_argument,
       "Invalid component type; it must be one of: " <>
         Enum.join(Prima.ComponentRef.executable_types(), ", ") <> "."}

  # A component's stored bytes that do not hash to the digest its registry
  # row records: never run, and only registering it again repairs it.
  defp row({:corrupt, {:artifact, digest}}) when is_binary(digest),
    do: {:corrupt, "The component's bytes do not match their recorded digest; register it again."}

  # A component that uses a WebAssembly feature the runtime refuses
  # (`Prima.ComponentFeatures`), refused where it is published, registered
  # or built and again before it is compiled; which feature is the log
  # line's. The digest is the one `Prima.Digest.sha256/1` computed of its
  # bytes, so nothing of the component is in the sentence.
  defp row({:component_feature_refused, digest}) when is_binary(digest) do
    if component_digest?(digest),
      do:
        {:invalid_argument,
         "The component #{digest} uses a WebAssembly feature this runtime does not admit: " <>
           "component-model async, GC or exception handling."}
  end

  # A core WebAssembly module where a component is published, registered
  # or built (`Prima.Wasm`), refused in that module's own sentence.
  defp row({:core_module, sentence}) when is_binary(sentence), do: {:invalid_argument, sentence}

  # A component the validator refuses with every feature it knows on.
  defp row({:component_invalid, digest}) when is_binary(digest) do
    if component_digest?(digest),
      do: {:invalid_argument, "The component #{digest} is not valid WebAssembly."}
  end

  # The validator could not answer (not installed, not started, killed at
  # its deadline): the component is refused unchecked.
  defp row(:component_validator_unavailable),
    do:
      {:unavailable,
       "The component could not be checked, so it was not admitted; try again later."}

  # A component whose signature or attestation does not verify.
  defp row({:attestation_failed, _what}),
    do:
      {:forbidden, "The component's signature could not be verified; signed pulls are required."}

  # A chain's authority refused what the chain asked, in the authority
  # vocabulary's own sentence (`Prima.Authority.Transition.deny_message/1`)
  # after the words a reader of a closed step or a guest's answer matches
  # a denial by.
  defp row({:invoke_denied, reason}) do
    if Prima.Authority.Transition.refusal?(reason),
      do:
        {:forbidden,
         "Denied by chain authority: " <> Prima.Authority.Transition.deny_message(reason)}
  end

  defp row({tag, _detail} = refusal)
       when tag in [:delegation_refused, :invoke_invalid, :invalid_need] do
    if Prima.Authority.Transition.refusal?(refusal),
      do: {:forbidden, Prima.Authority.Transition.deny_message(refusal)}
  end

  # The consent signals (`Prima.ConsentSignal`).
  defp row({tag, payload} = signal) when is_consent_signal(tag, payload),
    do: {signal_class(tag), Prima.ConsentSignal.message(signal)}

  defp row(:rate_limited), do: {:rate_limited, "Too many requests — slow down and retry"}

  defp row({:rate_limited, retry_after_s}) when is_integer(retry_after_s) and retry_after_s >= 0,
    do: {:rate_limited, "Too many requests; retry in #{retry_after_s} s."}

  defp row(:stream_limit),
    do: {:rate_limited, "Too many open streams — close one and retry"}

  # The two ceilings a sign-in meets minting the person their athanor:
  # how fast strangers arrive, and how many athanors the server holds.
  defp row({:limit_reached, :mint_per_hour, _limit}),
    do:
      {:rate_limited, "This server is admitting new people slowly right now — try again shortly"}

  defp row({:limit_reached, :max_athanors, _limit}),
    do: {:rate_limited, "This server holds as many athanors as it may — ask its operator"}

  defp row({:limit_reached, _what, _limit}),
    do: {:rate_limited, "A limit on this account was reached — try again later"}

  # A counted cap whose ceiling or count the store could not answer
  # (`Prima.Caps`): refused, and not the caller's to fix.
  defp row({:cap_unverifiable, key}) when is_atom(key),
    do: {:unavailable, "A limit on this account could not be checked — retry shortly"}

  # A presented credential that does not open anything.
  defp row(:invalid_bearer),
    do: {:unauthenticated, "The presented credential is not valid. If it expired, sign in again."}

  defp row(:invalid_api_key), do: {:unauthenticated, "Invalid API key"}
  defp row(:api_key_revoked), do: {:unauthenticated, "API key has been revoked"}

  defp row(:invalid_credential),
    do: {:unauthenticated, "The presented credential is not valid — sign in again"}

  defp row(:revoked), do: {:unauthenticated, "The presented credential has been revoked"}

  defp row(reason) when reason in [:expired_token, :expired_credential],
    do: {:unauthenticated, "The presented credential has expired — sign in again"}

  defp row(:no_athanor),
    do: {:unauthenticated, "This credential names no athanor — sign in to one"}

  defp row(:missing_generation),
    do: {:unauthenticated, "This session cannot vouch for its standing — sign in again"}

  defp row(:stale_generation),
    do: {:unauthenticated, "Your standing changed since this session was read — sign in again"}

  defp row(:signature_invalid), do: {:unauthenticated, "Signature verification failed"}
  defp row(:invalid_session), do: {:unauthenticated, "Invalid session token"}

  defp row(:denied), do: {:forbidden, "This account is not admitted on this server"}

  # A minted tincture token presented to mint its own successor.
  defp row(:not_primary), do: {:forbidden, "A minted tincture token cannot mint another"}

  defp row(:wrong_tincture),
    do: {:forbidden, "This credential opens a different tincture"}

  defp row(:ip_not_allowed), do: {:forbidden, "Request IP not in API key allowlist"}
  defp row(:origin_rejected), do: {:forbidden, "Origin not allowed"}
  defp row(:frame_request), do: {:forbidden, "A request made by a frame is refused"}

  # A context that was admitted, whose later action its standing no
  # longer covers. A credential presented and refused is `:unauthenticated`.
  defp row(:not_standing),
    do: {:forbidden, "The credential behind this request no longer stands"}

  defp row(:auth_provider_error),
    do: {:unavailable, "Authentication service unavailable — retry shortly"}

  defp row(reason) when reason in @transport_invalid,
    do: {:invalid_argument, "The request could not be read"}

  defp row(:method_not_found), do: {:not_found, "Unknown method"}

  defp row({:unknown_tool, name}) when is_binary(name),
    do: {:not_found, "Unknown tool: #{name}"}

  # A `server:tool` name no external server of the caller's athanor
  # answers (`Sanctum.Proxy`).
  defp row(:not_external), do: {:not_found, "Unknown tool"}

  defp row(:database_error),
    do: {:unavailable, "The store could not answer — retry shortly"}

  # A read that is refused answers as absent, so nothing about the row
  # leaks; `:not_found` is the same answer.
  defp row(reason) when reason in [:forbidden, :not_found], do: {:not_found, "Not found"}

  # A tincture invocation's outcomes (`Opus.invoke_tincture/3`).
  defp row(:invalid_params), do: {:invalid_argument, "The request's arguments are not valid"}

  defp row(:consent_required),
    do: {:consent_required, "The tincture is not consented to run here"}

  # More than one active profile answers the route: nothing says which.
  defp row({:ambiguous, ids}) when is_list(ids),
    do: {:conflict, "The reference matches more than one tincture."}

  defp row(:service_unavailable),
    do: {:unavailable, "The service is unavailable — retry shortly"}

  # A sensitive change's refusals that are no denial: the proof the change
  # needs cannot be given here, or not yet.
  defp row(:remote_identity_unavailable),
    do: {:unavailable, "This needs the CYFR that holds the person's identity: do it there."}

  defp row(:email_unavailable),
    do: {:unavailable, "No one-time code can be emailed to you here; confirm another way."}

  defp row(:reauth_required),
    do:
      {:unauthenticated,
       "Your first passkey needs a recent sign-in here: sign in again, then register it."}

  # An installation reserved for a restore: its first person comes back
  # through the restore, so no ordinary first sign-in is admitted, whoever
  # signs in. Not a denial of the person.
  defp row(:restore_reserved),
    do:
      {:forbidden,
       "This installation is waiting for its owner to restore their identity; no one signs " <>
         "in here until that restore finishes or the operator ends it."}

  # The setup token past its person's first sign-in method: it opens
  # nothing, whoever presents it.
  defp row(:setup_closed),
    do:
      {:forbidden,
       "This CYFR is set up. Sign in with your passkey, a device you connected, or a " <>
         "sign-in method you linked."}

  # An admission other than setup or a restore onto a CYFR with no person:
  # its first person is its administrator, made only by its setup.
  defp row(:not_set_up),
    do: {:setup_required, "This CYFR is not set up yet. Its operator opens the setup link first."}

  # A linked sign-in method no person here holds: a method unlocks a person
  # and never makes one.
  defp row(:no_person),
    do:
      {:not_found,
       "No one here signs in with this account. Sign in another way, then link it in Settings."}

  # A remote person's identity whose head this home could not confirm
  # fresh within its bound: their work here pauses and their session
  # stands, so it is no sign-out and no denial.
  defp row(:identity_stale),
    do:
      {:unavailable,
       "Your identity could not be confirmed fresh with its directory just now; try again shortly."}

  defp row(:execution_failed), do: {:internal, "The execution failed"}

  # Webhook ingress.
  defp row(:missing_idempotency_key),
    do: {:invalid_argument, "This webhook requires an idempotency key on every delivery"}

  defp row(:missing_token), do: {:unauthenticated, "No session token provided"}

  defp row(:unsupported_content_type),
    do: {:invalid_argument, "Unsupported content type — send the delivery as application/json"}

  # The endpoint's parsers: a multipart body is refused before it is read.
  defp row(:multipart_refused), do: {:invalid_argument, "This endpoint takes no multipart bodies"}

  # A socket transport's body, bounded before the transport reads any of it.
  defp row(:socket_body_too_large),
    do: {:invalid_argument, "The request body exceeds the size limit"}

  defp row(:socket_body_length_required),
    do: {:invalid_argument, "The request body's length must be declared"}

  defp row(:internal_error), do: {:internal, "Internal error"}

  defp row(:missing_grant),
    do: {:internal, "The execution's standing could not be read"}

  defp row(:attempt_not_owner),
    do: {:conflict, "This attempt no longer owns the execution"}

  defp row(:conflict), do: {:conflict, "Another change landed first — read again and retry"}

  # An approved launch whose root, as loaded, does not hold the account the
  # approval bound (its entry, under the name its binding stored): nothing
  # ran, and approving it again is what to do. The launch itself answers
  # in a sentence naming the account; this one is for a surface that
  # renders the reason without it.
  defp row(:approved_entry_moved),
    do:
      {:conflict,
       "The account this launch was approved for has changed since it was approved, so nothing " <>
         "ran: ask again to approve it as it stands now."}

  defp row(:approved_sources_moved),
    do:
      {:conflict,
       "This turn read more since the launch was approved, so nothing ran: ask again " <>
         "to approve it with what it has read now."}

  defp row(:approved_grant_moved),
    do:
      {:conflict,
       "The grant this launch was approved under has changed since it was approved, so nothing " <>
         "ran: ask again to approve it as it stands now."}

  defp row(reason) when reason in @barrier_conflicts,
    do: {:conflict, "The parent execution moved on — the child was not admitted"}

  defp row({:payload_not_retained, _why}),
    do: {:unavailable, "The payload this needs is no longer retained"}

  defp row(:not_cancellable), do: {:conflict, "The execution can no longer be cancelled"}
  defp row(:replayed), do: {:conflict, "This call was already answered"}

  defp row({:slot_refused, sentence}) when is_binary(sentence), do: {:conflict, sentence}

  # `Prima.Slots` refusals.
  defp row(reason) when reason in [:capacity, :key_cap, :key_unreaped],
    do: {:rate_limited, "The server is at capacity — retry shortly"}

  defp row(:timeout), do: {:timeout, "The call timed out"}
  defp row(:cancelled), do: {:cancelled, "The call was cancelled"}

  defp row(reason) when reason in @turn_conflicts,
    do: {:conflict, "The turn moved on — read the thread again and retry"}

  defp row({:already_resolved, _answer}),
    do: {:conflict, "This was already decided"}

  defp row({:no_claim, _id}), do: {:conflict, "The thread's claim moved on — read it again"}

  defp row(reason) when reason in @turn_internal,
    do: {:internal, "The turn's record refused the write"}

  defp row({:execution_not_in, _from}),
    do: {:internal, "The execution is not in the state the write expected"}

  defp row({:grant_failed, _reason}),
    do: {:internal, "The turn's grant could not be written"}

  defp row(reason) when reason in @turn_not_found, do: {:not_found, "Not found"}
  defp row(:empty), do: {:invalid_argument, "The message is empty"}

  # A send's own limits.
  defp row(:storage_full),
    do: {:rate_limited, "The athanor's storage is full — free some space and retry"}

  defp row(:storage_unverifiable),
    do: {:unavailable, "The athanor's storage use could not be read — retry shortly"}

  # The home's storage reserve is depleted (`Arca.StorageReserve`): what
  # Arca's write gate refuses, and the gate's refusal of every operation
  # but a read and one that takes authority away.
  defp row({:unavailable, :storage_reserve}),
    do:
      {:unavailable,
       "This CYFR is nearly out of storage: until space is freed it accepts only reads " <>
         "and changes that take authority away, such as signing out or revoking"}

  defp row(:context_too_long),
    do: {:invalid_argument, "The thread is longer than the model accepts"}

  defp row(:too_many_attachments), do: {:invalid_argument, "Too many attachments"}
  defp row(:attachment_too_large), do: {:invalid_argument, "An attachment is too large"}
  defp row(:storage_error), do: {:internal, "Storage failed"}

  defp row(reason) when is_map_key(@access, reason), do: Map.fetch!(@access, reason)

  # An access code carried with its payload, as the boot's resolver answers
  # it, reads as the same row.
  defp row({reason, payload})
       when is_map_key(@access, reason) and is_map(payload) and map_size(payload) == 0,
       do: Map.fetch!(@access, reason)

  # How the home is reached, as the boot reads it (`Cyfr.RuntimeConfig.resolve_access/1`):
  # each sentence names what is wrong and the command that writes it right.
  # Every payload is a setting's name or its non-secret value.
  defp row({:access_unknown_mode, %{value: value}}) when is_binary(value),
    do:
      {:invalid_argument,
       "CYFR_ACCESS is `#{value}`; it must be `local`, `tailnet` or `public`. Run " <>
         "`cyfr access <mode>` to set it with the address it implies."}

  defp row({:access_local_mismatch, %{key: key, value: value}})
       when key in ["CYFR_HOST", "CYFR_PUBLIC_URL"] and is_binary(value) do
    what = "#{key} is `#{value}`"

    {:invalid_argument,
     "CYFR_ACCESS is `local`, which serves this computer alone at its localhost address, " <>
       "but #{what}. Run `cyfr access local` to write the matching settings, or " <>
       "`cyfr access tailnet|public` to reach it from other devices."}
  end

  defp row({:access_tailnet_host_invalid, payload}) when is_map(payload) do
    what =
      case payload do
        %{host: host} when is_binary(host) -> "CYFR_HOST `#{host}` is not"
        _ -> "CYFR_HOST is not set to"
      end

    {:invalid_argument,
     tailnet_sentence("#{what} a tailnet machine name (<machine>.<tailnet>.ts.net)")}
  end

  defp row({:access_tailnet_node_invalid, payload}) when is_map(payload) do
    what =
      case payload do
        %{value: value} when is_binary(value) ->
          "CYFR_TAILNET_NODE_ID `#{value}` is malformed"

        _ ->
          "CYFR_TAILNET_NODE_ID is missing"
      end

    {:invalid_argument, tailnet_sentence(what)}
  end

  defp row({:access_public_host_invalid, payload}) when is_map(payload) do
    what =
      case payload do
        %{host: host} when is_binary(host) -> "CYFR_HOST `#{host}` is not"
        _ -> "CYFR_HOST is not set to"
      end

    {:invalid_argument,
     "CYFR_ACCESS is `public`, but #{what} a public domain name (not localhost, an IP address " <>
       "or a ts.net name). Run `cyfr access public --domain <your domain>`."}
  end

  defp row({:access_public_url_mismatch, %{mode: mode, expected: expected} = payload})
       when mode in ["tailnet", "public"] and is_binary(expected) do
    now =
      case payload do
        %{value: url} when is_binary(url) -> "it is `#{url}`"
        _ -> "it is not set"
      end

    {:invalid_argument,
     "CYFR_PUBLIC_URL must be exactly #{expected} when CYFR_ACCESS is `#{mode}`; #{now}. " <>
       "Run `cyfr access #{mode}` to rewrite both."}
  end

  defp row({:access_key_outside_mode, %{key: key, mode: mode, needs: needs}})
       when key in ["CADDY_ACME_EMAIL", "CYFR_TAILNET_NODE_ID"] and
              mode in ["local", "tailnet", "public"] and needs in ["tailnet", "public"],
       do:
         {:invalid_argument,
          "`#{key}` is set, but only `#{needs}` access uses it (CYFR_ACCESS is `#{mode}`). " <>
            "Remove it, or run `cyfr access #{needs}`."}

  defp row({:access_source_conflict, %{key: key, file_value: file, process_value: process}})
       when is_binary(key) and is_binary(file) and is_binary(process) do
    there = if process == "", do: "blank", else: "`#{process}`"

    {:conflict,
     "`#{key}` is `#{file}` in .env and #{there} in this process's environment; CYFR is " <>
       "reached one way. Remove one of them."}
  end

  defp row({:access_bind_not_loopback, %{address: address}}) when is_binary(address),
    do:
      {:forbidden,
       "CYFR_BIND_ADDRESS `#{address}` is not a loopback address, so other machines could " <>
         "reach CYFR's loopback listener. Bind 127.0.0.1 or ::1; to reach CYFR from " <>
         "other devices, use CYFR_ACCESS=tailnet or public."}

  defp row({:access_setting_invalid, %{key: key, value: value} = payload})
       when map_size(payload) == 2 and is_map_key(@access_setting_forms, key) and
              is_binary(value),
       do:
         {:invalid_argument,
          "`#{key}` is `#{value}`, which is not #{Map.fetch!(@access_setting_forms, key)}. " <>
            "Nothing started. Correct it, or remove it to take the default."}

  # The proxy listener on the loopback listener's port, at an address the
  # loopback listener's overlaps, where it could not bind.
  defp row(
         {:access_setting_invalid,
          %{key: "CYFR_PROXY_PORT", value: value, address: address, bind: bind, port: port} =
            payload}
       )
       when map_size(payload) == 5 and is_binary(value) and is_binary(address) and
              is_binary(bind) and is_binary(port),
       do:
         {:invalid_argument,
          "`CYFR_PROXY_PORT` is `#{value}` on `#{address}`, and the loopback listener takes " <>
            "CYFR_PORT `#{port}` on `#{bind}`: the proxy listener's port must differ from the " <>
            "loopback listener's on the same address. Nothing started. Set CYFR_PROXY_PORT to " <>
            "another port."}

  # A value no rule can read: its name alone, never its bytes.
  defp row({:access_setting_invalid, %{key: key} = payload})
       when is_binary(key) and map_size(payload) == 1,
       do:
         {:invalid_argument,
          "`#{key}` is not valid UTF-8 text. Nothing started. Correct it, or remove it."}

  # A `cyfr access` option only a public home takes, given for another mode.
  defp row({:access_option_outside_mode, %{option: option, mode: mode}})
       when option in ["--domain", "--acme-email"] and mode in ["local", "tailnet"],
       do:
         {:invalid_argument,
          "`#{option}` is for public access, and this command chooses `#{mode}`. Nothing was " <>
            "changed. Run it again without `#{option}`, or run `cyfr access public` with it."}

  defp row({:tailnet_node_id_unsupported, %{value: value}}) when is_binary(value),
    do:
      {:invalid_argument,
       "Tailscale reported a machine identity CYFR cannot store (`#{value}`). How CYFR " <>
         "is reached was not changed. Report this with your Tailscale version."}

  defp row({:compose_env_refused, %{key: "COMPOSE_" <> _ = key}}),
    do:
      {:invalid_argument,
       "`.env` sets `#{key}`, which Docker Compose would read to choose this stack's files, " <>
         "project or services behind cyfr's back. Nothing started. Remove it; cyfr chooses " <>
         "them from CYFR_ACCESS and CYFR_LOCUS_BUILDS_URL."}

  # A .env line Docker Compose does not read: cyfr neither reads nor
  # writes a file it cannot read as compose does, and names the line,
  # never its text, which may hold a secret.
  defp row({:compose_env_refused, %{line: line} = payload})
       when is_binary(line) and map_size(payload) == 1,
       do:
         {:invalid_argument,
          "Line #{line} of `.env` does not read as Docker Compose reads it, so cyfr cannot " <>
            "read or change .env as compose would. Nothing was changed. Correct that line, " <>
            "then run the command again."}

  # A compose file that would change, behind .env, how the home is
  # reached: an access setting assigned in the service's own environment, a name
  # written with `$` in any service's environment, which cyfr does not
  # resolve, or a service that does not read .env at all.
  defp row({:compose_override_refused, %{file: file, service: service, key: key} = payload})
       when map_size(payload) == 3 and is_binary(file) and is_binary(service) and is_binary(key),
       do:
         {:invalid_argument,
          "`#{file}` sets `#{key}` in the `#{service}` service's environment, where it would " <>
            "override how .env says CYFR is reached. Nothing started. Remove `#{key}` " <>
            "from `#{file}`; .env alone holds it, and `cyfr access` writes it."}

  defp row(
         {:compose_override_refused,
          %{file: file, service: service, key: key, why: :interpolated} = payload}
       )
       when map_size(payload) == 4 and is_binary(file) and is_binary(service) and
              is_binary(key),
       do:
         {:invalid_argument,
          "`#{file}` names `#{key}` in the `#{service}` service's environment, a name with " <>
            "`$` in it, which cyfr cannot check before Docker Compose reads it. Nothing " <>
            "started. Write the name in `#{file}` without `$`."}

  defp row({:compose_override_refused, %{file: file, service: service} = payload})
       when map_size(payload) == 2 and is_binary(file) and is_binary(service),
       do:
         {:invalid_argument,
          "`#{file}` does not give the `#{service}` service .env through its env_file, so it " <>
            "would not read how CYFR is reached. Nothing started. Add `env_file: .env` " <>
            "to the `#{service}` service in `#{file}`, as the shipped docker-compose.yml has it."}

  # The access engine's refusals and outcomes, in the words `cyfr access`
  # prints them. A sentence that follows a change that may have landed
  # says so and names the recovery, never a bare "try again".
  defp row({:access_busy, %{holder: holder, pid: pid, until: until}})
       when is_binary(holder) and is_binary(pid) and is_binary(until),
       do:
         {:conflict,
          "Another cyfr command holds CYFR's lock (`#{holder}`), or a docker command it " <>
            "started is still running (watchdog pid `#{pid}`, which ends by `#{until}` at the " <>
            "latest). Nothing was changed. Wait until it has finished, then run this command " <>
            "again; if the holder was interrupted, run `cyfr access --resume` after that time."}

  # The holder itself, between its docker commands, named with its pid
  # where its record or the kernel's lock table gives one.
  defp row({:access_busy, %{holder: holder} = payload})
       when map_size(payload) == 1 and is_binary(holder),
       do:
         {:conflict,
          "Another cyfr command holds CYFR's lock (`#{holder}`). Nothing was changed. Wait " <>
            "until it has finished, then run this command again."}

  defp row({:access_busy, %{holder: holder, pid: pid} = payload})
       when map_size(payload) == 2 and is_binary(holder) and is_binary(pid),
       do:
         {:conflict,
          "Another cyfr command holds CYFR's lock (`#{holder}`, pid `#{pid}`). Nothing was " <>
            "changed. Wait until it has finished, then run this command again."}

  # A tailnet join whose command has ended, still waiting for its approval
  # until its own deadline.
  defp row({:access_busy, %{join_id: join_id, until: until} = payload})
       when map_size(payload) == 2 and is_binary(join_id) and is_binary(until),
       do:
         {:conflict,
          "A tailnet join (`#{join_id}`) is still waiting for this machine's approval, until " <>
            "`#{until}` at the latest. Nothing was changed. Approve the machine with the link " <>
            "that join printed, or wait until then, and run this command again."}

  defp row({:access_stale, %{words: words}}) when is_binary(words),
    do:
      {:conflict,
       "How CYFR is reached changed after the change was shown to you (it is now: " <>
         "#{words}). Nothing was changed. Run the command again to review the change."}

  defp row({:access_unchanged, %{address: address}}) when is_binary(address),
    do:
      {:invalid_argument, "CYFR is already reached that way, at #{address}. Nothing was changed."}

  defp row({:access_invalid, %{input: input, kind: kind, rule: rule}})
       when is_binary(input) and is_map_key(@access_input_kinds, kind) and is_binary(rule),
       do:
         {:invalid_argument,
          "`#{input}` is not a valid #{Map.fetch!(@access_input_kinds, kind)}: #{rule}. " <>
            "Nothing was changed. Correct it and run the command again."}

  defp row({:tailnet_https_off, %{name: name}}) when is_binary(name),
    do:
      {:setup_required,
       "This machine joined your tailnet as `#{name}`, but your tailnet has HTTPS " <>
         "certificates turned off, and CYFR needs them. How CYFR is reached was " <>
         "not changed. Turn on HTTPS on the DNS page of the Tailscale admin console, then " <>
         "run `cyfr access tailnet` again, which uses this machine as it is. If you do not " <>
         "want it in your tailnet, remove `#{name}` on the Machines page of the admin console."}

  defp row({:tailnet_active, %{name: name}}) when is_binary(name),
    do:
      {:conflict,
       "CYFR is already on your tailnet as `#{name}`. Nothing was changed. To give it " <>
         "another name, run `cyfr access local`, then `cyfr access tailnet --new-node`, and " <>
         "remove `#{name}` on the Machines page of the Tailscale admin console."}

  defp row({:tailnet_name_changed, %{frozen: frozen, now: now}})
       when is_binary(frozen) and is_binary(now),
       do:
         {:conflict,
          "The machine's tailnet name or identity changed from `#{frozen}` to `#{now}` after " <>
            "the change was shown. Nothing was changed. Run the command again to review it."}

  defp row({:tailnet_node_mismatch, %{node: node, env: env}})
       when is_binary(node) and is_binary(env),
       do:
         {:conflict,
          "This machine's tailnet identity is `#{node}`, but .env says CYFR is " <>
            "`#{env}`, so it is not being served on your tailnet: it answers on this machine " <>
            "only, and nothing else was changed. Run `cyfr access tailnet`, which offers to " <>
            "move CYFR to https://#{node} after you confirm."}

  defp row({:docker_unavailable, %{reason: why}}) when is_binary(why),
    do:
      {:unavailable,
       "Docker did not answer (#{why}) before the change was accepted. Nothing was changed. " <>
         "Start Docker, then run the command again."}

  defp row({:access_rolled_back, %{new: new, old: old, reason: why} = payload})
       when map_size(payload) == 3 and is_binary(new) and is_binary(old) and is_binary(why),
       do:
         {:conflict,
          "CYFR could not start as #{new} (#{why}). What it started was stopped and " <>
            "checked stopped, and CYFR was put back: it is reached as before, #{old}, and " <>
            "running. Fix what the reason names, then run the command again."}

  # Put back as before, but the old head's tailnet machine is not ready to
  # serve it, so it answers on this machine only, and why.
  defp row({:access_rolled_back, %{new: new, old: old, reason: why, local: local} = payload})
       when map_size(payload) == 4 and is_binary(new) and is_binary(old) and is_binary(why) and
              is_map_key(@rolled_back_local, local) do
    {because, next} = Map.fetch!(@rolled_back_local, local)

    {:conflict,
     "CYFR could not start as #{new} (#{why}). What it started was stopped and checked " <>
       "stopped, and CYFR was put back as before, #{old}, but it answers on this machine " <>
       "only, because #{because}. Fix what the reason names, then run the command again; " <>
       "#{next}."}
  end

  defp row({:access_failed, %{new: new, env: env}}) when is_binary(new) and is_binary(env),
    do:
      {:unavailable,
       "CYFR could not start as #{new}, nor as before; everything was stopped and " <>
         "checked stopped. .env says: #{env}. Run `cyfr up` to start it as .env says, or " <>
         "`cyfr access <mode>` to choose again."}

  # A switch interrupted, then recovered after .env was edited meanwhile:
  # what the recovery did, in the one order it does it, and the next step.
  defp row({:access_env_edited, %{then: "started", env: env} = payload})
       when map_size(payload) == 2 and is_binary(env),
       do:
         {:conflict,
          env_edited() <>
            " CYFR stopped the stack, checked it stopped, left .env as edited, and started " <>
            "CYFR as it says: #{env}. If that is not how CYFR should be reached, run " <>
            "`cyfr access <mode>`."}

  defp row({:access_env_edited, %{then: "not_running", env: env} = payload})
       when map_size(payload) == 2 and is_binary(env),
       do:
         {:conflict,
          env_edited() <>
            " CYFR stopped the stack, checked it stopped, and left .env as edited, which says: " <>
            "#{env}. The stack was not running, so nothing was started. Run `cyfr up` to start " <>
            "it as .env says, or `cyfr access <mode>` to choose again."}

  defp row({:access_env_edited, %{then: "failed", env: env} = payload})
       when map_size(payload) == 2 and is_binary(env),
       do:
         {:conflict,
          env_edited() <>
            " CYFR stopped the stack, checked it stopped, and left .env as edited, but " <>
            "CYFR did not start as it says (#{env}), and everything is stopped. Fix .env, then " <>
            "run `cyfr up`, or run `cyfr access <mode>` to choose again."}

  defp row({:access_env_edited, %{then: "incoherent"} = payload}) when map_size(payload) == 1,
    do:
      {:conflict,
       env_edited() <>
         " CYFR stopped the stack, checked it stopped, and left .env as edited; nothing was " <>
         "started, because .env no longer says one coherent way CYFR is reached. Run " <>
         "`cyfr up` to see what is wrong with it, or `cyfr access <mode>` to choose again."}

  defp row({:access_uncertain, %{observed: observed}}) when is_binary(observed),
    do:
      {:uncertain,
       "CYFR could not be brought to a known state: #{observed} were still running " <>
         "after the stop. It may be partly reachable. Nothing more was done. On the machine, " <>
         "run `cyfr access --resume`, which stops what is running, checks, and starts " <>
         "CYFR as .env says; if it reports the same, run `cyfr down`, check `docker ps`, " <>
         "then `cyfr up`."}

  defp row({:access_outcome_unknown, %{reason: why}}) when is_binary(why),
    do:
      {:uncertain,
       "This command lost track of the change before it finished (#{why}), so it may have " <>
         "been applied. Do not ask for it again: run `cyfr access --resume`, which finishes it " <>
         "under the lock and reports what happened."}

  # A crafted sentence a producer returned as a bare binary: internal,
  # and its words as they are.
  defp row(reason) when is_binary(reason), do: {:internal, Prima.Sanitizer.sanitize(reason)}

  defp row(_reason), do: nil

  defp env_edited,
    do:
      "A change of how CYFR is reached was interrupted, and .env was edited before the " <>
        "change finished."

  defp tailnet_sentence(what),
    do:
      "CYFR_ACCESS is `tailnet`, but #{what}. Run `cyfr access tailnet`, which reads both from " <>
        "Tailscale."

  defp signal_class(:setup_required), do: :setup_required
  defp signal_class(:consent_required), do: :consent_required
  defp signal_class(:consent_conflict), do: :conflict
  defp signal_class(:confirmation_required), do: :confirmation_required

  defp component_digest?(digest), do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, digest)
end
