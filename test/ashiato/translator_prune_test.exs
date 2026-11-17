defmodule Ashiato.TranslatorPruneTest do
  @moduledoc """
  Drives the 30-day prune: the exact cutoff boundary, the returned count, and
  the worker's `perform/1` against the real clock.
  """

  use Ashiato.DataCase, async: false

  alias Ashiato.Schemas.Translation
  alias Ashiato.TranslatorService
  alias Ashiato.TranslatorService.PruneWorker
  alias Ashiato.Utils

  @now ~U[2026-11-16 12:00:00Z]
  @cutoff DateTime.add(@now, -2_592_000, :second)

  test "prune_expired/1 deletes rows older than the cutoff and returns the count" do
    insert_translation("fake", "en", "甲", "at-cutoff", @cutoff)
    insert_translation("fake", "en", "乙", "one-second-older", DateTime.add(@cutoff, -1, :second))
    insert_translation("other", "fr", "甲", "other-fresh", @now)

    assert TranslatorService.prune_expired(@now) == {:ok, 1}

    assert %Translation{translated_text: "at-cutoff"} = row("fake", "en", "甲")
    refute row("fake", "en", "乙")
    assert %Translation{translated_text: "other-fresh"} = row("other", "fr", "甲")
  end

  test "PruneWorker.perform/1 deletes only expired rows and returns :ok" do
    insert_translation(
      "fake",
      "en",
      "丙",
      "31-days-old",
      DateTime.add(Utils.utc_now(), -31 * 86_400, :second)
    )

    insert_translation("fake", "en", "丁", "fresh", Utils.utc_now())

    assert PruneWorker.perform(%Oban.Job{}) == :ok

    refute row("fake", "en", "丙")
    assert %Translation{translated_text: "fresh"} = row("fake", "en", "丁")
  end

  defp insert_translation(provider, lang, line, text, fetched_at) do
    %Translation{}
    |> Ecto.Changeset.change(%{
      provider: provider,
      lang: lang,
      source_hash: hash(line),
      translated_text: text,
      fetched_at: fetched_at
    })
    |> Repo.insert!()
  end

  defp row(provider, lang, line) do
    Repo.get_by(Translation, provider: provider, lang: lang, source_hash: hash(line))
  end

  defp hash(line), do: Base.encode16(:crypto.hash(:sha256, line), case: :lower)
end
