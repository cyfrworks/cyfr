# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Cyfr.RuntimeConfig

  # Build a getenv reader over a plain map (blank/absent both read as nil-ish).
  defp env(map), do: fn key -> Map.get(map, key) end

  describe "resolve_auth_provider/1 — set-or-default, fail loud" do
    test "unset + no credentials => no auth (default)" do
      assert {:ok, nil} = RuntimeConfig.resolve_auth_provider(env(%{}))
    end

    test "unset + github credentials => OAuth (auto-detect)" do
      assert {:ok, Sanctum.Auth.OAuth} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_GITHUB_CLIENT_ID" => "x"}))
    end

    test "unset + google credentials => OAuth (auto-detect)" do
      assert {:ok, Sanctum.Auth.OAuth} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_GOOGLE_CLIENT_ID" => "x"}))
    end

    test "explicit oauth + credentials => OAuth" do
      assert {:ok, Sanctum.Auth.OAuth} =
               RuntimeConfig.resolve_auth_provider(
                 env(%{"CYFR_AUTH_PROVIDER" => "oauth", "CYFR_GITHUB_CLIENT_ID" => "x"})
               )
    end

    test "explicit oauth WITHOUT credentials => error (no silent downgrade)" do
      assert {:error, msg} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_AUTH_PROVIDER" => "oauth"}))

      assert msg =~ "CYFR_GITHUB_CLIENT_ID"
    end

    test "explicit oidc + full trio => OIDC" do
      assert {:ok, Sanctum.Auth.OIDC} =
               RuntimeConfig.resolve_auth_provider(
                 env(%{
                   "CYFR_AUTH_PROVIDER" => "oidc",
                   "CYFR_OIDC_ISSUER" => "https://auth.example.com",
                   "CYFR_OIDC_CLIENT_ID" => "cid",
                   "CYFR_OIDC_CLIENT_SECRET" => "secret"
                 })
               )
    end

    test "explicit oidc missing issuer => error naming the missing var" do
      assert {:error, msg} =
               RuntimeConfig.resolve_auth_provider(
                 env(%{
                   "CYFR_AUTH_PROVIDER" => "oidc",
                   "CYFR_OIDC_CLIENT_ID" => "cid",
                   "CYFR_OIDC_CLIENT_SECRET" => "secret"
                 })
               )

      assert msg =~ "CYFR_OIDC_ISSUER"
    end

    test "unknown value => error (closes the silent-no-auth footgun)" do
      assert {:error, msg} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_AUTH_PROVIDER" => "saml"}))

      assert msg =~ "Unknown CYFR_AUTH_PROVIDER"
    end

    test "blank string is treated as unset" do
      assert {:ok, nil} =
               RuntimeConfig.resolve_auth_provider(env(%{"CYFR_AUTH_PROVIDER" => "   "}))
    end
  end

  describe "resolve_storage/1" do
    test "unset => local default" do
      assert {:ok, :local} = RuntimeConfig.resolve_storage(env(%{}))
    end

    test "explicit local => local" do
      assert {:ok, :local} = RuntimeConfig.resolve_storage(env(%{"CYFR_STORAGE" => "local"}))
    end

    test "s3 with full credentials => {:s3, opts}" do
      assert {:ok, {:s3, opts}} =
               RuntimeConfig.resolve_storage(
                 env(%{
                   "CYFR_STORAGE" => "s3",
                   "CYFR_S3_BUCKET" => "b",
                   "CYFR_S3_REGION" => "us-east-1",
                   "CYFR_S3_ACCESS_KEY_ID" => "ak",
                   "CYFR_S3_SECRET_ACCESS_KEY" => "sk",
                   "CYFR_S3_PATH_STYLE" => "true",
                   "CYFR_S3_ENDPOINT" => "http://minio:9000"
                 })
               )

      assert opts[:bucket] == "b"
      assert opts[:region] == "us-east-1"
      assert opts[:access_key_id] == "ak"
      assert opts[:secret_access_key] == "sk"
      assert opts[:path_style] == true
      assert opts[:endpoint] == "http://minio:9000"
    end

    test "s3 omits absent optional keys" do
      assert {:ok, {:s3, opts}} =
               RuntimeConfig.resolve_storage(
                 env(%{
                   "CYFR_STORAGE" => "s3",
                   "CYFR_S3_BUCKET" => "b",
                   "CYFR_S3_REGION" => "us-east-1",
                   "CYFR_S3_ACCESS_KEY_ID" => "ak",
                   "CYFR_S3_SECRET_ACCESS_KEY" => "sk"
                 })
               )

      refute Keyword.has_key?(opts, :endpoint)
      refute Keyword.has_key?(opts, :prefix)
      assert opts[:path_style] == false
    end

    test "s3 missing a required var => error naming it" do
      assert {:error, msg} =
               RuntimeConfig.resolve_storage(
                 env(%{"CYFR_STORAGE" => "s3", "CYFR_S3_REGION" => "us-east-1"})
               )

      assert msg =~ "CYFR_S3_BUCKET"
    end

    test "unknown value => error" do
      assert {:error, msg} = RuntimeConfig.resolve_storage(env(%{"CYFR_STORAGE" => "gcs"}))
      assert msg =~ "Unknown CYFR_STORAGE"
    end
  end

  describe "resolve_postgres/1" do
    test "url present => opts with defaults" do
      assert {:ok, opts} =
               RuntimeConfig.resolve_postgres(
                 env(%{"CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db"})
               )

      assert opts[:url] == "postgres://u:p@h:5432/db"
      assert opts[:pool_size] == 20
      assert opts[:ssl] == false
    end

    test "honors pool size and ssl overrides" do
      assert {:ok, opts} =
               RuntimeConfig.resolve_postgres(
                 env(%{
                   "CYFR_DATABASE_URL" => "postgres://u:p@h:5432/db",
                   "CYFR_DB_POOL_SIZE" => "10",
                   "CYFR_DB_SSL" => "true"
                 })
               )

      assert opts[:pool_size] == 10
      assert opts[:ssl] == true
    end

    test "missing url => error (no silent localhost attempt)" do
      assert {:error, msg} = RuntimeConfig.resolve_postgres(env(%{}))
      assert msg =~ "CYFR_DATABASE_URL"
    end
  end
end
