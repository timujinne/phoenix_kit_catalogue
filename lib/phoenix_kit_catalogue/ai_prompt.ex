defmodule PhoenixKitCatalogue.AIPrompt do
  @moduledoc """
  Idempotent provisioning of the catalogue's AI-translation prompts.

  `PhoenixKitAI.Translations.default_prompt_uuid/0` (the shared
  `phoenixkit-translate-content` prompt) hard-codes six field slots
  (`name`/`title`/`summary`/`description`/`body`/`content`) and none of
  those match `catalogue_set_label`'s/`catalogue_set_value`'s vocabulary
  (`label`/`title`) either — every catalogue call would render the
  unmatched slots as literal, unbound `{{placeholder}}` text (the engine
  substitutes variables globally, with no notion of "this field wasn't
  sent"), and a call binding only `label` or only `title` would fail
  `{:missing_fields, [...]}` outright since the shared template has no
  such slot at all. This module gives catalogue its own two prompts
  instead:

    * `ensure_prompt/0` — items/categories, vocabulary `name`/
      `description`/`summary`/`seo_title`/`seo_description`.
    * `ensure_sets_prompt/0` — attribute-set labels/value titles,
      vocabulary `label`/`title`.

  Both carry the same measurement-unit rule the shared prompt has no
  reason to carry — attribute values (e.g. sizes) are exactly where units
  show up.

  ## Glossary

  Both templates carry a `{{Glossary}}` slot, which
  `PhoenixKitAI.Translation.build_variables/4` binds from the operator's
  configured terminology (`PhoenixKitAI.Translations.glossary/1`, keyed
  per target language). It renders as exactly nothing when no glossary is
  configured — the bound value carries its own heading, so an install
  without one gets no terminology instruction at all, only the blank line
  the empty slot leaves behind.

  A glossary matters more here than anywhere else in PhoenixKit: a
  catalogue's value is that the same term reads the same way across every
  product, and left to itself a model renders "Materials and finish" as
  both `Materialien und Finish` and `Material und Oberfläche` across
  neighbouring items.

  Unlike the shared `phoenixkit-translate-content` prompt — created once
  and never rewritten, so existing installs must add the slot themselves —
  these two are content-addressed (see Rollout below), so the slot reaches
  every install on the next call after deploy without an operator doing
  anything.

  ## Source block and Markdown

  On a `phoenix_kit_ai` that binds `{{SourceFields}}` (0.23.0 and later,
  detected by capability), both templates take their SOURCE block from it:
  one `---MARKER---` section per field the call actually passes, and no
  per-field `{{name}}`/`{{label}}` slots. A slot a call did not bind used
  to reach the model as literal text; told to skip it, the model skipped it
  and then wrote a note saying so, which was stored with the translation.
  An older engine gets the per-field slots and the skip rule, as before.

  Both templates also state that a value's Markdown — `##`/`###`
  headings above all — belongs inside that value: models imitating the
  marker format turned a description's headings into marker lines of their
  own, which cut the description short.

  ## Rollout

  Each prompt is content-addressed: `ensure_prompt/0`/`ensure_sets_prompt/0`
  are idempotent by their own slug, and `Prompt.metadata["content_sha"]`
  (sha256 hex of the template as `content/2`/`sets_content/2` render it
  for the installed `phoenix_kit_ai`) tells them whether the stored row
  still matches. Editing a template and redeploying makes the next call
  update the stored prompt in place and keep the same uuid — no version
  counter, because the content already is the version.
  """

  alias PhoenixKitAI.Prompt

  # `PhoenixKitAI.create_prompt/1` derives a prompt's slug from its name
  # via `PhoenixKit.Utils.Slug.slugify/1`, overriding any `:slug` passed at
  # creation time — so each name below MUST slugify to its matching slug,
  # or the idempotency lookup never matches and every call re-attempts the
  # create (same constraint `PhoenixKitAI.Translations` documents for its
  # own shared prompt's `@prompt_name`/`@prompt_slug` pair).
  @name "PhoenixKit Catalogue Translation"
  @slug "phoenixkit-catalogue-translation"
  @sets_name "PhoenixKit Catalogue Set Translation"
  @sets_slug "phoenixkit-catalogue-set-translation"
  @managed_by "phoenix_kit_catalogue"

  # Each template is assembled from the pieces below: the prompt's own
  # rules, the rules both prompts share, and a SOURCE block in one of two
  # forms depending on the installed engine (see `content/2`).
  @item_rules """
  Translate the following catalogue fields from {{SourceLanguage}} to {{TargetLanguage}}.

  RULES:
  - Preserve formatting exactly (line breaks, spacing).
  - Measurements keep their numbers and unit abbreviations unchanged (e.g.
    "30 cm" stays "30 cm"); translate the unit WORDS themselves instead
    (e.g. "inches" becomes the target language's word for inches), never
    their abbreviations.
  - Keep any "|" separators in the source text exactly as they appear, in
    the same positions.
  - The translated seo_title must stay at or under 70 characters.
  """

  # Attribute-set labels and value titles are short standalone strings
  # (e.g. a set's display name, or a size/color value's title) — the same
  # unit rule as the item prompt applies (a value title is exactly where
  # "30 cm" / "12 inches" shows up), but there is no description/SEO
  # vocabulary here, and no separate "|"-joined multi-part text either.
  @sets_rules """
  Translate the following catalogue attribute-set fields from {{SourceLanguage}} to {{TargetLanguage}}.

  RULES:
  - Preserve formatting exactly (line breaks, spacing).
  - Measurements keep their numbers and unit abbreviations unchanged (e.g.
    "30 cm" stays "30 cm"); translate the unit WORDS themselves instead
    (e.g. "inches" becomes the target language's word for inches), never
    their abbreviations.
  """

  # A shop's `summary` can be the description's first ~500 characters, cut
  # mid-sentence; without the first rule a model continued it past the cut
  # (1976 characters of de-DE for a 500-character source).
  #
  # Descriptions are Markdown with `## Section` headings. Without the second
  # rule, models imitating the `---FIELD---` output format turned each
  # heading into a marker line of its own (`---MINIATURE_DETAILS---`,
  # `---SIZE AND USABLE SPACE---`), which cut the description short.
  @shared_rules """
  - Translate each field's text exactly as given — do not complete, extend
    or summarise it. If the source ends mid-sentence, end the translation
    at the same point.
  - A field's value may contain Markdown: headings (`##`, `###`), lists,
    links and blank lines. All of it belongs to that one field — reproduce
    it inside that field's section with the same structure, translating
    the heading text and keeping its `##`/`###`. Never turn a heading, or
    any other line of a value, into a marker line: the response has one
    marker line per translated field and no others.
  - Output ONLY the marker lines and their translated text described
    below. Nothing else — no commentary, no preface, no closing remarks,
    no notes, no parenthetical asides, no explanations of what you did or
    did not translate. The response must end immediately after the last
    marker's translated value.

  {{Glossary}}

  """

  # The engine binds `{{SourceFields}}` to one `---MARKER---` section per
  # field the caller actually passed, so the rendered prompt only ever
  # names fields that are there — no unbound `{{summary}}` for the model to
  # skip and then write a note about skipping.
  @source_fields_block """
  OUTPUT FORMAT — the SOURCE block below holds one section per field, each
  opened by that field's marker line. Emit exactly those marker lines, each
  followed by that field's translated value:

      ---<FIELD_NAME_UPPERCASE>---
      [translated value]

  === SOURCE ===

  {{SourceFields}}
  """

  # An engine without `{{SourceFields}}` only substitutes named slots, one
  # per possible field; a slot the call does not bind stays literal, and
  # this rule tells the model to skip it.
  @unbound_slot_rule """
  - A field below whose value still looks like an unfilled template slot —
    its own field name wrapped in a pair of double curly braces, with no
    real text — was never bound by the caller. As far as you are
    concerned, that field DOES NOT EXIST: skip it silently, do not emit a
    marker for it, do not translate that literal text, and NEVER mention,
    list, count, or comment on it or any other missing/omitted/skipped
    field anywhere in your response.
  """

  @per_field_block """
  OUTPUT FORMAT — for each field below that has a real (non-placeholder,
  non-blank) value, emit ONE marker named after the field (uppercase),
  followed by the translation, and nothing else:

      ---<FIELD_NAME_UPPERCASE>---
      [translated value]

  === SOURCE ===

  """

  @item_slots """
  Name: {{name}}

  Description: {{description}}

  Summary: {{summary}}

  Seo_title: {{seo_title}}

  Seo_description: {{seo_description}}
  """

  @sets_slots """
  Label: {{label}}

  Title: {{title}}
  """

  @doc "The item/category translation prompt's slug — stable across redeploys."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The attribute-set translation prompt's slug — stable across redeploys."
  @spec sets_slug() :: String.t()
  def sets_slug, do: @sets_slug

  @doc """
  Ensures the catalogue item/category translation prompt exists and
  matches this module's current template, creating or updating it as
  needed.

  Idempotent by slug: repeated calls return the same uuid as long as the
  template hasn't changed. When it has (a redeploy shipped an edited
  template), the next call updates the stored prompt in place and keeps
  the same uuid — callers holding an old `prompt_uuid` still resolve to
  the current rules.
  """
  # The `glossary_slot?` argument exists for the same reason `content/2`'s
  # does: the upgrade round trip this rollout promises — a prompt stored by
  # a pre-binding install, rewritten in place with the slot once
  # `phoenix_kit_ai` is upgraded, same uuid — cannot be observed at all
  # without driving the capability, only inferred from reading
  # `maybe_update/2`. Defaults to the detected capability, so every caller
  # is unaffected. `source_fields?` is the same kind of argument for the
  # engine's `{{SourceFields}}` block.
  @spec ensure_prompt(boolean(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def ensure_prompt(
        glossary_slot? \\ glossary_slot_supported?(),
        source_fields? \\ source_fields_supported?()
      ) do
    ensure(
      @slug,
      @name,
      content(glossary_slot?, source_fields?),
      "Catalogue item/category translation: name, description, summary, SEO title/description."
    )
  end

  @doc """
  Ensures the catalogue attribute-set translation prompt (labels and
  value titles) exists and matches this module's current template — same
  idempotent-by-slug, content-addressed rollout as `ensure_prompt/0`,
  under its own slug so it never collides with the item/category prompt
  or the shared `phoenixkit-translate-content` one.
  """
  @spec ensure_sets_prompt(boolean(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def ensure_sets_prompt(
        glossary_slot? \\ glossary_slot_supported?(),
        source_fields? \\ source_fields_supported?()
      ) do
    ensure(
      @sets_slug,
      @sets_name,
      sets_content(glossary_slot?, source_fields?),
      "Catalogue attribute-set translation: set label, value title."
    )
  end

  @glossary_slot "{{Glossary}}\n\n"

  @doc false
  # The item/category template as it should be stored RIGHT NOW: with the
  # `{{Glossary}}` slot when the installed `phoenix_kit_ai` binds that
  # variable, without it when it doesn't.
  #
  # Not a constant, because whether the slot is safe is a property of the
  # installed dependency, not of this source file. `mix.exs` pinned
  # `phoenix_kit_ai` loosely (`~> 0.18`) when this was written, and the
  # binding arrived much later — so on an older AI the slot would reach the model as the literal
  # text `{{Glossary}}`. That is not a cosmetic blemish: both templates
  # instruct the model that a value which "looks like an unfilled template
  # slot" is to be skipped silently, so a literal `{{Glossary}}` lands in
  # the RULES section as an instruction about nothing, in a prompt whose
  # whole point is that the model follows its rules exactly.
  #
  # Feature detection rather than a version bump: a version constraint
  # would have to name a release that does not exist yet, and would force
  # this repo and `phoenix_kit_ai` to merge in a fixed order. The capability
  # answers the only question that matters — does the engine bind it?
  #
  # Because both prompts are content-addressed (`content_sha` below), an
  # install that later upgrades `phoenix_kit_ai` picks the slot up on the
  # next `ensure_prompt/0` call, with no operator action; one that
  # downgrades loses it the same way.
  #
  # The flag is an argument with a default rather than an inlined call so a
  # test can drive BOTH branches deterministically — otherwise the only
  # assertion available is "whatever this install does", which passes either
  # way and proves nothing about the branch that is not taken here.
  #
  # `source_fields?` picks the SOURCE block the same way. With the engine's
  # `{{SourceFields}}` block the template names no field of its own, so a
  # call binding only `name` and `description` renders no leftover
  # `{{summary}}`/`{{seo_title}}` slot. Without it (an engine older than the
  # block), the template keeps one slot per field and the rule to skip the
  # unbound ones.
  @spec content(boolean(), boolean()) :: String.t()
  def content(
        glossary_slot? \\ glossary_slot_supported?(),
        source_fields? \\ source_fields_supported?()
      ),
      do:
        @item_rules |> template(@item_slots, source_fields?) |> with_glossary_slot(glossary_slot?)

  @doc false
  @spec sets_content(boolean(), boolean()) :: String.t()
  def sets_content(
        glossary_slot? \\ glossary_slot_supported?(),
        source_fields? \\ source_fields_supported?()
      ),
      do:
        @sets_rules |> template(@sets_slots, source_fields?) |> with_glossary_slot(glossary_slot?)

  @doc false
  # Whether the installed `PhoenixKitAI.Translation` binds `{{Glossary}}`.
  # `build_variables/4` is the arity that takes the glossary; the older
  # engine only has `/3`.
  @spec glossary_slot_supported?() :: boolean()
  def glossary_slot_supported? do
    Code.ensure_loaded?(PhoenixKitAI.Translation) and
      function_exported?(PhoenixKitAI.Translation, :build_variables, 4)
  end

  @doc false
  # Whether the installed `PhoenixKitAI.Translation` binds `{{SourceFields}}`.
  # `build_variables/3` arrived in the release that started binding it; an
  # engine without the function binds neither.
  @spec source_fields_supported?() :: boolean()
  def source_fields_supported? do
    Code.ensure_loaded?(PhoenixKitAI.Translation) and
      function_exported?(PhoenixKitAI.Translation, :build_variables, 3)
  end

  defp template(rules, _slots, true), do: rules <> @shared_rules <> @source_fields_block

  defp template(rules, slots, false),
    do: rules <> @unbound_slot_rule <> @shared_rules <> @per_field_block <> slots

  defp with_glossary_slot(template, true), do: template

  defp with_glossary_slot(template, false),
    do: String.replace(template, @glossary_slot, "", global: false)

  defp ensure(slug, name, content, description) do
    case PhoenixKitAI.get_prompt_by_slug(slug) do
      nil -> create_prompt(slug, name, content, description)
      %Prompt{} = prompt -> maybe_update(prompt, content)
    end
  end

  defp create_prompt(slug, name, content, description) do
    attrs = %{
      name: name,
      slug: slug,
      description: description,
      content: content,
      metadata: %{"managed_by" => @managed_by, "content_sha" => content_sha(content)}
    }

    case PhoenixKitAI.create_prompt(attrs) do
      {:ok, %Prompt{} = prompt} ->
        {:ok, prompt.uuid}

      # Lost a create race — another node inserted the same slug first.
      # Re-read it and fall through the same up-to-date check below; per
      # the module doc, both writers agree on the template, so this is
      # idempotent either way.
      {:error, %Ecto.Changeset{}} ->
        case PhoenixKitAI.get_prompt_by_slug(slug) do
          nil -> {:error, :prompt_unavailable}
          %Prompt{} = prompt -> maybe_update(prompt, content)
        end
    end
  end

  defp maybe_update(%Prompt{metadata: metadata} = prompt, content) do
    sha = content_sha(content)

    if Map.get(metadata || %{}, "content_sha") == sha do
      {:ok, prompt.uuid}
    else
      attrs = %{
        content: content,
        metadata: Map.merge(metadata || %{}, %{"managed_by" => @managed_by, "content_sha" => sha})
      }

      case PhoenixKitAI.update_prompt(prompt, attrs) do
        {:ok, %Prompt{} = updated} -> {:ok, updated.uuid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp content_sha(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
