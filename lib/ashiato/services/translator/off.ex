defmodule Ashiato.Translator.Off do
  @moduledoc """
  Translation disabled. Exists so the `translation_provider` setting has a value
  that is not a missing key (D45).
  """

  @behaviour Ashiato.Translator

  @doc """
  Always `{:error, :disabled}` — callers treat it as the translation-is-off signal,
  not a failure.
  """
  @impl Ashiato.Translator
  @spec translate_page([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def translate_page(_lines, _opts), do: {:error, :disabled}
end
