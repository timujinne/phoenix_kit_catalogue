# Gettext catalogues in phoenix_kit_catalogue

Why `priv/gettext/default.pot` is hand-maintained, and what `mix gettext.extract`
and `mix gettext.merge` actually do to it.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions.

## The situation

The module has its own backend, `PhoenixKitCatalogue.Gettext`. Almost every
string goes through the *runtime function* call
`Gettext.gettext(PhoenixKitCatalogue.Gettext, "…")` (~1100 sites) rather than
the `gettext("…")` macro, and the extractor only sees macros. So
`priv/gettext/default.pot` is hand-maintained: new msgids are added **by hand**
to `default.pot` and to every locale under `priv/gettext/`, and pinned in
`test/gettext_test.exs`.

## The trap that makes this worth spelling out

`mix gettext.extract` **merges into** an existing `.pot` rather than replacing
it. Run it with the committed file in place and it reports a near-identical
catalogue — nearly every msgid "extracted" — because it *kept* them. That looks
like proof the warning is stale. It isn't: delete the `.pot` first and the same
command yields the macro-form minority. Only the entries carrying
`#, elixir-autogen` came from extraction (currently ~110 of ~1020 msgids in the
file), which is the honest count of what extraction actually contributes.

So `mix gettext.merge priv/gettext` is safe **only** while the `.pot` still
holds the hand-added entries. Against a freshly regenerated one it would strip
the ~900 hand-added msgids from every `.po` file, since `on_obsolete: :delete`
is the default.

## The narrower extraction gap

The runtime form is **not** extracted from inside a HEEx attribute
interpolation (`title={Gettext.gettext(…)}`) even when the module carries
`use Gettext`. `web/components.ex` uses the macro there for that reason.

## The real fix

Convert the call sites to the macro form and add
`use Gettext, backend: PhoenixKitCatalogue.Gettext` per module, at which point
extraction works normally. Several files already do (`web/table_config.ex`,
`web/catalogues_live.ex`, `web/components.ex`, `web/item_form_live.ex`,
`web/category_form_live.ex`, `web/catalogue_detail_live.ex`,
`web/translations_live.ex`, and the three browse/selector components). Until
the rest follow, treat the catalogues as hand-edited files.
