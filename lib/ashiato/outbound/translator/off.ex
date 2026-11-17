defmodule Ashiato.Translator.Off do
  @moduledoc """
  Translation disabled. Returns `{:error, :disabled}` for every request so callers
  can distinguish "off" from a missing provider.
  """

  @behaviour Ashiato.Translator

  @doc """
  Always `"off"` — the cache label for translation disabled.
  """
  @impl Ashiato.Translator
  @spec provider_name() :: String.t()
  def provider_name, do: "off"

  @doc """
  Always `{:error, :disabled}` — callers treat it as the translation-is-off signal,
  not a failure.
  """
  @impl Ashiato.Translator
  @spec translate_page([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def translate_page(_lines, _opts), do: {:error, :disabled}
end
