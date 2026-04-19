defmodule Sanctum.UserStructTest do
  use ExUnit.Case, async: true

  alias Sanctum.User

  describe "struct fields" do
    test "includes org_id and project_id fields" do
      user = %User{id: "u1", email: "a@b.com", provider: "github"}
      assert Map.has_key?(user, :org_id)
      assert Map.has_key?(user, :project_id)
      assert user.org_id == nil
      assert user.project_id == nil
    end

    test "org_id and project_id can be set" do
      user = %User{id: "u1", org_id: "org_1", project_id: "proj_1"}
      assert user.org_id == "org_1"
      assert user.project_id == "proj_1"
    end

    test "from_oidc_claims returns user with nil org_id/project_id" do
      claims = %{"sub" => "12345", "email" => "alice@example.com", "iss" => "https://github.com"}
      user = User.from_oidc_claims(claims)
      assert user.id == "github|https://github.com|12345"
      assert user.email == "alice@example.com"
      assert user.org_id == nil
      assert user.project_id == nil
    end

    test "local user has nil org_id/project_id" do
      user = User.local()
      assert user.id == "local_user"
      assert user.org_id == nil
      assert user.project_id == nil
    end

    test "struct update syntax works for org_id/project_id" do
      user = %User{id: "u1"}
      updated = %{user | org_id: "org_2", project_id: "proj_2"}
      assert updated.org_id == "org_2"
      assert updated.project_id == "proj_2"
    end
  end
end
