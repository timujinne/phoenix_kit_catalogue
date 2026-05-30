defmodule PhoenixKitCatalogue.Catalogue.PdfQueueGuardTest do
  @moduledoc """
  Pure-decision tests for the PDF-extraction enqueue guard
  (`PdfLibrary.queue_runnable?/1`). No DB / no Oban needed — the guard
  decides, from an Oban config, whether a `:catalogue_pdf` job can
  actually be processed. Refusing to enqueue when it can't is what
  prevents the "hundreds of dead jobs" pile-up.

  The end-to-end "mark the extraction failed when unavailable" wiring is
  covered by the integration test in `PhoenixKitCatalogue.Catalogue.PdfLibraryTest`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.PdfLibrary

  describe "queue_runnable?/1" do
    test "true when :catalogue_pdf is configured (production, testing disabled)" do
      assert PdfLibrary.queue_runnable?(%{
               testing: :disabled,
               queues: [default: 10, catalogue_pdf: 2]
             })
    end

    test "false when :catalogue_pdf is absent — the misconfiguration that spammed Oban" do
      refute PdfLibrary.queue_runnable?(%{testing: :disabled, queues: [default: 10, sitemap: 5]})
    end

    test "false when no queues are configured at all" do
      refute PdfLibrary.queue_runnable?(%{testing: :disabled, queues: []})
    end

    test "true in :manual testing mode even without the queue (host integration tests)" do
      assert PdfLibrary.queue_runnable?(%{testing: :manual, queues: []})
    end

    test "true in :inline testing mode even without the queue" do
      assert PdfLibrary.queue_runnable?(%{testing: :inline, queues: [default: 10]})
    end

    test "missing :testing defaults to disabled — queue presence then decides" do
      refute PdfLibrary.queue_runnable?(%{queues: [default: 10]})
      assert PdfLibrary.queue_runnable?(%{queues: [catalogue_pdf: 2]})
    end

    test "missing :queues defaults to empty" do
      refute PdfLibrary.queue_runnable?(%{testing: :disabled})
    end

    test "works against a real %Oban.Config{} struct (not just a plain map)" do
      # The production caller passes `Oban.config()`, a struct — make
      # sure `Map.get`/`Keyword.has_key?` behave the same against it.
      runnable = struct(Oban.Config, testing: :disabled, queues: [catalogue_pdf: 2])
      not_runnable = struct(Oban.Config, testing: :disabled, queues: [default: 10])

      assert PdfLibrary.queue_runnable?(runnable)
      refute PdfLibrary.queue_runnable?(not_runnable)
    end
  end
end
