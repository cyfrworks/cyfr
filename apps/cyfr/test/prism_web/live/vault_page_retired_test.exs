# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultPageRetiredTest do
  @moduledoc """
  The vault is the tincture `tincture:local.vault` on the desktop, not a
  console page: the page's route answers 404, and no route, navigation
  entry or roster names it.
  """

  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    {:ok, conn: log_in_user(conn, test_user())}
  end

  test "its route answers 404, and no route, page or roster names it", %{conn: conn} do
    assert get(conn, athanor_path("/vault")).status == 404

    refute Enum.any?(Cyfr.Boundaries.routes(), &String.ends_with?(&1.path, "/vault"))

    refute Enum.any?(
             PrismWeb.Nav.items("dev") ++ PrismWeb.Nav.items("lite"),
             &(&1.key == "vault")
           )

    refute Code.ensure_loaded?(Module.concat(["PrismWeb", "VaultLive"]))

    root = Path.expand("../../../../..", __DIR__)

    for file <- Path.wildcard(Path.join(root, "apps/*/{lib,test}/**/*.{ex,exs}")),
        file != __ENV__.file do
      refute File.read!(file) =~ "VaultLive",
             "#{Path.relative_to(file, root)} names the retired page"
    end
  end
end
