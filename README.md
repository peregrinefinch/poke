# poke

[![Package Version](https://img.shields.io/hexpm/v/poke?style=for-the-badge&color=75618E)](https://hex.pm/packages/poke)
[![Hex Docs](https://img.shields.io/website?url=https%3A%2F%2Fpoke.hexdocs.pm%2F&style=for-the-badge&label=hex&up_message=docs&up_color=FF891F&down_message=not%20found&down_color=lightgrey)](https://poke.hexdocs.pm/)
[![Tests](https://img.shields.io/github/actions/workflow/status/peregrinefinch/poke/test.yml?branch=main&style=for-the-badge&label=tests)](https://github.com/peregrinefinch/poke/actions/workflows/test.yml)

Poke your code to find bugs!

Assertions, properties, regressions, snapshots, fixtures, state models and
process tests for Pooka.

```pooka
import poke/should

test "a small sum" {
  should.equal(1 + 1, 2)
  Ok(Some(42)) |> should.be_ok() |> should.be_some() |> should.equal(42)
}
```

Add Poke as a development dependency:

```sh
pooka add poke --dev
```

Run `pooka test`. Review snapshots with `pooka run -m poke review`.
Snapshots live in `test/snapshots`; `poke/pretty` formats values as plain text.
Read the [testing guide](docs/guide.md) for the rest of the toolkit.

## Licence

Licensed under the [Apache License, Version 2.0](LICENSE).
