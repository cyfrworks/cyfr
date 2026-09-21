# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PublicationContractS3Test do
  @moduledoc """
  `Arca.PublicationContract` against a real S3-compatible store: the same
  body `publication_contract_test.exs` runs, with `Arca.Adapters.S3`
  under the faults.

  This is where the write protocol meets a store that has no rename, no
  directories and a conditional write it must ask the server for. The
  double stands in for that shape in every run; only a real store proves
  it — the ETag a precondition is, the key listing a staging area is
  read with, and a move to the served location made object by object
  because `c:Arca.Storage.replace_tree/3` is not there.

  Excluded from ordinary runs. The `s3-minio` CI job runs it with
  `mix test --only s3_integration` against its pinned
  MinIO container; `Arca.Test.S3Env` names the variables that point it
  at another store instead. Each run stages under a prefix of its own, so
  two runs against one bucket never meet.
  """

  use Arca.PublicationContract,
    adapters: [%{adapter: Arca.Adapters.S3}],
    moduletag: :s3_integration

  setup_all do
    previous = Arca.Test.S3Env.configure!(prefix: "publication/#{System.system_time(:second)}")
    :ok = Arca.Test.S3Env.create_bucket!()

    on_exit(fn -> Arca.Test.S3Env.restore(previous) end)
    :ok
  end
end
