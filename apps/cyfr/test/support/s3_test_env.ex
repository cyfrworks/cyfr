# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.S3Env do
  @moduledoc """
  Where the `:s3_integration` suites get their store.

  Every setting is an environment variable with a default that names the
  MinIO container the `s3-minio` CI job starts, so an ordinary run needs
  no environment at all and a person can point the same suites at a real
  S3 bucket by setting them:

  | Variable | Default |
  |---|---|
  | `CYFR_TEST_S3_ENDPOINT` | `http://127.0.0.1:9000` |
  | `CYFR_TEST_S3_BUCKET` | `cyfr-test` |
  | `CYFR_TEST_S3_REGION` | `us-east-1` |
  | `CYFR_TEST_S3_ACCESS_KEY_ID` | `cyfrtest` |
  | `CYFR_TEST_S3_SECRET_ACCESS_KEY` | `cyfrtest123` |
  | `CYFR_TEST_S3_PATH_STYLE` | `true` (MinIO needs it; AWS S3 does not) |
  | `CYFR_TEST_S3_CREATE_BUCKET` | `true`; `false` where the bucket exists and the keys may not create one |

  The credentials in the defaults are the non-secret CI fixtures the
  workflow passes to its own container, mirrored here so the two cannot
  drift.

  `configure!/1` writes the `:s3` application environment the adapter
  reads and answers the previous value for a caller to restore. `prefix:`
  scopes a suite's keys under one name, so two runs against one real
  bucket never meet.
  """

  @defaults %{
    endpoint: {"CYFR_TEST_S3_ENDPOINT", "http://127.0.0.1:9000"},
    bucket: {"CYFR_TEST_S3_BUCKET", "cyfr-test"},
    region: {"CYFR_TEST_S3_REGION", "us-east-1"},
    access_key_id: {"CYFR_TEST_S3_ACCESS_KEY_ID", "cyfrtest"},
    secret_access_key: {"CYFR_TEST_S3_SECRET_ACCESS_KEY", "cyfrtest123"}
  }

  @doc "The adapter configuration this run's store is reached with."
  @spec config(keyword()) :: keyword()
  def config(opts \\ []) do
    settings =
      for {key, {variable, default}} <- @defaults, do: {key, System.get_env(variable, default)}

    Keyword.merge(settings,
      path_style: env_flag("CYFR_TEST_S3_PATH_STYLE", true),
      prefix: Keyword.get(opts, :prefix)
    )
  end

  @doc """
  Point the adapter at this run's store, answering what `:s3` held before
  so a caller's `on_exit` can put it back.
  """
  @spec configure!(keyword()) :: keyword() | nil
  def configure!(opts \\ []) do
    previous = Application.get_env(:cyfr, :s3)
    Application.put_env(:cyfr, :s3, config(opts))
    previous
  end

  @doc "Put `:s3` back to what `configure!/1` answered."
  @spec restore(keyword() | nil) :: :ok
  def restore(nil), do: Application.delete_env(:cyfr, :s3)
  def restore(previous), do: Application.put_env(:cyfr, :s3, previous)

  @doc """
  Create the bucket unless `CYFR_TEST_S3_CREATE_BUCKET` says not to — a
  bucket that already exists answers 409, and both outcomes leave a
  usable bucket. A store that refuses raises with its own error code,
  which is the whole diagnosis: `SignatureDoesNotMatch`,
  `InvalidAccessKeyId` and `AccessDenied` are all 403 and have nothing
  to do with each other.
  """
  @spec create_bucket!() :: :ok
  def create_bucket! do
    if env_flag("CYFR_TEST_S3_CREATE_BUCKET", true), do: put_bucket!(), else: :ok
  end

  defp put_bucket! do
    settings = config()
    url = "#{settings[:endpoint]}/#{settings[:bucket]}"

    # Only the host: sign_v4 supplies X-Amz-Content-SHA256 for the body it
    # hashes, and a second copy signs the name twice (see Arca.Adapters.S3).
    signed =
      :aws_signature.sign_v4(
        settings[:access_key_id],
        settings[:secret_access_key],
        settings[:region],
        "s3",
        :calendar.universal_time(),
        "PUT",
        url,
        [{"host", URI.parse(url).authority}],
        "",
        # S3 does not re-encode its canonical URI; see Arca.Adapters.S3.
        [{:uri_encode_path, false}]
      )

    {:ok, %{status: status, body: body}} =
      Req.request(
        method: :put,
        url: url,
        headers: Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end),
        body: "",
        decode_body: false
      )

    if status in [200, 409],
      do: :ok,
      else: raise("could not create bucket #{settings[:bucket]}: HTTP #{status} #{inspect(body)}")
  end

  defp env_flag(variable, default) do
    case System.get_env(variable) do
      nil -> default
      value -> String.downcase(value) in ["1", "true", "yes"]
    end
  end
end
