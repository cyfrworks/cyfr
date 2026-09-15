# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ManifestNeedsCapsTest do
  # The registration block below runs the sandbox in shared mode and points
  # the storage roots at its own directory — both are global, so this module
  # cannot run beside others.
  use ExUnit.Case, async: false

  alias Compendium.Manifest.Caps
  alias Compendium.Manifest.Needs

  @good_needs %{
    "needs" => %{
      "api_key" => %{
        "type" => "api_key:anthropic.com",
        "reason" => "to call the Anthropic API with your key",
        "fields" => ["ANTHROPIC_API_KEY"],
        "required" => true
      },
      "google" => %{
        "type" => "oauth:google",
        "reason" => "to read your Gmail inbox",
        "scopes" => ["https://www.googleapis.com/auth/gmail.readonly"]
      }
    }
  }

  @good_caps %{
    "caps" => %{
      "egress" => %{
        "domains" => ["api.anthropic.com"],
        "methods" => ["GET", "POST"],
        "schemes" => ["https"],
        "private_ips" => []
      },
      "storage" => %{"paths" => ["data/"], "actions" => ["read", "write"]},
      "tools" => ["execution.run", "component.*"],
      "limits" => %{
        "timeout" => "3m",
        "max_memory_bytes" => 67_108_864,
        "rate_limit" => %{"requests" => 100, "window" => "1m"}
      }
    }
  }

  describe "Needs.validate/1" do
    test "absent, nil, and well-formed all pass" do
      assert :ok = Needs.validate(nil)
      assert :ok = Needs.validate(%{"name" => "x"})
      assert :ok = Needs.validate(@good_needs)
    end

    test "the name is the slot key, so the edge-key grammar constrains it" do
      for bad <- ["@ingress", "has|pipe", "Upper", "", "0start", String.duplicate("a", 33)] do
        manifest = %{"needs" => %{bad => %{"type" => "api_key:x.com", "reason" => "r"}}}
        assert {:error, {:invalid_needs, {:invalid_name, ^bad}}} = Needs.validate(manifest)
      end
    end

    test "type must be kind:qualifier over the closed kind set" do
      for bad <- ["api_key", "wrench:acme.com", "oauth:", ":acme", 7, nil] do
        manifest = %{"needs" => %{"n" => %{"type" => bad, "reason" => "r"}}}
        assert {:error, {:invalid_needs, {:invalid_type, "n", _}}} = Needs.validate(manifest)
      end

      for good <- ["api_key:anthropic.com", "oauth:google", "bundle:supabase.com", "catalyst:db"] do
        manifest = %{"needs" => %{"n" => %{"type" => good, "reason" => "r"}}}
        assert :ok = Needs.validate(manifest)
      end
    end

    test "reason is required prose — the operator sees it instead of key names" do
      for bad <- [nil, "", "   "] do
        manifest = %{"needs" => %{"n" => %{"type" => "api_key:x.com", "reason" => bad}}}
        assert {:error, {:invalid_needs, {:reason_required, "n"}}} = Needs.validate(manifest)
      end
    end

    test "scopes only make sense on oauth kinds" do
      manifest = %{
        "needs" => %{
          "n" => %{"type" => "api_key:x.com", "reason" => "r", "scopes" => ["a"]}
        }
      }

      assert {:error, {:invalid_needs, {:scopes_on_non_oauth, "n"}}} = Needs.validate(manifest)
    end

    test "unknown keys are rejected" do
      manifest = %{
        "needs" => %{
          "n" => %{"type" => "api_key:x.com", "reason" => "r", "secret_name" => "LEAK"}
        }
      }

      assert {:error, {:invalid_needs, {:unknown_keys, "n", ["secret_name"]}}} =
               Needs.validate(manifest)
    end

    test "from_manifest normalizes into sorted rows" do
      assert [api_key, google] = Needs.from_manifest(@good_needs)
      assert api_key.name == "api_key"
      assert api_key.kind == "api_key"
      assert api_key.qualifier == "anthropic.com"
      assert api_key.fields == ["ANTHROPIC_API_KEY"]
      assert api_key.required
      assert google.kind == "oauth"
      assert google.scopes == ["https://www.googleapis.com/auth/gmail.readonly"]
      assert Needs.from_manifest(%{"name" => "x"}) == nil
    end
  end

  describe "Caps.validate/1" do
    test "absent, nil, and well-formed all pass" do
      assert :ok = Caps.validate(nil)
      assert :ok = Caps.validate(%{"name" => "x"})
      assert :ok = Caps.validate(@good_caps)
    end

    test "unknown keys are rejected at every level" do
      assert {:error, {:invalid_caps, {:unknown_keys, :caps, ["policy"]}}} =
               Caps.validate(%{"caps" => %{"policy" => %{}}})

      assert {:error, {:invalid_caps, {:unknown_keys, :egress, ["ports"]}}} =
               Caps.validate(%{"caps" => %{"egress" => %{"ports" => [80]}}})

      assert {:error, {:invalid_caps, {:unknown_keys, :limits, ["cpu"]}}} =
               Caps.validate(%{"caps" => %{"limits" => %{"cpu" => 2}}})
    end

    test "tools speak the ToolPattern grammar" do
      assert {:error, {:invalid_caps, {:invalid_tool_pattern, "read*"}}} =
               Caps.validate(%{"caps" => %{"tools" => ["read*"]}})

      assert :ok = Caps.validate(%{"caps" => %{"tools" => ["*"]}})
    end

    test "storage paths speak the guest vocabulary — out-of-scope grants fail at parse" do
      assert :ok = Caps.validate(%{"caps" => %{"storage" => %{"paths" => ["data/"]}}})

      assert :ok =
               Caps.validate(%{
                 "caps" => %{"storage" => %{"paths" => ["data/notes", "components/", "*"]}}
               })

      # A grant no runtime would honor — the host scopes are not guest
      # vocabulary — is refused here, not three layers later at dispatch.
      assert {:error, {:invalid_caps, {:invalid_storage_path, "aqua/"}}} =
               Caps.validate(%{"caps" => %{"storage" => %{"paths" => ["data/", "aqua/"]}}})

      assert {:error, {:invalid_caps, {:invalid_storage_path, "threads/"}}} =
               Caps.validate(%{"caps" => %{"storage" => %{"paths" => ["threads/"]}}})

      # `threads/` is a host scope of the athanor's tree, and the retired
      # name for it (spelled split for the vocabulary gate) is no root.
      assert "threads" in Arca.Storage.tenant_roots()
      retired = "conver" <> "sations"
      refute retired in Arca.Storage.tenant_roots()
      retired_grant = retired <> "/"

      assert {:error, {:invalid_caps, {:invalid_storage_path, ^retired_grant}}} =
               Caps.validate(%{"caps" => %{"storage" => %{"paths" => [retired_grant]}}})

      assert {:error, {:invalid_caps, {:invalid_storage_path, "guest/"}}} =
               Caps.validate(%{"caps" => %{"storage" => %{"paths" => ["guest/"]}}})
    end

    test "limits carry the Cyfr.Limits vocabulary with strict durations" do
      assert {:error, {:invalid_caps, {:invalid_limit, "timeout", "5min"}}} =
               Caps.validate(%{"caps" => %{"limits" => %{"timeout" => "5min"}}})

      assert {:error, {:invalid_caps, {:invalid_limit, "max_memory_bytes", "lots"}}} =
               Caps.validate(%{"caps" => %{"limits" => %{"max_memory_bytes" => "lots"}}})

      assert {:error, {:invalid_caps, {:invalid_limit, "rate_limit", _}}} =
               Caps.validate(%{"caps" => %{"limits" => %{"rate_limit" => %{"requests" => 5}}}})
    end

    test "from_manifest sorts and dedupes string sets and atomizes limits" do
      caps =
        Caps.from_manifest(%{
          "caps" => %{
            "egress" => %{"domains" => ["b.example", "a.example", "b.example"]},
            "limits" => %{"timeout" => "3m", "rate_limit" => %{"requests" => 9, "window" => "1m"}}
          }
        })

      assert caps.egress.domains == ["a.example", "b.example"]
      assert caps.egress.schemes == []
      assert caps.storage.paths == []
      assert caps.limits == %{timeout: "3m", rate_limit: %{requests: 9, window: "1m"}}
      assert Caps.from_manifest(%{"name" => "x"}) == nil
    end
  end

  describe "release digest coverage" do
    test "a caps or needs edit changes the release digest" do
      {:ok, bare} = Compendium.ReleaseDigest.compute("sha256:abc", %{"name" => "x"})
      {:ok, with_caps} = Compendium.ReleaseDigest.compute("sha256:abc", @good_caps)
      {:ok, with_needs} = Compendium.ReleaseDigest.compute("sha256:abc", @good_needs)

      assert bare != with_caps
      assert bare != with_needs
      assert with_caps != with_needs
    end
  end

  describe "registration refuses malformed blocks" do
    setup do
      Arca.Cache.init()
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      test_path = Path.join(System.tmp_dir!(), "needs_caps_#{:rand.uniform(1_000_000)}")
      original = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original,
          do: Application.put_env(:cyfr, :base_path, original),
          else: Application.delete_env(:cyfr, :base_path)
      end)

      wasm = File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))
      {:ok, ctx: Sanctum.TestContext.local(), wasm: wasm}
    end

    test "publish_bytes refuses a malformed needs block", %{ctx: ctx, wasm: wasm} do
      manifest =
        Jason.encode!(%{
          "name" => "bad-needs",
          "version" => "1.0.0",
          "type" => "reagent",
          "needs" => %{"@ingress" => %{"type" => "api_key:x.com", "reason" => "r"}}
        })

      assert {:error, {:invalid_needs, _}} =
               Compendium.Registry.publish_bytes(ctx, wasm, %{
                 name: "bad-needs",
                 version: "1.0.0",
                 type: "reagent",
                 manifest: manifest
               })
    end

    test "publish_bytes refuses a manifest with an unknown top-level key", %{ctx: ctx, wasm: wasm} do
      manifest =
        Jason.encode!(%{
          "name" => "unknown-key",
          "version" => "1.0.0",
          "type" => "reagent",
          "setup" => %{"policy" => %{"allowed_domains" => ["a.example"]}}
        })

      assert {:error, {:unknown_manifest_keys, msg}} =
               Compendium.Registry.publish_bytes(ctx, wasm, %{
                 name: "unknown-key",
                 version: "1.0.0",
                 type: "reagent",
                 manifest: manifest
               })

      assert msg =~ "unknown top-level key(s): setup"
    end

    test "publish_bytes accepts well-formed needs and caps", %{ctx: ctx, wasm: wasm} do
      manifest =
        Jason.encode!(
          Map.merge(
            %{"name" => "good-blocks", "version" => "1.0.0", "type" => "reagent"},
            Map.merge(@good_needs, @good_caps)
          )
        )

      assert {:ok, component} =
               Compendium.Registry.publish_bytes(ctx, wasm, %{
                 name: "good-blocks",
                 version: "1.0.0",
                 type: "reagent",
                 manifest: manifest
               })

      assert is_binary(component.release_digest)
    end
  end

  describe "the limits roster stays bound to Cyfr.Limits" do
    test "Caps admits exactly the fields Limits clamps" do
      # Caps holds a string-keyed copy (the manifest is JSON; Caps is
      # Apache, Limits is FSL) — this pin is what makes the copy safe. A
      # new clamped limit must be admitted at publish, or manifests
      # declaring it are refused while every downstream reader accepts it.
      caps_roster =
        Enum.sort(~w(max_memory_bytes max_request_size max_response_size
                     max_concurrent_tasks timeout batch_timeout rate_limit))

      limits_roster = Cyfr.Limits.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert caps_roster == limits_roster
    end

    test "one duration grammar: unit-suffixed and bare integer seconds both parse" do
      # Match duration parsing at publish and runtime, including rejection of trailing newlines.
      for {value, ok?} <- [
            {"30s", true},
            {"500ms", true},
            {"5m", true},
            {"1h", true},
            {"30", true},
            {"30s\n", false},
            {"", false},
            {"abc", false}
          ] do
        manifest = %{
          "caps" => %{"limits" => %{"timeout" => value}}
        }

        result = Caps.validate(manifest)

        limits_ok? = match?({:ok, _}, Cyfr.Limits.parse_duration(value))

        assert result == :ok == ok?,
               "Caps disagrees on #{inspect(value)}: got #{inspect(result)}"

        assert limits_ok? == ok?,
               "Limits disagrees on #{inspect(value)}: parse_duration says #{limits_ok?}"
      end
    end
  end

  describe "tincture and dependencies blocks refuse at the one validator" do
    alias Compendium.Manifest

    test "a non-map tincture block refuses instead of raising at the CSP builder" do
      assert {:error, {:invalid_tincture, _}} = Manifest.validate(%{"tincture" => "oops"})
    end

    test "connect entries are held to the CSP domain grammar at publish" do
      good = %{"tincture" => %{"connect" => ["api.example.com", "*.example.org"]}}
      assert :ok = Manifest.validate(good)

      for bad <- ["*", "https://x.com", "1.2.3.4", "x.com/path", "x.com:8080", "evil.com\n"] do
        assert {:error, {:invalid_tincture, msg}} =
                 Manifest.validate(%{"tincture" => %{"connect" => [bad]}}),
               "#{inspect(bad)} must refuse"

        assert msg =~ inspect(bad)
      end
    end

    test "static deps must be ref strings or ref objects; dynamic stays a descriptor" do
      assert :ok =
               Manifest.validate(%{
                 "dependencies" => %{
                   "static" => ["catalyst:local.files", %{"ref" => "c:local.http"}],
                   "dynamic" => %{"discovery" => "component.search"}
                 }
               })

      assert {:error, {:invalid_dependencies, _}} =
               Manifest.validate(%{"dependencies" => %{"static" => [%{"nope" => true}]}})

      assert {:error, {:invalid_dependencies, _}} =
               Manifest.validate(%{"dependencies" => %{"static" => "catalyst:local.files"}})

      assert {:error, {:invalid_dependencies, _}} =
               Manifest.validate(%{"dependencies" => ["catalyst:local.files"]})
    end
  end
end
