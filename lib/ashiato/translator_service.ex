defmodule Ashiato.TranslatorService do
  @moduledoc """
  The provider-scoped translation cache in front of the configured `Ashiato.Translator`.

  `translate_page/2` resolves `Translator.impl/0` **once** and pins that module for
  both the cache label (`provider_name/0`) and the provider call, so a settings
  change mid-page can never mix providers. Rows in `translations` are keyed
  `(provider_name, target_lang, sha256(line))` and are global, shared by all users:
  switching provider never reads another provider's rows.

  A page whose every line has a fresh row — `fetched_at >= now - 2_592_000`, equality
  is fresh — is answered from the cache with zero provider calls. Any miss or expired
  row deletes the expired rows for the page's keys, then makes **one** pinned
  `provider.translate_page/2` call over the full input, so cross-line context
  survives, and returns exactly the provider output. Misses are inserted with
  `on_conflict: :nothing`: fresh rows are never overwritten, and duplicate source
  lines store the first occurrence's translation. Provider errors insert or
  overwrite nothing, though the expired-row cleanup may already have run. A missing,
  empty, or non-string `target_lang` is `{:error, :missing_target_lang}` with no
  provider call and no write.

  All cache reads, writes, and deletes pass `log: false`, so translated text never
  reaches the query log.
  """

  import Ecto.Query

  alias Ashiato.Repo
  alias Ashiato.Schemas.Translation
  alias Ashiato.Translator
  alias Ashiato.Utils

  @ttl_seconds 2_592_000

  @doc """
  Translates a page through the pinned provider, consulting the cache first.

  Accepts a `:now` opt (a `DateTime`) for deterministic tests; production omits it
  and uses `Utils.utc_now/0`.
  """
  @spec translate_page([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def translate_page(lines, opts) do
    with {:ok, {_source, lang}} <- Translator.langs(opts) do
      provider = Translator.impl()
      translate_cached(lines, opts, provider, provider.provider_name(), lang)
    end
  end

  @doc """
  Deletes every expired translation row and returns the deleted count.

  A row is expired when `fetched_at < now - 2_592_000`; equality stays. Accepts
  a `now` (a `DateTime`) for deterministic tests; production omits it and uses
  `Utils.utc_now/0`.
  """
  @spec prune_expired(DateTime.t()) :: {:ok, non_neg_integer()}
  def prune_expired(now \\ Utils.utc_now()) do
    cutoff = DateTime.add(now, -@ttl_seconds, :second)

    {deleted, _} =
      from(t in Translation, where: t.fetched_at < ^cutoff)
      |> Repo.delete_all(log: false)

    {:ok, deleted}
  end

  # ——————————————————————————————————————————————————————————— private ——————

  defp translate_cached([], _opts, _provider, _name, _lang), do: {:ok, []}

  defp translate_cached(lines, opts, provider, name, lang) do
    now = Keyword.get(opts, :now, Utils.utc_now())
    cutoff = DateTime.add(now, -@ttl_seconds, :second)
    hashes = lines |> Enum.map(&hash_line/1) |> Enum.uniq()

    fresh = fresh_translations(name, lang, hashes, cutoff)

    if Enum.all?(hashes, &Map.has_key?(fresh, &1)) do
      {:ok, Enum.map(lines, &Map.fetch!(fresh, hash_line(&1)))}
    else
      delete_expired(name, lang, hashes, cutoff)

      case provider.translate_page(lines, opts) do
        {:ok, output} ->
          cache_output(name, lang, lines, output, now)
          {:ok, output}

        error ->
          error
      end
    end
  end

  defp fresh_translations(name, lang, hashes, cutoff) do
    from(t in Translation,
      where:
        t.provider == ^name and t.lang == ^lang and t.source_hash in ^hashes and
          t.fetched_at >= ^cutoff,
      select: {t.source_hash, t.translated_text}
    )
    |> Repo.all(log: false)
    |> Map.new()
  end

  defp delete_expired(name, lang, hashes, cutoff) do
    from(t in Translation,
      where:
        t.provider == ^name and t.lang == ^lang and t.source_hash in ^hashes and
          t.fetched_at < ^cutoff
    )
    |> Repo.delete_all(log: false)
  end

  defp cache_output(name, lang, lines, output, now) do
    {rows, _seen} =
      lines
      |> Enum.zip(output)
      |> Enum.flat_map_reduce(MapSet.new(), fn {line, text}, seen ->
        hash = hash_line(line)

        if MapSet.member?(seen, hash) do
          {[], seen}
        else
          {[
             %{
               provider: name,
               lang: lang,
               source_hash: hash,
               translated_text: text,
               fetched_at: now
             }
           ], MapSet.put(seen, hash)}
        end
      end)

    Repo.insert_all(Translation, rows,
      on_conflict: :nothing,
      conflict_target: [:provider, :lang, :source_hash],
      log: false
    )
  end

  defp hash_line(line), do: Base.encode16(:crypto.hash(:sha256, line), case: :lower)
end
