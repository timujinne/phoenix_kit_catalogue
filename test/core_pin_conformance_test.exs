defmodule PhoenixKitCatalogue.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR (the three-segment trap), and against a local path override
  reaching a commit.

  The trap is the three-segment form: `~> 2.8.x` expands to
  `>= 2.8.x and < 2.9.0`, so no 2.9 or later core satisfies it. The breakage
  lands on CONSUMERS, never here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get` fails
  outright, with no degraded mode. Nothing else in this repo's own test run
  would notice, which is why the check is a test rather than a convention.

  The floor is `>= 2.34.0 and < 3.0.0`: the Events page and the bulk bar use
  `PhoenixKit.Activity.split_changes/1`, `humanize_metadata_key/1` and
  `bulk_select_scope`'s `swap`, all first shipped in core 2.34.0 (#837) — on
  an older core the Events page raises on any entry with metadata.

  Before that it was `>= 2.13.11 and < 3.0.0` (raised from `~> 2.8`, addressing
  a catalogue V01 review finding): the V01 adoption chain
  (`PhoenixKitCatalogue.Migrations`) transcribes core's V178–V180 shape
  (`crm_company_uuid`, `manufacturer_source`/`supplier_source`, the
  dropped FKs), which first ships in core 2.13.4 (#743) — but 2.13.4
  through 2.13.10 crash applying V180 itself (a bare `LOCK TABLE` outside
  a transaction), fixed only in 2.13.11. A lower pin would let
  `mix deps.get` resolve to a core release whose own migration chain
  can't reach the shape this module assumes. `~> 2.13.11` (three-segment)
  would fall right back into the trap this test exists to catch — it
  admits only the 2.13 minor — so the floor is the compound form instead:
  patch-precise at the bottom, still open through every later 2.x minor
  at the top, same as `~> 2.8` was before it.
  """

  @must_admit ["2.34.0", "2.34.3", "2.35.0", "2.50.0"]
  @must_reject ["1.7.236", "2.3.0", "2.8.0", "2.13.4", "2.13.11", "2.33.0", "3.0.0"]

  test "the :phoenix_kit requirement admits every core >= 2.34.0 minor and nothing else" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor breaks `mix deps.get` for every host " <>
               "running this module alongside that core. Keep the floor patch-precise " <>
               "and the ceiling open (`>= 2.34.0 and < 3.0.0`), never a three-segment `~>`."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against."
    end
  end

  # Resolution order matters. `Mix.Project.config()` is exact, but it reports the
  # dep as it resolved THIS run — and `pk_dep/3` rewrites it to a `path:` tuple
  # whenever PHOENIX_KIT_PATH is exported, which is the workspace's sanctioned way
  # to run this suite against unreleased core. Reading the committed literal from
  # mix.exs as a fallback keeps the check meaningful under that override instead
  # of failing the documented workflow — and it still fails when a path dep is
  # COMMITTED, because then there is no literal left to find.
  defp core_requirement do
    resolved_requirement() || committed_requirement() ||
      flunk("""
      No version requirement found for `:phoenix_kit`.

      Neither the resolved dep nor mix.exs carries one, which means a `path:`
      dep has been committed. That ships a broken package and breaks every
      other consumer's build — restore the published requirement.
      """)
  end

  defp resolved_requirement do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.find_value(fn
      {:phoenix_kit, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
  end

  # First match wins, matching how every other tool in the workspace reads this
  # pin. Covers both the bare `{:phoenix_kit, "..."}` and the `pk_dep(:phoenix_kit,
  # "...")` forms, since the captured text is identical in each.
  defp committed_requirement do
    case Regex.run(~r/:phoenix_kit,\s*"([^"]+)"/, File.read!("mix.exs")) do
      [_full, requirement] -> requirement
      _ -> nil
    end
  end
end
