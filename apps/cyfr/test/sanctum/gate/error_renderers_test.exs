# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.ErrorRenderersTest do
  @moduledoc """
  One refusal, one sentence, whichever surface renders it.

  Checks that MCP, console, and guest surfaces render typed tool errors
  consistently and preserve the distinction between timeouts and crashes.
  """
  use ExUnit.Case, async: true

  alias Prima.Refusal

  # The seven a guest used to be handed by name. Each had a sentence in
  # the console's vocabulary and none in the runner's, and the runner
  # rendered an atom it did not know by spelling it — so a send that met a
  # full turn queue read "busy" to a guest and read the sentence below to
  # a person at the page.
  @named_by_the_atom [
    :busy,
    :not_member,
    :archived,
    :no_agent,
    :control_plane_lost,
    :not_provisioned,
    :message_too_long
  ]

  @crash_vocabulary [
    {:crashed, "Tool x crashed: boom"},
    {:exit, "Tool x exited unexpectedly"},
    {:timeout, "Tool x timed out after 300000ms"}
  ]

  # What a unit commit answers (`Arca.StorageUnits`): each is a different
  # thing to do about it, and none of them is "the write failed".
  @commit_vocabulary [
    :stale_writer,
    :stale_revision,
    :missing_unit,
    :invalid_objects,
    :outcome_unknown
  ]

  describe "a unit commit's refusals" do
    test "are part of the typed roster, and say what to do about each" do
      for reason <- @commit_vocabulary do
        assert Refusal.reason?(reason), "#{inspect(reason)} is not recognised"
        assert is_binary(Refusal.message(reason))
      end

      # A writer that died holding a draft blocks the unit until the
      # draft expires, so the sentence says how long rather than "retry
      # shortly".
      assert Refusal.message(:stale_writer) =~ "fifteen minutes"

      # The one that does not mean "nothing was written": nothing may be
      # assumed, so it does not tell the caller to simply retry.
      assert Refusal.message(:outcome_unknown) =~ "check before asking again"
      refute Refusal.message(:outcome_unknown) =~ "retry"

      # And the one that does: another commit landed first.
      assert Refusal.message(:stale_revision) =~ "landed first"
    end

    # `component.create`, `component.fork` and the scroll writes are
    # in-chain, so a guest receives these too. The guest view renders
    # `Prima.GuestError`, a second vocabulary that restates the sentences;
    # this case is what holds the two together.
    test "render the same sentence on all three surfaces" do
      for reason <- @commit_vocabulary do
        expected = Refusal.message(reason)

        assert PrismWeb.Ops.error_message(reason) == expected,
               "the console disagrees about #{inspect(reason)}"

        assert Locus.Runtime.FormulaHandler.render_reason(reason) == expected,
               "the guest view disagrees about #{inspect(reason)}"
      end
    end

    test "an unknown outcome is not the named-service outage" do
      refute Refusal.message(:outcome_unknown) == Refusal.message({:unavailable, "Storage"})
      assert Refusal.message({:unavailable, "Storage"}) =~ "retry shortly"
    end
  end

  describe "the crash vocabulary" do
    test "is part of the typed roster" do
      for reason <- @crash_vocabulary do
        assert Refusal.reason?(reason), "#{inspect(reason)} is not recognised"
        assert is_binary(Refusal.message(reason))
      end
    end

    test "renders the same sentence on all three surfaces" do
      for reason <- @crash_vocabulary do
        expected = Refusal.message(reason)

        assert PrismWeb.Ops.error_message(reason) == expected,
               "the console disagrees about #{inspect(reason)}"

        assert Locus.Runtime.FormulaHandler.render_reason(reason) == expected,
               "the guest view disagrees about #{inspect(reason)}"
      end
    end

    test "distinguishes tool timeouts from crashes" do
      timeout = PrismWeb.Ops.error_message({:timeout, "Tool x timed out after 1ms"})
      crash = PrismWeb.Ops.error_message({:crashed, "Tool x crashed: boom"})

      assert timeout =~ "timed out"
      assert crash =~ "crashed"
      refute timeout == crash
    end
  end

  describe "the refusals a guest used to be handed by name" do
    test "each is one sentence, and the guest reads it as the console does" do
      for reason <- @named_by_the_atom do
        expected = Refusal.message(reason)

        assert is_binary(expected) and String.length(expected) > 20,
               "#{inspect(reason)} has no sentence"

        refute expected == Atom.to_string(reason),
               "#{inspect(reason)} renders as its own name"

        assert Prima.GuestError.render(reason) == expected,
               "the runner's vocabulary disagrees about #{inspect(reason)}"

        assert Locus.Runtime.FormulaHandler.render_reason(reason) == expected,
               "the in-chain guest view disagrees about #{inspect(reason)}"

        assert PrismWeb.Ops.error_message(reason) == expected,
               "the console disagrees about #{inspect(reason)}"
      end
    end

    test "an atom outside the vocabulary is internal, and is not spelled out" do
      # What the runner's renderer did to every atom it did not know.
      assert Locus.Runtime.FormulaHandler.render_reason(:some_internal_state) ==
               "The call failed."

      assert Prima.GuestError.render(:some_internal_state) == nil
    end
  end

  describe "the guest never sees an internal term" do
    test "an unknown reason renders as a generic sentence, not inspect output" do
      rendered =
        Locus.Runtime.FormulaHandler.render_reason({:some_internal, %{"secret" => "leak"}})

      refute rendered =~ "secret"
      refute rendered =~ "leak"
      refute rendered =~ "%{"
    end

    test "a crafted binary still passes through" do
      assert Locus.Runtime.FormulaHandler.render_reason("No provider found for scheme ftp") ==
               "No provider found for scheme ftp"
    end

    test "the other typed vocabularies render through their own module" do
      assert Locus.Runtime.FormulaHandler.render_reason({:not_found, "component", "x"}) ==
               Refusal.message({:not_found, "component", "x"})

      # The runtime renders from contract data alone (`Prima.GuestError`): a Sanctum
      # refusal reaches a guest only once CYFR has rendered it into the wire
      # answer, so the bare term is internal to the engine and generalized.
      unauthorized = {:missing_permission, :vault_read}
      assert Sanctum.Unauthorized.reason?(unauthorized)
      assert Locus.Runtime.FormulaHandler.render_reason(unauthorized) == "The call failed."
    end
  end

  describe "the gate's classification" do
    test "asks the authorization vocabulary first, then the table" do
      assert %Refusal{class: :forbidden, message: message} =
               Sanctum.Refusals.classify({:missing_permission, :vault_read})

      assert message == Sanctum.Unauthorized.message({:missing_permission, :vault_read})

      assert %Refusal{class: :unauthenticated} = Sanctum.Refusals.classify(:unauthenticated)
      assert %Refusal{class: :setup_required} = Sanctum.Refusals.classify({:setup_required, %{}})
      assert %Refusal{class: :rate_limited} = Sanctum.Refusals.classify(:busy)
      assert %Refusal{class: :conflict} = Sanctum.Refusals.classify(:held_elsewhere)
    end

    test "keeps a refusal a provider built, and never needs a registry struct" do
      built =
        Compendium.Providers.Shared.refusal(%Compendium.OCI.Errors{
          reason: :not_found,
          message: "Resource not found on cyfr.run",
          registry: "cyfr.run",
          status: 404
        })

      assert %Refusal{class: :not_found, reason: {:registry, :not_found}} = built
      assert Sanctum.Refusals.classify(built) == built
    end

    test "renders every term to a sentence, an unknown one to the fixed sentence" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert Sanctum.Refusals.render({:some_internal, %{"secret" => "leak"}}) ==
                 "The outcome could not be confirmed."
      end)

      assert Sanctum.Refusals.render("a crafted sentence") == "a crafted sentence"
    end

    test "carries the wire codes the rows have always answered with" do
      assert Sanctum.Refusals.code_override(Sanctum.Refusals.classify(:invalid_api_key)) ==
               :auth_invalid

      assert Sanctum.Refusals.code_override(
               Sanctum.Refusals.classify({:authorization_required, "grant expired"})
             ) == :auth_required

      assert Sanctum.Refusals.code_override(Sanctum.Refusals.classify(:auth_provider_error)) ==
               nil
    end
  end

  # One term for each shape of `Sanctum.Unauthorized`'s `t:reason/0`,
  # keyed by the type's own spelling of the shape. A missing permission
  # carries two, since an API key's sentence names the permission.
  @authorization_reasons %{
    ":unauthenticated" => [:unauthenticated],
    ":missing_tenant" => [:missing_tenant],
    ":tenant_mismatch" => [:tenant_mismatch],
    ":malformed_record" => [:malformed_record],
    ":untagged_tenant_resource" => [:untagged_tenant_resource],
    ":platform_admin_required" => [:platform_admin_required],
    "{:missing_tenant, :no_membership}" => [{:missing_tenant, :no_membership}],
    "{:missing_permission, atom()}" => [
      {:missing_permission, :admin},
      {:missing_permission, :vault_read}
    ],
    "{:guest_plane, atom()}" => [{:guest_plane, :vault_read}],
    "{:guest_plane_call, String.t()}" => [{:guest_plane_call, "storage"}],
    "{:tool_auth_required, String.t()}" => [{:tool_auth_required, "session"}],
    "{:malformed_resource, :execution | :tenant}" => [
      {:malformed_resource, :execution},
      {:malformed_resource, :tenant}
    ],
    "{:consent_class_required, term()}" => [
      {:consent_class_required, :not_authenticated},
      {:consent_class_required, :unavailable},
      {:consent_class_required, {:surface_not_permitted, :api_key}}
    ],
    "{:authorization_required, String.t()}" => [{:authorization_required, "grant expired"}],
    "{:head_unavailable, String.t()}" => [{:head_unavailable, "prof_app"}],
    "{:head_corrupt, String.t()}" => [{:head_corrupt, "prof_app"}],
    "{:lender_unavailable, String.t()}" => [{:lender_unavailable, "reagent:local.dep"}],
    "{:lender_corrupt, String.t(), String.t()}" => [
      {:lender_corrupt, "reagent:local.dep", "prof_lender"}
    ]
  }

  # Every member of `Sanctum.Context`'s `t:auth_method/0`, `nil` included.
  @auth_methods [
    :oidc,
    :device,
    :api_key,
    :scheduled,
    :webhook,
    :tincture,
    :system,
    :session,
    nil
  ]

  # Refusals outside the authorization vocabulary: a sample of the table's
  # rows, the five consent signals, a producer's own sentence and a term
  # nobody knows.
  @other_reasons [
    :busy,
    :held_elsewhere,
    :stale_writer,
    :invalid_api_key,
    {:not_found, "component", "x"},
    {:invalid_argument, "the handler refused this argument"},
    {:unavailable, "Storage"},
    {:uncertain, "The outcome is unknown"},
    {:setup_required, %{}},
    {:consent_required, %{}},
    {:consent_conflict, %{}},
    {:restart_required, %{}},
    {:confirmation_required,
     %{id: "confirmation-7f3a", operation: "probe/change", expires_at: ~U[2026-09-29 12:05:00Z]}},
    "a crafted sentence",
    {:some_internal, %{"secret" => "leak"}}
  ]

  # The sentence each MCP path answers a refusal with — the router's
  # protocol error and the controller's rescue — is chosen in one place,
  # `Sanctum.Refusals.classify/2`; whether a refusal is one the gate knows
  # is answered in one place, `Sanctum.Refusals.known?/1`.
  describe "the sentence chosen for the caller's credential" do
    test "answers what each MCP path answers, and knows what either vocabulary knows" do
      # A term nobody knows is logged by its shape as it is classified.
      {reasons, _log} = ExUnit.CaptureLog.with_log(&every_reason/0)

      ExUnit.CaptureLog.capture_log(fn ->
        for reason <- reasons, auth_method <- @auth_methods do
          chosen = Sanctum.Refusals.classify(reason, auth_method)
          classified = Sanctum.Refusals.classify(reason)

          # The credential chooses the sentence alone: class, reason and
          # stage, and so the code each path answers with, are classify/1's.
          assert {reason, auth_method, %{chosen | message: nil}} ==
                   {reason, auth_method, %{classified | message: nil}}

          assert {reason, auth_method, chosen.message} ==
                   {reason, auth_method, answered(reason, auth_method)}
        end
      end)

      for reason <- reasons do
        assert {reason, Sanctum.Refusals.known?(reason)} ==
                 {reason, Sanctum.Unauthorized.reason?(reason) or Refusal.reason?(reason)}
      end

      # Each vocabulary knows a term the other does not, and neither knows
      # a producer's sentence or an unknown term, so each side of the
      # answer is held.
      assert Enum.any?(reasons, &(Sanctum.Unauthorized.reason?(&1) and not Refusal.reason?(&1)))
      assert Enum.any?(reasons, &(Refusal.reason?(&1) and not Sanctum.Unauthorized.reason?(&1)))
      refute Sanctum.Refusals.known?("a crafted sentence")
      refute Sanctum.Refusals.known?({:some_internal, %{"secret" => "leak"}})

      # The credential matters: an API key's missing permission names the
      # scope to recreate the key with, bare or wrapped, and no other
      # credential's sentence does.
      for reason <- [
            {:missing_permission, :admin},
            Sanctum.Refusals.admission({:missing_permission, :admin})
          ] do
        assert Sanctum.Refusals.classify(reason, :api_key).message =~ "--scope admin"
        refute Sanctum.Refusals.classify(reason, :oidc).message =~ "--scope"
        refute Sanctum.Refusals.classify(reason).message =~ "--scope"
      end
    end

    # A shape added to the vocabulary, or a credential added to the
    # context, without a term above fails here.
    test "covers every shape of the authorization vocabulary and every credential" do
      assert Enum.sort(Map.keys(@authorization_reasons)) ==
               Enum.sort(Enum.map(members(Sanctum.Unauthorized, :reason), &spelled/1))

      assert Enum.sort(Enum.map(@auth_methods, &inspect/1)) ==
               Enum.sort(Enum.map(members(Sanctum.Context, :auth_method), &spelled/1))

      for member <- members(Sanctum.Unauthorized, :reason),
          reason <- Map.fetch!(@authorization_reasons, spelled(member)) do
        assert {spelled(member), reason, of_type?(reason, member)} ==
                 {spelled(member), reason, true}

        assert {reason, Sanctum.Unauthorized.reason?(reason)} == {reason, true}
      end
    end
  end

  # Every authorization reason bare, as the gate's own refusal and as a
  # refusal a provider built with its own sentence; every other reason
  # bare and as the gate's own refusal; and a registry's refusal a
  # provider built.
  defp every_reason do
    authorization = @authorization_reasons |> Map.values() |> List.flatten()

    wrapped =
      for reason <- authorization do
        %Refusal{
          class: Sanctum.Unauthorized.class(reason),
          reason: reason,
          message: "A provider's own sentence"
        }
      end

    registry =
      Compendium.Providers.Shared.refusal(%Compendium.OCI.Errors{
        reason: :not_found,
        message: "Resource not found on cyfr.run",
        registry: "cyfr.run",
        status: 404
      })

    admitted = Enum.map(authorization ++ @other_reasons, &Sanctum.Refusals.admission/1)
    authorization ++ @other_reasons ++ wrapped ++ admitted ++ [registry]
  end

  # What each MCP path answers: an authorization reason, bare or inside a
  # `%Prima.Refusal{}`, in the vocabulary's sentence for the caller's
  # credential (`Sanctum.Unauthorized.message/2`); any other refusal in
  # `classify/1`'s sentence.
  defp answered(%Refusal{reason: inner} = refusal, auth_method) do
    if Sanctum.Unauthorized.reason?(inner),
      do: Sanctum.Unauthorized.message(inner, auth_method),
      else: Sanctum.Refusals.classify(refusal).message
  end

  defp answered(reason, auth_method) do
    if Sanctum.Unauthorized.reason?(reason),
      do: Sanctum.Unauthorized.message(reason, auth_method),
      else: Sanctum.Refusals.classify(reason).message
  end

  # The members of `module`'s union type `name`.
  defp members(module, name) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    case for {:type, {^name, body, []}} <- types, do: body do
      [{:type, _, :union, members}] -> members
      _ -> flunk("#{inspect(module)} declares no union type #{name}/0")
    end
  end

  defp spelled(member) do
    {:"::", _, [_name, quoted]} = Code.Typespec.type_to_quoted({:member, member, []})
    Macro.to_string(quoted)
  end

  # Whether `term` is a value of the type `member` spells, for the forms
  # the vocabulary's type uses; any other form fails.
  defp of_type?(term, {:atom, _, atom}), do: term === atom
  defp of_type?(term, {:type, _, :atom, []}), do: is_atom(term)
  defp of_type?(_term, {:type, _, :term, []}), do: true
  defp of_type?(term, {:type, _, :union, types}), do: Enum.any?(types, &of_type?(term, &1))

  defp of_type?(term, {:remote_type, _, [{:atom, _, String}, {:atom, _, :t}, []]}),
    do: is_binary(term)

  defp of_type?(term, {:type, _, :tuple, types}) when is_tuple(term) do
    tuple_size(term) == length(types) and
      term
      |> Tuple.to_list()
      |> Enum.zip(types)
      |> Enum.all?(fn {t, type} -> of_type?(t, type) end)
  end

  defp of_type?(_term, {:type, _, :tuple, _types}), do: false
  defp of_type?(_term, form), do: flunk("an unread type form: #{inspect(form)}")
end
