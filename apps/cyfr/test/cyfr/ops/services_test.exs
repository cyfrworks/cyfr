# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Ops.ServicesTest do
  use ExUnit.Case, async: true

  alias Cyfr.Ops.Services
  alias Cyfr.Ops.Catalog

  test "every configured provider maps to a service the roster lists" do
    names = Services.service_names()

    for module <- Catalog.configured_providers() do
      assert Services.service_name(module) in names
    end

    assert names == names |> Enum.uniq() |> Enum.sort()
  end

  test "the storage providers are arca's and files', everywhere they are named" do
    # routed_to and system.status read the same map, so the same module
    # cannot be one service in the log and another in the report. Several
    # providers may share a service.
    assert Services.service_name(Arca.Providers.Records) == "arca"
    assert Services.providers_for("arca") == [Arca.Providers.Records]
    assert Services.service_name(Arca.Providers.Files) == "files"
    assert Services.providers_for("files") == [Arca.Providers.Files]
  end

  test "an unlisted module is emissary's" do
    assert Services.service_name(UnknownProvider) == "emissary"
  end
end
