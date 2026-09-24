# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Refusal do
  @moduledoc """
  The closed refusal table: every reason a call can be refused for, the
  class it belongs to and the public sentence it reads as.

  A producer returns its own reason term; `classify/1` turns it into
  `%Prima.Refusal{class, reason, message}`, the normalized form every edge
  reads — the wire, the console, stored rows, bus payloads. The class is
  one of fifteen (`classes/0`) and decides status and code at each
  surface; the message is a sentence with no internal field name, no
  Elixir syntax and no `inspect/1` of a term.

  The authorization vocabulary is `Sanctum.Unauthorized`'s, which
  classifies its own reasons; `Grimoire.Error.classify/1` tries it first
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

  @signal_tags [:setup_required, :consent_required, :consent_conflict, :restart_required]

  # The class a guest error's `type` reads as on the worker wire.
  @guest_error_classes %{
    "invalid_request" => :invalid_argument,
    "invalid_json" => :invalid_argument,
    "tool_denied" => :forbidden,
    "action_denied" => :forbidden,
    "storage_path_denied" => :forbidden,
    "resource_limit" => :rate_limited,
    "storage_quota_exceeded" => :rate_limited,
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
    "cancel_failed" => :internal
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

  # A run's own record refused the write it was handed: an internal fault
  # of the writer, never something the caller can change.
  @turn_internal [:fence_required, :seq_conflict]

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
  @bootstrap %{
    slot_not_held: {:not_owner, "This server does not hold its member slot"},
    busy: {:conflict, "Another server is starting against this database"},
    malformed_configuration: {:invalid_argument, "The server configuration is malformed"},
    slot_lost: {:not_owner, "This server lost its member slot while starting"},
    claim_taken: {:conflict, "Another server took the start-up claim"},
    claim_lapsed: {:timeout, "The start-up claim lapsed before start-up finished"},
    missing_user: {:setup_required, "The configured first user does not exist"},
    release_failed:
      {:uncertain,
       "Start-up could not confirm that it released its claim — check before starting again"},
    database_error: {:unavailable, "The database could not answer during start-up"},
    exception: {:internal, "Start-up failed unexpectedly"}
  }

  @doc "The fifteen refusal classes."
  @spec classes() :: [class()]
  def classes, do: @classes

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

  defp row({:invalid_argument, message}) when is_binary(message),
    do: {:invalid_argument, message}

  defp row({:conflict, message}) when is_binary(message), do: {:conflict, message}

  defp row({:unavailable, what}) when is_binary(what),
    do: {:unavailable, "#{what} is unavailable — retry shortly"}

  # A stored registry credential that no longer opens: the person signs in
  # again, which is the only thing that replaces it.
  defp row({:corrupt, :registry_credential}),
    do: {:corrupt, "The stored registry credential is damaged; sign in to the registry again."}

  # Stored bytes that no longer match the digest their row recorded: an
  # integrity refusal, not an outage — a retry will not help, and the
  # bytes are not served under the digest a caller would trust.
  defp row({:corrupt, what}) when is_binary(what),
    do: {:corrupt, "#{what} does not match its recorded digest and was not served"}

  # A supervised call's own ending, already a client-safe sentence.
  defp row({:crashed, message}) when is_binary(message), do: {:internal, message}
  defp row({:exit, message}) when is_binary(message), do: {:internal, message}
  defp row({:cancelled, message}) when is_binary(message), do: {:cancelled, message}
  defp row({:timeout, message}) when is_binary(message), do: {:timeout, message}

  defp row(:action_missing), do: {:invalid_argument, "Missing required argument: action"}

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
    do: {:not_owner, "This server does not hold its member slot — retry shortly"}

  # The estate exists and is being filled. A turn waits for that; reads of
  # the tree answer meanwhile.
  defp row(:not_provisioned),
    do: {:unavailable, "This estate is still being prepared — retry shortly"}

  # The runner's queue is full: the one `:busy`. A live peer holding the
  # thread is `:held_elsewhere`.
  defp row(:busy),
    do: {:rate_limited, "The turn queue is full — send again after the current turn"}

  defp row(:held_elsewhere),
    do: {:conflict, "Another server is running this thread — send again once it finishes"}

  defp row({:held_elsewhere, turn_id}) when is_binary(turn_id),
    do: {:conflict, "Another turn holds this thread — send again once it finishes"}

  defp row(:not_member), do: {:forbidden, "Only a member of the estate can act in its threads"}
  defp row(:archived), do: {:forbidden, "This estate is archived — nothing runs in it"}

  defp row(:no_agent),
    do: {:setup_required, "This estate has no assistant to address — reset its AQUA tree"}

  defp row(:execution_unavailable),
    do: {:unavailable, "The execution engine is unavailable — retry shortly"}

  defp row(:engine_starting),
    do: {:unavailable, "The execution engine is starting — retry shortly"}

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

  # The row is committed. The unit is published; only the move of its
  # objects to where readers read did not finish, and the storage sweep
  # finishes it.
  defp row({:finish_failed, _reason}),
    do:
      {:internal, "This unit is published; serving its files did not finish and will be repaired"}

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

  # The consent remediation signals (`Prima.ConsentSignal`).
  defp row({tag, payload} = signal) when tag in @signal_tags and is_map(payload),
    do: {signal_class(tag), Prima.ConsentSignal.message(signal)}

  defp row(:rate_limited), do: {:rate_limited, "Too many requests — slow down and retry"}

  defp row(:stream_limit),
    do: {:rate_limited, "Too many open streams — close one and retry"}

  defp row({:limit_reached, _what, _limit}),
    do: {:rate_limited, "A limit on this account was reached — try again later"}

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
    do: {:unauthenticated, "This credential names no estate — sign in to one"}

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
  # answers (`Grimoire.Proxy`).
  defp row(:not_external), do: {:not_found, "Unknown tool"}

  defp row(:database_error),
    do: {:unavailable, "The store could not answer — retry shortly"}

  # A read that is refused answers as absent, so nothing about the row
  # leaks; `:not_found` is the same answer.
  defp row(reason) when reason in [:forbidden, :not_found], do: {:not_found, "Not found"}

  # A tincture invocation's outcomes (`Emissary.Tincture.Invoke`).
  defp row(:invalid_params), do: {:invalid_argument, "The request's arguments are not valid"}

  defp row(:consent_required),
    do: {:consent_required, "The tincture is not consented to run here"}

  defp row(:service_unavailable),
    do: {:unavailable, "The service is unavailable — retry shortly"}

  defp row(:execution_failed), do: {:internal, "The execution failed"}

  # Webhook ingress.
  defp row(:missing_idempotency_key),
    do: {:invalid_argument, "This webhook requires an idempotency key on every delivery"}

  defp row(:missing_token), do: {:invalid_argument, "No session token provided"}

  defp row(:unsupported_content_type),
    do: {:invalid_argument, "Unsupported content type — send the delivery as application/json"}

  defp row(:internal_error), do: {:internal, "Internal error"}

  defp row({:bootstrap_refused, sub}) when is_map_key(@bootstrap, sub),
    do: Map.fetch!(@bootstrap, sub)

  defp row(:missing_grant),
    do: {:internal, "The execution's standing could not be read"}

  defp row(:attempt_not_owner),
    do: {:conflict, "This attempt no longer owns the execution"}

  defp row(:conflict), do: {:conflict, "Another change landed first — read again and retry"}

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
    do: {:rate_limited, "The estate's storage is full — free some space and retry"}

  defp row(:storage_unverifiable),
    do: {:unavailable, "The estate's storage use could not be read — retry shortly"}

  defp row(:context_too_long),
    do: {:invalid_argument, "The thread is longer than the model accepts"}

  defp row(:too_many_attachments), do: {:invalid_argument, "Too many attachments"}
  defp row(:attachment_too_large), do: {:invalid_argument, "An attachment is too large"}
  defp row(:storage_error), do: {:internal, "Storage failed"}

  # A crafted sentence a producer returned as a bare binary: internal,
  # and its words as they are.
  defp row(reason) when is_binary(reason), do: {:internal, Prima.Sanitizer.sanitize(reason)}

  defp row(_reason), do: nil

  defp signal_class(:setup_required), do: :setup_required
  defp signal_class(:consent_required), do: :consent_required
  defp signal_class(:consent_conflict), do: :conflict
  defp signal_class(:restart_required), do: :cancelled
end
