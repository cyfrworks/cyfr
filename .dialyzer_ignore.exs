# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Dialyzer warning filters, configured by mix.exs.
# Each entry is {app_relative_file, warning_kind}, or a regex over the raw
# warning text, with the reason the warning is accepted in a comment
# directly above it (apps/cyfr/test/cyfr/dialyzer_ignore_reasons_test.exs
# refuses an entry without one). Remove an entry, with its reason, when its
# last matching warning is fixed; list_unused_filters fails on unused
# entries. Review the reported warning before adding a filter.
[
  # Ecto.Multi.run/3's success typing reaches Erlang's `:sets` through the
  # MapSet calls on the multi's `names`, so Dialyzer expects that field to
  # be the opaque `:sets.set/1`. Ecto.Multi.new/0's struct literal holds the
  # empty map `:sets.new(version: 2)` builds there (MapSet itself types the
  # field as term()), and Dialyzer reports each Ecto.Multi.run/3 on it as a
  # call without the opaque term. The struct and the pipeline are Ecto's
  # public API.
  {"lib/arca/consent_storage.ex", :call_without_opaque},
  # The same Ecto.Multi.new/0 literal handed to Ecto.Multi.run/3, in
  # prepare_transaction/2.
  {"lib/arca/repo.ex", :call_without_opaque},
]
