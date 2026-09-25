# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.UnauthorizedVocabularyTest do
  @moduledoc """
  The refusal vocabulary and its `@type reason` union stay one thing.

  Each exemplar must be accepted by `reason?/1`, `class/1`, and
  `message/2`, classify to its row's class, and read as a public sentence.
  The `Sanctum.Unauthorized.reason()` union must contain the same number
  of variants as the exemplar roster.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Unauthorized

  # One exemplar per union member, in the union's order, with its class.
  @exemplars [
    {:unauthenticated, :unauthenticated},
    {:missing_tenant, :forbidden},
    {:tenant_mismatch, :forbidden},
    {:malformed_record, :internal},
    {:untagged_tenant_resource, :internal},
    {:platform_admin_required, :forbidden},
    {{:missing_tenant, :no_membership}, :forbidden},
    {{:missing_permission, :vault_read}, :forbidden},
    {{:guest_plane, :vault_read}, :forbidden},
    {{:guest_plane_call, "vault"}, :forbidden},
    {{:tool_auth_required, "vault"}, :unauthenticated},
    {{:malformed_resource, :execution}, :internal},
    {{:consent_class_required, :no_capability}, :forbidden},
    {{:authorization_required, "grant expired"}, :setup_required}
  ]

  # The one row whose JSON-RPC code is not its class's: a connection to
  # re-authorize keeps the identity code it has always carried. Every other
  # reason answers with its class's code.
  @overrides %{
    {:authorization_required, "grant expired"} => :auth_required
  }

  test "every union member is accepted by reason?/1, class/1 and message/2" do
    for {reason, class} <- @exemplars do
      assert Unauthorized.reason?(reason), "reason?/1 rejects #{inspect(reason)}"
      assert Unauthorized.class(reason) == class, "#{inspect(reason)} is not #{class}"
      assert Unauthorized.class(reason) in Prima.Refusal.classes()
      assert is_binary(Unauthorized.message(reason)), "message/2 fails for #{inspect(reason)}"

      assert is_binary(Unauthorized.message(reason, :api_key)),
             "message/2 with a method fails for #{inspect(reason)}"
    end
  end

  test "a consent class refused for want of a sign-in is unauthenticated" do
    assert Unauthorized.class({:consent_class_required, :not_authenticated}) == :unauthenticated
    assert Unauthorized.class({:consent_class_required, :anonymous}) == :forbidden
  end

  test "no sentence names an internal field or spells a term" do
    for {reason, _class} <- @exemplars, method <- [nil, :api_key, :oidc] do
      message = Unauthorized.message(reason, method)

      for private <- ["athanor_id", "{:", "%{", "=>", "consent_class_required", "guest-plane"] do
        refute message =~ private, "#{inspect(reason)} reads #{inspect(message)}"
      end
    end
  end

  test "the rows whose wire code is not their class's carry it as an override" do
    for {reason, _class} <- @exemplars do
      assert Unauthorized.code_override(reason) == Map.get(@overrides, reason)
    end

    for reason <- [
          :malformed_record,
          :untagged_tenant_resource,
          {:malformed_resource, :tenant},
          {:consent_class_required, :not_authenticated}
        ] do
      assert Unauthorized.code_override(reason) == nil,
             "#{inspect(reason)} still overrides its class's code"
    end
  end

  test "a raised refusal answers 401 for want of a sign-in and 403 for anything else" do
    for {reason, class} <- @exemplars do
      status = Plug.Exception.status(%Sanctum.UnauthorizedError{reason: reason})
      assert status == if(class == :unauthenticated, do: 401, else: 403)
    end
  end

  test "the @type union names exactly the exemplar roster" do
    source =
      Path.expand("../../lib/sanctum/unauthorized.ex", __DIR__)
      |> File.read!()

    [union] = Regex.run(~r/@type reason ::\n(.*?)\n\n/s, source, capture: :all_but_first)

    # Split on newline-anchored pipes only — a member's own inner union
    # (`:execution | :tenant`) must not count twice.
    members =
      union
      |> String.split(~r/\n\s*\|/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assert length(members) == length(@exemplars),
           "the union names #{length(members)} members, the exemplar table " <>
             "#{length(@exemplars)} — a reason was added to one and not the other"
  end
end
