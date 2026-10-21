# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RefusalTest do
  @moduledoc """
  The closed refusal table: every rostered reason classifies to its class,
  every class has a sentence, no sentence spells a term, and a reason the
  table does not know is `internal`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Prima.Refusal

  # The access rows: each code with its class and the sentence it reads
  # as, word for word. The boot's own rows are held to the same words by
  # tests/fixtures/access_modes.json, on both sides.
  @access_rows [
    {:access_missing, :setup_required,
     "CYFR_ACCESS is not set in .env, so this home does not know how it is reached. Nothing started. Run `cyfr init` for a new home, or `cyfr access local|tailnet|public` for this one."},
    {{:access_missing, %{}}, :setup_required,
     "CYFR_ACCESS is not set in .env, so this home does not know how it is reached. Nothing started. Run `cyfr init` for a new home, or `cyfr access local|tailnet|public` for this one."},
    {{:access_assertion_from_file, %{}}, :forbidden,
     "CYFR_LOCAL_INGRESS_ASSERTED is the compose file's assertion and cannot come from .env. Remove it from .env."},
    {{:access_unknown_mode, %{value: "lan"}}, :invalid_argument,
     "CYFR_ACCESS is `lan`; it must be `local`, `tailnet` or `public`. Run `cyfr access <mode>` to set it with the address it implies."},
    {{:access_source_conflict, %{key: "CYFR_PORT", file_value: "4000", process_value: "4100"}},
     :conflict,
     "`CYFR_PORT` is `4000` in .env and `4100` in this process's environment; a home is reached one way. Remove one of them."},
    {{:access_bind_not_loopback, %{address: "0.0.0.0"}}, :forbidden,
     "CYFR_BIND_ADDRESS `0.0.0.0` is not a loopback address, so other machines could reach this home's loopback listener. Bind 127.0.0.1 or ::1; a home reached from other devices uses CYFR_ACCESS=tailnet or public."},
    {{:access_key_outside_mode, %{key: "CADDY_ACME_EMAIL", mode: "tailnet", needs: "public"}},
     :invalid_argument,
     "`CADDY_ACME_EMAIL` is set, but only a `public` home uses it (CYFR_ACCESS is `tailnet`). Remove it, or run `cyfr access public`."},
    {{:access_setting_invalid, %{key: "CYFR_PORT", value: "+4000"}}, :invalid_argument,
     "`CYFR_PORT` is `+4000`, which is not a port from 1 to 65535. Nothing started. Correct it, or remove it to take the default."},
    {{:access_setting_invalid,
      %{
        key: "CYFR_PROXY_PORT",
        value: "4001",
        address: "0.0.0.0",
        bind: "127.0.0.1",
        port: "4001"
      }}, :invalid_argument,
     "`CYFR_PROXY_PORT` is `4001` on `0.0.0.0`, and the loopback listener takes CYFR_PORT `4001` on `127.0.0.1`: the proxy listener's port must differ from the loopback listener's on the same address. Nothing started. Set CYFR_PROXY_PORT to another port."},
    {{:access_setting_invalid, %{key: "CADDY_ACME_EMAIL"}}, :invalid_argument,
     "`CADDY_ACME_EMAIL` is not valid UTF-8 text. Nothing started. Correct it, or remove it."},
    {{:access_setting_invalid, %{key: "CYFR_LOCUS_BUILDS_URL", value: "http://locus-builds:bad"}},
     :invalid_argument,
     "`CYFR_LOCUS_BUILDS_URL` is `http://locus-builds:bad`, which is not an http or https URL with a host, an optional port and no path, query or credentials. Nothing started. Correct it, or remove it to take the default."},
    {{:access_option_outside_mode, %{option: "--domain", mode: "local"}}, :invalid_argument,
     "`--domain` is for a public home, and this command chooses `local`. Nothing was changed. Run it again without `--domain`, or run `cyfr access public` with it."},
    {{:access_option_outside_mode, %{option: "--acme-email", mode: "tailnet"}}, :invalid_argument,
     "`--acme-email` is for a public home, and this command chooses `tailnet`. Nothing was changed. Run it again without `--acme-email`, or run `cyfr access public` with it."},
    {{:compose_env_refused, %{key: "COMPOSE_PROFILES"}}, :invalid_argument,
     "`.env` sets `COMPOSE_PROFILES`, which Docker Compose would read to choose this stack's files, project or services behind cyfr's back. Nothing started. Remove it; cyfr chooses them from CYFR_ACCESS and CYFR_LOCUS_BUILDS_URL."},
    {{:compose_env_refused, %{line: "7"}}, :invalid_argument,
     "Line 7 of `.env` does not read as Docker Compose reads it, so cyfr cannot read or change .env as compose would. Nothing was changed. Correct that line, then run the command again."},
    {{:compose_override_refused,
      %{file: "docker-compose.override.yml", service: "cyfr", key: "CYFR_HOST"}},
     :invalid_argument,
     "`docker-compose.override.yml` sets `CYFR_HOST` in the `cyfr` service's environment, where it would override how .env says this home is reached. Nothing started. Remove `CYFR_HOST` from `docker-compose.override.yml`; .env alone holds it, and `cyfr access` writes it."},
    {{:compose_override_refused,
      %{
        file: "docker-compose.override.yml",
        service: "cyfr",
        key: "${HOSTKEY}",
        why: :interpolated
      }}, :invalid_argument,
     "`docker-compose.override.yml` names `${HOSTKEY}` in the `cyfr` service's environment, a name with `$` in it, which cyfr cannot check before Docker Compose reads it. Nothing started. Write the name in `docker-compose.override.yml` without `$`."},
    {{:compose_override_refused, %{file: "docker-compose.yml", service: "cyfr"}},
     :invalid_argument,
     "`docker-compose.yml` does not give the `cyfr` service .env through its env_file, so it would not read how this home is reached. Nothing started. Add `env_file: .env` to the `cyfr` service in `docker-compose.yml`, as the shipped docker-compose.yml has it."},
    {{:access_busy, %{holder: "cyfr update on host1, pid 4242", pid: "4250", until: "14:03:00"}},
     :conflict,
     "Another cyfr command holds this home (`cyfr update on host1, pid 4242`), or a docker command it started is still running (watchdog pid `4250`, which ends by `14:03:00` at the latest). Nothing was changed. Wait until it has finished, then run this command again; if the holder was interrupted, run `cyfr access --resume` after that time."},
    {{:access_busy, %{holder: "cyfr access tailnet on host1"}}, :conflict,
     "Another cyfr command holds this home (`cyfr access tailnet on host1`). Nothing was changed. Wait until it has finished, then run this command again."},
    {{:access_busy, %{holder: "cyfr access tailnet on host1", pid: "4242"}}, :conflict,
     "Another cyfr command holds this home (`cyfr access tailnet on host1`, pid `4242`). Nothing was changed. Wait until it has finished, then run this command again."},
    {{:access_busy, %{join_id: "a1b2c3", until: "2026-10-19T14:03:00Z"}}, :conflict,
     "A tailnet join (`a1b2c3`) is still waiting for this machine's approval, until `2026-10-19T14:03:00Z` at the latest. Nothing was changed. Approve the machine with the link that join printed, or wait until then, and run this command again."},
    {{:access_env_edited,
      %{then: "started", env: "only this computer, at http://localhost:4000"}}, :conflict,
     "A change of how this home is reached was interrupted, and .env was edited before the change finished. CYFR stopped the stack, checked it stopped, left .env as edited, and started the home as it says: only this computer, at http://localhost:4000. If that is not how this home should be reached, run `cyfr access <mode>`."},
    {{:access_env_edited,
      %{then: "not_running", env: "only this computer, at http://localhost:4000"}}, :conflict,
     "A change of how this home is reached was interrupted, and .env was edited before the change finished. CYFR stopped the stack, checked it stopped, and left .env as edited, which says: only this computer, at http://localhost:4000. The stack was not running, so nothing was started. Run `cyfr up` to start it as .env says, or `cyfr access <mode>` to choose again."},
    {{:access_env_edited, %{then: "failed", env: "only this computer, at http://localhost:4000"}},
     :conflict,
     "A change of how this home is reached was interrupted, and .env was edited before the change finished. CYFR stopped the stack, checked it stopped, and left .env as edited, but the home did not start as it says (only this computer, at http://localhost:4000), and everything is stopped. Fix .env, then run `cyfr up`, or run `cyfr access <mode>` to choose again."},
    {{:access_env_edited, %{then: "incoherent"}}, :conflict,
     "A change of how this home is reached was interrupted, and .env was edited before the change finished. CYFR stopped the stack, checked it stopped, and left .env as edited; nothing was started, because .env no longer says one coherent way this home is reached. Run `cyfr up` to see what is wrong with it, or `cyfr access <mode>` to choose again."},
    {{:access_stale, %{words: "your devices on Tailscale, at https://cyfr.tail1a2b3c.ts.net"}},
     :conflict,
     "How this home is reached changed after the change was shown to you (it is now: your devices on Tailscale, at https://cyfr.tail1a2b3c.ts.net). Nothing was changed. Run the command again to review the change."},
    {{:access_unchanged, %{address: "http://localhost:4000"}}, :invalid_argument,
     "This home is already reached that way, at http://localhost:4000. Nothing was changed."},
    {{:access_invalid,
      %{input: "192.0.2.10", kind: "domain", rule: "an IP address is not a domain"}},
     :invalid_argument,
     "`192.0.2.10` is not a valid domain: an IP address is not a domain. Nothing was changed. Correct it and run the command again."},
    {:access_request_reused, :conflict,
     "This request names a different change than the one first sent under its id. Nothing was changed. Send it again under a new id."},
    {:tailnet_not_joined, :setup_required,
     "This machine has not joined your tailnet. Nothing was changed. Run `cyfr access tailnet` and approve the machine with the link it prints."},
    {{:tailnet_https_off, %{name: "cyfr.tail1a2b3c.ts.net"}}, :setup_required,
     "This machine joined your tailnet as `cyfr.tail1a2b3c.ts.net`, but your tailnet has HTTPS certificates turned off, and this home needs them. How this home is reached was not changed. Turn on HTTPS on the DNS page of the Tailscale admin console, then run `cyfr access tailnet` again, which uses this machine as it is. If you do not want it in your tailnet, remove `cyfr.tail1a2b3c.ts.net` on the Machines page of the admin console."},
    {{:tailnet_active, %{name: "cyfr.tail1a2b3c.ts.net"}}, :conflict,
     "This home is already on your tailnet as `cyfr.tail1a2b3c.ts.net`. Nothing was changed. To give it another name, run `cyfr access local`, then `cyfr access tailnet --new-node`, and remove `cyfr.tail1a2b3c.ts.net` on the Machines page of the Tailscale admin console."},
    {{:tailnet_name_changed,
      %{frozen: "cyfr.tail1a2b3c.ts.net", now: "cyfr-2.tail1a2b3c.ts.net"}}, :conflict,
     "The machine's tailnet name or identity changed from `cyfr.tail1a2b3c.ts.net` to `cyfr-2.tail1a2b3c.ts.net` after the change was shown. Nothing was changed. Run the command again to review it."},
    {{:tailnet_node_mismatch, %{node: "b.tail1a2b3c.ts.net", env: "a.tail1a2b3c.ts.net"}},
     :conflict,
     "This machine's tailnet identity is `b.tail1a2b3c.ts.net`, but .env says this home is `a.tail1a2b3c.ts.net`, so it is not being served on your tailnet: it answers on this machine only, and nothing else was changed. Run `cyfr access tailnet`, which offers to move the home to https://b.tail1a2b3c.ts.net after you confirm."},
    {{:tailnet_node_id_unsupported, %{value: "n/bad"}}, :invalid_argument,
     "Tailscale reported a machine identity this home cannot store (`n/bad`). How this home is reached was not changed. Report this with your Tailscale version."},
    {:tailnet_join_expired, :timeout,
     "The approval link expired before the machine was approved. How this home is reached was not changed. Run `cyfr access tailnet` for a new link."},
    {:tailnet_join_cancelled, :cancelled,
     "Joining your tailnet was cancelled. How this home is reached was not changed."},
    {:tailnet_join_ended, :unauthenticated,
     "Tailscale did not accept this machine's join: the auth key may be wrong, already used or expired, or the join ended before the machine was approved. How this home is reached was not changed. Check the key if you gave one, then run `cyfr access tailnet` again."},
    {{:tailnet_join_ended, %{}}, :unauthenticated,
     "Tailscale did not accept this machine's join: the auth key may be wrong, already used or expired, or the join ended before the machine was approved. How this home is reached was not changed. Check the key if you gave one, then run `cyfr access tailnet` again."},
    {:tailnet_join_not_current, :conflict,
     "That join attempt is no longer the one in progress. Nothing was changed."},
    {{:docker_unavailable, %{reason: "the daemon socket refused the connection"}}, :unavailable,
     "Docker did not answer (the daemon socket refused the connection) before the change was accepted. Nothing was changed. Start Docker, then run the command again."},
    {{:access_rolled_back,
      %{
        new: "your devices on Tailscale",
        old: "only this computer",
        reason: "cyfr did not become healthy"
      }}, :conflict,
     "This home could not start as your devices on Tailscale (cyfr did not become healthy). What it started was stopped and checked stopped, and the home was put back: it is reached as before, only this computer, and running. Fix what the reason names, then run the command again."},
    {{:access_rolled_back,
      %{
        new: "anyone on the internet, who still has to sign in",
        old: "your devices on Tailscale",
        reason: "cyfr did not become healthy",
        local: "tailnet_node_mismatch"
      }}, :conflict,
     "This home could not start as anyone on the internet, who still has to sign in (cyfr did not become healthy). What it started was stopped and checked stopped, and the home was put back as before, your devices on Tailscale, but it answers on this machine only, because this machine's tailnet identity is not the one .env names. Fix what the reason names, then run the command again; run `cyfr access tailnet`, which offers to move the home to the machine's tailnet name."},
    {{:access_rolled_back,
      %{new: "x", old: "your devices on Tailscale", reason: "y", local: "tailnet_https_off"}},
     :conflict,
     "This home could not start as x (y). What it started was stopped and checked stopped, and the home was put back as before, your devices on Tailscale, but it answers on this machine only, because your tailnet has HTTPS certificates turned off. Fix what the reason names, then run the command again; turn on HTTPS on the DNS page of the Tailscale admin console, then run `cyfr access tailnet`."},
    {{:access_failed, %{new: "your devices on Tailscale", env: "only this computer"}},
     :unavailable,
     "This home could not start as your devices on Tailscale, nor as before; everything was stopped and checked stopped. .env says: only this computer. Run `cyfr up` to start it as .env says, or `cyfr access <mode>` to choose again."},
    {{:access_uncertain, %{observed: "cyfr and tailscale"}}, :uncertain,
     "This home could not be brought to a known state: cyfr and tailscale were still running after the stop. It may be partly reachable. Nothing more was done. On the machine, run `cyfr access --resume`, which stops what is running, checks, and starts the home as .env says; if it reports the same, run `cyfr down`, check `docker ps`, then `cyfr up`."},
    {{:access_outcome_unknown, %{reason: "the command was interrupted"}}, :uncertain,
     "This command lost track of the change before it finished (the command was interrupted), so it may have been applied. Do not ask for it again: run `cyfr access --resume`, which finishes it under the lock and reports what happened."}
  ]

  # One exemplar per rostered reason, with the class it classifies to.
  # The authorization vocabulary (`Sanctum.Unauthorized`) classifies its
  # own reasons and is not here.
  @rostered [
    {{:not_found, "component", "c:local.x:1.0.0"}, :not_found},
    {{:invalid_argument, "name is required"}, :invalid_argument},
    {{:conflict, "the draft moved on"}, :conflict},
    {{:unavailable, "Storage"}, :unavailable},
    {{:not_found, {:component, "c:local.x:1.0.0"}}, :not_found},
    {{:not_found, {:blob, "sha256:ab12"}}, :not_found},
    {{:invalid_reference, "Invalid reference format: x"}, :invalid_argument},
    {{:invalid_reference, :empty}, :invalid_argument},
    {{:corrupt, {:digest, "The artifact"}}, :corrupt},
    {{:corrupt, {:profile, "prof_1"}}, :corrupt},
    {{:corrupt, {:manifest, "c:local.x:1.0.0"}}, :corrupt},
    {{:dependency_unreadable, "reagent:local.x:1.0.0", :malformed_manifest}, :corrupt},
    {:projection_unavailable, :unavailable},
    {{:corrupt, :person_identity}, :corrupt},
    {{:corrupt, {:component_graph, "c:local.x:1.0.0"}}, :corrupt},
    {{:corrupt, {:artifact, "sha256:ab12"}}, :corrupt},
    {{:corrupt, {:execution, "exec_1"}}, :corrupt},
    {{:component_type_mismatch, :formula, :reagent}, :invalid_argument},
    {:invalid_component_type, :invalid_argument},
    {{:corrupt, {:settings, :retention}}, :corrupt},
    {{:corrupt, :registry_credential}, :corrupt},
    {{:registry, :policy_version_mismatch, "2026-09"}, :conflict},
    {{:registry, :policy_version_mismatch, nil}, :conflict},
    {{:registry, :unauthorized}, :unauthenticated},
    {{:timeout, :parent_deadline}, :timeout},
    {{:rate_limited, 5}, :rate_limited},
    {{:attestation_failed, :signed_pulls_required}, :forbidden},
    {{:core_module, "The binary is a core WebAssembly module, not a component."},
     :invalid_argument},
    {{:setup_required, :registry_binding}, :setup_required},
    {{:invoke_denied, :depth_cap}, :forbidden},
    {{:invoke_denied, :invoke_budget_exhausted}, :forbidden},
    {{:invoke_denied, :edge_only}, :forbidden},
    {{:invoke_denied, {:need, :undeclared}}, :forbidden},
    {{:invoke_denied, :stale_attempt}, :forbidden},
    {{:invoke_denied, :reservation_released}, :forbidden},
    {{:delegation_refused, "a delegate must name a role its roster lists"}, :forbidden},
    {{:invoke_invalid, {:malformed_target, :call, :task}}, :forbidden},
    {{:invalid_need, "a|b"}, :forbidden},
    {{:crashed, "Tool x crashed"}, :internal},
    {{:exit, "Tool x exited unexpectedly"}, :internal},
    {{:cancelled, "Tool x was cancelled"}, :cancelled},
    {{:timeout, "Tool x timed out after 1ms"}, :timeout},
    {:action_missing, :invalid_argument},
    {{:unknown_action, "thread.nope"}, :invalid_argument},
    {:control_plane_lost, :not_owner},
    {:not_provisioned, :unavailable},
    {:busy, :rate_limited},
    {:held_elsewhere, :conflict},
    {{:held_elsewhere, "turn_1"}, :conflict},
    {:not_member, :forbidden},
    {:archived, :forbidden},
    {:no_agent, :setup_required},
    {:execution_unavailable, :unavailable},
    {:message_too_long, :invalid_argument},
    {:client_id_reused, :conflict},
    {:message_id_reused, :conflict},
    {{:uncertain, "the effect may have happened"}, :uncertain},
    {{:result_lost, "the result was not kept"}, :uncertain},
    {{:not_recorded, "the ending was not recorded"}, :uncertain},
    {:stale_writer, :conflict},
    {:stale_revision, :conflict},
    {:missing_unit, :not_found},
    {:no_unit, :not_found},
    {{:reserved_path, ["aqua", ".staging"]}, :invalid_argument},
    {:invalid_objects, :corrupt},
    {:outcome_unknown, :uncertain},
    {:unavailable, :unavailable},
    {:lost, :uncertain},
    {{:guest_error, "tool_denied", "Denied"}, :forbidden},
    {{:guest_error, "setup_required", "Set up", %{"need" => "k"}}, :setup_required},
    {{:failed, "the worker failed"}, :internal},
    {{:setup_required, %{"node_ref" => "c:local.x:1.0.0"}}, :setup_required},
    {{:consent_required, %{}}, :consent_required},
    {{:consent_conflict, %{}}, :conflict},
    {{:confirmation_required, %{id: "confirmation-7f3a", operation: "vault/create"}},
     :confirmation_required},
    {{:confirmation_required, %{"id" => "confirmation-7f3a"}}, :confirmation_required},
    {:rate_limited, :rate_limited},
    {:stream_limit, :rate_limited},
    {{:limit_reached, :athanors, 3}, :rate_limited},
    {{:limit_reached, :mint_per_hour, 10}, :rate_limited},
    {{:limit_reached, :max_athanors, 100}, :rate_limited},
    {:invalid_bearer, :unauthenticated},
    {:invalid_api_key, :unauthenticated},
    {:api_key_revoked, :unauthenticated},
    {:invalid_credential, :unauthenticated},
    {:revoked, :unauthenticated},
    {:expired_token, :unauthenticated},
    {:expired_credential, :unauthenticated},
    {:no_athanor, :unauthenticated},
    {:denied, :forbidden},
    {:wrong_tincture, :forbidden},
    {:not_primary, :forbidden},
    {:ip_not_allowed, :forbidden},
    {:auth_provider_error, :unavailable},
    {:origin_rejected, :forbidden},
    {:frame_request, :forbidden},
    {:parse_error, :invalid_argument},
    {:invalid_request, :invalid_argument},
    {:header_mismatch, :invalid_argument},
    {:unsupported_protocol_version, :invalid_argument},
    {:method_not_found, :not_found},
    {{:unknown_tool, "nope"}, :not_found},
    {:not_external, :not_found},
    {:database_error, :unavailable},
    {:forbidden, :not_found},
    {:not_found, :not_found},
    {:missing_idempotency_key, :invalid_argument},
    {:unsupported_content_type, :invalid_argument},
    {:multipart_refused, :invalid_argument},
    {:socket_body_too_large, :invalid_argument},
    {:socket_body_length_required, :invalid_argument},
    {:signature_invalid, :unauthenticated},
    {:internal_error, :internal},
    {:invalid_params, :invalid_argument},
    {:consent_required, :consent_required},
    {{:ambiguous, ["prof_a", "prof_b"]}, :conflict},
    {:service_unavailable, :unavailable},
    {:remote_identity_unavailable, :unavailable},
    {:email_unavailable, :unavailable},
    {:reauth_required, :unauthenticated},
    {:identity_stale, :unavailable},
    {:restore_reserved, :forbidden},
    {:execution_failed, :internal},
    {:invalid_session, :unauthenticated},
    {:missing_token, :unauthenticated},
    {{:bootstrap_refused, :slot_not_held}, :not_owner},
    {{:bootstrap_refused, :busy}, :conflict},
    {{:bootstrap_refused, :malformed_configuration}, :invalid_argument},
    {{:bootstrap_refused, :slot_lost}, :not_owner},
    {{:bootstrap_refused, :claim_taken}, :conflict},
    {{:bootstrap_refused, :claim_lapsed}, :timeout},
    {{:bootstrap_refused, :missing_user}, :setup_required},
    {{:bootstrap_refused, :release_failed}, :uncertain},
    {{:bootstrap_refused, :database_error}, :unavailable},
    {{:bootstrap_refused, :exception}, :internal},
    {:missing_generation, :unauthenticated},
    {:stale_generation, :unauthenticated},
    {:not_standing, :forbidden},
    {:missing_grant, :internal},
    {:not_owner, :not_owner},
    {:attempt_not_owner, :conflict},
    {:slot_not_held, :not_owner},
    {:conflict, :conflict},
    {:approved_entry_moved, :conflict},
    {:hold_expired, :conflict},
    {:step_superseded, :conflict},
    {:parent_ended, :conflict},
    {:occurrence_not_claimed, :conflict},
    {{:payload_not_retained, :expired}, :unavailable},
    {:not_cancellable, :conflict},
    {:not_running, :conflict},
    {:no_worker_for_target, :unavailable},
    {{:slot_refused, "The execution slots are full"}, :conflict},
    {:replayed, :conflict},
    {:capacity, :rate_limited},
    {:key_cap, :rate_limited},
    {:key_unreaped, :rate_limited},
    {:timeout, :timeout},
    {:cancelled, :cancelled},
    {:superseded, :conflict},
    {:not_open, :conflict},
    {:not_suspended, :conflict},
    {:recovery_exhausted, :conflict},
    {:held, :conflict},
    {:not_accepted, :conflict},
    {:not_paused, :conflict},
    {:attempt_not_paused, :conflict},
    {:already_finished, :conflict},
    {:steer_pending, :conflict},
    {:clone, :conflict},
    {:no_root, :conflict},
    {:turn_over, :conflict},
    {:turn_exists, :conflict},
    {:stale, :conflict},
    {:catalyst_pinned, :conflict},
    {:not_proposed, :conflict},
    {:not_dispatched, :conflict},
    {:proposal_digest_required, :conflict},
    {{:already_resolved, :approved}, :conflict},
    {:parent_not_running, :conflict},
    {:clone_depth, :conflict},
    {:not_a_clone, :conflict},
    {:consent_moved, :conflict},
    {:agent_changed, :conflict},
    {:no_pin, :conflict},
    {:turn_superseded, :conflict},
    {{:no_claim, "thr_1"}, :conflict},
    {:fence_required, :internal},
    {:seq_conflict, :internal},
    {:illegal_transition, :internal},
    {{:execution_not_in, "running"}, :internal},
    {{:grant_failed, :database_error}, :internal},
    {:thread_not_found, :not_found},
    {:turn_not_found, :not_found},
    {:approval_not_found, :not_found},
    {:catalyst_not_found, :not_found},
    {:step_not_found, :not_found},
    {:empty, :invalid_argument},
    {:storage_full, :rate_limited},
    {:storage_unverifiable, :unavailable},
    {{:cap_unverifiable, :max_athanors}, :unavailable},
    {:context_too_long, :invalid_argument},
    {:too_many_attachments, :invalid_argument},
    {:attachment_too_large, :invalid_argument},
    {:storage_error, :internal},
    {:destination_mismatch, :forbidden},
    {:scope_not_attenuable, :forbidden},
    {:disclosure_refused, :forbidden},
    {:not_offered, :forbidden},
    {:component_not_admitted, :forbidden},
    {:provider_mismatch, :invalid_argument},
    {{:provider_mismatch, "openai.com"}, :invalid_argument},
    {:credential_header_refused, :invalid_argument},
    {:endpoints_immutable, :invalid_argument},
    {:connection_not_granted, :setup_required},
    {{:invoke_denied, :connection_not_granted}, :forbidden},
    {:connection_cap, :rate_limited},
    {{:connection_cap, ~U[2026-10-05 00:00:00Z]}, :rate_limited},
    {:grant_expired, :consent_required},
    {"No provider found for scheme ftp", :internal}
  ]

  # The access and setup rows are rostered with their classes too.
  @rostered @rostered ++ for({reason, class, _sentence} <- @access_rows, do: {reason, class})

  # What a guest error's type reads as.
  @guest_types %{
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
    "method_blocked" => :forbidden,
    "scheme_blocked" => :forbidden,
    "domain_blocked" => :forbidden,
    "private_ip_blocked" => :forbidden,
    "dns_error" => :unavailable,
    "rate_limited" => :rate_limited,
    "request_too_large" => :invalid_argument
  }

  describe "the table" do
    test "every rostered reason classifies to its class, with its reason kept" do
      for {reason, class} <- @rostered do
        refusal = Refusal.classify(reason)

        assert %Refusal{class: ^class, reason: ^reason, message: message} = refusal,
               "#{inspect(reason)} classifies #{inspect(refusal.class)}, not #{inspect(class)}"

        assert is_binary(message) and message != "", "#{inspect(reason)} has no sentence"
        assert Refusal.reason?(reason) or is_binary(reason)
      end
    end

    test "an unreadable dependency is damage, and an index behind its files is unavailable" do
      assert %Refusal{
               class: :corrupt,
               message:
                 "A dependency's stored manifest is damaged, so its dependencies cannot be read."
             } =
               Refusal.classify(
                 {:dependency_unreadable, "reagent:local.x:1.0.0", :malformed_manifest}
               )

      assert %Refusal{
               class: :unavailable,
               message: "The component index is catching up with its files — retry shortly"
             } = Refusal.classify(:projection_unavailable)
    end

    test "every class has a sentence, and the table reaches all sixteen" do
      assert length(Refusal.classes()) == 16

      reached = @rostered |> Enum.map(&elem(&1, 1)) |> MapSet.new()
      assert reached == MapSet.new(Refusal.classes())

      for class <- Refusal.classes() do
        {reason, ^class} = Enum.find(@rostered, &(elem(&1, 1) == class))
        assert Refusal.classify(reason).message =~ ~r/\w/
      end
    end

    test "every access and setup row reads as its class and its words" do
      for {reason, class, sentence} <- @access_rows do
        assert %Refusal{class: ^class, message: ^sentence} = Refusal.classify(reason),
               "#{inspect(reason)} reads as #{inspect(Refusal.classify(reason))}"
      end
    end

    test "a webhook delivery whose target no worker serves reads as unavailable, in its words" do
      assert %Refusal{
               class: :unavailable,
               message: "No worker serves this webhook's target; try again when one does."
             } = Refusal.classify(:no_worker_for_target)
    end

    test "an access row whose payload lacks a part is no sentence of its own" do
      for reason <- [
            {:access_unknown_mode, %{}},
            {:access_source_conflict, %{key: "CYFR_PORT", file_value: "4000"}},
            {:access_bind_not_loopback, %{address: {0, 0, 0, 0}}},
            {:access_key_outside_mode, %{key: "CYFR_PORT", mode: "local", needs: "public"}},
            {:access_public_url_mismatch, %{mode: "local", expected: "https://x.example"}},
            {:access_setting_invalid, %{key: "CYFR_HOST", value: "x"}},
            {:compose_env_refused, %{key: "CYFR_PORT"}},
            {:compose_env_refused, %{line: 7}},
            {:access_busy, %{until: "x"}},
            {:access_busy, %{pid: "1"}},
            {:access_busy, %{join_id: "x"}},
            {:access_busy, %{holder: "x", until: "y"}},
            {:compose_override_refused, %{file: "x"}},
            {:compose_override_refused, %{service: "cyfr", key: "CYFR_HOST"}},
            {:compose_override_refused, %{file: "x", service: "cyfr", key: "$X", why: :other}},
            {:compose_override_refused, %{file: "x", service: "cyfr", key: "X", extra: "y"}},
            {:access_env_edited, %{then: "started"}},
            {:access_env_edited, %{then: "incoherent", env: "x"}},
            {:access_env_edited, %{then: "other", env: "x"}},
            {:tailnet_join_ended, %{reason: "x"}},
            {:access_rolled_back, %{new: "x", old: "y", reason: "z", local: "other"}},
            {:access_rolled_back, %{new: "x", old: "y", reason: "z", extra: "w"}},
            {:access_invalid, %{input: "x", kind: "port", rule: "y"}},
            {:access_option_outside_mode, %{option: "--domain", mode: "public"}},
            {:access_setting_invalid, %{key: "CYFR_HOST", value: "x", extra: "y"}},
            {:access_setting_invalid, %{key: "CYFR_PROXY_PORT", value: "4001", extra: "y"}},
            {:access_setting_invalid,
             %{key: "CYFR_PORT", value: "4001", address: "a", bind: "b", port: "4001"}},
            {:tailnet_join_expired, %{reason: "x"}}
          ] do
        assert capture_log(fn ->
                 assert %Refusal{class: :internal, message: message} = Refusal.classify(reason)
                 assert message == Refusal.unconfirmed()
               end) =~ "Prima.Refusal"
      end
    end

    test "no sentence spells a term" do
      for {reason, _class} <- @rostered do
        message = Refusal.classify(reason).message

        for syntax <- ["%{", "%", "{:", "[:", "#Reference", "#PID", "__struct__", "=>"] do
          refute message =~ syntax, "#{inspect(reason)} renders #{inspect(message)}"
        end

        refute message =~ ~r/(^|\s):[a-z_]+/, "#{inspect(reason)} spells an atom: #{message}"
        refute message =~ "athanor_id", "#{inspect(reason)} names an internal field"
      end
    end

    test "a guest error reads as its type's class" do
      for {type, class} <- @guest_types do
        assert %Refusal{class: ^class, message: "said"} =
                 Refusal.classify({:guest_error, type, "said"})
      end

      assert %Refusal{class: :internal} = Refusal.classify({:guest_error, "novel", "said"})

      # Attaching is built: no reason or guest type stands in for it.
      refute Refusal.reason?(:attach_unavailable)

      assert %Refusal{class: :internal} =
               Refusal.classify({:guest_error, "attach_unavailable", "said"})
    end

    test "the credential refusals are reasons under the closed classes, in fixed words" do
      assert Refusal.credential_reasons() ==
               Enum.sort(~w(destination_mismatch provider_mismatch connection_not_granted
                            credential_header_refused connection_cap scope_not_attenuable
                            endpoints_immutable grant_expired disclosure_refused not_offered
                            component_not_admitted)a)

      assert length(Refusal.classes()) == 16

      for reason <- Refusal.credential_reasons() do
        refusal = Refusal.classify(reason)
        assert refusal.class in Refusal.classes(), inspect(reason)

        # The guest error of the same name reads as the same refusal.
        assert Refusal.classify({:guest_error, Atom.to_string(reason), refusal.message}) ==
                 %Refusal{
                   class: refusal.class,
                   reason: {:guest_error, Atom.to_string(reason), refusal.message},
                   message: refusal.message
                 }
      end

      assert Refusal.message(:component_not_admitted) ==
               "This instance entry requires an unmodified shipped component."

      # A detail beside the reason stays out of the sentence.
      assert Refusal.message({:provider_mismatch, "openai.com"}) ==
               Refusal.message(:provider_mismatch)

      refute Refusal.message({:provider_mismatch, "openai.com"}) =~ "openai"

      assert Refusal.message({:connection_cap, ~U[2026-10-05 00:00:00Z]}) ==
               Refusal.message(:connection_cap)

      assert Refusal.message({:connection_cap, "anything"}) == Refusal.message(:connection_cap)
    end

    test "a launch whose approved entry moved is a conflict that says to ask again, never " <>
           "an unexpected reason" do
      log =
        capture_log(fn ->
          assert %Refusal{class: :conflict, reason: :approved_entry_moved, message: message} =
                   Refusal.classify(:approved_entry_moved)

          assert message ==
                   "The account this launch was approved for has changed since it was approved, " <>
                     "so nothing ran: ask again to approve it as it stands now."
        end)

      # The module runs async, and capture_log takes every process's log
      # while it runs: only this reason's own warning is this test's.
      refute log =~ "[Prima.Refusal] unexpected message: :approved_entry_moved"
      assert Refusal.reason?(:approved_entry_moved)
    end

    test "the corrupt registry credential says what to do" do
      assert Refusal.classify({:corrupt, :registry_credential}).message ==
               "The stored registry credential is damaged; sign in to the registry again."
    end

    test "a policy-version refusal names the version the registry requires" do
      assert Refusal.message({:registry, :policy_version_mismatch, "2026-09"}) ==
               "The registry requires acceptance of policy version 2026-09"

      assert Refusal.message({:registry, :policy_version_mismatch, nil}) ==
               "The registry requires acceptance of a newer policy version"
    end

    test "each damaged store reads as what it is, not as a digest mismatch" do
      assert Refusal.message({:corrupt, {:digest, "Payload x/input"}}) ==
               "Payload x/input does not match its recorded digest and was not served"

      assert Refusal.message({:corrupt, {:profile, "prof_secret"}}) ==
               "The stored profile is damaged and cannot be used."

      assert Refusal.message({:corrupt, {:manifest, "c:local.x:1.0.0"}}) ==
               "The stored manifest is damaged."

      assert Refusal.message({:corrupt, :person_identity}) ==
               "This person's identity record is missing, so it cannot be used."

      assert Refusal.message({:corrupt, {:execution, "exec_secret"}}) ==
               "The stored execution record is damaged."

      assert Refusal.message({:corrupt, {:settings, :retention}}) ==
               "The stored retention settings are damaged."
    end

    test "a run's damaged component graph is damage, named without its ref or a grant to make" do
      assert %Refusal{class: :corrupt, message: message} =
               Refusal.classify({:corrupt, {:component_graph, "reagent:local.secret-name:1.0.0"}})

      assert message ==
               "The component graph this run needs is stored damaged and cannot be used."

      assert Refusal.reason?({:corrupt, {:component_graph, "reagent:local.x:1.0.0"}})
    end

    test "admission's refusals read as their rows" do
      assert Refusal.message({:rate_limited, 7}) == "Too many requests; retry in 7 s."

      assert Refusal.message({:attestation_failed, :signer_mismatch}) ==
               "The component's signature could not be verified; signed pulls are required."

      assert Refusal.message({:setup_required, :registry_binding}) ==
               "The component has no registry binding; register it again."

      # The specifics ride in the reason; the sentence names neither the
      # types nor the digest.
      assert Refusal.message({:component_type_mismatch, :formula, :reagent}) ==
               "The requested type does not match the component's registered type."

      assert Refusal.message(:invalid_component_type) =~ "Invalid component type"

      assert Refusal.message({:corrupt, {:artifact, "sha256:ab12"}}) ==
               "The component's bytes do not match their recorded digest; register it again."

      assert Refusal.message({:not_found, {:component, "c:local.x:1.0.0"}}) ==
               "Component not found: c:local.x:1.0.0"

      assert Refusal.message({:invalid_reference, "Invalid reference format: x"}) =~
               "Invalid reference format: x"
    end

    test "a chain-authority refusal reads as the authority vocabulary's own sentence" do
      for reason <- [
            {:invoke_denied, :depth_cap},
            {:invoke_denied, :edge_only},
            {:invoke_denied, :stale_attempt},
            {:invoke_denied, {:need, :required}}
          ] do
        {:invoke_denied, deny} = reason

        assert Refusal.message(reason) ==
                 "Denied by chain authority: " <> Prima.Authority.Transition.deny_message(deny)
      end

      assert Refusal.message({:invoke_invalid, {:malformed_target, :call, :task}}) ==
               "The chain named a target that does not exist."

      assert Refusal.message({:invalid_need, "a|b"}) ==
               "The chain asked for a need its authority does not grant."

      assert Refusal.message({:delegation_refused, "the roster lists no such role"}) ==
               "the roster lists no such role"

      capture_log(fn ->
        assert %Refusal{class: :internal} = Refusal.classify({:invoke_denied, :novel})
        assert %Refusal{class: :internal} = Refusal.classify({:invoke_invalid, :malformed})
      end)
    end

    test "the split atoms read apart" do
      refute Refusal.message(:busy) == Refusal.message(:held_elsewhere)
      refute Refusal.message(:unavailable) == Refusal.message(:outcome_unknown)
      assert Refusal.message(:outcome_unknown) =~ "check before asking again"
      refute Refusal.message({:held_elsewhere, "turn_secret_id"}) =~ "turn_secret_id"
    end

    test "a proof that cannot be given here is no denial, and says which" do
      assert %Refusal{class: :unavailable, message: remote} =
               Refusal.classify(:remote_identity_unavailable)

      assert remote =~ "own home"
      refute remote =~ "not built"

      assert %Refusal{class: :unavailable, message: email} = Refusal.classify(:email_unavailable)
      assert email =~ "confirm another way"

      assert %Refusal{class: :unauthenticated, message: again} =
               Refusal.classify(:reauth_required)

      assert again =~ "sign in again"

      for reason <- [:remote_identity_unavailable, :email_unavailable, :reauth_required],
          do: assert(Refusal.reason?(reason))
    end

    test "an installation reserved for a restore says so, and denies no one" do
      assert %Refusal{class: :forbidden, message: message} = Refusal.classify(:restore_reserved)
      assert message =~ "waiting for its owner to restore"
      refute message =~ "not admitted"
      assert Refusal.reason?(:restore_reserved)
    end

    test "an identity that could not be confirmed fresh pauses: retryable, no sign-out" do
      assert %Refusal{class: :unavailable, message: message} =
               Refusal.classify(:identity_stale)

      assert message =~ "could not be confirmed fresh"
      assert message =~ "try again shortly"
      refute message =~ "sign in"
      assert Refusal.reason?(:identity_stale)
    end

    test "a binary is internal and keeps its words" do
      assert %Refusal{class: :internal, message: "cargo build failed: --locked"} =
               Refusal.classify("cargo build failed: --locked")
    end
  end

  describe "a reason the table does not know" do
    test "is internal, reads the fixed sentence and is logged by its shape" do
      log =
        capture_log(fn ->
          assert %Refusal{
                   class: :internal,
                   reason: {:some_internal, %{"secret" => "leak"}},
                   message: "The outcome could not be confirmed."
                 } = Refusal.classify({:some_internal, %{"secret" => "leak"}})
        end)

      assert log =~ "Prima.Refusal"
      refute log =~ "leak"
      refute Refusal.reason?({:some_internal, %{}})
    end

    test "includes the authorization vocabulary, which is not the contracts'" do
      capture_log(fn ->
        assert %Refusal{class: :internal} = Refusal.classify({:missing_permission, :vault_read})
        assert %Refusal{class: :internal} = Refusal.classify(:platform_admin_required)
      end)
    end

    test "an atom outside the table is not spelled" do
      capture_log(fn ->
        refusal = Refusal.classify(:some_internal_state)
        assert refusal.message == Refusal.unconfirmed()
        refute refusal.message =~ "some_internal_state"
      end)
    end

    test "includes a confirmation signal that names no confirmation" do
      capture_log(fn ->
        for payload <- [%{}, %{operation: "vault/create"}, %{id: ""}] do
          assert %Refusal{class: :internal} = Refusal.classify({:confirmation_required, payload})
          refute Refusal.reason?({:confirmation_required, payload})
        end
      end)
    end
  end

  test "a pending confirmation is its own class: neither a denial nor a consent to give" do
    signal = {:confirmation_required, %{id: "confirmation-7f3a", operation: "vault/create"}}

    assert %Refusal{class: :confirmation_required} = Refusal.classify(signal)
    assert :confirmation_required in Refusal.classes()
    assert :confirmation_required in Refusal.signal_tags()
    refute Refusal.classify(signal).class in [:forbidden, :consent_required]
  end

  test "a refusal classifies as itself" do
    built = %Refusal{
      class: :unavailable,
      reason: {:registry, :registry_unavailable},
      message: "x"
    }

    assert Refusal.classify(built) == built
  end

  test "a refusal is an execution refusal unless its maker says it refused admission" do
    assert %Refusal{stage: :execution} = Refusal.classify({:invalid_argument, "x"})

    admitted_not = %{Refusal.classify({:invalid_argument, "x"}) | stage: :admission}
    assert Refusal.classify(admitted_not) == admitted_not
    assert Refusal.message(admitted_not) == "x"
  end

  test "the presented-credential rows keep their auth_invalid code" do
    for reason <- [:invalid_bearer, :invalid_api_key, :api_key_revoked] do
      assert Refusal.code_override(reason) == :auth_invalid
      assert Refusal.code_override(Refusal.classify(reason)) == :auth_invalid
    end

    assert Refusal.code_override(:auth_provider_error) == nil
    assert Refusal.code_override(:unauthenticated) == nil
  end
end
