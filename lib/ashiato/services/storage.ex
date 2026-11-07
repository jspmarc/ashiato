defmodule Ashiato.Storage do
  @moduledoc """
  Behaviour for binary object storage (page images, line crops).

  D29: the app and the OCR service must not assume they share a filesystem, so
  all access goes through this behaviour and is swappable by config. A key is
  an **object key**, never a filesystem path — `Ashiato.Schemas.Page.image_key`
  stores exactly such a key. The validation here is the only defence between
  an OCR-supplied locator and the filesystem, so it rejects anything that could
  resolve outside the store's root rather than sanitising it.
  """

  @callback put(key :: String.t(), binary()) :: :ok | {:error, term()}
  @callback get(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback presigned_get(key :: String.t(), ttl_seconds :: pos_integer()) ::
              {:ok, String.t()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc """
  The configured implementation, so callers depend on the behaviour and never
  on a concrete module. Swapped by config (e.g. a later S3 card):

      config :ashiato, Ashiato.Storage, impl: Ashiato.Storage.S3

  Defaults to `Ashiato.Storage.Local`, matching the `local` default image store.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ashiato, __MODULE__, [])[:impl] || Ashiato.Storage.Local
  end

  @doc """
  Whether `key` is an acceptable object key.

  Rejects the empty key, anything containing `..`, a leading `/`, or a null
  byte — the shapes a path-traversal attempt takes — and callers resolve the
  remainder against the root so nothing can land outside it even if a check
  here is ever loosened.
  """
  @spec valid_key?(String.t()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) > 0 do
    not String.contains?(key, ["..", "\0"]) and not String.starts_with?(key, "/")
  end

  def valid_key?(_), do: false
end
