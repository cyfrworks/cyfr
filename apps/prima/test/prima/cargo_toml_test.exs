# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CargoTomlTest do
  use ExUnit.Case, async: true

  alias Prima.CargoToml

  describe "template/2" do
    test "reagent/formula templates are identical regardless of the oauth option" do
      for type <- [:reagent, :formula] do
        assert CargoToml.template(type) ==
                 CargoToml.template(type, include_oauth_wit: false)
      end
    end

    test "catalyst variants differ ONLY by the cyfr:oauth WIT dep line" do
      oauth_line = ~s("cyfr:oauth" = { path = "wit/deps/cyfr-oauth" }\n)

      with_oauth = CargoToml.template(:catalyst)
      without_oauth = CargoToml.template(:catalyst, include_oauth_wit: false)

      assert with_oauth =~ oauth_line
      refute without_oauth =~ "cyfr:oauth"
      assert String.replace(with_oauth, oauth_line, "") == without_oauth
    end
  end
end
