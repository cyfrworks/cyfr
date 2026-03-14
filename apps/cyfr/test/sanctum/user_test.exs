defmodule Sanctum.UserTest do
  use ExUnit.Case, async: true

  alias Sanctum.User

  describe "local/0" do
    test "returns user with local_user id" do
      user = User.local()
      assert user.id == "local_user"
      assert user.provider == "local"
      assert user.email == nil
    end

    test "grants wildcard permissions" do
      user = User.local()
      assert :* in user.permissions
    end
  end

  describe "from_oidc_claims/1" do
    test "extracts user info from claims" do
      claims = %{
        "sub" => "12345",
        "email" => "alice@example.com",
        "iss" => "https://github.com"
      }

      user = User.from_oidc_claims(claims)

      assert user.id == "12345"
      assert user.email == "alice@example.com"
      assert user.provider == "https://github.com"
      assert user.permissions == []
    end
  end
end
