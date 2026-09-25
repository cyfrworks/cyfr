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
    {{:corrupt, {:settings, :retention}}, :corrupt},
    {{:corrupt, :registry_credential}, :corrupt},
    {{:timeout, :parent_deadline}, :timeout},
    {{:rate_limited, 5}, :rate_limited},
    {{:attestation_failed, :signed_pulls_required}, :forbidden},
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
    {:invalid_objects, :corrupt},
    {:outcome_unknown, :uncertain},
    {:unavailable, :unavailable},
    {{:finish_failed, :enospc}, :internal},
    {:lost, :uncertain},
    {{:guest_error, "tool_denied", "Denied"}, :forbidden},
    {{:guest_error, "setup_required", "Set up", %{"need" => "k"}}, :setup_required},
    {{:failed, "the worker failed"}, :internal},
    {{:setup_required, %{"node_ref" => "c:local.x:1.0.0"}}, :setup_required},
    {{:consent_required, %{}}, :consent_required},
    {{:consent_conflict, %{}}, :conflict},
    {{:restart_required, %{}}, :cancelled},
    {:rate_limited, :rate_limited},
    {:stream_limit, :rate_limited},
    {{:limit_reached, :athanors, 3}, :rate_limited},
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
    {:signature_invalid, :unauthenticated},
    {:internal_error, :internal},
    {:invalid_params, :invalid_argument},
    {:consent_required, :consent_required},
    {{:ambiguous, ["prof_a", "prof_b"]}, :conflict},
    {:service_unavailable, :unavailable},
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
    {:hold_expired, :conflict},
    {:step_superseded, :conflict},
    {:parent_ended, :conflict},
    {:occurrence_not_claimed, :conflict},
    {{:payload_not_retained, :expired}, :unavailable},
    {:not_cancellable, :conflict},
    {:not_running, :conflict},
    {:engine_starting, :unavailable},
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
    {:context_too_long, :invalid_argument},
    {:too_many_attachments, :invalid_argument},
    {:attachment_too_large, :invalid_argument},
    {:storage_error, :internal},
    {"No provider found for scheme ftp", :internal}
  ]

  # What a guest error's type reads as.
  @guest_types %{
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

    test "every class has a sentence, and the table reaches all fifteen" do
      assert length(Refusal.classes()) == 15

      reached = @rostered |> Enum.map(&elem(&1, 1)) |> MapSet.new()
      assert reached == MapSet.new(Refusal.classes())

      for class <- Refusal.classes() do
        {reason, ^class} = Enum.find(@rostered, &(elem(&1, 1) == class))
        assert Refusal.classify(reason).message =~ ~r/\w/
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
    end

    test "the corrupt registry credential says what to do" do
      assert Refusal.classify({:corrupt, :registry_credential}).message ==
               "The stored registry credential is damaged; sign in to the registry again."
    end

    test "each damaged store reads as what it is, not as a digest mismatch" do
      assert Refusal.message({:corrupt, {:digest, "Payload x/input"}}) ==
               "Payload x/input does not match its recorded digest and was not served"

      assert Refusal.message({:corrupt, {:profile, "prof_secret"}}) ==
               "The stored profile is damaged and cannot be used."

      assert Refusal.message({:corrupt, {:manifest, "c:local.x:1.0.0"}}) ==
               "The stored manifest is damaged."

      assert Refusal.message({:corrupt, {:settings, :retention}}) ==
               "The stored retention settings are damaged."
    end

    test "admission's refusals read as their rows" do
      assert Refusal.message({:rate_limited, 7}) == "Too many requests; retry in 7 s."

      assert Refusal.message({:attestation_failed, :signer_mismatch}) ==
               "The component's signature could not be verified; signed pulls are required."

      assert Refusal.message({:setup_required, :registry_binding}) ==
               "The component has no registry binding; register it again."

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
        assert Refusal.message(reason) == Prima.Authority.Transition.deny_message(deny)
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
