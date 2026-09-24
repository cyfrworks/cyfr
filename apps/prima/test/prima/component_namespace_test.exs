# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentNamespaceTest do
  use ExUnit.Case, async: true

  alias Prima.ComponentNamespace

  doctest Prima.ComponentNamespace

  test "only the local publisher's units take a write" do
    assert :ok = ComponentNamespace.require_local_guest_write("local")
    assert :ok = ComponentNamespace.require_local_guest_write(nil)

    for publisher <- ["acme", "cyfr", "Local-ish"] do
      assert {:error, :not_local_namespace} =
               ComponentNamespace.require_local_guest_write(publisher)
    end
  end

  test "the refusal names the publisher and the fork path" do
    assert ComponentNamespace.message(:not_local_namespace, "acme") ==
             "Components under 'acme/' are pulled from the registry and " <>
               "never modified in place — fork into local/ to make changes."
  end
end
