# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.Newcomers do
  @moduledoc """
  What a local admission brings beside its first proof
  (`Sanctum.Newcomer`): the new person's identity, as the trusted form or
  the command line draws it, and the directory a deployment pins, without
  which no local person is admitted.

  `identity/1` is the parsed identity a credential carries, and `fields/1`
  the same identity as a surface sends it (`Sanctum.Newcomer.identity/1`
  parses it back). `directory!/1` pins a directory for the calling test
  and restores the setting on exit; an admission names it in the genesis
  and sends nothing to it.
  """

  @directory "https://dir-a.test"

  @doc "The directory `directory!/0` pins."
  def directory, do: @directory

  @doc """
  A new person's identity: `name` (a fresh one when nil), a fresh 32-byte
  recovery secret and a request id of `req_` and 32 hex digits.
  """
  def identity(name \\ nil) do
    %{
      name: name || "n#{System.unique_integer([:positive])}",
      recovery_secret: :crypto.strong_rand_bytes(32),
      request_id: "req_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }
  end

  @doc "`identity` as a surface's fields: the secret in unpadded base64url."
  def fields(identity \\ identity()) do
    %{
      "name" => identity.name,
      "recovery_secret" => Base.url_encode64(identity.recovery_secret, padding: false),
      "request_id" => identity.request_id
    }
  end

  @doc "Pin `url` as this deployment's directory for the calling test."
  def directory!(url \\ @directory),
    do: Prima.Test.Env.put_app_env(:sanctum, :directory_url, url)
end
