# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAccessTest do
  use ExUnit.Case, async: false

  alias Sanctum.{Context, TinctureAccess}

  # Component facts whose every read fails with an exception that carries
  # storage text, the `@canary`, in its message.
  defmodule RaisingFacts do
    @moduledoc false
    @behaviour Sanctum.Consent.Components

    # Filling is not what this stand-in is for: the component domain fills.
    @impl true
    defdelegate fill(athanor, ctx, entry_kind), to: Compendium.ConsentFacts

    @canary "T8_RAW_STORAGE_ERROR_CANARY"
    def canary, do: @canary

    @impl true
    def resolve(_ctx, _component), do: failed()
    @impl true
    def resolve_verified(_ctx, _component), do: failed()
    @impl true
    def get_component(_ctx, _name, _version, _publisher, _type), do: failed()
    @impl true
    def agent_rows(_ctx), do: failed()
    @impl true
    def shipped_nodes(_ctx, _rows), do: failed()
    @impl true
    def newer_shipped(_ctx, _row), do: failed()
    @impl true
    def tincture_placement(_ctx, _row), do: failed()

    defp failed, do: {:error, %RuntimeError{message: @canary}}
  end

  # Component facts whose every read fails with a map that looks like an
  # exception but names no module: its `__struct__` is storage text.
  defmodule MalformedFacts do
    @moduledoc false
    @behaviour Sanctum.Consent.Components

    # Filling is not what this stand-in is for: the component domain fills.
    @impl true
    defdelegate fill(athanor, ctx, entry_kind), to: Compendium.ConsentFacts

    @impl true
    def resolve(_ctx, _component), do: failed()
    @impl true
    def resolve_verified(_ctx, _component), do: failed()
    @impl true
    def get_component(_ctx, _name, _version, _publisher, _type), do: failed()
    @impl true
    def agent_rows(_ctx), do: failed()
    @impl true
    def shipped_nodes(_ctx, _rows), do: failed()
    @impl true
    def newer_shipped(_ctx, _row), do: failed()
    @impl true
    def tincture_placement(_ctx, _row), do: failed()

    defp failed, do: {:error, %{__exception__: true, __struct__: RaisingFacts.canary()}}
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    # Public-ness reads the profiles table now; point the source at it.

    on_exit(fn ->
      nil
    end)

    # Create temp tincture structure with one public and one private tincture,
    # under an isolated storage root.
    base = Path.join(System.tmp_dir!(), "tincture_access_test_#{:rand.uniform(1_000_000)}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    # Public tincture
    pub_dir = tincture_dir("public-dash")

    File.mkdir_p!(pub_dir)

    pub_manifest = %{
      "name" => "public-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Public Dashboard",
      "tincture" => %{
        "entry" => "index.html",
        "public" => true,
        "window" => %{"width" => 800, "height" => 600}
      },
      "schema" => %{
        "tables" => %{},
        "queries" => %{
          "latest" => %{
            "sql" => "SELECT 1",
            "params" => %{},
            "cache_ttl" => 60
          }
        }
      }
    }

    File.write!(Path.join(pub_dir, "cyfr-manifest.json"), Jason.encode!(pub_manifest))
    File.write!(Path.join(pub_dir, "index.html"), "<html></html>")

    # Private tincture
    priv_dir = tincture_dir("private-dash")

    File.mkdir_p!(priv_dir)

    priv_manifest = %{
      "name" => "private-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Private Dashboard",
      "tincture" => %{
        "entry" => "index.html",
        "public" => false,
        "window" => %{"width" => 800, "height" => 600}
      },
      "schema" => %{
        "tables" => %{},
        "queries" => %{}
      }
    }

    File.write!(Path.join(priv_dir, "cyfr-manifest.json"), Jason.encode!(priv_manifest))
    File.write!(Path.join(priv_dir, "index.html"), "<html></html>")

    ctx = Sanctum.TestContext.local()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Register components in SQLite so Compendium.Registry.get_latest finds them
    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "test_pub_dash_#{:rand.uniform(1_000_000)}",
        name: "public-dash",
        version: "1.0.0",
        component_type: "tincture",
        description: "Public Dashboard",
        tags: "[]",
        digest: "sha256:test_pub",
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(pub_manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "test_priv_dash_#{:rand.uniform(1_000_000)}",
        name: "private-dash",
        version: "1.0.0",
        component_type: "tincture",
        description: "Private Dashboard",
        tags: "[]",
        digest: "sha256:test_priv",
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(priv_manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    # Public-ness is a published profile: the public tincture gets one,
    # the private one stays profile-less.
    pub_ref = "tincture:local.public-dash"

    {:ok, _} =
      Arca.Test.Writers.put_profile(%{
        id: "prof_pub_#{:rand.uniform(1_000_000)}",
        athanor_id: ctx.athanor_id,
        source_ref: pub_ref,
        kind: "public",
        label: "public",
        status: "active"
      })

    on_exit(fn ->
      if original_path do
        Application.put_env(:arca, :base_path, original_path)
      else
        Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(base)
    end)

    :ok
  end

  defp tincture_dir(name) do
    Arca.Adapters.Local.build_path(
      Sanctum.Context.actor(Sanctum.TestContext.local()),
      ["components", "tinctures", "local", name, "1.0.0"]
    )
  end

  describe "get_private/3" do
    test "returns tincture for authenticated context" do
      ctx = Sanctum.TestContext.local()
      assert {:ok, tincture} = TinctureAccess.get_private(ctx, "local", "public-dash")
      assert tincture.name == "public-dash"
    end

    test "returns private tincture for authenticated context" do
      ctx = Sanctum.TestContext.local()
      assert {:ok, tincture} = TinctureAccess.get_private(ctx, "local", "private-dash")
      assert tincture.name == "private-dash"
    end

    test "returns :not_found for nonexistent tincture" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :not_found} = TinctureAccess.get_private(ctx, "local", "nonexistent")
    end

    test "returns :not_found for invalid publisher" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :not_found} = TinctureAccess.get_private(ctx, "../evil", "public-dash")
    end

    test "returns :not_found for invalid name" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :not_found} = TinctureAccess.get_private(ctx, "local", "../etc/passwd")
    end
  end

  describe "get_public/3" do
    test "returns public tincture" do
      ctx = Context.build(athanor_id: "ath_test", authenticated: false)
      assert {:ok, tincture} = TinctureAccess.get_public(ctx, "local", "public-dash")
      assert tincture.name == "public-dash"
    end

    test "returns :not_found for private tincture (indistinguishable)" do
      ctx = Context.build(athanor_id: "ath_test", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "private-dash")
    end

    test "returns :not_found for nonexistent tincture" do
      ctx = Context.build(athanor_id: "ath_test", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "nonexistent")
    end

    test "fails closed when the athanor is unresolved" do
      # The public route resolves the owning athanor before the lookup; a
      # context that names none must not find even a public tincture.
      ctx = Context.build(athanor_id: nil, authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "public-dash")
    end

    test "returns :not_found for invalid publisher" do
      ctx = Context.build(athanor_id: "ath_test", authenticated: false)

      assert {:error, :not_found} =
               TinctureAccess.get_public(ctx, "bad publisher!", "public-dash")
    end

    test "returns :not_found for invalid name" do
      ctx = Context.build(athanor_id: "ath_test", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "bad name!")
    end
  end

  describe "a version whose stored manifest does not decode to a JSON object" do
    # Text that is not JSON, JSON that is no object, and none at all: each
    # a declaration refused, so the version is found neither publicly nor
    # privately, though it holds an active public profile.
    test "is found by neither get_public/3 nor get_private/3" do
      ctx = Sanctum.TestContext.local()
      public_ctx = Context.build(athanor_id: ctx.athanor_id, authenticated: false)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for {name, stored} <- [
            {"bad-json", "{\"name\": \"bad-json\","},
            {"list-json", "[]"},
            {"no-manifest", nil}
          ] do
        dir = tincture_dir(name)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "index.html"), "<html></html>")

        {:ok, _} =
          Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
            id: "test_#{name}_#{:rand.uniform(1_000_000)}",
            name: name,
            version: "1.0.0",
            component_type: "tincture",
            description: name,
            tags: "[]",
            digest: "sha256:test_#{name}",
            size: 100,
            exports: "[]",
            manifest: stored,
            publisher: "local",
            publisher_id: "local|local|testns",
            source: Compendium.Source.filesystem(),
            signature_verified: false,
            inserted_at: now,
            updated_at: now
          })

        {:ok, _} =
          Arca.Test.Writers.put_profile(%{
            id: "prof_#{name}_#{:rand.uniform(1_000_000)}",
            athanor_id: ctx.athanor_id,
            source_ref: "tincture:local.#{name}",
            kind: "public",
            label: "public",
            status: "active"
          })

        assert {name, TinctureAccess.get_public(public_ctx, "local", name)} ==
                 {name, {:error, :not_found}}

        assert {name, TinctureAccess.get_private(ctx, "local", name)} ==
                 {name, {:error, :not_found}}
      end
    end
  end

  describe "a store that cannot answer" do
    # One outage and one read per test: on PostgreSQL the failed read
    # aborts the test's transaction, so a second read would meet that, not
    # the outage.
    for read <- [:private, :public, :private_published] do
      test "a component-facts outage is unavailable to the #{read} read, never not found or a raise" do
        assert {:ok, _} = read(unquote(read))

        # The public read reaches the facts only past the public profile.
        Arca.Repo.query!("ALTER TABLE components RENAME TO components_unavailable")
        assert read(unquote(read)) == {:error, :unavailable}
      end

      test "a component-facts port nothing installed is unavailable to the #{read} read" do
        real = Sanctum.Consent.Components.impl!()
        on_exit(fn -> Sanctum.Consent.Components.install!(real) end)

        Sanctum.TestContext.uninstall_port(Sanctum.Consent.Components)

        answer =
          try do
            read(unquote(read))
          after
            Sanctum.Consent.Components.install!(real)
          end

        assert answer == {:error, :unavailable}
      end
    end

    test "a component-facts answer that is neither a row nor absence is unavailable, and logged" do
      # A platform context working in no athanor holds `:storage_read` and
      # passes the tenant gate, and the facts answer it `:no_athanor`,
      # which is no outage the port names.
      ctx = Sanctum.TestContext.platform()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert TinctureAccess.get_private(ctx, "local", "public-dash") == {:error, :unavailable}
        end)

      assert log =~
               "[TinctureAccess] component facts unreadable for local/public-dash: :no_athanor"

      # An error carrying storage text: the warning names its kind alone.
      real = Sanctum.Consent.Components.impl!()
      on_exit(fn -> Sanctum.Consent.Components.install!(real) end)
      Sanctum.Consent.Components.install!(RaisingFacts)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          answer =
            try do
              TinctureAccess.get_private(Sanctum.TestContext.local(), "local", "public-dash")
            after
              Sanctum.Consent.Components.install!(real)
            end

          assert answer == {:error, :unavailable}
        end)

      refute log =~ RaisingFacts.canary()

      assert log =~
               "[TinctureAccess] component facts unreadable for local/public-dash: RuntimeError"

      # A map shaped like an exception whose `__struct__` is not a module:
      # no kind can be read from it, so the warning says so and nothing else.
      Sanctum.Consent.Components.install!(MalformedFacts)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          answer =
            try do
              TinctureAccess.get_private(Sanctum.TestContext.local(), "local", "public-dash")
            after
              Sanctum.Consent.Components.install!(real)
            end

          assert answer == {:error, :unavailable}
        end)

      refute log =~ RaisingFacts.canary()

      assert log =~
               "[TinctureAccess] component facts unreadable for local/public-dash: :unknown"
    end

    # A tincture with no public profile is refused before the facts are
    # read: private and absent stay one answer.
    for name <- ["private-dash", "nonexistent"] do
      test "a component-facts outage leaves a tincture with no public profile not found: #{name}" do
        Arca.Repo.query!("ALTER TABLE components RENAME TO components_unavailable")

        assert TinctureAccess.get_public(public_ctx(), "local", unquote(name)) ==
                 {:error, :not_found}
      end
    end

    for name <- ["public-dash", "private-dash", "nonexistent"] do
      test "a profiles outage is unavailable on the public read, never public or not found: #{name}" do
        Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

        assert TinctureAccess.get_public(public_ctx(), "local", unquote(name)) ==
                 {:error, :unavailable}
      end
    end
  end

  defp public_ctx,
    do: Context.build(athanor_id: Sanctum.TestContext.local().athanor_id, authenticated: false)

  # Each read of a tincture the store holds.
  defp read(:private),
    do: TinctureAccess.get_private(Sanctum.TestContext.local(), "local", "private-dash")

  defp read(:public), do: TinctureAccess.get_public(public_ctx(), "local", "public-dash")

  defp read(:private_published),
    do: TinctureAccess.get_private(Sanctum.TestContext.local(), "local", "public-dash")

  describe "public_context/1" do
    defp create_athanor!(kind, slug) do
      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: kind,
          name: slug,
          slug: slug,
          created_by: "test",
          owner_user_id: if(kind == "person", do: "github|https://github.com|#{slug}")
        })

      athanor
    end

    test "resolves a group by slug into an unauthenticated context anchored to it" do
      athanor = create_athanor!("group", "acme")

      assert {:ok, %Context{} = ctx} = TinctureAccess.public_context("acme")
      assert ctx.athanor_id == athanor.id
      assert ctx.scope == :athanor
      assert ctx.authenticated == false
    end

    test "resolves a person by @namespace, and a bare slug only as a group" do
      athanor = create_athanor!("person", "bob")

      assert {:ok, ctx} = TinctureAccess.public_context("@bob")
      assert ctx.athanor_id == athanor.id
      assert ctx.authenticated == false

      # A bare "bob" is a group slug, which nobody created.
      assert {:error, :not_found} = TinctureAccess.public_context("bob")
    end

    test "an unknown segment is not found — never a default athanor" do
      for segment <- ["nobody", "@nobody", "", "@"] do
        assert {:error, :not_found} = TinctureAccess.public_context(segment), segment
      end
    end

    test "an archived athanor is not found, in either form" do
      group = create_athanor!("group", "gone")
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)
      assert {:error, :not_found} = TinctureAccess.public_context("gone")

      person = create_athanor!("person", "left")
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(person, force: true)
      assert {:error, :not_found} = TinctureAccess.public_context("@left")
    end

    test "a store that cannot answer is unavailable, never not found, in either form" do
      create_athanor!("group", "acme")
      assert {:ok, _} = TinctureAccess.public_context("acme")

      # An outage, simulated inside the test's transaction: the table the
      # slug is read from is gone until the sandbox rolls it back.
      Arca.Repo.query!("ALTER TABLE athanors RENAME TO athanors_unreachable")

      assert {:error, :unavailable} = TinctureAccess.public_context("acme")
      assert {:error, :unavailable} = TinctureAccess.public_context("@acme")
    end
  end
end
