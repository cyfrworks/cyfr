# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.UnauthorizedVocabularyTest do
  @moduledoc """
  The refusal vocabulary and its `@type reason` union stay one thing.

  Each exemplar must be accepted by `reason?/1`, `code/1`, and `message/2`.
  The `Sanctum.Unauthorized.reason()` union must contain the same number
  of variants as the exemplar roster.
  """

  use ExUnit.Case, async: true

  alias Sanctum.Unauthorized

  # One exemplar per union member, in the union's order.
  @exemplars [
    :unauthenticated,
    :missing_tenant,
    :tenant_mismatch,
    :malformed_record,
    :untagged_tenant_resource,
    :platform_admin_required,
    {:missing_tenant, :no_membership},
    {:missing_permission, :vault_read},
    {:guest_plane, :vault_read},
    {:guest_plane_call, "vault"},
    {:tool_auth_required, "vault"},
    {:malformed_resource, :execution},
    {:consent_class_required, %{}},
    {:authorization_required, "grant expired"}
  ]

  test "every union member is accepted by reason?/1, code/1 and message/2" do
    for reason <- @exemplars do
      assert Unauthorized.reason?(reason), "reason?/1 rejects #{inspect(reason)}"
      assert is_atom(Unauthorized.code(reason)), "code/1 fails for #{inspect(reason)}"
      assert is_binary(Unauthorized.message(reason)), "message/2 fails for #{inspect(reason)}"

      assert is_binary(Unauthorized.message(reason, :api_key)),
             "message/2 with a method fails for #{inspect(reason)}"
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
