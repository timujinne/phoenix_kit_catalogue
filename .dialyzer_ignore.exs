[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2. Known upstream false positive.
  {"lib/phoenix_kit_catalogue/gettext.ex", :call_without_opaque}
]
