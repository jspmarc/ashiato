defmodule Ashiato.Translator do
  @moduledoc """
  Translation provider behaviour.

  A page is translated in **one request** so cross-line context survives. Providers
  return line-aligned text; when a page reply does not carry the same number of
  lines as the input — or cannot be interpreted at all — the shared wrapper in this
  module falls back to one request per line, so the rule lives in exactly one place
  and no provider can forget it.

  Options accepted by `translate_page/2`:

    * `:source_lang` — ISO code of the source language, e.g. `"ja"`. Defaults to
      `"auto"`, which every provider either supports natively or omits.
    * `:target_lang` — ISO code of the target language, e.g. `"en"`. Required;
      without it providers return `{:error, :missing_target_lang}`.
    * `:api_key` — credential for `deepl` and `google_cloud`. Passed in by the
      settings context; never logged.
    * `:model` — model name for `llm`; see `Ashiato.Translator.Llm`.

  Known providers, selectable as `config :ashiato, Ashiato.Translator, provider: ...`
  by atom: `:google_free` (default), `:llm`, `:deepl`, `:google_cloud`, `:off` — or
  directly as a module.

  **No caching in this module.** Nothing here logs the text being translated or any
  credential, and an unconfigured provider returns `{:error, :not_configured}`
  instead of raising.
  """

  @callback translate_page(lines :: [String.t()], opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @callback page_request(lines :: [String.t()], opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks page_request: 2

  require Logger

  # Keyed by the string the settings table stores (`translation_provider` is JSON, so it
  # comes back as a binary), which also accepts the atom form.
  @providers %{
    "google_free" => Ashiato.Translator.GoogleFree,
    "llm" => Ashiato.Translator.Llm,
    "deepl" => Ashiato.Translator.Deepl,
    "google_cloud" => Ashiato.Translator.GoogleCloud,
    "off" => Ashiato.Translator.Off
  }

  @doc """
  Includes the shared page-then-per-line wrapper in a provider module.

  A provider only defines `page_request(lines, opts) :: {:ok, [String.t()]} |
  {:error, term()}` — the attempt to translate the whole page in one request — and
  this macro turns it into a full `translate_page/2` implementation with the
  fallback rule applied.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Ashiato.Translator

      # Providers call the shared helpers by their short name (`Translator.langs/1`,
      # `Translator.http_post/2`), so the alias belongs in the macro, not in each file.
      alias Ashiato.Translator

      @doc false
      @impl Ashiato.Translator
      @spec translate_page([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
      def translate_page(lines, opts) do
        Ashiato.Translator.run_provider(__MODULE__, lines, opts, &page_request/2)
      end
    end
  end

  @doc """
  The configured provider module, or `Ashiato.Translator.Off` when the configured value
  names no provider.

  Defaults to `:google_free`. An unknown provider fails **closed** rather than
  falling back to `:google_free`, so a typo cannot send text to a provider the
  caller did not select.
  """
  @spec impl() :: module()
  def impl do
    provider =
      :ashiato
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:provider, :google_free)

    case resolve(provider) do
      {:ok, module} ->
        module

      :error ->
        Logger.warning(
          "Unknown translation provider #{inspect(provider)}; translation disabled until it is fixed"
        )

        Ashiato.Translator.Off
    end
  end

  @spec resolve(term()) :: {:ok, module()} | :error
  defp resolve(provider) when is_atom(provider) do
    case Atom.to_string(provider) do
      # a module atom was configured directly, which is how tests point at a fake
      "Elixir." <> _ -> {:ok, provider}
      name -> resolve(name)
    end
  end

  defp resolve(provider) when is_binary(provider), do: Map.fetch(@providers, provider)
  defp resolve(_provider), do: :error

  @doc """
  Translates a page through `impl/0`.

  Refused providers enter a 300 s cool-down keyed by provider module.
  """
  @spec translate_page([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def translate_page(lines, opts), do: impl().translate_page(lines, opts)

  @doc false
  @spec run_provider(
          module(),
          [String.t()],
          keyword(),
          ([String.t()], keyword() -> {:ok, [String.t()]} | {:error, term()})
        ) :: {:ok, [String.t()]} | {:error, term()}
  def run_provider(provider, lines, opts, page_request) do
    case check_cooldown(provider) do
      nil ->
        case page_with_fallback(lines, opts, page_request) do
          {:error, {:http, status}} = error when status in [403, 429] or status >= 500 ->
            record_cooldown(provider)
            error

          other ->
            other
        end

      remaining ->
        {:error, {:cooldown, max(1, remaining)}}
    end
  end

  @doc """
  Erases only this module's cooldown keys from `:persistent_term`.

  Use in tests and after a manual retry to clear stale cooldowns.
  """
  @spec clear_cooldowns() :: :ok
  def clear_cooldowns() do
    for {{__MODULE__, :cooldown, _provider} = key, _expiry} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ok
  end

  # ——————————————————————————————————————————————————————————— private ——————

  @cooldown_secs 300

  defp check_cooldown(provider) do
    key = cooldown_key(provider)

    case :persistent_term.get(key, nil) do
      nil ->
        nil

      expiry_mono ->
        diff = System.monotonic_time(:millisecond) - expiry_mono
        if diff < 0, do: div(-diff + 999, 1000), else: nil
    end
  end

  defp record_cooldown(provider) do
    expiry = System.monotonic_time(:millisecond) + @cooldown_secs * 1000
    :persistent_term.put(cooldown_key(provider), expiry)
  end

  defp cooldown_key(provider), do: {__MODULE__, :cooldown, provider}

  @doc """
  The shared page→per-line rule: accept a page reply only when it is line-aligned.
  A reply with a different line count, or one that cannot be interpreted
  (`:unparsable`), is retried as one request per line. Any other error is returned
  as-is — in particular `:not_configured` never triggers per-line traffic.
  """
  @spec page_with_fallback(
          [String.t()],
          keyword(),
          ([String.t()], keyword() -> {:ok, [String.t()]} | {:error, term()})
        ) :: {:ok, [String.t()]} | {:error, term()}
  def page_with_fallback([], _opts, _page_request), do: {:ok, []}

  def page_with_fallback(lines, opts, page_request) do
    case page_request.(lines, opts) do
      {:ok, translated} when length(translated) == length(lines) ->
        {:ok, translated}

      {:ok, _misaligned} ->
        per_line(lines, opts, page_request)

      {:error, :unparsable} ->
        per_line(lines, opts, page_request)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp per_line(lines, opts, page_request) do
    result =
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case page_request.([line], opts) do
          {:ok, [translated]} -> {:cont, {:ok, [translated | acc]}}
          {:ok, _misaligned} -> {:halt, {:error, :misaligned_line}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Posts to `url` through `Ashiato.HTTP`. A non-200 reply returns its status only
  and discards the body. `:decode` in `req_opts` receives the 200 body.
  """
  @spec http_post(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def http_post(url, req_opts) do
    req_opts = put_test_plug(req_opts)

    case Keyword.pop(req_opts, :decode) do
      {nil, _opts} ->
        {:error, :no_decoder}

      {decode, opts} ->
        case Ashiato.HTTP.post(url, opts) do
          {:ok, body} ->
            decode.(body)

          # Ashiato.HTTP discards the exception's `data` (the reply text); keeping
          # only the atom here preserves that guarantee.
          {:error, :invalid_json} ->
            {:error, :unparsable}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp put_test_plug(req_opts) do
    case Application.get_env(:ashiato, __MODULE__, [])[:plug] do
      nil -> req_opts
      plug -> Keyword.put_new(req_opts, :plug, plug)
    end
  end

  @doc false
  @spec langs(keyword()) :: {:ok, {String.t(), String.t()}} | {:error, :missing_target_lang}
  def langs(opts) do
    case Keyword.get(opts, :target_lang) do
      target when is_binary(target) and target != "" ->
        source =
          case Keyword.get(opts, :source_lang) do
            sl when is_binary(sl) and sl != "" -> sl
            _ -> "auto"
          end

        {:ok, {source, target}}

      # nil and "" would be encoded as null and come back as an opaque HTTP 400
      _absent_or_empty ->
        {:error, :missing_target_lang}
    end
  end

  @doc false
  @spec configured?(term()) :: boolean()
  def configured?(value), do: is_binary(value) and value != ""
end
