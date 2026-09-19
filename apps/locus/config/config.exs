# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A standalone Locus build and test run (`cd apps/locus`) needs no
# compile-time configuration: every setting has its default in
# `Locus.Config`. Umbrella builds supply the root application's config,
# and the `locus` release reads its `LOCUS_BUILDS_*` environment through
# `config/locus_runtime.exs`.
import Config
