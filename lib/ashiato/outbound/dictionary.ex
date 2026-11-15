defmodule Ashiato.Dictionary do
  @moduledoc """
  Dictionary service behind a behaviour.

  The configured service is returned by `impl/0`, from
  `Application.get_env(:ashiato, Ashiato.Dictionary, [])[:impl]`, default
  `Ashiato.Dictionary.Http`. Callers depend on the behaviour, not a concrete
  module: `Http` talks to the HTTP API, and `Fake` serves canned entries in
  tests.

  Callbacks are the raw service calls: `lookup/1`, `lookup_many/1`, and
  `dict_version/0`. This module holds no persistence: the version-keyed cache,
  validation, and pruning live one layer up, in the dictionary context.
  """

  @type entry :: map()

  @callback lookup(term :: String.t()) :: {:ok, entry()} | {:error, term()}
  @callback lookup_many(terms :: [String.t()]) ::
              {:ok, %{String.t() => entry()}} | {:error, term()}
  @callback dict_version() :: {:ok, String.t()} | {:error, term()}

  @doc """
  The configured service module. Callers depend on this indirection rather than
  on a concrete module.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ashiato, __MODULE__, [])[:impl] || Ashiato.Dictionary.Http
  end
end
