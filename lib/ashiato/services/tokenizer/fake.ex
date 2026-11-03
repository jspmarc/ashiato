defmodule Ashiato.Tokenizer.Fake do
  @behaviour Ashiato.Tokenizer

  use Agent

  @moduledoc """
  Test double for `Ashiato.Tokenizer` — no test ever calls the real service.

  State lives in an Agent started by the test with `start_supervised!/1` rather than in
  application env, which is global to the VM and shared by six parallel wave-2 cards.
  """

  @doc """
  Starts the fake.

  ## Options

    * `:tokens` — canned `t:Ashiato.Tokenizer.token/1` maps returned verbatim by `tokenize/1`
      (default `[]`)
    * `:error` — when set, `tokenize/1` returns `{:error, reason}` with it instead of the canned
      tokens
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    state = %{
      tokens: Keyword.get(opts, :tokens, []),
      error: Keyword.get(opts, :error),
      calls: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @impl true
  @spec tokenize(String.t()) :: {:ok, [Ashiato.Tokenizer.token()]} | {:error, term()}
  def tokenize(text) do
    Agent.get_and_update(__MODULE__, fn state ->
      reply =
        case state.error do
          nil -> {:ok, state.tokens}
          reason -> {:error, reason}
        end

      {reply, %{state | calls: state.calls ++ [text]}}
    end)
  end

  @doc """
  Every input `tokenize/1` was asked to tokenize, oldest first.
  """
  @spec calls() :: [String.t()]
  def calls, do: Agent.get(__MODULE__, & &1.calls)
end
