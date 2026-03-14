defmodule SanctumArx.ProjectsTest do
  use ExUnit.Case, async: false

  alias SanctumArx.{Orgs, Projects}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    original_edition = Application.get_env(:cyfr, :edition)
    Application.put_env(:cyfr, :edition, :arx)

    on_exit(fn ->
      if original_edition,
        do: Application.put_env(:cyfr, :edition, original_edition),
        else: Application.delete_env(:cyfr, :edition)
    end)

    {:ok, org} = Orgs.create(%{name: "Test Org", slug: "test-org", plan: "free"})
    {:ok, org: org}
  end

  defp valid_project_attrs(overrides \\ %{}) do
    Map.merge(%{name: "My Project", slug: "my-project"}, overrides)
  end

  describe "create/2" do
    test "creates a project", %{org: org} do
      assert {:ok, project} = Projects.create(org.id, valid_project_attrs())
      assert project.name == "My Project"
      assert project.org_id == org.id
      assert String.starts_with?(project.id, "proj_")
    end

    test "rejects invalid slug", %{org: org} do
      assert {:error, changeset} = Projects.create(org.id, valid_project_attrs(%{slug: "BAD"}))
      assert %{slug: [_ | _]} = errors_on(changeset)
    end

    test "rejects duplicate slug within same org", %{org: org} do
      assert {:ok, _} = Projects.create(org.id, valid_project_attrs())
      assert {:error, changeset} = Projects.create(org.id, valid_project_attrs(%{name: "Another"}))
      assert %{org_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "get/1" do
    test "returns project by id", %{org: org} do
      {:ok, project} = Projects.create(org.id, valid_project_attrs())
      assert {:ok, found} = Projects.get(project.id)
      assert found.id == project.id
    end

    test "returns not_found" do
      assert {:error, :not_found} = Projects.get("proj_nonexistent")
    end
  end

  describe "get_by_slug/2" do
    test "returns project by org_id and slug", %{org: org} do
      {:ok, project} = Projects.create(org.id, valid_project_attrs())
      assert {:ok, found} = Projects.get_by_slug(org.id, "my-project")
      assert found.id == project.id
    end
  end

  describe "update/2" do
    test "updates project attributes", %{org: org} do
      {:ok, project} = Projects.create(org.id, valid_project_attrs())
      assert {:ok, updated} = Projects.update(project, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end
  end

  describe "delete/1" do
    test "deletes a project", %{org: org} do
      {:ok, project} = Projects.create(org.id, valid_project_attrs())
      assert {:ok, _} = Projects.delete(project)
      assert {:error, :not_found} = Projects.get(project.id)
    end
  end

  describe "list_by_org/2" do
    test "lists projects for an org", %{org: org} do
      {:ok, _} = Projects.create(org.id, valid_project_attrs(%{slug: "proj-01"}))
      {:ok, _} = Projects.create(org.id, valid_project_attrs(%{slug: "proj-02"}))
      projects = Projects.list_by_org(org.id)
      assert length(projects) >= 2
    end
  end

  describe "cascading delete" do
    test "deleting org removes projects", %{org: org} do
      {:ok, project} = Projects.create(org.id, valid_project_attrs())
      {:ok, _} = Orgs.delete(org)
      assert {:error, :not_found} = Projects.get(project.id)
    end
  end

  describe "edition gating" do
    test "returns feature_not_available in community mode", %{org: org} do
      Application.put_env(:cyfr, :edition, :core)
      assert {:error, :feature_not_available} = Projects.create(org.id, valid_project_attrs())
      assert {:error, :feature_not_available} = Projects.get("proj_x")
      assert {:error, :feature_not_available} = Projects.list_by_org(org.id)
    end
  end

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
